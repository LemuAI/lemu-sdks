# Changelog

All notable changes to the Lemu JavaScript SDKs. The three packages are
released together with the same version, tagged `js-v<version>`.

## 1.0.0 (unreleased)

First release on npm.

### @lemuai/analytics

- Platform-agnostic core (`@lemuai/analytics/core`) speaking Lemu tracking protocol v1: batching (at most 50 messages per request), retry with backoff (1 s doubling to 5 minutes, plus or minus 20% jitter), 413 splitting, consent, opt-out, `reset()`, user id carried on every message, typed `purchase()`, and pluggable storage, transport, context and lifecycle adapters.
- `LemuEvent` constants for every event in `spec/events.json` (Meta's standard events and the app lifecycle events).
- Browser client: visitor id in the `_lemu_aid` cookie and localStorage (compatible with the earlier snippet, so returning visitors keep their id), `text/plain` requests without a CORS preflight, `sendBeacon` when the page is hidden, `page()` with url, path, title and referrer, `trackPageChanges` for single-page apps, UTM capture, `context.platform: "web"`.
- `dist/lemu.js`: a drop-in replacement for the snippet served at `/api/v1/pixel/sdk.js`. Same `window.lemu` queue and calls, plus `lemu("purchase", {...})` and `lemu("flush")`. About 5.5 KB gzipped, ES2017.
- Changes from the earlier snippet: messages carry `context.platform` and the user id from `identify` on later messages, the user id is kept in localStorage (`_lemu_uid`), failed requests are retried, and `setConsent(false)` also clears unsent events.

### @lemuai/react

- `LemuProvider`, `useLemu()` and `usePageTracking(pathname)` for React Router and the Next.js app router. Safe during server-side rendering.

### @lemuai/react-native

- Works in Expo without a native module. Queue, ids and opt-out persisted in AsyncStorage (at most 1,000 messages, oldest non-Purchase dropped first, messages older than 7 days dropped).
- `app_installed`, `app_updated`, `app_opened`, `app_backgrounded` and `deep_link_opened`, with UTM parameters from links kept in `context.campaign` for the session. Flush on background and after a purchase.
- `screen()`, `trackNavigationState()` and `useLemuNavigationTracking()` for React Navigation.
- App version and device model from `react-native-device-info` when installed, otherwise from the `appVersion` and `appBuild` options.
