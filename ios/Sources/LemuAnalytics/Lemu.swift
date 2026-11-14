import Foundation

/// Lemu analytics for iOS and tvOS.
///
/// ```swift
/// Lemu.setup(writeKey: "lpk_...")
/// Lemu.track(LemuEvent.addToCart, properties: ["value": 999, "currency": "INR"])
/// Lemu.purchase(value: 1499.5, currency: "INR", orderId: "1042")
/// ```
///
/// Every method can be called from any thread, never throws, and does nothing
/// (with a log line) before `setup`.
@objc(Lemu)
public final class Lemu: NSObject {
    private static let lock = NSLock()
    private static var client: LemuClient?
    private static var warnedNotSetUp = false
    #if canImport(UIKit) && (os(iOS) || os(tvOS))
    private static var lifecycleObserver: LemuLifecycleObserver?
    #endif

    override private init() {
        super.init()
    }

    // MARK: Setup

    /// Starts the SDK. Call once, as early as possible: in
    /// `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App`'s `init()`.
    @objc(setupWithWriteKey:options:)
    public static func setup(writeKey: String, options: LemuOptions = LemuOptions()) {
        setup(writeKey: writeKey, options: options, environment: nil)
    }

    static func setup(writeKey: String, options: LemuOptions, environment: LemuEnvironment?) {
        let key = writeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let logger = LemuLogger(enabled: options.debug)
        guard !key.isEmpty else {
            logger.warning("setup ignored: the write key is empty")
            return
        }
        lock.lock()
        if client != nil {
            lock.unlock()
            logger.warning("setup ignored: Lemu is already set up")
            return
        }
        let configuration = LemuConfiguration(writeKey: key, options: options)
        let env = environment ?? LemuEnvironment()
        let newClient = LemuClient(config: configuration, environment: env)
        client = newClient
        lock.unlock()

        if configuration.trackLifecycle {
            newClient.trackApplicationLaunch(app: env.app)
        }
        #if canImport(UIKit) && (os(iOS) || os(tvOS))
        if environment == nil {
            let startObserver = {
                if let screen = DeviceInfo.mainScreen() { newClient.setScreen(screen) }
                let observer = LemuLifecycleObserver(client: newClient, trackLifecycle: configuration.trackLifecycle)
                lock.lock()
                lifecycleObserver = observer
                lock.unlock()
            }
            if Thread.isMainThread {
                startObserver()
            } else {
                DispatchQueue.main.async(execute: startObserver)
            }
        }
        #endif
    }

    /// Test hook: forgets the current client.
    static func tearDownForTesting() {
        lock.lock()
        let old = client
        client = nil
        warnedNotSetUp = false
        #if canImport(UIKit) && (os(iOS) || os(tvOS))
        lifecycleObserver = nil
        #endif
        lock.unlock()
        old?.shutdown()
    }

    static var currentClient: LemuClient? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    private static func withClient(_ call: String, _ body: (LemuClient) -> Void) {
        lock.lock()
        let current = client
        let shouldWarn = current == nil && !warnedNotSetUp
        if shouldWarn { warnedNotSetUp = true }
        lock.unlock()
        if let current = current {
            body(current)
        } else if shouldWarn {
            LemuLogger(enabled: false).warning("\(call) ignored: call Lemu.setup(writeKey:) first")
        }
    }

    // MARK: Tracking

    /// Sends a `track` event. Use `LemuEvent` constants for Meta's standard events.
    @objc(track:properties:)
    public static func track(_ event: String, properties: [String: Any]? = nil) {
        withClient("track") { $0.track(event, properties: properties) }
    }

    /// Records a screen view (`type: "screen"`).
    @objc(screen:properties:)
    public static func screen(_ name: String, properties: [String: Any]? = nil) {
        withClient("screen") { $0.screen(name, properties: properties) }
    }

    /// Tells Lemu who the user is. `userId` is your own id for the user and is
    /// sent with every later event until `reset()`. Traits: `email`, `phone`
    /// (E.164), `first_name`, `last_name`, `name`, anything else.
    @objc(identifyWithUserId:traits:)
    public static func identify(userId: String? = nil, traits: [String: Any]? = nil) {
        withClient("identify") { $0.identify(userId: userId, traits: traits) }
    }

    /// Sends `Purchase` and flushes right away. `orderId` lets Lemu count each
    /// order once, however many sources report it.
    public static func purchase(
        value: Double,
        currency: String,
        orderId: String,
        contents: [LemuContent]? = nil,
        contentIds: [String]? = nil,
        numItems: Int? = nil,
        properties: [String: Any]? = nil
    ) {
        withClient("purchase") {
            $0.purchase(
                value: value, currency: currency, orderId: orderId, contents: contents,
                contentIds: contentIds, numItems: numItems, properties: properties
            )
        }
    }

    /// Objective-C version of `purchase(value:currency:orderId:...)`.
    @available(swift, obsoleted: 1.0, message: "Use purchase(value:currency:orderId:contents:contentIds:numItems:properties:)")
    @objc(purchaseWithValue:currency:orderId:contents:properties:)
    public static func objcPurchase(
        value: Double,
        currency: String,
        orderId: String,
        contents: [LemuContent]?,
        properties: [String: Any]?
    ) {
        purchase(value: value, currency: currency, orderId: orderId, contents: contents, properties: properties)
    }

    // MARK: Deep links

    /// Call with the URL that opened the app: from `application(_:open:options:)`,
    /// `scene(_:openURLContexts:)`, `scene(_:continue:)` or SwiftUI `.onOpenURL`.
    /// Sends `deep_link_opened` and copies UTM parameters, `gclid` and `fbclid`
    /// into `context.campaign` for this and later events.
    @objc(trackDeepLink:referrer:)
    public static func trackDeepLink(_ url: URL, referrer: String? = nil) {
        withClient("trackDeepLink") { $0.trackDeepLink(url, referrer: referrer) }
    }

    // MARK: Identity, delivery and privacy

    /// Call on logout: a new anonymous id, and the user id is cleared.
    @objc public static func reset() {
        withClient("reset") { $0.reset() }
    }

    /// Sends queued events now.
    @objc public static func flush() {
        withClient("flush") { $0.flush() }
    }

    /// Sends queued events now. `completion` runs on a background queue when
    /// the queue is empty or delivery has to wait for a retry.
    public static func flush(completion: @escaping () -> Void) {
        lock.lock()
        let current = client
        lock.unlock()
        guard let current = current else {
            completion()
            return
        }
        current.flush(completion: completion)
    }

    /// With `requireConsent`, `true` starts sending (including events held
    /// since launch) and is remembered; `false` discards held and queued events.
    @objc(setConsent:)
    public static func setConsent(_ granted: Bool) {
        withClient("setConsent") { $0.setConsent(granted) }
    }

    /// Stops all tracking and clears the queue. Remembered across launches.
    @objc public static func optOut() {
        withClient("optOut") { $0.optOut() }
    }

    /// Undoes `optOut()`.
    @objc public static func optIn() {
        withClient("optIn") { $0.optIn() }
    }

    /// The id Lemu uses for this install until `reset()`. Nil before `setup`.
    @objc public static var anonymousId: String? {
        return currentClient?.anonymousId
    }

    /// Whether `optOut()` is in effect.
    @objc public static var isOptedOut: Bool {
        return currentClient?.isOptedOut ?? false
    }
}
