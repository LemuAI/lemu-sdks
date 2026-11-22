import Foundation

/// Settings for `Lemu.setup(writeKey:options:)`.
@objc(LemuOptions)
public final class LemuOptions: NSObject {
    public static let defaultAPIHost = "https://app.lemuai.com"

    /// Where events are sent. Change it only for testing or a custom collection domain.
    @objc public var apiHost: String
    /// Logs every call, request and response to the console (os_log, subsystem `com.lemuai.analytics`).
    @objc public var debug: Bool
    /// When true, nothing is sent or stored until `Lemu.setConsent(true)`.
    @objc public var requireConsent: Bool
    /// Send once this many messages are queued. Default 20.
    @objc public var flushAt: Int
    /// Send queued messages every this many seconds. Default 30. 0 turns the timer off.
    @objc public var flushInterval: TimeInterval
    /// Most messages kept on disk while offline. Default 1,000.
    @objc public var maxQueueSize: Int
    /// Sends app_installed, app_updated, app_opened and app_backgrounded. Default true.
    @objc public var trackLifecycle: Bool
    /// Sends deep_link_opened from `Lemu.trackDeepLink(_:referrer:)`. Default true.
    @objc public var trackDeepLinks: Bool
    /// Shows in-app messages (the experiences you build in Lemu for this app). Default true.
    /// False: the SDK never loads them and `Lemu.experiences.show(_:)` does nothing.
    @objc public var inAppMessages: Bool

    public init(
        apiHost: String = LemuOptions.defaultAPIHost,
        debug: Bool = false,
        requireConsent: Bool = false,
        flushAt: Int = 20,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        trackLifecycle: Bool = true,
        trackDeepLinks: Bool = true,
        inAppMessages: Bool = true
    ) {
        self.apiHost = apiHost
        self.debug = debug
        self.requireConsent = requireConsent
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.trackLifecycle = trackLifecycle
        self.trackDeepLinks = trackDeepLinks
        self.inAppMessages = inAppMessages
        super.init()
    }

    @objc override public convenience init() {
        self.init(apiHost: LemuOptions.defaultAPIHost)
    }
}
