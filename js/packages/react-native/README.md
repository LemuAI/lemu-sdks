# @lemuai/react-native

Lemu tracking for React Native and Expo apps: events, purchases, known users, screens, app installs and opens, and the deep links that bring people in.

Pure JavaScript with no native module of its own, so it works in Expo Go and in bare React Native apps.

## Install

```bash
npm install @lemuai/react-native @react-native-async-storage/async-storage
# optional, for the app version and device model:
npm install react-native-device-info
```

Expo:

```bash
npx expo install @lemuai/react-native @react-native-async-storage/async-storage
```

`react-native-device-info` needs a development build in Expo. Without it, pass `appVersion` and `appBuild` yourself (for example from `expo-application` or `expo-constants`).

## Quick start

```tsx
import { lemu, LemuEvent } from "@lemuai/react-native";

lemu.init("YOUR_WRITE_KEY");

lemu.track(LemuEvent.AddToCart, { value: 999, currency: "INR", content_ids: ["SKU1"] });
```

Call `init` once, as early as possible (for example in `index.js` or your root component). Calls made before storage has loaded are kept and sent in order.

Expo without `react-native-device-info`:

```tsx
import * as Application from "expo-application";

lemu.init("YOUR_WRITE_KEY", {
  appVersion: Application.nativeApplicationVersion ?? undefined,
  appBuild: Application.nativeBuildVersion ?? undefined,
});
```

## What is tracked for you

| Event | When | Properties |
|---|---|---|
| `app_installed` | First launch | `version`, `build` |
| `app_updated` | First launch after the version or build changed | `version`, `build`, `previous_version`, `previous_build` |
| `app_opened` | Every launch and every return from the background | `from_background`, `url` when a link opened the app |
| `app_backgrounded` | The app goes to the background (queued events are sent then too) | |
| `deep_link_opened` | A link opens the app or arrives while it runs | `url`, `referrer` |

UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`) and `gclid` / `fbclid` in a deep link are kept in `context.campaign` on that event and every later event in the session, so Lemu can attribute what happens next to the campaign.

Turn these off with `trackLifecycle: false` and `trackDeepLinks: false`.

## Screens

Screens are not tracked automatically. Call `screen` yourself:

```tsx
lemu.screen("Checkout", { step: 2 });
```

Or track every route change in React Navigation:

```tsx
import { NavigationContainer, useNavigationContainerRef } from "@react-navigation/native";
import { useLemuNavigationTracking } from "@lemuai/react-native";

export function App() {
  const navigationRef = useNavigationContainerRef();
  useLemuNavigationTracking(navigationRef);
  return <NavigationContainer ref={navigationRef}>{/* screens */}</NavigationContainer>;
}
```

Outside a component, `trackNavigationState(navigationRef)` does the same and returns a function that stops it. Only the route name is sent, not route params, because params can hold personal data.

## Standard events

`LemuEvent` has a constant for every standard event. They are [Meta's standard events](https://developers.facebook.com/docs/meta-pixel/reference) with the same names and parameters, so the same names work with the Meta SDK and Lemu.

| Constant | Event name | Common properties |
|---|---|---|
| `LemuEvent.ViewContent` | `ViewContent` | `content_ids`, `content_name`, `content_type`, `value`, `currency` |
| `LemuEvent.Search` | `Search` | `search_string` |
| `LemuEvent.AddToCart` | `AddToCart` | `content_ids`, `contents`, `value`, `currency` |
| `LemuEvent.AddToWishlist` | `AddToWishlist` | `content_ids`, `value`, `currency` |
| `LemuEvent.InitiateCheckout` | `InitiateCheckout` | `contents`, `num_items`, `value`, `currency` |
| `LemuEvent.AddPaymentInfo` | `AddPaymentInfo` | `value`, `currency` |
| `LemuEvent.Purchase` | `Purchase` | `value`, `currency`, `order_id` (required); use `purchase()` |
| `LemuEvent.Lead` | `Lead` | `value`, `currency` |
| `LemuEvent.CompleteRegistration` | `CompleteRegistration` | `status` |
| `LemuEvent.Subscribe` / `StartTrial` | `Subscribe` / `StartTrial` | `value`, `currency`, `predicted_ltv` |
| `LemuEvent.Schedule`, `SubmitApplication`, `Contact`, `CustomizeProduct`, `Donate`, `FindLocation`, `PageView` | same as the constant | |
| `LemuEvent.AppInstalled` ... `LemuEvent.ScreenViewed` | `app_installed` ... `screen_viewed` | the app events above |

## Purchases

```tsx
lemu.purchase({
  value: 1499.5,
  currency: "INR",
  order_id: "1042",
  contents: [{ id: "SKU1", quantity: 1, item_price: 1499.5 }],
});
```

`purchase()` sends a `Purchase` event and sends the queue right away. `order_id` matters: the same order is often reported by the app, your backend and your payment provider. Lemu counts one conversion per `order_id`, so revenue isn't double counted.

## Identify

```tsx
// after sign-up or login
lemu.identify("crm-123", { email: "asha@example.com", phone: "+919876543210", first_name: "Asha" });

// on logout
lemu.reset();
```

The user id is stored and sent with every later event, across restarts, until `reset()`. Contact details belong in traits only; Lemu removes them from event properties.

## Consent and opt-out

```tsx
lemu.init("YOUR_WRITE_KEY", { requireConsent: true });
// once the user agrees
lemu.setConsent(true);
```

Until consent, nothing is sent and nothing is written to storage, not even the anonymous id. Up to 50 events wait in memory and are sent on consent; `setConsent(false)` discards them. A granted consent is remembered across launches; `setConsent(false)` also forgets it. `lemu.optOut()` stops all tracking and is remembered across launches; `lemu.optIn()` resumes.

## Offline and delivery

Events are kept in AsyncStorage and survive restarts. They are sent every 30 seconds, every 20 events, when the app goes to the background, and right after a purchase. Failed requests are retried with backoff (1 s, 2 s, 4 s and so on, up to 5 minutes). At most 1,000 events are kept; when full, the oldest event that isn't a `Purchase` is dropped. Events older than 7 days are dropped.

Requests carry a `User-Agent` of the form `lemu-react-native/1.0.0 (iOS 17.4; iPhone15,2)`. No advertising ids or hardware ids are collected.

## Debug mode

`lemu.init("YOUR_WRITE_KEY", { debug: true })` logs every call, request and response with a `[lemu]` prefix. Bad arguments are logged and ignored; the SDK never throws into your app.

## Options

| Option | Default | |
|---|---|---|
| `apiHost` | `https://app.lemuai.com` | Collection host |
| `debug` | `false` | Log calls, requests and responses |
| `requireConsent` | `false` | Hold events until `setConsent(true)` |
| `flushAt` | `20` | Send when this many events are queued |
| `flushInterval` | `30000` | Send queued events after this many milliseconds |
| `maxQueueSize` | `1000` | Most events kept on the device |
| `trackLifecycle` | `true` | `app_installed`, `app_updated`, `app_opened`, `app_backgrounded` |
| `trackDeepLinks` | `true` | `deep_link_opened` and UTM parameters from links |
| `appVersion`, `appBuild` | from `react-native-device-info` | Use when it isn't installed |
| `appName`, `appNamespace` | from `react-native-device-info` | |
| `storage` | AsyncStorage | Any `{ get, set, remove }` storage, for example MMKV |
| `deviceInfo` | found automatically | Pass `react-native-device-info` explicitly |

## API

`init`, `track(event, properties?)`, `screen(name, properties?)`, `purchase({ value, currency, order_id, ... })`, `identify(userId?, traits?)`, `reset()`, `flush()`, `setConsent(granted)`, `optOut()`, `optIn()`, `anonymousId()`, plus `trackNavigationState`, `useLemuNavigationTracking`, `createLemu()` for a separate client and `LemuEvent`.

## License

MIT
