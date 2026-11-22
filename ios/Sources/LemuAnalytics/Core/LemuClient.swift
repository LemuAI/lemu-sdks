import Foundation

/// Settings the client runs with. Built from `LemuOptions`; tests change the
/// timing fields.
struct LemuConfiguration {
    var writeKey: String
    var apiHost: String = LemuOptions.defaultAPIHost
    var debug = false
    var requireConsent = false
    var flushAt = 20
    var flushInterval: TimeInterval = 30
    var maxQueueSize = 1000
    var trackLifecycle = true
    var trackDeepLinks = true
    var inAppMessages = true

    // Protocol values (spec/protocol.md).
    var maxBatchSize = 50
    var maxHeldMessages = 50
    var maxRequestBytes = 250_000
    var retryBaseDelay: TimeInterval = 1
    var retryMaxDelay: TimeInterval = 300
    var retryGiveUpAfter: TimeInterval = 20 * 3600
    var maxMessageAge: TimeInterval = 7 * 24 * 3600

    init(writeKey: String) {
        self.writeKey = writeKey
    }

    init(writeKey: String, options: LemuOptions) {
        self.writeKey = writeKey
        let host = options.apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        apiHost = host.isEmpty ? LemuOptions.defaultAPIHost : host
        debug = options.debug
        requireConsent = options.requireConsent
        flushAt = max(1, options.flushAt)
        flushInterval = max(0, options.flushInterval)
        maxQueueSize = max(1, options.maxQueueSize)
        trackLifecycle = options.trackLifecycle
        trackDeepLinks = options.trackDeepLinks
        inAppMessages = options.inAppMessages
    }

    var endpoint: URL {
        var host = apiHost
        while host.hasSuffix("/") { host.removeLast() }
        return URL(string: host + "/api/v1/pixel/batch")
            ?? URL(string: LemuOptions.defaultAPIHost + "/api/v1/pixel/batch")!
    }
}

/// What the client talks to: clock, network, storage, device. Tests swap these.
struct LemuEnvironment {
    var clock: LemuClock = SystemClock()
    var transport: LemuTransport = URLSessionTransport()
    var store: KeyValueStore = UserDefaultsStore()
    var directory: URL = PersistentQueue.defaultDirectory()
    var app: AppInfo = .current()
    var device: DeviceInfo = .current()
    var logSink: ((String) -> Void)?
    /// In-app messages: config, decide and submit requests, and where they show.
    var experienceHTTP: ExperienceHTTP = URLSessionExperienceHTTP()
    var experiencePresenter: ExperiencePresenter?
}

/// The tracking engine. Every piece of state is touched only on `queue`, a
/// serial queue, so the public API can be called from any thread.
final class LemuClient {
    let config: LemuConfiguration
    let queue = DispatchQueue(label: "com.lemuai.analytics", qos: .utility)
    let logger: LemuLogger

    private let clock: LemuClock
    private let transport: LemuTransport
    private let store: KeyValueStore
    private let persistentQueue: PersistentQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    // Identity
    private var anonymousIdValue = ""
    private var userId: String?

    // Context
    private var baseContext: [String: JSONValue]
    private var campaign: [String: JSONValue] = [:]
    private var pendingOpenURL: String?

    // Privacy
    private var optedOut = false
    private var storedConsent: String?
    private var sessionConsent: Bool?
    /// Messages kept in memory while consent is pending.
    private var held: [QueuedMessage] = []
    /// Storage writes made while storage isn't allowed yet. A nil value removes the key.
    private var pendingWrites: [String: String?] = [:]
    private var loadedFromDisk = false

    // Sending
    private var sending = false
    private var pendingBatches: [[String]] = []
    private var retryAttempt = 0
    private var nextRetryAt: Date?
    private var retryWork: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var idleCallbacks: [() -> Void] = []
    private var stopped = false

    init(config: LemuConfiguration, environment: LemuEnvironment = LemuEnvironment()) {
        self.config = config
        clock = environment.clock
        transport = environment.transport
        store = environment.store
        logger = LemuLogger(enabled: config.debug)
        logger.sink = environment.logSink
        baseContext = LemuContextBuilder.base(app: environment.app, device: environment.device)
        persistentQueue = PersistentQueue(
            fileURL: environment.directory.appendingPathComponent(PersistentQueue.fileName(writeKey: config.writeKey)),
            logger: logger
        )
        queue.setSpecific(key: queueKey, value: 1)
        queue.async { [weak self] in self?.start() }
    }

    // MARK: - Start and stop

    private func start() {
        optedOut = store.string(forKey: StoreKey.optOut) == "1"
        storedConsent = store.string(forKey: StoreKey.consent)
        if let existing = read(StoreKey.anonymousId), !existing.isEmpty, existing.count <= 128 {
            anonymousIdValue = existing
        } else {
            anonymousIdValue = LemuClient.newId()
            write(StoreKey.anonymousId, anonymousIdValue)
        }
        userId = read(StoreKey.userId)
        if storageAllowed { loadQueue() }
        if optedOut, !persistentQueue.items.isEmpty { persistentQueue.removeAll() }
        startTimer()
        logger.debug("ready: writeKey \(config.writeKey), apiHost \(config.apiHost), anonymousId \(anonymousIdValue), consent \(consentState), optedOut \(optedOut), queued \(persistentQueue.count)")
        if consentState == .granted, !optedOut, persistentQueue.count >= config.flushAt {
            drain(force: false)
        }
    }

    /// Stops timers and retries. Used by tests and when `setup` replaces a client.
    func shutdown() {
        onQueue {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.retryWork?.cancel()
            self.retryWork = nil
            self.notifyIdle()
        }
    }

    private func startTimer() {
        guard config.flushInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = config.flushInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(min(interval, 5) * 100)))
        timer.setEventHandler { [weak self] in self?.drain(force: false) }
        timer.resume()
        self.timer = timer
    }

    private func loadQueue() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        persistentQueue.load()
        let expired = persistentQueue.removeOlderThan(clock.now().addingTimeInterval(-config.maxMessageAge))
        if expired > 0 { logger.debug("dropped \(expired) message(s) older than 7 days") }
        persistentQueue.enforceLimit(config.maxQueueSize)
    }

    // MARK: - Public calls (any thread)

    var anonymousId: String {
        return onQueueSync { anonymousIdValue }
    }

    var currentUserId: String? {
        return onQueueSync { userId }
    }

    var isOptedOut: Bool {
        return onQueueSync { optedOut }
    }

    /// False while `requireConsent` waits for an answer (or consent was refused):
    /// in-app message history then stays in memory.
    var isStorageAllowed: Bool {
        return onQueueSync { storageAllowed && consentState == .granted }
    }

    func track(_ event: String, properties: [String: Any]?) {
        let timestamp = clock.now()
        let name = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            logger.debug("track ignored: the event name is empty")
            return
        }
        let props = JSONValue.properties(properties)
        queue.async { [weak self] in
            self?.trackOnQueue(name, properties: props, timestamp: timestamp)
        }
    }

    func screen(_ name: String, properties: [String: Any]?) {
        let timestamp = clock.now()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.debug("screen ignored: the screen name is empty")
            return
        }
        let props = JSONValue.properties(properties)
        queue.async { [weak self] in
            self?.logger.debug("screen \(trimmed)")
            self?.enqueue(type: "screen", fields: ["name": .string(trimmed), "properties": .object(props)], timestamp: timestamp)
        }
    }

    func identify(userId newUserId: String?, traits: [String: Any]?) {
        let timestamp = clock.now()
        let traitValues = JSONValue.properties(traits)
        var cleanUserId = newUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = cleanUserId, candidate.isEmpty { cleanUserId = nil }
        if let candidate = cleanUserId, candidate.count > 255 {
            logger.debug("identify: userId longer than 255 characters ignored")
            cleanUserId = nil
        }
        guard cleanUserId != nil || !traitValues.isEmpty else {
            logger.debug("identify ignored: no userId and no traits")
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.optedOut {
                self.logger.debug("identify ignored: opted out")
                return
            }
            if self.consentState == .denied {
                self.logger.debug("identify ignored: consent refused")
                return
            }
            if let id = cleanUserId, id != self.userId {
                self.userId = id
                self.write(StoreKey.userId, id)
            }
            self.logger.debug("identify userId \(self.userId ?? "nil")")
            self.enqueue(type: "identify", fields: ["traits": .object(traitValues)], timestamp: timestamp)
        }
    }

    func purchase(
        value: Double,
        currency: String,
        orderId: String,
        contents: [LemuContent]?,
        contentIds: [String]?,
        numItems: Int?,
        properties: [String: Any]?
    ) {
        guard value.isFinite else {
            logger.debug("purchase ignored: value is not a finite number")
            return
        }
        var props = JSONValue.properties(properties)
        let currencyCode = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let order = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        if currencyCode.isEmpty { logger.debug("purchase: currency is empty; Lemu needs it to count revenue") }
        if order.isEmpty { logger.debug("purchase: orderId is empty; Lemu needs it to count each order once") }
        props["value"] = .double(value)
        props["currency"] = .string(currencyCode)
        props["order_id"] = .string(order)
        if let contents = contents, !contents.isEmpty {
            props["contents"] = .array(contents.map { $0.jsonValue })
        }
        if let ids = contentIds, !ids.isEmpty {
            props["content_ids"] = .array(ids.map { .string($0) })
        } else if let contents = contents, !contents.isEmpty {
            props["content_ids"] = .array(contents.map { .string($0.id) })
        }
        if let count = numItems {
            props["num_items"] = .int(Int64(count))
        } else if let contents = contents, !contents.isEmpty {
            props["num_items"] = .int(Int64(contents.reduce(0) { $0 + max(0, $1.quantity) }))
        }
        let timestamp = clock.now()
        queue.async { [weak self] in
            self?.trackOnQueue(LemuEvent.purchase, properties: props, timestamp: timestamp)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.anonymousIdValue = LemuClient.newId()
            self.userId = nil
            self.write(StoreKey.anonymousId, self.anonymousIdValue)
            self.write(StoreKey.userId, nil)
            self.logger.debug("reset: new anonymousId \(self.anonymousIdValue)")
        }
    }

    /// Sends everything queued now. `completion` runs (on the SDK's queue) when
    /// the queue is empty, a retry is scheduled, or there is nothing to send.
    func flush(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if let completion = completion { self.idleCallbacks.append(completion) }
            self.logger.debug("flush")
            self.drain(force: true)
        }
    }

    func setConsent(_ granted: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessionConsent = granted
            if granted {
                self.storedConsent = "1"
                self.store.set("1", forKey: StoreKey.consent)
                self.applyPendingWrites()
                self.loadQueue()
                let heldCount = self.held.count
                for item in self.held where !self.optedOut {
                    self.persistentQueue.append(item)
                }
                self.held.removeAll()
                self.persistentQueue.enforceLimit(self.config.maxQueueSize)
                self.logger.debug("consent granted; \(heldCount) held message(s) queued")
                if heldCount > 0 { self.drain(force: true) }
            } else {
                let discarded = self.held.count
                self.held.removeAll()
                self.discardQueue()
                if self.config.requireConsent {
                    self.storedConsent = nil
                    self.store.set(nil, forKey: StoreKey.consent)
                } else {
                    self.storedConsent = "0"
                    self.store.set("0", forKey: StoreKey.consent)
                }
                self.logger.debug("consent refused; \(discarded) held message(s) discarded, queue cleared")
            }
        }
    }

    func optOut() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.optedOut = true
            self.store.set("1", forKey: StoreKey.optOut)
            self.held.removeAll()
            self.discardQueue()
            self.logger.debug("opted out; queue cleared")
        }
    }

    func optIn() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.optedOut = false
            self.store.set(nil, forKey: StoreKey.optOut)
            self.logger.debug("opted in")
        }
    }

    // MARK: - Lifecycle and deep links

    /// `app_installed` on the first launch, `app_updated` when the version or build changed.
    func trackApplicationLaunch(app: AppInfo) {
        let timestamp = clock.now()
        queue.async { [weak self] in
            guard let self = self else { return }
            let previousVersion = self.read(StoreKey.appVersion)
            let previousBuild = self.read(StoreKey.appBuild)
            let version = app.version ?? ""
            let build = app.build ?? ""
            if previousVersion == nil, previousBuild == nil {
                self.trackOnQueue(LemuEvent.appInstalled, properties: [
                    "version": .string(version), "build": .string(build),
                ], timestamp: timestamp)
            } else if previousVersion != version || previousBuild != build {
                self.trackOnQueue(LemuEvent.appUpdated, properties: [
                    "version": .string(version), "build": .string(build),
                    "previous_version": .string(previousVersion ?? ""),
                    "previous_build": .string(previousBuild ?? ""),
                ], timestamp: timestamp)
            }
            self.write(StoreKey.appVersion, version)
            self.write(StoreKey.appBuild, build)
        }
    }

    func trackApplicationOpened(fromBackground: Bool) {
        let timestamp = clock.now()
        queue.async { [weak self] in
            guard let self = self else { return }
            var props: [String: JSONValue] = ["from_background": .bool(fromBackground)]
            if let url = self.pendingOpenURL { props["url"] = .string(url) }
            self.pendingOpenURL = nil
            self.trackOnQueue(LemuEvent.appOpened, properties: props, timestamp: timestamp)
        }
    }

    func trackApplicationBackgrounded() {
        let timestamp = clock.now()
        queue.async { [weak self] in
            self?.trackOnQueue(LemuEvent.appBackgrounded, properties: [:], timestamp: timestamp)
        }
    }

    /// Records the link that opened the app. UTM parameters (and gclid,
    /// fbclid) go into `context.campaign` for this and later messages.
    func trackDeepLink(_ url: URL, referrer: String?) {
        let timestamp = clock.now()
        let found = LemuClient.campaign(from: url)
        let urlString = url.absoluteString
        queue.async { [weak self] in
            guard let self = self else { return }
            if !found.isEmpty { self.campaign = found }
            self.pendingOpenURL = urlString
            guard self.config.trackDeepLinks else {
                self.logger.debug("deep link \(urlString) (event off: trackDeepLinks is false)")
                return
            }
            var props: [String: JSONValue] = ["url": .string(urlString)]
            if let referrer = referrer, !referrer.isEmpty { props["referrer"] = .string(referrer) }
            self.trackOnQueue(LemuEvent.deepLinkOpened, properties: props, timestamp: timestamp)
        }
    }

    static func campaign(from url: URL) -> [String: JSONValue] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        let keys: [String: String] = [
            "utm_source": "source", "utm_medium": "medium", "utm_campaign": "campaign",
            "utm_term": "term", "utm_content": "content", "gclid": "gclid", "fbclid": "fbclid",
            "lmclid": "lmclid",
        ]
        var campaign: [String: JSONValue] = [:]
        for item in items {
            guard let key = keys[item.name.lowercased()], let value = item.value, !value.isEmpty else { continue }
            campaign[key] = .string(value)
        }
        return campaign
    }

    /// Fills in the screen size once UIKit has given it (main thread).
    func setScreen(_ screen: ScreenInfo) {
        queue.async { [weak self] in
            self?.baseContext["screen"] = .object([
                "width": .double(screen.width),
                "height": .double(screen.height),
                "density": .double(screen.density),
            ])
        }
    }

    // MARK: - Queueing (on queue)

    private enum ConsentState: CustomStringConvertible {
        case granted, pending, denied
        var description: String {
            switch self {
            case .granted: return "granted"
            case .pending: return "pending"
            case .denied: return "refused"
            }
        }
    }

    private var consentState: ConsentState {
        if let session = sessionConsent { return session ? .granted : .denied }
        switch storedConsent {
        case "1": return .granted
        case "0": return .denied
        default: return config.requireConsent ? .pending : .granted
        }
    }

    /// With `requireConsent`, nothing touches the disk before consent.
    private var storageAllowed: Bool {
        return consentState == .granted || (!config.requireConsent && consentState != .pending)
    }

    private func trackOnQueue(_ event: String, properties: [String: JSONValue], timestamp: Date) {
        logger.debug("track \(event)")
        enqueue(
            type: "track",
            fields: ["event": .string(event), "properties": .object(properties)],
            timestamp: timestamp,
            isPurchase: event == LemuEvent.purchase
        )
    }

    private func enqueue(type: String, fields: [String: JSONValue], timestamp: Date, isPurchase: Bool = false) {
        guard !stopped else { return }
        if optedOut {
            logger.debug("\(type) ignored: opted out")
            return
        }
        let state = consentState
        if state == .denied {
            logger.debug("\(type) ignored: consent refused")
            return
        }

        let messageId = LemuClient.newId()
        var message = fields
        message["type"] = .string(type)
        message["messageId"] = .string(messageId)
        message["anonymousId"] = .string(anonymousIdValue)
        message["timestamp"] = .string(ISO8601.string(from: timestamp))
        if let userId = userId { message["userId"] = .string(userId) }
        var context = baseContext
        if !campaign.isEmpty { context["campaign"] = .object(campaign) }
        message["context"] = .object(context)

        let item = QueuedMessage(id: messageId, queuedAt: timestamp, isPurchase: isPurchase, firstAttemptAt: nil, message: .object(message))

        if state == .pending {
            held.append(item)
            if held.count > config.maxHeldMessages { held.removeFirst(held.count - config.maxHeldMessages) }
            logger.debug("\(type) held in memory until consent (\(held.count) held)")
            return
        }

        persistentQueue.append(item)
        let dropped = persistentQueue.enforceLimit(config.maxQueueSize)
        if dropped > 0 { logger.debug("queue full: dropped \(dropped) oldest message(s)") }

        if isPurchase || persistentQueue.count >= config.flushAt {
            drain(force: isPurchase)
        }
    }

    private func discardQueue() {
        pendingBatches.removeAll()
        persistentQueue.removeAll()
        resetRetry()
        if !sending { notifyIdle() }
    }

    // MARK: - Sending (on queue)

    private func drain(force: Bool) {
        if stopped || optedOut || consentState != .granted {
            notifyIdle()
            return
        }
        if sending { return } // the request in flight continues the drain
        if !force, let next = nextRetryAt, clock.now() < next {
            notifyIdle()
            return
        }
        let expired = persistentQueue.removeOlderThan(clock.now().addingTimeInterval(-config.maxMessageAge))
        if expired > 0 { logger.debug("dropped \(expired) message(s) older than 7 days") }

        guard let (ids, body) = nextBatch() else {
            notifyIdle()
            return
        }
        send(ids: ids, body: body)
    }

    /// The next batch to send and its encoded body, or nil when there's nothing.
    private func nextBatch() -> ([String], Data)? {
        while true {
            let candidate: [QueuedMessage]
            if !pendingBatches.isEmpty {
                let wanted = Set(pendingBatches.removeFirst())
                candidate = persistentQueue.items.filter { wanted.contains($0.id) }
                if candidate.isEmpty { continue }
            } else {
                candidate = Array(persistentQueue.items.prefix(config.maxBatchSize))
                if candidate.isEmpty { return nil }
            }
            guard let body = encodeBody(candidate) else {
                // Can't happen with JSONValue, but never loop forever.
                persistentQueue.remove(ids: Set(candidate.map { $0.id }))
                continue
            }
            if body.count > config.maxRequestBytes {
                if candidate.count > 1 {
                    let ids = candidate.map { $0.id }
                    let half = ids.count / 2
                    pendingBatches.insert(contentsOf: [Array(ids[..<half]), Array(ids[half...])], at: 0)
                } else {
                    logger.debug("dropped message \(candidate[0].id): larger than the request size limit")
                    persistentQueue.remove(ids: [candidate[0].id])
                }
                continue
            }
            return (candidate.map { $0.id }, body)
        }
    }

    private struct Body: Encodable {
        let writeKey: String
        let sentAt: String
        let batch: [JSONValue]
    }

    private func encodeBody(_ items: [QueuedMessage]) -> Data? {
        let body = Body(
            writeKey: config.writeKey,
            sentAt: ISO8601.string(from: clock.now()),
            batch: items.map { $0.message }
        )
        return JSON.encode(body)
    }

    private func send(ids: [String], body: Data) {
        sending = true
        persistentQueue.setFirstAttempt(clock.now(), ids: Set(ids))

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseContext["userAgent"]?.stringValue ?? "lemu-ios/\(LemuVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        if logger.enabled || logger.sink != nil {
            logger.debug("POST \(config.endpoint.absoluteString) (\(ids.count) message(s), \(body.count) bytes): \(String(data: body, encoding: .utf8) ?? "")")
        }
        transport.send(request) { [weak self] result in
            self?.queue.async { self?.handle(result, ids: ids) }
        }
    }

    private func handle(_ result: TransportResult, ids: [String]) {
        sending = false
        let idSet = Set(ids)
        switch result {
        case let .status(code) where (200 ..< 300).contains(code):
            logger.debug("response \(code): \(ids.count) message(s) delivered")
            persistentQueue.remove(ids: idSet)
            resetRetry()
            drain(force: false)
        case let .status(code) where code == 400 || code == 401 || code == 403:
            logger.debug("response \(code): batch of \(ids.count) dropped (\(LemuClient.reason(code)))")
            persistentQueue.remove(ids: idSet)
            drain(force: false)
        case .status(413):
            if ids.count > 1 {
                logger.debug("response 413: splitting \(ids.count) messages in two")
                let half = ids.count / 2
                pendingBatches.insert(contentsOf: [Array(ids[..<half]), Array(ids[half...])], at: 0)
            } else {
                logger.debug("response 413: message too large, dropped")
                persistentQueue.remove(ids: idSet)
            }
            drain(force: true)
        case let .status(code) where code == 408 || code == 429 || code >= 500 || code < 400:
            logger.debug("response \(code): will retry")
            scheduleRetry(ids: idSet)
        case let .status(code):
            logger.debug("response \(code): batch of \(ids.count) dropped")
            persistentQueue.remove(ids: idSet)
            drain(force: false)
        case let .failure(error):
            logger.debug("request failed: \(error.localizedDescription); will retry")
            scheduleRetry(ids: idSet)
        }
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 400: return "malformed request"
        case 401: return "unknown or paused write key"
        case 403: return "app not allowed for this write key"
        default: return "rejected"
        }
    }

    private func scheduleRetry(ids: Set<String>) {
        pendingBatches.removeAll()
        let now = clock.now()
        let firstAttempt = persistentQueue.items
            .filter { ids.contains($0.id) }
            .compactMap { $0.firstAttemptAt }
            .min() ?? now
        if now.timeIntervalSince(firstAttempt) >= config.retryGiveUpAfter {
            logger.debug("giving up on \(ids.count) message(s) after 20 hours of retries")
            persistentQueue.remove(ids: ids)
            resetRetry()
            drain(force: false)
            return
        }
        retryAttempt = min(retryAttempt + 1, 32)
        let delay = LemuClient.backoff(attempt: retryAttempt, base: config.retryBaseDelay, cap: config.retryMaxDelay)
        nextRetryAt = now.addingTimeInterval(delay)
        persistentQueue.rewrite() // keeps firstAttemptAt across restarts
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retryWork = nil
            self.drain(force: true)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        logger.debug("retry \(retryAttempt) in \(String(format: "%.1f", delay)) s")
        notifyIdle()
    }

    /// 1 s, 2 s, 4 s ... capped at 5 minutes, with plus or minus 20% jitter.
    static func backoff(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(base * pow(2, exponent), cap)
        return raw * Double.random(in: 0.8 ... 1.2)
    }

    private func resetRetry() {
        retryAttempt = 0
        nextRetryAt = nil
        retryWork?.cancel()
        retryWork = nil
    }

    private func notifyIdle() {
        guard !idleCallbacks.isEmpty else { return }
        let callbacks = idleCallbacks
        idleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    // MARK: - Storage helpers (on queue)

    private func read(_ key: String) -> String? {
        if let pending = pendingWrites[key] { return pending }
        return store.string(forKey: key)
    }

    private func write(_ key: String, _ value: String?) {
        if storageAllowed {
            store.set(value, forKey: key)
        } else {
            pendingWrites[key] = .some(value)
        }
    }

    private func applyPendingWrites() {
        for (key, value) in pendingWrites {
            store.set(value, forKey: key)
        }
        pendingWrites.removeAll()
    }

    // MARK: - Helpers

    static func newId() -> String {
        return UUID().uuidString.lowercased()
    }

    private func onQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private func onQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }

    // MARK: - Test hooks

    /// Waits until every call made so far has been processed.
    func waitForQueue() {
        onQueueSync {}
    }

    var queuedCount: Int { return onQueueSync { persistentQueue.count } }
    var heldCount: Int { return onQueueSync { held.count } }
    var queuedMessages: [QueuedMessage] { return onQueueSync { persistentQueue.items } }
}
