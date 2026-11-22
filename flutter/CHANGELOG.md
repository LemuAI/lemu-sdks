# Changelog

## 1.1.0

- Campaign context keeps `lmclid`, the click id Lemu adds to message links, so a visit from a WhatsApp, SMS or email link is tied to the person it was sent to.

- In-app messages: experiences built in Lemu for apps (popup, slide-in, toast and top bar) show
  as native widgets inside `LemuExperiencesHost`. Screen rules, page load, delay, event and manual
  triggers, frequency caps, A/B variants with holdout and targeting follow the same rules as the
  website. Forms submit to Lemu, including multi-step forms, the WhatsApp code check and offer codes.
- `Lemu.instance.experiences`: `show()`, `hide()`, `setEnabled()`, `refresh()`, `urlHandler` and
  an `events` stream (`LemuExperienceEvent`).
- `LemuOptions.inAppMessages` (default true) turns them off.

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
