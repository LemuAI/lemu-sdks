# Lemu Analytics for Android

Send app events, purchases and installs from your Android app to [Lemu](https://lemuai.com), so journeys,
campaigns and ROI reports see what customers do in your app as well as on your website.

- Kotlin, works from Java. minSdk 21.
- No OkHttp, Retrofit or Gson: nothing to clash with your app's versions. One small AndroidX dependency
  (`androidx.lifecycle:lifecycle-process`).
- Events are queued on disk, batched, and retried when the network is back.
- No advertising id and no hardware ids.

## Install

The SDK is on Maven Central. In your app module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.lemuai:analytics:1.0.0")

    // Optional: attribute installs to the Play Store campaign that brought the user.
    implementation("com.android.installreferrer:installreferrer:2.2")
}
```

Make sure `mavenCentral()` is in your repositories (it is by default in new projects).

## Set up

Call `setup` once, in `Application.onCreate()`. Find your write key in Lemu under
**Settings > Tracking sources**, after adding a source of type **App**.

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Lemu.setup(this, "lpk_...", LemuOptions(debug = BuildConfig.DEBUG))
    }
}
```

Java:

```java
Lemu.setup(this, "lpk_...", LemuOptions.builder().debug(BuildConfig.DEBUG).build());
```

If your app runs code in more than one process, call `setup` in the main process only.

### Options

| Option | Default | What it does |
|---|---|---|
| `apiHost` | `https://app.lemuai.com` | Collection host. Change only for testing or a first-party collection domain |
| `debug` | `false` | Logs every call, request and response to Logcat with the tag `Lemu` |
| `requireConsent` | `false` | Sends and stores nothing until `setConsent(true)` |
| `trackLifecycleEvents` | `true` | `app_installed`, `app_updated`, `app_opened`, `app_backgrounded` |
| `trackDeepLinks` | `true` | `deep_link_opened` for links that open an activity, and UTM parameters into the campaign |
| `collectInstallReferrer` | `true` | Reads the Play install referrer on first launch, when the library is in your app |
| `trackActivityScreens` | `false` | A screen message each time an activity starts |
| `flushAt` | `20` | Send when this many events are queued |
| `flushIntervalSeconds` | `30` | Send at least this often while events are queued |
| `maxQueueSize` | `1000` | Most events kept on the device while offline |

## Track events

```kotlin
Lemu.track(LemuEvent.ADD_TO_CART, mapOf(
    "value" to 999,
    "currency" to "INR",
    "content_ids" to listOf("SKU1"),
    "content_type" to "product",
))

Lemu.track("coupon_applied", mapOf("code" to "DIWALI10"))
```

Any event name works. For the actions Meta defines as standard events, use the `LemuEvent` constants so
the names match exactly what Lemu (and Meta) expect:

| Constant | Name sent | When |
|---|---|---|
| `VIEW_CONTENT` | `ViewContent` | A product or other key page is viewed |
| `SEARCH` | `Search` | A search |
| `ADD_TO_CART` | `AddToCart` | An item is added to the cart |
| `ADD_TO_WISHLIST` | `AddToWishlist` | An item is added to a wishlist |
| `INITIATE_CHECKOUT` | `InitiateCheckout` | Checkout starts |
| `ADD_PAYMENT_INFO` | `AddPaymentInfo` | Payment details entered |
| `PURCHASE` | `Purchase` | An order is placed (use `purchase()`) |
| `LEAD` | `Lead` | A lead is submitted |
| `COMPLETE_REGISTRATION` | `CompleteRegistration` | Sign-up completed |
| `SUBSCRIBE`, `START_TRIAL` | `Subscribe`, `StartTrial` | Paid subscription or free trial started |
| `SCHEDULE`, `SUBMIT_APPLICATION`, `CONTACT`, `CUSTOMIZE_PRODUCT`, `DONATE`, `FIND_LOCATION`, `PAGE_VIEW` | as named | as Meta defines them |

Parameters follow Meta's definitions: `value` (a number in major units, so `1499.5` is Rs 1,499.50),
`currency` (ISO 4217, `INR`), `content_ids`, `contents`, `content_type`, `content_name`,
`content_category`, `num_items`, `search_string`, `predicted_ltv`, `status`. You can add your own
parameters next to them.

Do not put contact details (email, phone, address) in event properties. Lemu removes them from events;
send them with `identify()` instead.

## Purchases

```kotlin
Lemu.purchase(
    value = 1499.5,
    currency = "INR",
    orderId = "1042",
    contents = listOf(LemuContent(id = "SKU1", quantity = 1, itemPrice = 1499.5)),
    contentIds = listOf("SKU1"),
    numItems = 1,
    properties = mapOf("payment_method" to "cod"),
)
```

`purchase()` sends a `Purchase` event and sends it straight away instead of waiting for the next batch.
`value`, `currency` and `orderId` are what Lemu calculates journey and campaign ROI from.

**Why `orderId` matters.** The same order is often reported more than once: by the app, by your website,
by Shopify, or by your server. Lemu counts one conversion per `order_id`, however many times it arrives.
Without it, every report of the order counts as a separate sale and your revenue is overstated. Use the
same order id your backend and store use.

For the most reliable numbers, also send `Purchase` from your server (the app can be closed right after
payment). With the same `order_id`, both count once.

## Screens

```kotlin
Lemu.screen("Checkout", mapOf("step" to 2))
```

Lemu stores these as `screen_viewed`. Screens are not tracked automatically. To send one each time an
activity starts, set `trackActivityScreens = true`, or register the tracker yourself to choose names:

```kotlin
LemuActivityScreenTracker.register(this) { activity -> activity.title?.toString() }
```

Apps built on one activity with Compose or Fragments should call `Lemu.screen()` from their navigation.

## Identify users

When a user signs in or gives you their details:

```kotlin
Lemu.identify("user-829", mapOf(
    "email" to "asha@example.com",
    "phone" to "+919812345678", // E.164
    "first_name" to "Asha",
    "last_name" to "Rao",
))
```

The user id is sent with every later event until `reset()`. Traits are the only place contact details
belong; Lemu uses them to match the app user to a contact.

On logout:

```kotlin
Lemu.reset() // new anonymous id, user id cleared
```

`Lemu.anonymousId` returns the id of this install (a random UUID created by the SDK).

## Consent and opt-out

If you need consent before tracking (for example under GDPR or the DPDP Act):

```kotlin
Lemu.setup(this, "lpk_...", LemuOptions(requireConsent = true))

// Later, from your consent screen:
Lemu.setConsent(true)   // sends what was held and starts tracking
Lemu.setConsent(false)  // discards held and queued events
```

Until consent is given, nothing is sent and nothing is written to the device, not even the anonymous id.
Up to 50 events are held in memory and sent once consent is given. A granted consent is remembered across
launches; call `setConsent(false)` if the user withdraws it.

To let users switch tracking off entirely:

```kotlin
Lemu.optOut() // stops everything, clears queued events, remembered across launches
Lemu.optIn()  // turns it back on
```

## App lifecycle events

Sent automatically unless you set `trackLifecycleEvents = false`:

| Event | When | Properties |
|---|---|---|
| `app_installed` | First launch with the SDK | `version`, `build` |
| `app_updated` | First launch after the version changes | `version`, `build`, `previous_version`, `previous_build` |
| `app_opened` | Every time the app comes to the foreground | `from_background`, `url` when opened by a link |
| `app_backgrounded` | The app goes to the background (queued events are sent then) | |

If you add the SDK to an app that is already installed, the first launch after the update counts as
`app_installed`.

## Deep links

Links that start an activity (`ACTION_VIEW` with a URL) are recorded automatically as `deep_link_opened`
with `url` and `referrer`. UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_term`,
`utm_content`) and `gclid` / `fbclid` in the link become the campaign for this and later events in the
session.

Links delivered to an activity that is already running arrive in `onNewIntent`, which the SDK cannot see.
Record those yourself:

```kotlin
override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    Lemu.trackDeepLink(intent)
}
```

## Install referrer

Add `com.android.installreferrer:installreferrer` to your app (see Install) and the SDK reads the Play
install referrer on the first launch. The UTM parameters the user arrived with (for example from a Google
Ads or Meta app campaign link to the Play Store) are added to `app_installed` and the rest of that first
session. The `app_installed` event waits up to 10 seconds for the referrer. Without the library, this is
skipped and nothing else changes. Set `collectInstallReferrer = false` to turn it off.

## Debug logging

```kotlin
LemuOptions(debug = true)
```

Every call, request body and server response is logged to Logcat with the tag `Lemu`. Use it during
development only. Event properties and traits appear in the log.

With debug on, `track("Purchase", ...)` without `value`, `currency` or `order_id` logs a warning (the event
is still sent).

## Delivery

- Events are sent in batches of up to 50: every 30 seconds, when 20 are queued, when the app goes to the
  background, and right after a purchase. `Lemu.flush()` sends now.
- Events are stored in the app's no-backup files directory, so they survive restarts and are not copied to
  other devices by Auto Backup. At most 1,000 are kept; when full, the oldest are dropped first, purchases
  last. Events older than 7 days are dropped.
- Failed requests are retried with backoff (1 s, 2 s, 4 s and so on, up to 5 minutes apart). Retries stop
  20 hours after the first attempt that reached the server. Rejected batches (an unknown write key, for
  example) are dropped, and logged in debug mode.
- The SDK never throws into your app. A bad argument is logged in debug mode and ignored.

## ProGuard and R8

The SDK ships its own consumer rules; you do not need to add anything. If you keep the install referrer
library out of your app, R8 will not complain about it.

## Google Play data safety

The answers depend on how you use the SDK. With the SDK alone, this is what it collects and sends to Lemu:

| Play data type | Collected | When | Purpose |
|---|---|---|---|
| Device or other IDs | Yes | Always: a random anonymous id created by the SDK for this install (not an advertising id, not a hardware id) | Analytics |
| App activity: App interactions | Yes | Always: lifecycle events, screens and the events you track | Analytics |
| App activity: Other actions | Yes, if you track them | Searches, sign-ups and other custom events | Analytics |
| Financial info: Purchase history | Yes, if you call `purchase()` or track purchases | Order value, currency, order id, items | Analytics |
| Personal info: User IDs | Yes, if you call `identify(userId)` | Your own user id | Analytics, App functionality |
| Personal info: Name, Email address, Phone number | Yes, if you pass them to `identify()` | The traits you send | Analytics, and Advertising or marketing if you message users from Lemu |

Also sent with every event, and not a Play data type: app name, version, build and package name; device
manufacturer and model; device type (phone, tablet or TV); Android version; screen size and density;
locale and time zone; the link that opened the app and its campaign parameters.

Not collected: advertising id (GAID), Android ID, IMEI, serial number, MAC address, location, contacts,
photos, files, crash logs.

- **Is data encrypted in transit?** Yes, it is sent over HTTPS.
- **Is data shared?** Lemu processes it as your service provider. Under Play's definitions, transfer to a
  service provider acting on your behalf is not sharing.
- **Can users ask for deletion?** Answer according to your own deletion process; you can delete a
  contact's data in Lemu.
- **Is collection optional?** Yes if you use `requireConsent` or offer `optOut()`.

## Java

Every method is static on `Lemu` and has Java overloads:

```java
Map<String, Object> props = new HashMap<>();
props.put("value", 999);
props.put("currency", "INR");
Lemu.track(LemuEvent.ADD_TO_CART, props);
Lemu.purchase(1499.5, "INR", "1042");
```

## Modules in this repository

| Module | Artifact | |
|---|---|---|
| `lemu-android` | `com.lemuai:analytics` | The Android SDK you add to your app |
| `lemu-core` | `com.lemuai:analytics-core` | Plain Kotlin/JVM: messages, queue, batching, retries. Added for you by `analytics` |
| `sample` | not published | A small app that calls every API |

Build and test (JDK 17; the Android modules need an Android SDK with platform 34):

```bash
./gradlew test          # conformance scenarios C01 to C20 and unit tests
./gradlew lint assemble
```

Without an Android SDK, Gradle builds and tests `lemu-core` only. The wire protocol is described in
[`../spec/protocol.md`](../spec/protocol.md).

## License

MIT. See [LICENSE](LICENSE).
