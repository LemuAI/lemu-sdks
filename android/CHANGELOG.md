# Changelog

All notable changes to the Lemu Android SDK (`com.lemuai:analytics`) are listed here.
Releases are tagged `android-v<version>`.

## 1.1.0

- Campaign context keeps `lmclid`, the click id Lemu adds to message links, so a visit from a WhatsApp, SMS or email link is tied to the person it was sent to.

- In-app messages: experiences built in Lemu for apps (popup, slide-in, toast, bar) render with native
  views, using the same screen rules, triggers (screen, delay, event, manual), audience, frequency,
  A/B variants and holdout as the website. Forms submit to Lemu, show the offer code, and support
  multi-step and WhatsApp code verification. Views, closes, clicks and holdout are sent as
  `onsite_viewed`, `onsite_closed`, `onsite_clicked` and `onsite_held_out`.
- `Lemu.experiences`: `show(key)`, `hide()`, `setEnabled()`, `isEnabled`, `refresh()` and
  `setListener(LemuExperienceListener)` with `LemuExperienceEvent`.
- `LemuOptions.inAppMessages` (default true) to turn in-app messages off.

## 1.0.0

First release.

- `Lemu.setup`, `track`, `screen`, `identify`, `purchase`, `reset`, `flush`, `setConsent`, `optOut`,
  `optIn`, `anonymousId`, `trackDeepLink`.
- `LemuEvent` constants for Meta's standard events and the app lifecycle events.
- Typed `purchase()` with `value`, `currency` and `order_id`, sent immediately.
- Persistent queue (1,000 events, purchases kept longest, 7-day limit), batches of up to 50,
  retry with backoff for 20 hours, split on 413, drop on 400, 401 and 403.
- Automatic `app_installed`, `app_updated`, `app_opened`, `app_backgrounded` and `deep_link_opened`.
- Campaign parameters from deep links and the Play install referrer (optional dependency).
- Opt-in activity screen tracking (`LemuActivityScreenTracker`).
- Consent mode: nothing sent or stored before consent.
- Protocol version 1.
