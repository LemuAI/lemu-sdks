# Lemu iOS SDK (LemuAnalytics)

Send events from your iOS or tvOS app to [Lemu](https://lemuai.com): purchases for
journey and campaign ROI, Meta standard events, screens, app opens and the deep links
that brought people in.

- iOS 13+, tvOS 13+ (macOS 10.15+ builds, for tests and Mac Catalyst)
- Swift and Objective-C
- No third-party dependencies
- No advertising identifier (IDFA), no IDFV, no AdSupport or AppTrackingTransparency
- Events are queued on disk and sent in batches, so nothing is lost offline
- In-app messages built in Lemu, shown as native popups, slide-ins, toasts and bars

You need a **write key** (`lpk_...`). In Lemu, open **Settings > Tracking sources**, add a
source of type **App** and copy its key.

## Install

### Swift Package Manager

In Xcode, choose **File > Add Package Dependencies...** and enter:

```
https://github.com/LemuAI/lemu-sdks
```

Pick **Up to Next Major Version** from `1.0.0` and add the `LemuAnalytics` library to your app target.

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/LemuAI/lemu-sdks", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LemuAnalytics", package: "lemu-sdks"),
    ]),
]
```

### CocoaPods

```ruby
pod 'LemuAnalytics', '~> 1.0'
```

Then run `pod install`.

## Set up

Call `setup` once, as early as possible, so the first app open is recorded.

UIKit (`AppDelegate`):

```swift
import LemuAnalytics

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Lemu.setup(writeKey: "lpk_...")
    return true
}
```

SwiftUI (`App`):

```swift
import LemuAnalytics
import SwiftUI

@main
struct BrandApp: App {
    init() {
        Lemu.setup(writeKey: "lpk_...", options: LemuOptions(debug: true))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in Lemu.trackDeepLink(url) }
        }
    }
}
```

Options (all optional):

| Option | Default | |
|---|---|---|
| `apiHost` | `https://app.lemuai.com` | Change only for testing or a custom collection domain |
| `debug` | `false` | Log every call, request and response |
| `requireConsent` | `false` | Send and store nothing until `Lemu.setConsent(true)` |
| `flushAt` | `20` | Send once this many events are queued |
| `flushInterval` | `30` | Send queued events every this many seconds |
| `maxQueueSize` | `1000` | Most events kept on the device while offline |
| `trackLifecycle` | `true` | `app_installed`, `app_updated`, `app_opened`, `app_backgrounded` |
| `trackDeepLinks` | `true` | `deep_link_opened` from `Lemu.trackDeepLink(_:)` |

Every `Lemu` method can be called from any thread. None of them throws: a bad argument
(an empty event name, a value JSON can't hold) is skipped and logged when `debug` is on.

## Track events

```swift
Lemu.track(LemuEvent.addToCart, properties: [
    "value": 999,
    "currency": "INR",
    "content_ids": ["SKU1"],
])

Lemu.track("wishlist_shared", properties: ["list_size": 4])
```

Any event name works. For the events Meta defines, use the `LemuEvent` constants so the
names match Meta's exactly. If you already call `AppEvents` or the Meta Pixel with these
names, the same properties work here.

| Constant | Event | Typical properties |
|---|---|---|
| `LemuEvent.viewContent` | `ViewContent` | `content_ids`, `content_name`, `content_type`, `contents`, `currency`, `value` |
| `LemuEvent.search` | `Search` | `search_string`, `content_ids`, `contents`, `currency`, `value` |
| `LemuEvent.addToCart` | `AddToCart` | `content_ids`, `content_name`, `contents`, `currency`, `value` (of what was added) |
| `LemuEvent.addToWishlist` | `AddToWishlist` | `content_ids`, `content_name`, `contents`, `currency`, `value` |
| `LemuEvent.initiateCheckout` | `InitiateCheckout` | `content_ids`, `contents`, `currency`, `num_items`, `value` (cart total) |
| `LemuEvent.addPaymentInfo` | `AddPaymentInfo` | `content_ids`, `contents`, `currency`, `value` |
| `LemuEvent.purchase` | `Purchase` | use `Lemu.purchase(...)` |
| `LemuEvent.lead` | `Lead` | `content_category`, `content_name`, `currency`, `value` |
| `LemuEvent.completeRegistration` | `CompleteRegistration` | `content_name`, `currency`, `status`, `value` |
| `LemuEvent.subscribe` | `Subscribe` | `currency`, `predicted_ltv`, `value` |
| `LemuEvent.startTrial` | `StartTrial` | `currency`, `predicted_ltv`, `value` |
| `LemuEvent.schedule`, `.submitApplication`, `.contact`, `.customizeProduct`, `.donate`, `.findLocation`, `.pageView` | | any |

`value` is in major units: `1499.5` means Rs 1,499.50. `currency` is an ISO 4217 code such as `INR`.

Keep contact details out of event properties. Lemu removes keys such as `email`, `phone`,
`address` and `password` from event properties on the server; send them with `identify` instead.

## Purchases

```swift
Lemu.purchase(
    value: 1499.5,
    currency: "INR",
    orderId: "1042",
    contents: [LemuContent(id: "SKU1", quantity: 1, itemPrice: 1499.5, title: "Kurta")],
    properties: ["payment_method": "cod", "coupon": "DIWALI10"]
)
```

`purchase` sends a `Purchase` event and delivers it straight away instead of waiting for
the next batch. `content_ids` and `num_items` are filled in from `contents` when you
don't pass them.

**Always pass `orderId`.** Lemu counts one conversion per order. The same order is often
reported more than once: by the app, by your website pixel, by a Shopify webhook, or by
the app again after a retry. With `order_id` these are recognised as one order, so journey
and campaign revenue isn't counted twice. Without it, every `Purchase` event counts as a
separate order. `value` and `currency` are needed to show revenue at all.

## Identify users

When someone signs in or gives you contact details:

```swift
Lemu.identify(userId: "cust_8812", traits: [
    "email": "asha@example.com",
    "phone": "+919876543210", // E.164
    "first_name": "Asha",
    "last_name": "Rao",
])
```

`userId` is your own id for the customer. It is stored and sent with every later event
until `reset()`. `identify` traits are the only place contact details should go.

On logout:

```swift
Lemu.reset() // new anonymous id, user id cleared
```

`Lemu.anonymousId` returns the id Lemu uses for this install, for example to pass to your
backend so server-side events join up with the app's.

## Consent and opt-out

If you must ask before collecting data, start with `requireConsent`:

```swift
Lemu.setup(writeKey: "lpk_...", options: LemuOptions(requireConsent: true))

// later, from your consent prompt
Lemu.setConsent(true)   // sends events held since launch, and remembers the answer
Lemu.setConsent(false)  // discards held and queued events
```

Until consent, nothing is sent and nothing is written to the device (not even the
anonymous id). Up to 50 events are held in memory and sent if consent is given. Consent,
once given, is remembered across launches; call `setConsent(false)` to withdraw it.

To let people turn tracking off in your settings screen:

```swift
Lemu.optOut()  // stops everything, clears the queue, remembered across launches
Lemu.optIn()   // turns it back on
Lemu.isOptedOut
```

## Deep links and campaign attribution

Pass every URL that opens the app to `trackDeepLink`. It sends `deep_link_opened` with the
`url` and copies `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`,
`gclid` and `fbclid` into `context.campaign` for this and every later event in the session,
so a purchase made after tapping a campaign link is credited to that campaign.

```swift
// SwiftUI
WindowGroup { ContentView().onOpenURL { Lemu.trackDeepLink($0) } }

// UIKit, AppDelegate
func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Lemu.trackDeepLink(url, referrer: options[.sourceApplication] as? String)
    return true
}

// UIKit, SceneDelegate
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { Lemu.trackDeepLink($0.url, referrer: $0.options.sourceApplication) }
}

// Universal links
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { Lemu.trackDeepLink(url) }
}
```

For a cold launch from a link with scenes, also pass the URLs in
`scene(_:willConnectTo:options:)` (`connectionOptions.urlContexts` and
`connectionOptions.userActivities`).

The next `app_opened` carries the link as `properties.url`.

## Screens

SwiftUI:

```swift
CheckoutView()
    .lemuScreen("Checkout")

ProductView(product: product)
    .lemuScreen("Product", properties: ["product_id": product.id])
```

Anywhere:

```swift
Lemu.screen("Checkout", properties: ["step": 2])
```

UIKit, automatically (off by default):

```swift
Lemu.enableAutomaticScreenTracking()
```

Each of your view controllers sends a screen view when it appears, named after its class
without the `ViewController` suffix (`CheckoutViewController` becomes `Checkout`). Navigation,
tab bar, split and page controllers, Apple's own controllers, SwiftUI hosting controllers
and child controllers embedded in your own are skipped. To rename a screen or skip one:

```swift
extension CheckoutViewController: LemuScreenNameProviding {
    var lemuScreenName: String? { "Checkout" } // return nil to send nothing
}
```

## In-app messages

Experiences you build in Lemu for this app (popups, slide-ins, toasts and bars) show in
the app as native views, with the same rules, A/B variants and holdout as on your website.
They are on by default; nothing else is needed after `Lemu.setup`. Build them in Lemu under
**Experiences** with the platform set to **App** (or **Any**).

How it works:

- The SDK loads the live experiences for your write key at launch and again when the app
  returns to the foreground (at most every 5 minutes).
- **Screens** decide where a message may show. Rules match the names you send with
  `Lemu.screen(...)` or `.lemuScreen(...)`: "Screen is" and "Screen starts with" (case is
  ignored), or any screen.
- **Triggers**: when a screen is shown, a number of seconds after a screen is shown, when
  you track an event (for example `AddToCart`; case, spaces, `_` and `-` are ignored), or
  only when your code asks for it.
- **Who**: new or returning visitor, number of visits, and logged in (`identify` with a user
  id). Rules that need Lemu's data (segments, known contact, records, catalog) are checked
  with Lemu before the message shows. Website-only rules (device, UTM, cart) are skipped.
- **How often**: always, once per session (a session ends after 30 minutes away), once a day,
  once every N days or once ever; stop after a form is sent; stop after N closes, with a
  24-hour pause after a close by default. The history is kept on the device.
- One message shows at a time. A visitor in an experience's holdout group never sees it
  (Lemu counts them for the comparison).

### Show, pause and listen

```swift
// Show one now, whatever its screens, trigger and frequency (for example on a "Notify me" tap).
Lemu.experiences.show("size_alert")

// No automatic messages for a while (for example during checkout). show(_:) still works.
Lemu.experiences.setEnabled(false)

// Close the one on screen.
Lemu.experiences.hide()

// Hear about messages (called on the main thread; every method is optional).
final class Messages: NSObject, LemuExperiencesDelegate {
    func lemuExperienceShown(_ event: LemuExperienceEvent) {}
    func lemuExperienceClosed(_ event: LemuExperienceEvent) {}      // event.byUser
    func lemuExperienceSubmitted(_ event: LemuExperienceEvent) {}   // event.fields, event.offerCode
    func lemuExperienceClicked(_ event: LemuExperienceEvent) {}     // event.target
}
let messages = Messages()
Lemu.experiences.delegate = messages // held weakly
```

To turn in-app messages off entirely (nothing is loaded):

```swift
Lemu.setup(writeKey: "lpk_...", options: LemuOptions(inAppMessages: false))
```

Product context: tracking `ViewContent` with `content_ids`, or sending `sku` with a screen
(`Lemu.screen("Product", properties: ["sku": "SKU1"])`), tells Lemu which product is on screen
for rules about the catalog or records.

### What shows

| Format | In the app |
|---|---|
| Popup | A card in the middle of the screen over a dimmed background. Tapping the background closes it unless turned off. |
| Slide-in | A card at the bottom of the screen. |
| Toast | A small card at the bottom that hides itself after a few seconds (8 by default). |
| Bar | A banner across the top, below the status bar. |

Other formats (inline blocks, teasers, floating buttons) are website only. Blocks: heading,
text (shown as plain text), image, button (send the form, next step, close, open a link,
copy the code), fields (email, phone with country code, text, number, checkbox or consent,
and choices as chips), the offer code with a Copy button, and "No thanks". Forms post to
Lemu, which can ask for a WhatsApp code before it accepts a phone number; the success step
shows the offer code. Colours, corner radius and button shape come from your theme in Lemu.

Lemu records `onsite_viewed`, `onsite_closed`, `onsite_clicked` and `onsite_held_out`
through the SDK (they appear in your event stream like other events), and form submissions
on the server. With `requireConsent`, messages still show before consent, but their history
is kept in memory only. After `optOut()` no messages show.

## App lifecycle events

Sent automatically unless you set `trackLifecycle: false`:

| Event | When | Properties |
|---|---|---|
| `app_installed` | first launch with the SDK | `version`, `build` |
| `app_updated` | first launch after the version or build changed | `version`, `build`, `previous_version`, `previous_build` |
| `app_opened` | every time the app comes to the foreground | `from_background`, `url` (when opened by a link) |
| `app_backgrounded` | the app goes to the background | |

On an app that already had users before it added the SDK, existing users send
`app_installed` once after updating, because the SDK has no record of an earlier version.

## Delivery

- Events are kept in `Application Support/Lemu` (excluded from iCloud and device backups)
  and survive app restarts.
- They are sent every 30 seconds, when 20 are queued, when the app goes to the background,
  and right after a purchase. `Lemu.flush()` sends now.
- Requests carry at most 50 events. Failed requests are retried with backoff (1 s, 2 s,
  4 s and so on, up to 5 minutes) for up to 20 hours. Events older than 7 days are dropped.
- The queue holds at most 1,000 events; when it is full the oldest non-purchase event is dropped first.

## Debug logging

```swift
Lemu.setup(writeKey: "lpk_...", options: LemuOptions(debug: true))
```

Every call, request body and response is logged with `os_log` under the subsystem
`com.lemuai.analytics`. Watch it in the Xcode console, or in Console.app filtered by that
subsystem. Turn `debug` off for release builds.

## App Store privacy

### Privacy manifest

The SDK ships its own privacy manifest (`PrivacyInfo.xcprivacy`, in the package and in
the CocoaPods resource bundle `LemuAnalyticsPrivacy`). Xcode includes it in your app's
privacy report automatically. It declares:

- `NSPrivacyTracking`: `false`, with no tracking domains.
- Required reason API: UserDefaults, reason `CA92.1` (the SDK stores its anonymous id,
  user id, opt-out, consent and the last app version in its own UserDefaults suite).
- Collected data, all linked to the user and none used for tracking:

| Data type | Why it is collected | Purposes |
|---|---|---|
| User ID | anonymous install id, and your `userId` from `identify` | Analytics, Developer's advertising or marketing |
| Email address, phone number, name | only if you pass them to `identify` | Analytics, Developer's advertising or marketing |
| Product interaction | events, screens, app opens | Analytics, Developer's advertising or marketing |
| Purchase history | `purchase()` and other commerce events | Analytics, Developer's advertising or marketing |
| Other usage data | lifecycle and custom events | Analytics |

### App Privacy answers in App Store Connect

Your app's privacy label covers all the data your app collects, including through Lemu.
For the data that goes to Lemu, answer:

- **Data used to track you: No.** Lemu does not use advertising identifiers, does not
  share data with data brokers and does not link your app's data with other companies'
  data for advertising. See the note below if you forward data to ad networks.
- **Data linked to you**, for each type you actually send:
  - Contact Info > **Email Address**, **Phone Number**, **Name**: if you call `identify` with them.
  - Identifiers > **User ID**: yes (the SDK always sends an anonymous id; plus your own user id).
  - Purchases > **Purchase History**: if you call `purchase()` or send commerce events.
  - Usage Data > **Product Interaction**: yes (app opens, screens, events).
  - Usage Data > **Other Usage Data**: if you send custom events.
- **Purposes**: **Analytics**, and **Developer's Advertising or Marketing** if you use Lemu
  journeys or campaigns (WhatsApp, email, SMS, voice) to message these customers. Add
  **App Functionality** if your app relies on Lemu data to work.
- **Not collected by the SDK**: precise or coarse location, device ID (IDFA or IDFV),
  diagnostics, contacts, health, financial info, browsing history, search history (unless
  you send search terms as events: then also declare Search History).

**Forwarding to ad networks.** If you send Lemu events to an advertising platform (for
example through a Meta Conversions API connection), Apple counts that as tracking. Then
answer "Data used to track you: Yes" for the shared types, ask permission with
App Tracking Transparency first, and only call `identify` with email or phone after the user allows it.

## Objective-C

```objc
@import LemuAnalytics;

LemuOptions *options = [LemuOptions new];
options.debug = YES;
[Lemu setupWithWriteKey:@"lpk_..." options:options];

[Lemu track:LemuEvent.addToCart properties:@{@"value": @999, @"currency": @"INR"}];
[Lemu identifyWithUserId:@"cust_8812" traits:@{@"email": @"asha@example.com"}];
[Lemu purchaseWithValue:1499.5 currency:@"INR" orderId:@"1042"
               contents:@[[[LemuContent alloc] initWithId:@"SKU1" quantity:1 itemPrice:@1499.5 title:nil]]
             properties:nil];
[Lemu trackDeepLink:url referrer:nil];
[Lemu setConsent:YES];
[Lemu.experiences show:@"size_alert"];
[Lemu.experiences setEnabled:NO];
Lemu.experiences.delegate = self; // <LemuExperiencesDelegate>
```

## Wire protocol

The SDK speaks Lemu tracking protocol v1 (`spec/protocol.md` in this repository):
`POST {apiHost}/api/v1/pixel/batch` with a JSON body, `User-Agent:
lemu-ios/<sdk version> (iOS <version>; <model>)`.

## Development

```sh
cd ios
swift test                    # with Xcode installed
./scripts/test.sh             # also works with only the Command Line Tools
xcodebuild -scheme LemuAnalytics -destination 'generic/platform=iOS Simulator' build
```

Tests are named after the conformance scenarios (`C01` to `C20` in `conformance/README.md`)
and check every request body against `conformance/batch.schema.json`. Some run against a
local HTTP server on `127.0.0.1`.

## License

MIT. See [LICENSE](LICENSE).
