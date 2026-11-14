# Changelog

All notable changes to the Lemu iOS SDK (`LemuAnalytics`). Releases are tagged
`ios-v<version>` (CocoaPods) and `<version>` (Swift Package Manager).

## 1.0.0 (unreleased)

First release.

- `Lemu.setup(writeKey:options:)` with `LemuOptions`: `apiHost`, `debug`, `requireConsent`,
  `flushAt`, `flushInterval`, `maxQueueSize`, `trackLifecycle`, `trackDeepLinks`.
- `track`, `screen`, `identify`, `reset`, `flush`, `setConsent`, `optOut`, `optIn`, `anonymousId`.
- Typed `purchase(value:currency:orderId:...)` that sends `Purchase` and delivers it at once.
- `LemuEvent` constants for every Meta standard event and lifecycle event in `spec/events.json`.
- Automatic `app_installed`, `app_updated`, `app_opened` and `app_backgrounded`.
- `trackDeepLink(_:referrer:)` sends `deep_link_opened` and keeps UTM parameters, `gclid`
  and `fbclid` in `context.campaign`.
- SwiftUI `.lemuScreen("Name")` modifier and opt-in automatic screen tracking for UIKit view controllers.
- Queue on disk (Application Support/Lemu, excluded from backup), up to 1,000 messages,
  sent in batches of up to 50, with retries and backoff as in protocol v1.
- Privacy manifest (`PrivacyInfo.xcprivacy`): no tracking, UserDefaults reason CA92.1,
  collected data types declared.
- No advertising identifier, no IDFV, no AdSupport or AppTrackingTransparency.
- Objective-C entry points.
