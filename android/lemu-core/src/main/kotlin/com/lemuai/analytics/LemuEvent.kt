package com.lemuai.analytics

/**
 * Event names for `Lemu.track()`. Meta standard events are spelled exactly as Meta defines them, so a
 * brand can reuse its Meta Pixel calls. Lifecycle events are sent by the SDK itself.
 *
 * Generated from spec/events.json (version 1); a test checks they match.
 */
object LemuEvent {
    // Meta standard events
    /** Page view. */
    const val PAGE_VIEW: String = "PageView"

    /** View content. */
    const val VIEW_CONTENT: String = "ViewContent"

    /** Search. */
    const val SEARCH: String = "Search"

    /** Add to cart. */
    const val ADD_TO_CART: String = "AddToCart"

    /** Add to wishlist. */
    const val ADD_TO_WISHLIST: String = "AddToWishlist"

    /** Initiate checkout. */
    const val INITIATE_CHECKOUT: String = "InitiateCheckout"

    /** Add payment info. */
    const val ADD_PAYMENT_INFO: String = "AddPaymentInfo"

    /** Purchase. */
    const val PURCHASE: String = "Purchase"

    /** Lead. */
    const val LEAD: String = "Lead"

    /** Complete registration. */
    const val COMPLETE_REGISTRATION: String = "CompleteRegistration"

    /** Subscribe. */
    const val SUBSCRIBE: String = "Subscribe"

    /** Start trial. */
    const val START_TRIAL: String = "StartTrial"

    /** Schedule. */
    const val SCHEDULE: String = "Schedule"

    /** Submit application. */
    const val SUBMIT_APPLICATION: String = "SubmitApplication"

    /** Contact. */
    const val CONTACT: String = "Contact"

    /** Customize product. */
    const val CUSTOMIZE_PRODUCT: String = "CustomizeProduct"

    /** Donate. */
    const val DONATE: String = "Donate"

    /** Find location. */
    const val FIND_LOCATION: String = "FindLocation"

    // App lifecycle events (Lemu names)
    /** App installed. */
    const val APP_INSTALLED: String = "app_installed"

    /** App updated. */
    const val APP_UPDATED: String = "app_updated"

    /** App opened. */
    const val APP_OPENED: String = "app_opened"

    /** App backgrounded. */
    const val APP_BACKGROUNDED: String = "app_backgrounded"

    /** Deep link opened. */
    const val DEEP_LINK_OPENED: String = "deep_link_opened"

    /** Screen viewed (sent by screen tracking, never automatic by default). */
    const val SCREEN_VIEWED: String = "screen_viewed"

    /** Every Meta standard event name. */
    @JvmField
    val META_EVENTS: List<String> =
        listOf(
            PAGE_VIEW,
            VIEW_CONTENT,
            SEARCH,
            ADD_TO_CART,
            ADD_TO_WISHLIST,
            INITIATE_CHECKOUT,
            ADD_PAYMENT_INFO,
            PURCHASE,
            LEAD,
            COMPLETE_REGISTRATION,
            SUBSCRIBE,
            START_TRIAL,
            SCHEDULE,
            SUBMIT_APPLICATION,
            CONTACT,
            CUSTOMIZE_PRODUCT,
            DONATE,
            FIND_LOCATION,
        )

    /** Every lifecycle event name. */
    @JvmField
    val LIFECYCLE_EVENTS: List<String> =
        listOf(
            APP_INSTALLED,
            APP_UPDATED,
            APP_OPENED,
            APP_BACKGROUNDED,
            DEEP_LINK_OPENED,
            SCREEN_VIEWED,
        )

    /** Events that Lemu treats as conversions by default and that need value, currency and order_id. */
    @JvmField
    val CONVERSION_REQUIRED_FIELDS: List<String> = listOf("value", "currency", "order_id")
}
