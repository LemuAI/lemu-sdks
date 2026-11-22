# Lemu tracking protocol, version 1

Every Lemu SDK speaks this protocol. Anyone without an SDK can speak it too.

## Endpoint

```
POST {apiHost}/api/v1/pixel/batch
```

- `apiHost` defaults to `https://app.lemuai.com`. SDKs accept an override (`apiHost`) for testing and for self-hosted collection domains.
- Body: JSON. Browsers send it as `Content-Type: text/plain` (no CORS preflight). Apps and servers may send `application/json`; the server reads the body either way.
- Every SDK sends a `User-Agent` header: `lemu-<platform>/<sdk version> (<os name> <os version>; <device model>)`, for example `lemu-android/1.0.0 (Android 14; Pixel 8)`. Requests without a User-Agent are dropped as bots. Browsers can't set it and send their own.
- Limits: at most 100 messages and 256 KB per request. SDKs send at most 50 messages per request.

## Request body

```json
{
  "writeKey": "lpk_...",
  "sentAt": "2026-11-14T10:00:01.123Z",
  "batch": [ <message>, ... ]
}
```

`sentAt` is the client clock when the request was sent. The server corrects each message's `timestamp` by `receivedAt - sentAt`, so a wrong device clock doesn't misplace events. Messages more than 7 days old (after correction) or in the future get the receive time.

## Messages

Fields on every message:

| Field | Required | |
|---|---|---|
| `type` | yes | `page`, `screen`, `track` or `identify` |
| `messageId` | yes | UUID v4, new per message. The server ignores a `messageId` it has seen in the last 24 hours, so retries are safe within that window |
| `anonymousId` | yes | UUID v4, generated once per install / browser and kept until `reset()`. At most 128 characters |
| `timestamp` | yes | ISO 8601 with milliseconds and `Z`, when the call was made |
| `context` | yes | see below |
| `userId` | no | the brand's own id for a known user, set by `identify(userId, …)` and sent on every later message until `reset()` |

By type:

| Type | Fields |
|---|---|
| `page` (web) | `name` (optional), `properties` (`url`, `path`, `title`, `referrer`, anything else) |
| `screen` (apps) | `name` (required), `properties` |
| `track` | `event` (required, any name; Meta standard names for standard events, see `events.json`), `properties` |
| `identify` | `traits`: `email`, `phone` (E.164), `first_name`, `last_name`, `name`, anything else. `userId` optional |

`identify` traits are the only place contact details belong. The server removes personal-data keys (`email`, `phone`, `mobile`, `password`, `card`, `otp`, `address`, ...) from `track` / `page` / `screen` properties at any depth.

## Context

Set by the SDK, never by the brand's code. Send what the platform can provide; omit the rest.

```json
{
  "platform": "android",
  "library": {"name": "lemu-android", "version": "1.0.0"},
  "app": {"name": "Brand", "version": "3.2.0", "build": "320", "namespace": "com.brand.app"},
  "device": {"manufacturer": "Google", "model": "Pixel 8", "type": "phone"},
  "os": {"name": "Android", "version": "14"},
  "screen": {"width": 1080, "height": 2400, "density": 2.625},
  "locale": "en-IN",
  "timezone": "Asia/Kolkata",
  "userAgent": "...",
  "campaign": {"source": "google", "medium": "cpc", "campaign": "diwali", "term": "", "content": "", "gclid": "", "fbclid": "", "lmclid": ""},
  "page": {"url": "...", "path": "/", "title": "...", "referrer": "..."}
}
```

- `platform`: `web`, `ios`, `android`, `flutter`, `react_native`, `shopify` or `server`.
- `device.type`: `phone`, `tablet`, `desktop`, `tv` or `other`.
- `campaign`: UTM parameters (without the `utm_` prefix) plus `gclid` / `fbclid` / `lmclid`, from the page URL, the deep link that opened the app, or the Android install referrer. `lmclid` is added by Lemu message links (le2.in) on links to the workspace's own sites; the server uses it to link a not-yet-known visitor to the person the message went to.
- No advertising ids (IDFA, GAID) and no hardware ids.

## Responses

| Status | Meaning | SDK action |
|---|---|---|
| 204 | accepted | remove the batch from the queue |
| 400 | malformed | drop the batch (retrying won't help), log in debug mode |
| 401 | unknown or paused write key | drop the batch; log in debug mode |
| 403 | origin or app id not allowed for this key | drop the batch; log in debug mode |
| 413 | too large | split the batch in half and retry each half; drop a single message that is still too large |
| 429 | rate limited | retry with backoff |
| 5xx, network error, timeout | | retry with backoff |

Backoff: 1 s, 2 s, 4 s ... doubling, capped at 5 minutes between attempts, with ±20% jitter. Give up on a batch 20 hours after its oldest message was queued (inside the server's 24-hour de-duplication window).

## Behaviour every SDK implements

- **Queue and flush.** Web: flush every 1 s or 10 messages, and with `sendBeacon` when the page is hidden. Apps: flush every 30 s or 20 messages, when the app goes to the background, and right after a conversion event (`Purchase`). `flush()` sends now.
- **Persistence (apps).** The queue is kept on disk and survives restarts. At most 1,000 messages; when full, drop the oldest non-`Purchase` message first. Drop messages older than 7 days before sending.
- **Consent.** With `requireConsent: true`, nothing is sent or written to storage (not even the anonymous id) until `setConsent(true)`. Up to 50 messages are held in memory meanwhile and sent on consent; `setConsent(false)` discards them. `optOut()` stops everything, clears the queue and is remembered across launches; `optIn()` undoes it.
- **`reset()`** (logout): new `anonymousId`, `userId` cleared.
- **Auto events (apps)**, each switchable off with an option:
  - `app_installed` on first launch (`properties.version`, `properties.build`);
  - `app_updated` when the stored version differs (`version`, `build`, `previous_version`, `previous_build`);
  - `app_opened` on every foreground (`from_background`: bool, `url` when opened by a link);
  - `app_backgrounded`;
  - `deep_link_opened` (`url`, `referrer`), with UTM parameters copied into `context.campaign` for this and later messages of the session.
  - `screen_viewed` is never automatic by default; SDKs offer an opt-in observer for their navigation system and a `screen(name)` call.
- **Typed `purchase()`** with `value`, `currency` and `order_id` required, plus `contents`, `content_ids`, `num_items` and extra properties. It sends `track` with `event: "Purchase"` and flushes.
- **Event name constants** for every event in `events.json`.
- **Debug mode** (`debug: true`): log every call, every request and its response.
- **Never throw** into the host app. A bad argument is logged in debug mode and ignored.
