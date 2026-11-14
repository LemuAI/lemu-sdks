# @lemuai/analytics

Lemu tracking for websites: page views, events, purchases and known users, sent to your Lemu workspace so journeys, segments and ROI reports can use them.

- Zero runtime dependencies, about 5.5 KB gzipped as a script tag.
- Works with or without a bundler. Safe to import during server-side rendering.
- Standard events use Meta's names, so the same event names work for the Meta pixel and for Lemu.

For React and Next.js use [`@lemuai/react`](../react). For React Native and Expo use [`@lemuai/react-native`](../react-native).

## Install

With a bundler:

```bash
npm install @lemuai/analytics
```

Or paste the snippet into your site's `<head>`. It loads the script from Lemu and queues calls until it arrives:

```html
<script>
  !function(w,d){w.lemu=w.lemu||function(){(w.lemu.q=w.lemu.q||[]).push(arguments)};
  var s=d.createElement("script");s.async=1;s.src="https://app.lemuai.com/api/v1/pixel/sdk.js";
  d.head.appendChild(s)}(window,document);
  lemu("init", "YOUR_WRITE_KEY");
  lemu("page");
</script>
```

The same file is published as `@lemuai/analytics/dist/lemu.js` if you prefer to load it from a CDN or host it yourself. Loaded from `/api/v1/pixel/sdk.js`, it sends events back to that host; loaded from anywhere else, it sends to `https://app.lemuai.com` unless you pass `apiHost`.

## Quick start

```js
import { lemu, LemuEvent } from "@lemuai/analytics";

lemu.init("YOUR_WRITE_KEY");
lemu.page();

lemu.track(LemuEvent.AddToCart, {
  value: 999,
  currency: "INR",
  content_ids: ["SKU1"],
  content_type: "product",
});
```

With the snippet, every method is called by name: `lemu("track", "AddToCart", { value: 999, currency: "INR" })`.

## Standard events

Use these names (available as `LemuEvent.*` constants) so Lemu's reports, journeys and ad integrations recognise them. They are [Meta's standard events](https://developers.facebook.com/docs/meta-pixel/reference) with the same parameters. Any other name works too, as a custom event.

| Constant | Event name | Common properties |
|---|---|---|
| `LemuEvent.PageView` | `PageView` | (none; `page()` covers this) |
| `LemuEvent.ViewContent` | `ViewContent` | `content_ids`, `content_name`, `content_type`, `value`, `currency` |
| `LemuEvent.Search` | `Search` | `search_string`, `content_ids` |
| `LemuEvent.AddToCart` | `AddToCart` | `content_ids`, `contents`, `value`, `currency` |
| `LemuEvent.AddToWishlist` | `AddToWishlist` | `content_ids`, `value`, `currency` |
| `LemuEvent.InitiateCheckout` | `InitiateCheckout` | `contents`, `num_items`, `value`, `currency` |
| `LemuEvent.AddPaymentInfo` | `AddPaymentInfo` | `value`, `currency` |
| `LemuEvent.Purchase` | `Purchase` | `value`, `currency`, `order_id` (required); use `purchase()` |
| `LemuEvent.Lead` | `Lead` | `content_name`, `value`, `currency` |
| `LemuEvent.CompleteRegistration` | `CompleteRegistration` | `status`, `value`, `currency` |
| `LemuEvent.Subscribe` | `Subscribe` | `value`, `currency`, `predicted_ltv` |
| `LemuEvent.StartTrial` | `StartTrial` | `value`, `currency`, `predicted_ltv` |
| `LemuEvent.Schedule` | `Schedule` | |
| `LemuEvent.SubmitApplication` | `SubmitApplication` | |
| `LemuEvent.Contact` | `Contact` | |
| `LemuEvent.CustomizeProduct` | `CustomizeProduct` | |
| `LemuEvent.Donate` | `Donate` | |
| `LemuEvent.FindLocation` | `FindLocation` | |

`value` is in major units (1499.5 means Rs 1,499.50) and `currency` is an ISO 4217 code such as `INR`. `contents` is a list of `{ id, quantity, item_price }`.

## Purchases

```js
lemu.purchase({
  value: 1499.5,
  currency: "INR",
  order_id: "1042",
  contents: [{ id: "SKU1", quantity: 1, item_price: 1499.5 }],
});
```

`purchase()` sends a `Purchase` event and sends it at once, without waiting for the next batch, so it isn't lost if the visitor closes the tab on the thank-you page.

`value`, `currency` and `order_id` are required. `order_id` matters most: the same order is often reported by more than one source (this page, your Shopify or payment webhook, a reload of the thank-you page). Lemu counts one conversion per `order_id`, so revenue isn't double counted and journeys get the right credit. Lemu never rejects an event for a missing field, but it flags the conversion as incomplete.

## Identify

Call `identify` when the visitor signs up or logs in. Pass your own user id and their contact details as traits:

```js
lemu.identify("crm-123", {
  email: "asha@example.com",
  phone: "+919876543210",
  first_name: "Asha",
});
```

The user id is kept and sent on every later event until `reset()`. `identify(traits)` without an id works too. Traits are the only place for contact details: Lemu removes keys such as `email` and `phone` from event properties.

On logout, call `reset()`. The visitor gets a new anonymous id and the user id is cleared.

## Consent and opt-out

If you need consent before tracking, start with `requireConsent`:

```js
lemu.init("YOUR_WRITE_KEY", { requireConsent: true });

// later, from your consent banner
lemu.setConsent(true); // snippet: lemu("consent", true)
```

Until consent, nothing is sent and nothing is written to cookies or localStorage, not even the visitor id. Up to 50 events are held in memory and sent once consent is given. `setConsent(false)` discards them. A granted consent is remembered in localStorage (`_lemu_consent`), so returning visitors aren't asked again; `setConsent(false)` forgets it.

`lemu.optOut()` stops all tracking and clears the queue. It is remembered in a cookie and localStorage. `lemu.optIn()` undoes it.

## Single-page apps

`lemu.init(key, { trackPageChanges: true })` sends `page()` on `history.pushState` and back/forward navigation. In React, use `usePageTracking` from `@lemuai/react` instead.

## Debug mode

```js
lemu.init("YOUR_WRITE_KEY", { debug: true });
```

Logs every call, request and response to the console with a `[lemu]` prefix. Bad arguments (an empty event name, properties that can't be turned into JSON) are logged in debug mode and otherwise ignored. The SDK never throws into your code.

## Options

| Option | Default | |
|---|---|---|
| `apiHost` | `https://app.lemuai.com` | Collection host. The snippet uses the host it was loaded from |
| `debug` | `false` | Log calls, requests and responses |
| `requireConsent` | `false` | Hold events until `setConsent(true)` |
| `flushAt` | `10` | Send when this many events are queued |
| `flushInterval` | `1000` | Send queued events after this many milliseconds |
| `maxQueueSize` | `1000` | Most events kept while offline |
| `cookieDomain` | (current host) | Share the visitor id across subdomains, for example `.example.com` |
| `trackPageChanges` | `false` | `page()` on single-page-app navigation |

## API

| Method | |
|---|---|
| `init(writeKey, options?)` | Start. Calls made before `init` are kept and run after it |
| `page(name?, properties?)` | A page view, with url, path, title and referrer |
| `track(event, properties?)` | Any event |
| `purchase({ value, currency, order_id, ... })` | A `Purchase`, sent at once |
| `identify(userId?, traits?)` | Set the user id and send traits |
| `reset()` | New anonymous id, user id cleared |
| `flush()` | Send now. Returns a promise |
| `setConsent(granted)` | Start or stop sending under `requireConsent` |
| `optOut()` / `optIn()` | Stop or resume all tracking, remembered |
| `anonymousId()` | The visitor id, or `null` before consent or after opt-out |
| `createLemu()` | A separate client, for more than one source on a page |

Events are batched and sent as `text/plain` (no CORS preflight), every second or every 10 events, and with `sendBeacon` when the page is hidden. Failed requests are retried with backoff. The visitor id lives in the `_lemu_aid` first-party cookie and localStorage, the same as earlier versions of the snippet, so returning visitors keep their id.

## Other platforms

`@lemuai/analytics/core` is the platform-agnostic client with pluggable storage, transport, context and lifecycle adapters. `@lemuai/react-native` is built on it. The wire protocol is documented in [`spec/protocol.md`](../../../spec/protocol.md).

## License

MIT
