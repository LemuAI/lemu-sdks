# Lemu SDKs

Client SDKs that send website and app events to Lemu (https://lemuai.com): page and screen views, Meta's standard events such as `AddToCart` and `Purchase`, and `identify()` for known users. Purchases sent with `value`, `currency` and `order_id` give journeys and campaigns their revenue and ROI in Lemu.

| Platform | Package | Directory |
|---|---|---|
| Website (script tag) | `https://app.lemuai.com/api/v1/pixel/sdk.js` | [js/packages/analytics](js/packages/analytics) (`src/snippet.ts`) |
| JavaScript / TypeScript | npm `@lemuai/analytics` | [js/packages/analytics](js/packages/analytics) |
| React, Next.js | npm `@lemuai/react` | [js/packages/react](js/packages/react) |
| React Native, Expo | npm `@lemuai/react-native` | [js/packages/react-native](js/packages/react-native) |
| Android (Kotlin, Java) | Maven Central `com.lemuai:analytics` | [android](android) |
| iOS, tvOS (Swift, Objective-C) | Swift Package Manager (this repository), CocoaPods `LemuAnalytics` | [ios](ios), [Package.swift](Package.swift), [LemuAnalytics.podspec](LemuAnalytics.podspec) |
| Flutter (iOS, Android, web, desktop) | pub.dev `lemu_analytics` | [flutter](flutter) |

Each directory has a README with installation, setup, sending events, `purchase()`, identify, consent and opt-out, deep links and debugging.

## Shared contract

- [spec/protocol.md](spec/protocol.md): the wire protocol every SDK speaks (`POST /api/v1/pixel/batch`), retries, consent, queueing and the automatic app events.
- [spec/events.json](spec/events.json): the event names every SDK exposes as constants. Meta Pixel's standard events, used exactly as Meta defines them, plus the app lifecycle events. Only conversion events (`Purchase` by default) have required fields: `value`, `currency`, `order_id`.
- [conformance](conformance): scenarios C01 to C20 that every SDK's tests implement against a local fake server, and the JSON Schema every request body must pass.

The Lemu server keeps its own copy of the event names and its tests check that the two agree.

## Development

| SDK | Test | Toolchain |
|---|---|---|
| JS, React, React Native | `cd js && npm ci && npm run lint && npm test && npm run build && npm run size` | Node 20+ |
| Android | `cd android && ./gradlew test lint assemble` | JDK 17, Android SDK 34 (`ANDROID_HOME`); without an Android SDK only `lemu-core` builds |
| iOS | `cd ios && swift test` (or `scripts/test.sh` with only the Command Line Tools) | Xcode 16+ |
| Flutter | `cd flutter && flutter pub get && dart format --set-exit-if-changed . && flutter analyze && flutter test` | Flutter 3.22+ |

The website script Lemu serves at `/api/v1/pixel/sdk.js` is `js/packages/analytics/dist/lemu.js`, built from `src/snippet.ts`.

## Releasing

Each SDK is released from a tag; the workflows in [.github/workflows](.github/workflows) check the tag against the package version, run the tests and publish.

| Tag | Publishes to | Secrets / setup |
|---|---|---|
| `js-v1.0.0` | npm (`@lemuai/analytics`, `@lemuai/react`, `@lemuai/react-native`) with provenance | `NPM_TOKEN`; the `@lemuai` npm org |
| `android-v1.0.0` | Maven Central (`com.lemuai:analytics`, `com.lemuai:analytics-core`) | `SIGNING_KEY`, `SIGNING_KEY_ID`, `SIGNING_KEY_PASSWORD`, `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`; the `com.lemuai` namespace verified on central.sonatype.com |
| `ios-v1.0.0` | CocoaPods trunk, and a plain `1.0.0` tag for Swift Package Manager | `COCOAPODS_TRUNK_TOKEN` |
| `flutter-v1.0.0` | pub.dev (`lemu_analytics`) | Automated publishing enabled on pub.dev for this repository, tag pattern `flutter-v{{version}}`, environment `pub.dev` |

Swift Package Manager resolves versions from plain semver tags at the repository root, so in this repository the plain `x.y.z` tags belong to the iOS SDK.

## Where the code lives

This repository (https://github.com/LemuAI/lemu-sdks) is where the SDKs are developed and released. The workflows, `Package.swift` and the podspec use paths relative to its root.

## License

MIT, see [LICENSE](LICENSE). The SDKs are open source; the Lemu platform they send to is not.
