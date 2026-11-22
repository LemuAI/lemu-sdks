import Foundation

// MARK: - HTTP

/// GET and POST with the response body (the event transport only needs a status).
protocol ExperienceHTTP {
    /// `status` is nil when no response arrived.
    func send(_ request: URLRequest, completion: @escaping (_ status: Int?, _ body: Data?) -> Void)
}

final class URLSessionExperienceHTTP: ExperienceHTTP {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest, completion: @escaping (Int?, Data?) -> Void) {
        session.dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }
}

// MARK: - Presenting

/// Puts a view model on screen. The UIKit presenter on iOS; tests use a fake.
/// Called on the main thread.
protocol ExperiencePresenter: AnyObject {
    /// Shows the model. Returns false when there is nowhere to show it (no window yet).
    func present(_ model: ExperienceViewModel) -> Bool
    /// Opens a link from a button.
    func open(_ url: URL)
}

// MARK: - Manager

/// Fetches the experiences bundle, evaluates the rules when screens change and
/// events are tracked, keeps each experience's history and shows the winner.
/// All state lives on `queue`; view models live on the main thread.
final class ExperienceManager: ExperienceViewModelHost {
    struct Dependencies {
        var writeKey: String
        var apiHost: String
        var userAgent: String
        var platform = "ios"
        var http: ExperienceHTTP
        var store: KeyValueStore
        var now: () -> Date = { Date() }
        var anonymousId: () -> String? = { nil }
        var userId: () -> String? = { nil }
        var isOptedOut: () -> Bool = { false }
        var storageAllowed: () -> Bool = { true }
        var track: (String, [String: Any]) -> Void = { _, _ in }
        var presenter: ExperiencePresenter?
        /// Runs UI work: the main queue in apps; tests run it in place.
        var ui: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
        var emit: (LemuExperienceEvent) -> Void = { _ in }
        var log: (String) -> Void = { _ in }
    }

    static let refreshInterval: TimeInterval = 5 * 60
    static let decideTTL: TimeInterval = 10 * 60

    let queue = DispatchQueue(label: "com.lemuai.experiences", qos: .userInitiated)
    private var deps: Dependencies

    private(set) var bundle: ExperienceBundle?
    private(set) var state = ExperienceVisitorState()
    private var lastFetch: Date?
    private var fetching = false
    private var pendingShow: String?
    private var enabled = true
    private var stopped = false
    private var current: ExperienceViewModel?
    private var currentScreen = ""
    private var productSku: String?
    private var popupsThisScreen = 0
    private var screenGeneration = 0
    private var decisions: [String: (at: Date, decision: ExperienceDecision)] = [:]
    /// Lifecycle observers (UIKit), kept alive with the manager.
    var observers: AnyObject?

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    // MARK: Called by the SDK (any thread)

    func start() {
        queue.async {
            self.state = ExperienceVisitorState.decode(self.deps.store.string(forKey: ExperienceVisitorState.storeKey))
            self.state.touch(now: self.nowMillis)
            self.persist()
            self.fetchConfig()
        }
    }

    func shutdown() {
        queue.async { self.stopped = true }
    }

    func appForegrounded() {
        queue.async {
            guard !self.stopped else { return }
            self.state.touch(now: self.nowMillis)
            self.persist()
            if let last = self.lastFetch, self.deps.now().timeIntervalSince(last) < ExperienceManager.refreshInterval { return }
            self.fetchConfig()
        }
    }

    func appBackgrounded() {
        queue.async {
            self.state.last = self.nowMillis
            self.persist()
        }
    }

    func didScreen(_ name: String, properties: [String: Any]?) {
        let sku = ExperienceManager.sku(from: properties)
        queue.async {
            guard !self.stopped else { return }
            self.currentScreen = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.productSku = sku
            self.popupsThisScreen = 0
            self.screenGeneration += 1
            if self.bundle != nil { self.evaluateScreen() }
        }
    }

    func didTrack(_ event: String, properties: [String: Any]?) {
        if event.hasPrefix("onsite_") { return }
        let sku = ExperienceRules.sameEvent("ViewContent", event) ? ExperienceManager.sku(from: properties) : nil
        queue.async {
            guard !self.stopped else { return }
            if let sku = sku { self.productSku = sku }
            guard let bundle = self.bundle else { return }
            let matching = bundle.experiences.filter { ExperienceRules.sameEvent($0.triggerEventName, event) }
            if !matching.isEmpty { self.autoShow(matching, generation: nil) }
        }
    }

    // MARK: Public API (any thread)

    func show(_ key: String) -> Bool {
        return queue.sync {
            guard !stopped else { return false }
            guard let bundle = bundle else {
                pendingShow = key
                return false
            }
            guard let exp = bundle.experiences.first(where: { $0.key == key }) else { return false }
            return attemptShow(exp)
        }
    }

    func hide() {
        let model: ExperienceViewModel? = queue.sync { current }
        guard let m = model else { return }
        deps.ui { m.close(byUser: false) }
    }

    func setEnabled(_ on: Bool) {
        queue.sync { enabled = on }
    }

    var isEnabled: Bool {
        return queue.sync { enabled }
    }

    func refresh() {
        queue.async { self.fetchConfig() }
    }

    /// Tests: waits for queued work.
    func waitForQueue() {
        queue.sync {}
    }

    // MARK: Fetching

    private var nowMillis: Int64 {
        return Int64((deps.now().timeIntervalSince1970 * 1000).rounded())
    }

    private var host: String {
        var h = deps.apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        return h.isEmpty ? LemuOptions.defaultAPIHost : h
    }

    private func request(_ path: String, body: JSONObject? = nil) -> URLRequest? {
        guard let url = URL(string: host + path) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(deps.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func fetchConfig() {
        guard !stopped, !fetching, !deps.isOptedOut() else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let key = deps.writeKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? deps.writeKey
        guard let r = request("/api/v1/pixel/onsite/config?k=" + key) else { return }
        fetching = true
        deps.log("experiences: loading config")
        deps.http.send(r) { [weak self] status, data in
            guard let self = self else { return }
            self.queue.async {
                self.fetching = false
                guard !self.stopped else { return }
                guard status == 200, let parsed = ExperienceBundle.parse(data) else {
                    self.deps.log("experiences: config failed (\(status.map(String.init) ?? "no response"))")
                    return
                }
                let first = self.bundle == nil
                self.bundle = parsed
                self.lastFetch = self.deps.now()
                self.deps.log("experiences: \(parsed.experiences.count) for this app")
                if let key = self.pendingShow {
                    self.pendingShow = nil
                    if let exp = parsed.experiences.first(where: { $0.key == key }) { _ = self.attemptShow(exp) }
                }
                if first { self.evaluateScreen() }
            }
        }
    }

    private var decisionKey: String {
        return currentScreen + "|" + (productSku ?? "")
    }

    private func freshDecision() -> ExperienceDecision? {
        guard let cached = decisions[decisionKey], deps.now().timeIntervalSince(cached.at) < ExperienceManager.decideTTL else { return nil }
        return cached.decision
    }

    /// Asks the server about the experiences whose targeting needs Lemu's data, then calls `then` on the queue.
    private func withDecision(_ needed: Bool, then: @escaping () -> Void) {
        guard needed, bundle?.decide == true, freshDecision() == nil, !deps.isOptedOut() else { return then() }
        let key = decisionKey
        let body: JSONObject = [
            "writeKey": deps.writeKey,
            "anonymousId": deps.anonymousId() ?? NSNull(),
            "userId": deps.userId() ?? NSNull(),
            "context": ["screen": currentScreen, "product": productSku.map { ["sku": $0] } ?? [:]] as JSONObject,
        ]
        guard let r = request("/api/v1/pixel/onsite/decide", body: body) else { return then() }
        deps.http.send(r) { [weak self] status, data in
            guard let self = self else { return }
            self.queue.async {
                if status == 200, let decision = ExperienceDecision.parse(data) {
                    self.decisions[key] = (self.deps.now(), decision)
                }
                then()
            }
        }
    }

    // MARK: Rules

    private func evaluateScreen() {
        guard let bundle = bundle else { return }
        let generation = screenGeneration
        let onLoad = bundle.experiences.filter { $0.trigger == "page_load" }
        if !onLoad.isEmpty { autoShow(onLoad, generation: generation) }
        for exp in bundle.experiences where exp.trigger == "delay" {
            queue.asyncAfter(deadline: .now() + max(0, exp.triggerSeconds)) { [weak self] in
                guard let self = self, self.screenGeneration == generation else { return }
                self.autoShow([exp], generation: generation)
            }
        }
    }

    /// Shows the first of `list` that qualifies now (bundle order is priority order).
    private func autoShow(_ list: [Experience], generation: Int?) {
        guard enabled, current == nil, !stopped else { return }
        let local = list.filter { locallyEligible($0) }
        guard !local.isEmpty else { return }
        withDecision(local.contains { $0.needsServer }) { [weak self] in
            guard let self = self else { return }
            if let g = generation, g != self.screenGeneration { return }
            let decision = self.freshDecision()
            for exp in local {
                guard self.enabled, self.current == nil, self.locallyEligible(exp) else { continue }
                guard ExperienceRules.whoMatches(exp, decision: decision, userId: self.deps.userId(), visits: self.state.visits) else { continue }
                if self.attemptShow(exp) { break }
            }
        }
    }

    private func locallyEligible(_ exp: Experience) -> Bool {
        guard ExperienceRules.scheduleOpen(exp.schedule, now: deps.now()) else { return false }
        guard ExperienceRules.whereMatches(exp, screen: currentScreen) else { return false }
        guard ExperienceRules.frequencyAllows(exp, seen: state.seenFor(exp.key), session: state.session, now: nowMillis) else { return false }
        return capsAllow(exp)
    }

    private func capsAllow(_ exp: Experience) -> Bool {
        guard overlayExperienceFormats.contains(exp.format) else { return true }
        let caps = bundle?.caps ?? [:]
        if let perPage = jsonNumber(caps["popups_per_page"]), Double(popupsThisScreen) >= perPage { return false }
        if let perSession = jsonNumber(caps["popups_per_session"]), Double(state.popupsThisSession) >= perSession { return false }
        return true
    }

    private func baseProperties(_ exp: Experience, variant: String) -> [String: Any] {
        return [
            "experience_id": exp.id,
            "experience": exp.key,
            "variant": variant,
            "version": exp.version,
            "format": exp.format,
            "screen": currentScreen,
        ]
    }

    /// Assigns the variant and shows it. False for held-out visitors and when nothing can show.
    private func attemptShow(_ exp: Experience) -> Bool {
        guard !stopped, current == nil, !deps.isOptedOut(), let presenter = deps.presenter, let bundle = bundle else { return false }
        var seen = state.seenFor(exp.key)
        let visitor = deps.anonymousId() ?? state.session
        let key = ExperienceRules.assign(exp, visitorId: visitor, seen: &seen)
        state.seen[exp.key] = seen
        if key == "holdout" {
            if seen.sessionShown != state.session {
                seen.sessionShown = state.session
                state.seen[exp.key] = seen
                deps.track("onsite_held_out", baseProperties(exp, variant: "holdout"))
            }
            persist()
            return false
        }
        guard let variant = exp.variants.first(where: { $0.key == key }) ?? exp.variants.first,
              variant.kind == "blocks", !variant.steps.isEmpty
        else {
            persist()
            return false
        }
        let now = nowMillis
        seen.n += 1
        seen.last = now
        seen.sessionShown = state.session
        state.seen[exp.key] = seen
        state.last = now
        if overlayExperienceFormats.contains(exp.format) {
            state.popupsThisSession += 1
            popupsThisScreen += 1
        }
        persist()
        let model = ExperienceViewModel(experience: exp, variant: variant, theme: ExperienceTheme(theme: bundle.theme, style: variant.style))
        model.host = self
        current = model
        deps.track("onsite_viewed", baseProperties(exp, variant: variant.key))
        deps.log("experiences: showing \(exp.key) (\(variant.key))")
        let event = LemuExperienceEvent(type: .shown, experience: exp.key, variant: variant.key)
        deps.ui { [weak self] in
            guard let self = self else { return }
            if presenter.present(model) {
                self.deps.emit(event)
            } else {
                self.queue.async { if self.current === model { self.current = nil } }
            }
        }
        return true
    }

    private func persist() {
        guard deps.storageAllowed(), let text = state.encoded() else { return }
        deps.store.set(text, forKey: ExperienceVisitorState.storeKey)
    }

    static func sku(from properties: [String: Any]?) -> String? {
        guard let p = properties else { return nil }
        if let ids = p["content_ids"] as? [Any], let first = ids.first {
            let s = ExperienceRules.text(first)
            if !s.isEmpty { return s }
        }
        for key in ["sku", "content_id"] {
            if let v = p[key], !(v is NSNull) {
                let s = ExperienceRules.text(v)
                if !s.isEmpty { return s }
            }
        }
        return nil
    }

    // MARK: ExperienceViewModelHost (main thread)

    func viewModel(_ model: ExperienceViewModel, closedByUser byUser: Bool) {
        let exp = model.experience
        let variant = model.variant.key
        queue.async {
            if byUser {
                var seen = self.state.seenFor(exp.key)
                seen.closes += 1
                seen.lastClose = self.nowMillis
                self.state.seen[exp.key] = seen
                self.persist()
                self.deps.track("onsite_closed", self.baseProperties(exp, variant: variant))
            }
            if self.current === model { self.current = nil }
        }
        let event = LemuExperienceEvent(type: .closed, experience: exp.key, variant: variant)
        event.byUser = byUser
        deps.emit(event)
    }

    func viewModel(_ model: ExperienceViewModel, clicked target: String) {
        let exp = model.experience
        let variant = model.variant.key
        queue.async {
            var props = self.baseProperties(exp, variant: variant)
            props["target"] = target
            self.deps.track("onsite_clicked", props)
        }
        let event = LemuExperienceEvent(type: .clicked, experience: exp.key, variant: variant)
        event.target = target
        deps.emit(event)
    }

    func viewModel(_ model: ExperienceViewModel, open url: URL) {
        deps.presenter?.open(url)
    }

    func viewModel(_ model: ExperienceViewModel, submitted fields: JSONObject, offer: JSONObject?) {
        let key = model.experience.key
        queue.async {
            var seen = self.state.seenFor(key)
            seen.submitted = self.nowMillis
            self.state.seen[key] = seen
            self.persist()
        }
        let event = LemuExperienceEvent(type: .submitted, experience: key, variant: model.variant.key)
        event.fields = fields
        event.offerCode = jsonString(offer?["code"]).flatMap { $0.isEmpty ? nil : $0 }
        deps.emit(event)
    }

    func viewModel(
        _ model: ExperienceViewModel,
        send fields: JSONObject,
        otp: String?,
        phoneCountry: String,
        completion: @escaping (ExperienceSubmitResult) -> Void
    ) {
        let exp = model.experience
        let variant = model.variant.key
        queue.async {
            var body: JSONObject = [
                "writeKey": self.deps.writeKey,
                "experience": exp.key,
                "variant": variant,
                "anonymousId": self.deps.anonymousId() ?? NSNull(),
                "userId": self.deps.userId() ?? NSNull(),
                "fields": fields,
                "context": ["screen": self.currentScreen, "platform": self.deps.platform, "phone_country": phoneCountry] as JSONObject,
            ]
            if let otp = otp { body["otp"] = otp }
            guard JSONSerialization.isValidJSONObject(body), let r = self.request("/api/v1/pixel/onsite/submit", body: body) else {
                self.deps.ui { completion(ExperienceSubmitResult(status: nil, json: nil)) }
                return
            }
            self.deps.http.send(r) { status, data in
                let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSONObject }
                self.deps.ui { completion(ExperienceSubmitResult(status: status, json: json)) }
            }
        }
    }
}
