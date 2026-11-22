# lemu_analytics

The Lemu tracking SDK for Flutter. It sends events, purchases, user identity, app lifecycle
events, deep links and screen views from your app to [Lemu](https://lemuai.com), where they drive
journeys, audiences and conversion reporting.

- Pure Dart, no platform channels of its own. Works on Android, iOS, web, macOS, Windows and Linux.
- Events are queued on the device, sent in batches, retried when the network fails and kept
  across restarts.
- Meta standard event names, so ads platforms receive conversions unchanged.
- Consent mode and opt-out built in. No advertising ids, no hardware ids.
- In-app messages: popups, banners and forms built in Lemu, shown with native Flutter widgets.

Requires Dart 3.4 or later (Flutter 3.22 or later).

## Install

```bash
flutter pub add lemu_analytics
```

On **macOS**, apps are sandboxed and need permission to make network requests. Add this to
`macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Android and iOS need no extra setup.

## Set up

Get your write key (it starts with `lpk_`) from Lemu: Settings, Tracking sources, add a
source of type App. Call `setup` once in `main()`, before `runApp()`:

```dart
import 'package:flutter/widgets.dart';
import 'package:lemu_analytics/lemu_analytics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lemu.instance.setup('lpk_...');
  runApp(const MyApp());
}
```

The write key is public; it is safe to ship in the app.

Options:

```dart
await Lemu.instance.setup(
  'lpk_...',
  options: const LemuOptions(
    debug: false,            // log every call, request and response
    requireConsent: false,   // see "Consent and opt-out"
    flushAt: 20,             // send once this many events are queued (web: 10)
    flushInterval: Duration(seconds: 30), // and at least this often (web: 1 second)
    maxQueueSize: 1000,      // events kept on the device while offline (at most 1,000)
    trackLifecycle: true,    // app_installed, app_updated, app_opened, app_backgrounded
    trackDeepLinks: true,    // deep_link_opened from trackDeepLink()
    inAppMessages: true,     // see "In-app messages"
  ),
);
```

Calls made before `setup` are ignored. No method ever throws: a bad argument is ignored and, with
`debug: true`, logged.

## Track events

```dart
Lemu.instance.track(LemuEvent.addToCart, {
  'value': 999,
  'currency': 'INR',
  'content_ids': ['SKU1'],
});

Lemu.instance.track('wishlist_shared', {'list_id': 'summer'});
```

Any event name works. For the actions ads platforms understand, use the `LemuEvent` constants,
which are Meta's standard event names spelled exactly as Meta expects:

| Constant | Event | Useful properties |
|---|---|---|
| `LemuEvent.viewContent` | `ViewContent` | `content_ids`, `content_name`, `content_type`, `value`, `currency` |
| `LemuEvent.search` | `Search` | `search_string` |
| `LemuEvent.addToCart` | `AddToCart` | `content_ids`, `contents`, `value`, `currency` |
| `LemuEvent.addToWishlist` | `AddToWishlist` | `content_ids`, `value`, `currency` |
| `LemuEvent.initiateCheckout` | `InitiateCheckout` | `num_items`, `value`, `currency` |
| `LemuEvent.addPaymentInfo` | `AddPaymentInfo` | `value`, `currency` |
| `LemuEvent.purchase` | `Purchase` | use `purchase()` below |
| `LemuEvent.lead` | `Lead` | `value`, `currency` |
| `LemuEvent.completeRegistration` | `CompleteRegistration` | `status` |
| `LemuEvent.subscribe` | `Subscribe` | `value`, `currency`, `predicted_ltv` |
| `LemuEvent.startTrial` | `StartTrial` | `value`, `currency`, `predicted_ltv` |

Also `pageView`, `schedule`, `submitApplication`, `contact`, `customizeProduct`, `donate` and
`findLocation`. `value` is in major units: `1499.5` means Rs 1,499.50.

Do not put email addresses, phone numbers or other contact details in event properties. Lemu
removes them from events on arrival; they belong in `identify()`.

## Purchases

```dart
Lemu.instance.purchase(
  value: 1499.5,
  currency: 'INR',
  orderId: '1042',
  contents: const [
    LemuContent(id: 'SKU1', quantity: 1, itemPrice: 999, title: 'Kurta'),
    LemuContent(id: 'SKU7', quantity: 1, itemPrice: 500.5),
  ],
  properties: {'coupon': 'DIWALI10'},
);
```

`purchase()` sends a `Purchase` event right away instead of waiting for the next batch.
`content_ids` and `num_items` are filled in from `contents` when you don't pass them.

**Always pass the order id from your backend.** The same order is often reported by more than
one source: the app, your website pixel, your server, Shopify. Lemu counts one conversion per
`orderId`, so revenue is not counted twice and automations do not fire twice. Without it, every
report counts.

## Identify users

When a user signs in or signs up:

```dart
Lemu.instance.identify(
  userId: 'cust_8812',            // your own id for this user
  traits: {
    'email': 'asha@example.com',
    'phone': '+919812345678',     // E.164
    'first_name': 'Asha',
    'last_name': 'Rao',
  },
);
```

The `userId` is kept and sent with every later event, also after the app restarts. On logout:

```dart
Lemu.instance.reset(); // new anonymous id, no user id
```

`Lemu.instance.anonymousId` is the id Lemu uses for this install before the user is known.

## Screens

Add `LemuNavigatorObserver` to your navigator to send a screen view each time a named page
becomes visible:

```dart
MaterialApp(
  navigatorObservers: [LemuNavigatorObserver()],
  routes: {...},
);
```

With go_router:

```dart
final router = GoRouter(
  observers: [LemuNavigatorObserver()],
  routes: [
    GoRoute(name: 'product', path: '/product/:id', builder: ...),
  ],
);
```

go_router names each page after the GoRoute `name`, or its path pattern (`/product/:id`) when it
has none. Routes inside a `ShellRoute` need the observer on that `ShellRoute` too. Dialogs, bottom
sheets and unnamed routes are skipped. To choose names yourself:

```dart
LemuNavigatorObserver(
  nameExtractor: (route) => route.settings.name?.replaceAll('/', ' ').trim(),
)
```

Or send screens by hand:

```dart
Lemu.instance.screen('Checkout', {'step': 2});
```

## In-app messages

Experiences you build in Lemu (Onsite, platform App or Any) show in the app as native Flutter
widgets: popups, slide-ins, toasts and top bars with text, images, buttons and forms. Answers go
to Lemu the same way website forms do, so they update contacts, consent and records and can start
journeys. The rules are the same as on the website: screens, targeting, triggers, frequency, A/B
variants and holdout.

### Set up

Mount `LemuExperiencesHost` once around your app. Messages are drawn inside it:

```dart
MaterialApp(
  builder: (context, child) => LemuExperiencesHost(child: child!),
  navigatorObservers: [LemuNavigatorObserver()],
);
```

`LemuExperiencesHost` needs no Material ancestor, so it also works with `CupertinoApp` and
`WidgetsApp`. The SDK fetches the live experiences after `setup` and again when the app returns
to the foreground (at most every 5 minutes).

### Screens and triggers

The "Where" rules in Lemu match the screen names the SDK reports (`LemuNavigatorObserver` or
`Lemu.instance.screen()`): "Screen is" (ignores case) and "Screen starts with". Triggers:

| Trigger in Lemu | In the app |
|---|---|
| Page load | Each time a matching screen is reported |
| After N seconds | N seconds after a matching screen is reported; a new screen cancels it |
| SDK event | When you call `track()` with that event name, for example `LemuEvent.addToCart` |
| Manual | Only when you call `show()` |

Other website triggers (scroll, exit intent, clicks on page elements) don't apply in apps.
Targeting rules that apps can answer are new or returning visitor, visit count and "identified"
(after `identify()` with a user id); rules that need Lemu's data (segments, known contact, records)
are checked by Lemu. A `ViewContent` event with `content_ids` tells Lemu which product is on screen
until the next screen. At most one message shows at a time.

### Control them from code

```dart
final experiences = Lemu.instance.experiences;

experiences.show('size_alert');   // show now, whatever its trigger, screens and frequency say
experiences.hide();               // close the message on screen
experiences.setEnabled(false);    // pause automatic messages, for example during checkout
experiences.setEnabled(true);
await experiences.refresh();      // fetch the live experiences now
```

`show()` returns false when nothing could show: the key is unknown, a message is already on
screen, no `LemuExperiencesHost` is mounted, or the user is in the experiment's holdout group. If
the experiences haven't loaded yet, it shows once they have.

### Events

```dart
Lemu.instance.experiences.events.listen((event) {
  switch (event.type) {
    case LemuExperienceEventType.shown:
    case LemuExperienceEventType.closed:     // event.byUser
    case LemuExperienceEventType.submitted:  // event.fields, event.offerCode
    case LemuExperienceEventType.clicked:    // event.target (the URL or copy_code)
  }
});
```

The SDK also sends `onsite_viewed`, `onsite_closed`, `onsite_clicked` and `onsite_held_out` to
Lemu for the experience's reports.

### Links

The SDK has no dependency for opening links. Give it a handler, for example with url_launcher:

```dart
Lemu.instance.experiences.urlHandler = (uri) => launchUrl(uri);
```

Without one, a button that opens a link records the click and closes the message.

### What is supported

- Formats: popup (centred, over a dimmed background), slide-in and toast (at the bottom; a toast
  hides itself after a few seconds), bar (at the top). Other formats are website only.
- Blocks: heading, text, image, button (submit, next step, close, open a link, copy code), close
  link, form fields (email, phone, text, number, checkbox and consent, choices) and the offer
  code after a submit. Multi-step forms and the WhatsApp code check work as on the website.
- Colours, corner radius and button style come from your Onsite theme in Lemu.

To turn in-app messages off, set `inAppMessages: false` in `LemuOptions`; the SDK then never
fetches them. Opted-out users see none. With `requireConsent`, messages show before consent but
what the SDK remembers about them (shown, closed, submitted) stays in memory until consent is
given. On Flutter web the website script shows experiences, so this SDK doesn't.

## Deep links and campaigns

Pass each link that opens the app to `trackDeepLink`. It sends `deep_link_opened` and keeps the
link's `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `gclid` and
`fbclid` in `context.campaign` for the rest of the session, so later events (including the
purchase) are attributed to the campaign.

With [app_links](https://pub.dev/packages/app_links) (its stream also delivers the link that
launched the app):

```dart
final appLinks = AppLinks();
appLinks.uriLinkStream.listen((uri) => Lemu.instance.trackDeepLink(uri));
```

With go_router handling links, track them in the top-level `redirect`. It also runs for in-app
navigation, so only track URLs that carry campaign parameters, once each:

```dart
Uri? lastTrackedLink;

final router = GoRouter(
  redirect: (context, state) {
    final uri = state.uri;
    final hasCampaign = uri.queryParameters.keys
        .any((k) => k.startsWith('utm_') || k == 'gclid' || k == 'fbclid');
    if (hasCampaign && uri != lastTrackedLink) {
      lastTrackedLink = uri;
      Lemu.instance.trackDeepLink(uri);
    }
    return null;
  },
  routes: [...],
);
```

`trackDeepLink(uri, referrer: 'com.instagram.android')` records where the link came from when
you know it.

## App lifecycle

Unless `trackLifecycle: false`, the SDK sends:

| Event | When | Properties |
|---|---|---|
| `app_installed` | first launch | `version`, `build` |
| `app_updated` | first launch after the version or build changed | `version`, `build`, `previous_version`, `previous_build` |
| `app_opened` | launch and every return to the foreground | `from_background` |
| `app_backgrounded` | the app goes to the background | |

Queued events are sent when the app goes to the background, with or without lifecycle events.
If you add the SDK to an app that is already installed, existing users send `app_installed` once
on their first launch with the SDK.

## Consent and opt-out

If you must ask before tracking (for example under GDPR or DPDP), set `requireConsent: true`.
Nothing is sent and nothing is written to the device, not even the anonymous id, until the user
agrees. Up to 50 events are held in memory meanwhile.

```dart
await Lemu.instance.setup('lpk_...',
    options: const LemuOptions(requireConsent: true));

// Later, from your consent screen:
Lemu.instance.setConsent(true);  // sends the held events; remembered across launches
Lemu.instance.setConsent(false); // discards held and queued events
```

To stop all tracking for a user who opts out in your settings screen:

```dart
Lemu.instance.optOut(); // clears the queue, remembered across launches
Lemu.instance.optIn();  // resumes
```

## Flutter web

On the web the SDK reuses the anonymous id of the Lemu website pixel (the `_lemu_aid` cookie and
localStorage key) when the Flutter app runs on the same site, so a visitor who browses your
website and then your Flutter web app is one visitor. A visitor who opted out on the website
stays opted out. Events are sent every second or every 10 events.

## Debugging

```dart
await Lemu.instance.setup('lpk_...',
    options: const LemuOptions(debug: true));
```

Every call, request body and response status is printed with a `[Lemu]` prefix through
`debugPrint`. Events also show up live in Lemu under Settings, Tracking sources, in the source's
debugger. `Lemu.instance.flush()` sends the queue immediately, which helps while testing.

## Privacy and store forms

What the SDK collects:

- A random anonymous id created on first launch, stored in the app's preferences. It is not
  derived from the device and is replaced on `reset()` or reinstall.
- Events and properties your code sends, plus the `userId` and traits you pass to `identify()`.
- App name, version, build and package name; device manufacturer, model and type (phone, tablet,
  desktop); OS name and version; screen size and pixel density; locale; time zone; campaign
  parameters from deep links.

What it does not collect: advertising ids (IDFA, GAID), hardware or vendor ids (Android ID,
`identifierForVendor`), location, contacts, or anything else you don't send.

These notes help you fill in the store forms; your answers depend on what your app sends and on
how your Lemu workspace uses it.

**App Store (App Privacy).** The SDK reads no advertising identifier and does not need the App
Tracking Transparency prompt to work. Typical declarations: Identifiers, User ID (the anonymous
id, and your user id if you call `identify`); Contact Info (email, phone, name, if you send them
as traits); Purchases (purchase history, if you call `purchase`); Usage Data, Product
Interaction. They are linked to the user once you call `identify`. Purposes: Analytics, plus
Developer's Advertising or Marketing if you message users through Lemu journeys. If your
workspace forwards conversions to ad platforms (for example the Meta Conversions API), Apple
counts that as tracking: declare it, and follow Apple's App Tracking Transparency rules for it.

**Google Play (Data safety).** Data is encrypted in transit (HTTPS). Typical declarations:
Device or other IDs (the anonymous id the app generates); App activity (app interactions, other
user-generated actions); Personal info (name, email address, phone number, user ids) if you pass
them to `identify`; Financial info (purchase history) if you call `purchase`. Purposes:
Analytics, plus Advertising or marketing if you message users through Lemu or forward
conversions to ad platforms. Data sent to Lemu, as your service provider, is not "shared" in
Play's sense; conversions forwarded to ad platforms are.

## How sending works

- Events are queued on the device (shared_preferences) and survive restarts. At most 1,000 are
  kept; when full, the oldest event that is not a `Purchase` is dropped. Events older than 7 days
  are dropped before sending.
- Requests carry at most 50 events. Apps send every 30 seconds or 20 events, when going to the
  background and right after a purchase; the web every second or 10 events.
- Network errors, timeouts, `429` and `5xx` are retried after 1, 2, 4 ... seconds, up to 5
  minutes apart. A batch the server keeps failing is dropped 20 hours after it was queued. `413`
  splits the batch; other `4xx` drop it (the reason is logged in debug mode).
- Every request has the User-Agent `lemu-flutter/<version> (<os> <os version>; <model>)`, except
  on the web, where the browser sets its own.

The wire protocol is documented in [spec/protocol.md](https://github.com/LemuAI/lemu-sdks/blob/main/spec/protocol.md).

## License

MIT. See [LICENSE](LICENSE).
