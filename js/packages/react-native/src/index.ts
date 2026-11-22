/**
 * @lemuai/react-native: Lemu tracking for React Native and Expo apps.
 *
 *   import { lemu, LemuEvent } from "@lemuai/react-native";
 *   lemu.init("lpk_...", { appVersion: "3.2.0", appBuild: "320" });
 *   lemu.track(LemuEvent.AddToCart, { value: 999, currency: "INR" });
 *
 * In-app messages (experiences built in Lemu for apps) show once
 * `<LemuExperiences />` is mounted at the root of the app.
 *
 * Pure JavaScript: no native module of its own, so it works in Expo Go.
 */
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  type Context,
  fetchTransport,
  KEYS,
  type LemuOptions,
  LemuClient,
  LemuEvent,
  parseCampaign,
  type Properties,
  type StorageAdapter,
} from "@lemuai/analytics/core";
import { AppState, Dimensions, Linking, Platform } from "react-native";
import { createElement, type ReactElement, useEffect } from "react";
import { ExperiencesHost } from "./experiences/host";
import { ExperienceManager } from "./experiences/manager";

export { LemuEvent };
export { ExperienceManager };
export type { LemuExperienceEvent, LemuExperienceEventType } from "./experiences/manager";
export type {
  LemuEventName,
  LemuOptions,
  Properties,
  PurchaseContent,
  PurchaseProperties,
  StorageAdapter,
} from "@lemuai/analytics/core";

/** Kept in step with package.json. */
export const VERSION = "1.0.0";

const VERSION_KEY = "_lemu_app_version";
const BUILD_KEY = "_lemu_app_build";

/** The parts of react-native-device-info this package reads (all synchronous). */
export interface DeviceInfoLike {
  getVersion?(): string;
  getBuildNumber?(): string;
  getApplicationName?(): string;
  getBundleId?(): string;
  getModel?(): string;
  getBrand?(): string;
  getManufacturerSync?(): string;
  getSystemName?(): string;
  getSystemVersion?(): string;
  getDeviceType?(): string;
}

export interface ReactNativeOptions extends LemuOptions {
  /** App version, when react-native-device-info isn't installed (Expo: Constants.expoConfig.version). */
  appVersion?: string;
  /** App build number, when react-native-device-info isn't installed. */
  appBuild?: string;
  appName?: string;
  /** Bundle id or package name. */
  appNamespace?: string;
  /** Use another storage (for example MMKV) instead of AsyncStorage. */
  storage?: StorageAdapter;
  /** Pass react-native-device-info explicitly. Found automatically when installed. */
  deviceInfo?: DeviceInfoLike | null;
  /** In-app messages from Lemu (shown by `<LemuExperiences />`). Default true; false fetches nothing. */
  inAppMessages?: boolean;
  /** Opens links from in-app message buttons. Default `Linking.openURL`. */
  openUrl?: (url: string) => void;
  /** Copies an offer code. Default `@react-native-clipboard/clipboard` when installed, else React Native's own `Clipboard` when it has one. */
  copyToClipboard?: (text: string) => void;
}

declare const require: (id: string) => unknown;

function loadDeviceInfo(): DeviceInfoLike | null {
  try {
    const mod = require("react-native-device-info") as { default?: DeviceInfoLike } & DeviceInfoLike;
    return (mod && (mod.default || mod)) || null;
  } catch (e) {
    return null;
  }
}

interface ClipboardLike {
  setString(text: string): void;
}

function loadClipboard(): ClipboardLike | null {
  const pick = (mod: unknown): ClipboardLike | null => {
    const m = mod as { default?: ClipboardLike; Clipboard?: ClipboardLike } & Partial<ClipboardLike>;
    const c = m && (m.default || m.Clipboard || m);
    return c && typeof (c as ClipboardLike).setString === "function" ? (c as ClipboardLike) : null;
  };
  try {
    const found = pick(require("@react-native-clipboard/clipboard"));
    if (found) return found;
  } catch (e) {
    /* not installed */
  }
  try {
    return pick({ Clipboard: (require("react-native") as { Clipboard?: ClipboardLike }).Clipboard });
  } catch (e) {
    return null;
  }
}

function call(info: DeviceInfoLike | null | undefined, name: keyof DeviceInfoLike): string | undefined {
  try {
    const fn = info && info[name];
    const value = typeof fn === "function" ? (fn as () => unknown).call(info) : undefined;
    return typeof value === "string" && value && value !== "unknown" ? value : undefined;
  } catch (e) {
    return undefined;
  }
}

function deviceType(info: DeviceInfoLike | null | undefined): "phone" | "tablet" | "desktop" | "tv" | "other" {
  const t = call(info, "getDeviceType");
  if (t === "Handset") return "phone";
  if (t === "Tablet") return "tablet";
  if (t === "Tv") return "tv";
  if (t === "Desktop") return "desktop";
  if (Platform.isTV) return "tv";
  if (Platform.isPad) return "tablet";
  return Platform.OS === "ios" || Platform.OS === "android" ? "phone" : "other";
}

function osName(): string {
  if (Platform.OS === "ios") return "iOS";
  if (Platform.OS === "android") return "Android";
  return String(Platform.OS);
}

/** Storage over AsyncStorage. */
export function asyncStorageAdapter(store: typeof AsyncStorage = AsyncStorage): StorageAdapter {
  return {
    get: (key) => store.getItem(key),
    set: (key, value) => store.setItem(key, value),
    remove: (key) => store.removeItem(key),
  };
}

/** The React Native client. */
export class LemuReactNative extends LemuClient<ReactNativeOptions> {
  private headers: Record<string, string>;
  private base: Partial<Context> = {};
  private appVersion?: string;
  private appBuild?: string;
  private linkSub?: { remove(): void };
  private configured = false;
  private consented = true;
  private optedOutNow = false;

  /** In-app messages: `show(key)`, `hide()`, `setEnabled(on)`, `refresh()`, `on(type, fn)`. */
  readonly experiences: ExperienceManager;

  constructor() {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    let context: () => Partial<Context> = () => ({});
    super({
      platform: "react_native",
      library: { name: "lemu-react-native", version: VERSION },
      storage: asyncStorageAdapter(),
      transport: fetchTransport({ headers }),
      context: () => context(),
      lifecycle: {
        subscribe(h) {
          let wasBackground = false;
          const sub = AppState.addEventListener("change", (state) => {
            if (state === "background") {
              wasBackground = true;
              h.background();
            } else if (state === "active" && wasBackground) {
              wasBackground = false;
              h.foreground();
            }
          });
          return () => sub && sub.remove();
        },
      },
      defaults: { flushAt: 20, flushInterval: 30000, trackLifecycle: true, trackDeepLinks: true },
      persistQueue: true,
      extraKeys: [VERSION_KEY, BUILD_KEY],
    });
    this.headers = headers;
    context = () => this.deviceContext();
    this.experiences = new ExperienceManager({
      writeKey: () => this.writeKey,
      host: () => this.host,
      anonymousId: () => this.anonymousId(),
      userId: () => this.userId(),
      track: (event, properties) => this.track(event, properties),
      storage: () => this.a.storage,
      headers: () => {
        const out: Record<string, string> = {};
        if (this.headers["User-Agent"]) out["User-Agent"] = this.headers["User-Agent"];
        return out;
      },
      optedOut: () => this.optedOutNow,
      storageAllowed: () => this.consented && !this.optedOutNow,
      platform: () => (Platform.OS === "ios" || Platform.OS === "android" ? Platform.OS : String(Platform.OS)),
      log: (...args) => this.log(...args),
      openUrl: (url) => {
        const custom = this.options().openUrl;
        if (custom) custom(url);
        else Linking.openURL(url).catch(() => undefined);
      },
      copy: (text) => {
        const custom = this.options().copyToClipboard;
        if (custom) return custom(text);
        const clipboard = loadClipboard();
        if (clipboard) clipboard.setString(text);
      },
    });
  }

  init(writeKey: string, options?: ReactNativeOptions): void {
    this.safe(() => {
      if (this.configured || !writeKey) return;
      this.configured = true;
      const o = options || {};
      if (o.storage) this.a.storage = o.storage;
      this.consented = !o.requireConsent;
      const info = o.deviceInfo !== undefined ? o.deviceInfo : loadDeviceInfo();
      this.appVersion = call(info, "getVersion") || o.appVersion;
      this.appBuild = call(info, "getBuildNumber") || o.appBuild;
      const model = call(info, "getModel");
      const osVersion = call(info, "getSystemVersion") || String(Platform.Version);
      const app: NonNullable<Context["app"]> = {};
      const name = call(info, "getApplicationName") || o.appName;
      const namespace = call(info, "getBundleId") || o.appNamespace;
      if (name) app.name = name;
      if (this.appVersion) app.version = this.appVersion;
      if (this.appBuild) app.build = this.appBuild;
      if (namespace) app.namespace = namespace;
      const device: NonNullable<Context["device"]> = { type: deviceType(info) };
      const manufacturer = call(info, "getManufacturerSync") || call(info, "getBrand");
      if (manufacturer) device.manufacturer = manufacturer;
      if (model) device.model = model;
      this.base = { app, device, os: { name: osName(), version: osVersion } };
      try {
        const intl = Intl.DateTimeFormat().resolvedOptions();
        this.base.locale = intl.locale;
        this.base.timezone = intl.timeZone;
      } catch (e) {
        /* no Intl on this engine */
      }
      this.headers["User-Agent"] = "lemu-react-native/" + VERSION + " (" + osName() + " " + osVersion + "; " + (model || "unknown") + ")";
    });
    super.init(writeKey, options);
  }

  track(event: string, properties?: Properties): void {
    super.track(event, properties);
    this.safe(() => this.experiences.onTrack(event, properties));
  }

  screen(name: string, properties?: Properties): void {
    super.screen(name, properties);
    this.safe(() => {
      if (typeof name === "string" && name.trim()) this.experiences.onScreen(name.trim(), properties);
    });
  }

  setConsent(granted: boolean): void {
    super.setConsent(granted);
    this.when(() => {
      this.consented = !!granted;
    });
  }

  optOut(): void {
    super.optOut();
    this.when(() => {
      this.optedOutNow = true;
      this.experiences.hide();
    });
  }

  optIn(): void {
    super.optIn();
    this.when(() => {
      this.optedOutNow = false;
    });
  }

  shutdown(): void {
    super.shutdown();
    this.safe(() => this.experiences.shutdown());
    this.safe(() => {
      if (this.linkSub) this.linkSub.remove();
      this.linkSub = undefined;
    });
  }

  protected started(): void {
    const o = this.options();
    this.optedOutNow = this.stored(KEYS.optOut) === "1";
    if (this.stored(KEYS.consent) === "1") this.consented = true;
    if (o.inAppMessages !== false) this.experiences.start();
    if (o.trackLifecycle) {
      const previous = this.stored(VERSION_KEY);
      const previousBuild = this.stored(BUILD_KEY);
      const version = this.appVersion || "";
      const build = this.appBuild || "";
      if (previous == null) {
        this.track(LemuEvent.AppInstalled, strip({ version: this.appVersion, build: this.appBuild }));
      } else if (previous !== version || (previousBuild || "") !== build) {
        this.track(
          LemuEvent.AppUpdated,
          strip({ version: this.appVersion, build: this.appBuild, previous_version: previous || undefined, previous_build: previousBuild || undefined }),
        );
      }
      this.store(VERSION_KEY, version);
      this.store(BUILD_KEY, build);
    }
    if (o.trackDeepLinks) {
      this.linkSub = Linking.addEventListener("url", (event) => this.safe(() => this.deepLink(event && event.url)));
    }
    if (!o.trackLifecycle && !o.trackDeepLinks) return;
    let initial: Promise<string | null>;
    try {
      initial = Promise.resolve(Linking.getInitialURL());
    } catch (e) {
      initial = Promise.resolve(null);
    }
    initial
      .catch(() => null)
      .then((url) =>
        this.safe(() => {
          if (o.trackLifecycle) this.track(LemuEvent.AppOpened, strip({ from_background: false, url: url || undefined }));
          if (url && o.trackDeepLinks) this.deepLink(url);
        }),
      );
  }

  protected onForeground(): void {
    if (this.options().trackLifecycle) this.track(LemuEvent.AppOpened, { from_background: true });
    if (this.options().inAppMessages !== false) this.experiences.onForeground();
  }

  protected onBackground(): void {
    if (this.options().trackLifecycle) this.track(LemuEvent.AppBackgrounded, {});
    this.experiences.onBackground();
    super.onBackground();
  }

  private deepLink(url: string | null | undefined): void {
    if (!url || typeof url !== "string") return;
    const campaign = parseCampaign(url);
    if (Object.keys(campaign).length) this.setCampaign(campaign);
    const props: Properties = { url };
    const referrer = /[?&]referrer=([^&#]*)/.exec(url);
    if (referrer) props.referrer = decodeURIComponent(referrer[1]);
    this.track(LemuEvent.DeepLinkOpened, props);
  }

  private deviceContext(): Partial<Context> {
    const ctx: Partial<Context> = {};
    for (const k in this.base) (ctx as Record<string, unknown>)[k] = (this.base as Record<string, unknown>)[k];
    try {
      const s = Dimensions.get("screen");
      if (s && s.width) ctx.screen = { width: Math.round(s.width * s.scale), height: Math.round(s.height * s.scale), density: s.scale };
    } catch (e) {
      /* no screen */
    }
    return ctx;
  }
}

function strip(o: Properties): Properties {
  const out: Properties = {};
  for (const k in o) if (o[k] !== undefined) out[k] = o[k];
  return out;
}

/** A new, independent client. Most apps use the shared `lemu` instead. */
export function createLemu(): LemuReactNative {
  return new LemuReactNative();
}

/** The shared client. */
export const lemu: LemuReactNative = /* @__PURE__ */ createLemu();

/**
 * Shows in-app messages. Mount it once, as the last child of the app's root
 * view (inside your providers, after the navigation container), so messages
 * draw above every screen:
 *
 *   <View style={{ flex: 1 }}>
 *     <NavigationContainer>...</NavigationContainer>
 *     <LemuExperiences />
 *   </View>
 */
export function LemuExperiences(props: { client?: LemuReactNative }): ReactElement {
  const client = (props && props.client) || lemu;
  return createElement(ExperiencesHost, { manager: client.experiences });
}

// ----------------------------------------------------------------------------
// React Navigation
// ----------------------------------------------------------------------------

interface RouteLike {
  name: string;
}

/** What this needs from a React Navigation container ref (`createNavigationContainerRef()` or `useNavigationContainerRef()`). */
export interface NavigationRefLike {
  isReady?(): boolean;
  getCurrentRoute?(): RouteLike | undefined;
  addListener?(event: "state", callback: () => void): () => void;
  current?: NavigationRefLike | null;
}

/**
 * Sends `screen(routeName)` whenever the focused route changes. Route params
 * are not sent (they can hold personal data); add your own `screen()` calls
 * when you need more. Returns a function that stops tracking.
 */
export function trackNavigationState(navigationRef: NavigationRefLike, client: LemuClient = lemu): () => void {
  let last: string | undefined;
  let stopped = false;
  let unsubscribe: (() => void) | undefined;
  let poll: ReturnType<typeof setTimeout> | undefined;
  const nav = (): NavigationRefLike | null | undefined =>
    navigationRef && typeof navigationRef.getCurrentRoute === "function" ? navigationRef : navigationRef && navigationRef.current;
  const onState = () => {
    try {
      const n = nav();
      const route = n && n.getCurrentRoute ? n.getCurrentRoute() : undefined;
      if (route && route.name && route.name !== last) {
        last = route.name;
        client.screen(route.name);
      }
    } catch (e) {
      /* never throw into the app */
    }
  };
  let tries = 0;
  const attach = () => {
    if (stopped) return;
    const n = nav();
    if (n && typeof n.addListener === "function" && (!n.isReady || n.isReady())) {
      try {
        unsubscribe = n.addListener("state", onState);
      } catch (e) {
        unsubscribe = undefined;
      }
      onState();
    } else if (tries++ < 100) {
      poll = setTimeout(attach, 100);
    }
  };
  attach();
  return () => {
    stopped = true;
    if (poll) clearTimeout(poll);
    if (unsubscribe) unsubscribe();
  };
}

/** Hook form of `trackNavigationState`: `useLemuNavigationTracking(navigationRef)`. */
export function useLemuNavigationTracking(navigationRef: NavigationRefLike, client?: LemuClient): void {
  useEffect(() => trackNavigationState(navigationRef, client || lemu), [navigationRef, client]);
}
