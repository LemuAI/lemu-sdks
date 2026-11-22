import Foundation

/// What happened to an in-app message.
@objc(LemuExperienceEventType)
public enum LemuExperienceEventType: Int {
    case shown
    case closed
    case submitted
    case clicked
}

/// An in-app message was shown, closed, submitted or clicked.
@objc(LemuExperienceEvent)
public final class LemuExperienceEvent: NSObject {
    @objc public let type: LemuExperienceEventType
    /// The experience's key in Lemu.
    @objc public let experience: String
    /// The variant the user saw.
    @objc public let variant: String
    /// Closed: true when the user closed it (not a toast hiding itself or a form finishing).
    @objc public internal(set) var byUser = false
    /// Clicked: the link that was opened, or `copy_code`.
    @objc public internal(set) var target: String?
    /// Submitted: the values the user entered.
    @objc public internal(set) var fields: [String: Any] = [:]
    /// Submitted: the offer code Lemu returned, if any.
    @objc public internal(set) var offerCode: String?

    init(type: LemuExperienceEventType, experience: String, variant: String) {
        self.type = type
        self.experience = experience
        self.variant = variant
        super.init()
    }
}

/// Hears about in-app messages. Every method is optional and called on the main thread.
@objc(LemuExperiencesDelegate)
public protocol LemuExperiencesDelegate: AnyObject {
    @objc optional func lemuExperienceShown(_ event: LemuExperienceEvent)
    @objc optional func lemuExperienceClosed(_ event: LemuExperienceEvent)
    @objc optional func lemuExperienceSubmitted(_ event: LemuExperienceEvent)
    @objc optional func lemuExperienceClicked(_ event: LemuExperienceEvent)
}

/// In-app messages: the experiences you build in Lemu for this app (popups,
/// slide-ins, toasts and bars), shown on the screens and events their rules
/// name. Use `Lemu.experiences`.
///
/// ```swift
/// Lemu.experiences.show("size_alert")   // show one now
/// Lemu.experiences.setEnabled(false)    // no automatic messages (for example during checkout)
/// Lemu.experiences.delegate = self
/// ```
@objc(LemuExperiences)
public final class LemuExperiences: NSObject {
    static let shared = LemuExperiences()

    private let lock = NSLock()
    private var manager: ExperienceManager?
    private weak var delegateValue: LemuExperiencesDelegate?

    override private init() {
        super.init()
    }

    var currentManager: ExperienceManager? {
        lock.lock(); defer { lock.unlock() }
        return manager
    }

    func attach(_ newManager: ExperienceManager) {
        lock.lock()
        let old = manager
        manager = newManager
        lock.unlock()
        old?.shutdown()
    }

    func detach() {
        lock.lock()
        let old = manager
        manager = nil
        lock.unlock()
        old?.shutdown()
    }

    /// Called on the main thread.
    func dispatch(_ event: LemuExperienceEvent) {
        lock.lock()
        let d = delegateValue
        lock.unlock()
        switch event.type {
        case .shown: d?.lemuExperienceShown?(event)
        case .closed: d?.lemuExperienceClosed?(event)
        case .submitted: d?.lemuExperienceSubmitted?(event)
        case .clicked: d?.lemuExperienceClicked?(event)
        }
    }

    /// Told when a message is shown, closed, submitted or clicked. Held weakly.
    @objc public var delegate: LemuExperiencesDelegate? {
        get {
            lock.lock(); defer { lock.unlock() }
            return delegateValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            delegateValue = newValue
        }
    }

    /// Shows the experience with this key now, whatever its screens, trigger
    /// and frequency say (and even while paused with `setEnabled(false)`).
    /// Visitors in its holdout group still see nothing. Returns false when
    /// nothing showed: unknown key, a format apps don't show, another message
    /// already on screen, or in-app messages turned off. Called before the
    /// config has loaded, it shows once the config arrives.
    @objc @discardableResult
    public func show(_ key: String) -> Bool {
        return currentManager?.show(key) ?? false
    }

    /// Closes the message on screen, if any (not counted as a close by the user).
    @objc public func hide() {
        currentManager?.hide()
    }

    /// `false` pauses automatic messages (screen, delay and event triggers);
    /// `show(_:)` still works. A message already on screen stays.
    @objc public func setEnabled(_ enabled: Bool) {
        currentManager?.setEnabled(enabled)
    }

    /// Whether automatic messages are on. False before `Lemu.setup` and when
    /// `LemuOptions.inAppMessages` is false.
    @objc public var isEnabled: Bool {
        return currentManager?.isEnabled ?? false
    }

    /// Loads the experiences from Lemu now. The SDK does this at launch and
    /// when the app returns to the foreground (at most every 5 minutes).
    @objc public func refresh() {
        currentManager?.refresh()
    }
}
