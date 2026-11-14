# Changelog

## 1.0.0

First release.

- `Lemu.instance.setup()` with `LemuOptions` (`apiHost`, `debug`, `requireConsent`, `flushAt`,
  `flushInterval`, `maxQueueSize`, `trackLifecycle`, `trackDeepLinks`).
- `track()`, `screen()`, `identify()`, typed `purchase()`, `reset()`, `flush()`.
- `LemuEvent` constants for Meta standard events and app lifecycle events, and `LemuContent`.
- Queue kept on the device (shared_preferences), up to 1,000 events, sent in batches of at most
  50. Sends every 30 seconds or 20 events in apps (1 second or 10 events on the web), when the app
  goes to the background, and right after a purchase.
- Retries with exponential backoff (1 second doubling to 5 minutes, with jitter) on network
  errors, timeouts, 429 and 5xx; splits a batch on 413; drops it on other 4xx.
- Consent (`requireConsent`, `setConsent()`) and `optOut()` / `optIn()`, remembered across launches.
- Automatic `app_installed`, `app_updated`, `app_opened` and `app_backgrounded`.
- `trackDeepLink()` with UTM, gclid and fbclid into `context.campaign`.
- `LemuNavigatorObserver` for screen views.
- Flutter web shares the anonymous id with the Lemu website pixel (`_lemu_aid`).
- Android, iOS, web, macOS, Windows and Linux.
