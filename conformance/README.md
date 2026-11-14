# Conformance scenarios

Every SDK's test suite runs these scenarios against a local fake ingest server (an HTTP server on `127.0.0.1` that records request bodies and answers with a status the test chooses). Every recorded request body must validate against [`batch.schema.json`](batch.schema.json). The Lemu server's tests parse request bodies built from the same rules, so both sides agree on the wire format.

Each SDK keeps its implementation of these scenarios in its own test directory and names each test after the scenario id, so a reviewer can check coverage with a grep.

| Id | Scenario | Expect |
|---|---|---|
| C01 | `init` then `track("AddToCart", {value: 999, currency: "INR"})`, then `flush()` | one request; body valid; message `type: "track"`, `event: "AddToCart"`, properties as given; `context.platform` and `context.library` set; `User-Agent` starts with `lemu-` (apps) |
| C02 | two `track` calls | same `anonymousId`, different `messageId`s, both UUID v4 |
| C03 | `identify("u1", {email: "a@b.co"})` then `track("X")` | identify message has `userId: "u1"` and the traits; the later track carries `userId: "u1"` |
| C04 | `reset()` after C03, then `track("X")` | new `anonymousId`, no `userId` |
| C05 | `purchase(value: 1499.5, currency: "INR", orderId: "1042")` | sent at once without calling `flush()`; `event: "Purchase"`, `properties.value == 1499.5`, `properties.currency == "INR"`, `properties.order_id == "1042"` |
| C06 | flush threshold: 20 `track` calls (apps) / 10 (web) | a request goes out without `flush()` |
| C07 | `requireConsent: true`, `track("X")`, `flush()` | no request, nothing written to storage; after `setConsent(true)` one request with the held message |
| C08 | `requireConsent: true`, `track("X")`, `setConsent(false)` then `setConsent(true)`, `flush()` | no request (held message discarded) |
| C09 | `optOut()`, `track("X")`, `flush()` | no request; opt-out survives a new SDK instance with the same storage; `optIn()` resumes |
| C10 | server answers 500, then 204 | the batch is retried and delivered once; same `messageId`s |
| C11 | server answers 400 | the batch is dropped, not retried |
| C12 | server answers 413 for a 2-message batch | split and retried as two 1-message requests |
| C13 | persistence (apps): queue 3 messages with the server down, create a new SDK instance on the same storage, server up, `flush()` | the 3 messages arrive |
| C14 | queue limit (apps): 1,001 messages queued while offline, one of them `Purchase` | 1,000 kept; the `Purchase` is among them |
| C15 | first launch (apps) | `app_installed` with `version`, `build`; second launch with a higher version: `app_updated` with `previous_version` |
| C16 | `screen("Checkout", {step: 2})` (apps) | `type: "screen"`, `name: "Checkout"` |
| C17 | invalid arguments (empty event name, null properties) | no exception reaches the caller; nothing sent for the empty name |
| C18 | `sentAt` is set at send time, `timestamp` at call time | `sentAt >= timestamp` for every message |
| C19 | more than 50 messages queued | requests of at most 50 messages |
| C20 | event name constants | every name in `../spec/events.json` (`meta_events` and `lifecycle_events`) is exposed, spelled exactly |
