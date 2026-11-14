import { DEFAULT_API_HOST, KEYS, LemuClient } from "../core/client";
import { fetchTransport } from "../core/fetch-transport";
import type { Campaign, Context, LemuOptions, Properties, StorageAdapter, TransportAdapter } from "../core/types";
import { hasKeys, parseCampaign } from "../core/util";
import { VERSION } from "../version";

/* eslint-disable @typescript-eslint/no-explicit-any */
// Referenced as bare globals (not through globalThis) so the code also runs in
// sandboxes that only define `window` and `document`.
declare const window: any;
declare const document: any;
declare const Blob: any;

export interface BrowserOptions extends LemuOptions {
  /** Share the visitor id across subdomains, for example ".example.com". */
  cookieDomain?: string;
  /** Send `page()` on single-page-app navigation (history.pushState and back/forward). */
  trackPageChanges?: boolean;
}

export interface BrowserClientConfig {
  /** Host used when `init` gets no `apiHost`. */
  apiHost?: string;
  /** Reported as `context.library`. */
  library?: { name: string; version: string };
}

const COOKIE_KEYS = [KEYS.anonymousId, KEYS.optOut];
const YEAR_DAYS = 365;

/** True in a browser, false during server-side rendering or in Node. */
export function hasDom(): boolean {
  return typeof window !== "undefined" && typeof document !== "undefined" && !!window && !!document;
}

function readCookie(name: string): string | null {
  try {
    const match = String(document.cookie || "").match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
    return match ? decodeURIComponent(match[1]) : null;
  } catch (e) {
    return null;
  }
}

function writeCookie(name: string, value: string, days: number, domain?: string): void {
  try {
    let cookie = name + "=" + encodeURIComponent(value) + "; path=/; max-age=" + days * 86400 + "; SameSite=Lax";
    if (window.location.protocol === "https:") cookie += "; Secure";
    if (domain) cookie += "; domain=" + domain;
    document.cookie = cookie;
  } catch (e) {
    /* cookies blocked: localStorage still works */
  }
}

function local(key: string, value?: string | null): string | null {
  try {
    const ls = window.localStorage;
    if (value === undefined) return ls.getItem(key);
    if (value === null) ls.removeItem(key);
    else ls.setItem(key, value);
  } catch (e) {
    /* storage blocked: the cookie still works */
  }
  return null;
}

/**
 * The visitor id and opt-out live in a first-party cookie and in
 * localStorage (`_lemu_aid`, `_lemu_optout`), the same as the original
 * snippet, so existing visitors keep their id. Other keys use localStorage.
 */
export function browserStorage(cookieDomain: () => string | undefined = () => undefined): StorageAdapter {
  return {
    get(key) {
      return (COOKIE_KEYS.indexOf(key) >= 0 ? readCookie(key) : null) || local(key);
    },
    set(key, value) {
      if (COOKIE_KEYS.indexOf(key) >= 0) writeCookie(key, value, YEAR_DAYS, cookieDomain());
      local(key, value);
    },
    remove(key) {
      if (COOKIE_KEYS.indexOf(key) >= 0) writeCookie(key, "", -1, cookieDomain());
      local(key, null);
    },
  };
}

/** text/plain POST (no CORS preflight) with keepalive, and sendBeacon when the page is going away. */
export function browserTransport(): TransportAdapter {
  const send = (url: string, init: Record<string, unknown>) => window.fetch(url, init);
  const headers = { "Content-Type": "text/plain" };
  const keepalive = fetchTransport({ fetch: send, headers, init: { keepalive: true, credentials: "omit" } });
  const plain = fetchTransport({ fetch: send, headers, init: { credentials: "omit" } });
  return {
    send(request) {
      // keepalive requests are limited to 64 KB in flight.
      return (request.body.length < 60000 ? keepalive : plain).send(request);
    },
    beacon(request) {
      const nav = window.navigator;
      if (!nav || typeof nav.sendBeacon !== "function") return false;
      return !!nav.sendBeacon(request.url, new Blob([request.body], { type: "text/plain" }));
    },
  };
}

let lastCampaign: Campaign | null = null;

/** Page, user agent, locale, timezone, screen and UTM parameters. */
export function browserContext(): Partial<Context> {
  const loc = window.location || {};
  const nav = window.navigator || {};
  const ctx: Partial<Context> = {
    page: { url: loc.href, path: loc.pathname, referrer: document.referrer, title: document.title },
    userAgent: nav.userAgent,
    locale: nav.language,
  };
  try {
    ctx.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch (e) {
    /* old browser */
  }
  const scr = window.screen;
  if (scr && scr.width) ctx.screen = { width: scr.width, height: scr.height, density: window.devicePixelRatio || 1 };
  // UTM parameters from the landing URL stay with later pages of a single-page app.
  const campaign = parseCampaign(loc.search);
  if (hasKeys(campaign)) lastCampaign = campaign;
  if (lastCampaign) ctx.campaign = lastCampaign;
  return ctx;
}

/** The browser client. Methods are no-ops during server-side rendering. */
export class LemuBrowser extends LemuClient<BrowserOptions> {
  private hooked = false;
  private lastUrl = "";

  constructor(config: BrowserClientConfig = {}) {
    let cookieDomain: () => string | undefined = () => undefined;
    super({
      platform: "web",
      library: config.library || { name: "lemu-js", version: VERSION },
      storage: browserStorage(() => cookieDomain()),
      transport: browserTransport(),
      context: browserContext,
      lifecycle: {
        subscribe(h) {
          const onHide = () => h.background();
          const onVisibility = () => (document.visibilityState === "hidden" ? h.background() : h.foreground());
          window.addEventListener("pagehide", onHide);
          document.addEventListener("visibilitychange", onVisibility);
          return () => {
            if (window.removeEventListener) window.removeEventListener("pagehide", onHide);
            if (document.removeEventListener) document.removeEventListener("visibilitychange", onVisibility);
          };
        },
      },
      defaults: { flushAt: 10, flushInterval: 1000, trackLifecycle: false, trackDeepLinks: false },
    });
    cookieDomain = () => this.options().cookieDomain;
    this.host = (config.apiHost || DEFAULT_API_HOST).replace(/\/+$/, "");
  }

  init(writeKey: string, options?: BrowserOptions): void {
    if (!hasDom()) return;
    super.init(writeKey, options);
    if (options && options.trackPageChanges) this.when(() => this.hookHistory());
  }

  /**
   * Records a page view with the page's url, path, title and referrer.
   * `page()`, `page(name)`, `page(properties)` or `page(name, properties)`.
   */
  page(name?: string | Properties, properties?: Properties): void {
    if (!hasDom()) return;
    if (name && typeof name === "object") {
      properties = name;
      name = undefined;
    }
    const props: Properties = {};
    this.safe(() => {
      const loc = window.location;
      this.lastUrl = loc.href;
      props.url = loc.href;
      props.path = loc.pathname;
      props.title = document.title;
      if (document.referrer) props.referrer = document.referrer;
      if (properties && typeof properties === "object") for (const k in properties) props[k] = properties[k];
    });
    super.page(name as string | undefined, props);
  }

  protected when(fn: () => void, otherwise?: () => void): void {
    if (hasDom()) super.when(fn, otherwise);
    else if (otherwise) otherwise();
  }

  private hookHistory(): void {
    if (this.hooked) return;
    this.hooked = true;
    const changed = () =>
      setTimeout(() => {
        if (window.location.href !== this.lastUrl) this.page();
      }, 0);
    const history = window.history;
    const push = history.pushState;
    history.pushState = function (this: unknown) {
      // eslint-disable-next-line prefer-rest-params
      const result = push.apply(this, arguments as any);
      changed();
      return result;
    };
    window.addEventListener("popstate", changed);
  }
}

/** A new, independent browser client. Most sites use the shared `lemu` instead. */
export function createLemu(config?: BrowserClientConfig): LemuBrowser {
  return new LemuBrowser(config);
}

/** The shared browser client. */
export const lemu: LemuBrowser = /* @__PURE__ */ createLemu();
