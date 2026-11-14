import Foundation

/// Event names, spelled exactly as Lemu (and Meta, for the standard events)
/// expects them. Generated from `spec/events.json`; a test checks they match.
///
/// ```swift
/// Lemu.track(LemuEvent.addToCart, properties: ["value": 999, "currency": "INR", "content_ids": ["SKU1"]])
/// ```
@objc(LemuEvent)
public final class LemuEvent: NSObject {
    // Meta standard events
    @objc public static let pageView = "PageView"
    @objc public static let viewContent = "ViewContent"
    @objc public static let search = "Search"
    @objc public static let addToCart = "AddToCart"
    @objc public static let addToWishlist = "AddToWishlist"
    @objc public static let initiateCheckout = "InitiateCheckout"
    @objc public static let addPaymentInfo = "AddPaymentInfo"
    /// Use `Lemu.purchase(value:currency:orderId:...)`, which sends this event with the fields Lemu needs.
    @objc public static let purchase = "Purchase"
    @objc public static let lead = "Lead"
    @objc public static let completeRegistration = "CompleteRegistration"
    @objc public static let subscribe = "Subscribe"
    @objc public static let startTrial = "StartTrial"
    @objc public static let schedule = "Schedule"
    @objc public static let submitApplication = "SubmitApplication"
    @objc public static let contact = "Contact"
    @objc public static let customizeProduct = "CustomizeProduct"
    @objc public static let donate = "Donate"
    @objc public static let findLocation = "FindLocation"

    // App lifecycle events (sent by the SDK)
    @objc public static let appInstalled = "app_installed"
    @objc public static let appUpdated = "app_updated"
    @objc public static let appOpened = "app_opened"
    @objc public static let appBackgrounded = "app_backgrounded"
    @objc public static let deepLinkOpened = "deep_link_opened"
    @objc public static let screenViewed = "screen_viewed"

    /// Every Meta standard event name.
    @objc public static let metaEvents: [String] = [
        pageView, viewContent, search, addToCart, addToWishlist, initiateCheckout, addPaymentInfo,
        purchase, lead, completeRegistration, subscribe, startTrial, schedule, submitApplication,
        contact, customizeProduct, donate, findLocation,
    ]

    /// Every lifecycle event name.
    @objc public static let lifecycleEvents: [String] = [
        appInstalled, appUpdated, appOpened, appBackgrounded, deepLinkOpened, screenViewed,
    ]

    override private init() {
        super.init()
    }
}
