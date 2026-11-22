/*
 * Lemu website pixel (dist/lemu.js). A drop-in replacement for the original
 * snippet served at /api/v1/pixel/sdk.js:
 *
 *   <script>
 *     !function(w,d){w.lemu=w.lemu||function(){(w.lemu.q=w.lemu.q||[]).push(arguments)};
 *     var s=d.createElement("script");s.async=1;s.src="https://app.lemuai.com/api/v1/pixel/sdk.js";
 *     d.head.appendChild(s)}(window,document);
 *     lemu("init", "WRITE_KEY");
 *     lemu("page");
 *   </script>
 *
 *   lemu("track", "AddToCart", { value: 999, currency: "INR", content_ids: ["SKU1"] })
 *   lemu("purchase", { value: 1499.5, currency: "INR", order_id: "1042" })
 *   lemu("identify", "crm-123", { email: "asha@example.com" })
 *   lemu("reset") / lemu("consent", true) / lemu("optOut") / lemu("optIn")
 *   lemu("onsite.show", "size_alert") / lemu("onsite.context", { product: {...} })
 *
 * Experiences (popups, bars, widgets) and landing page forms run in
 * onsite.js, loaded after init only when the site has something live; pass
 * lemu("init", KEY, { onsite: false }) to never load it.
 */
import { LemuBrowser } from "./browser";
import { DEFAULT_API_HOST } from "./core/client";
import { VERSION } from "./version";

/* eslint-disable @typescript-eslint/no-explicit-any */
declare const window: any;
declare const document: any;

function scriptHost(): string {
  let script = document.currentScript;
  if (!script || !script.src) {
    const all = document.getElementsByTagName ? document.getElementsByTagName("script") : [];
    for (let i = 0; i < all.length; i++) if (/\/api\/v1\/pixel\/sdk\.js/.test(all[i].src)) script = all[i];
  }
  const src = script && script.src;
  return src && /\/api\/v1\/pixel\/sdk\.js/.test(src) ? src.replace(/\/api\/v1\/pixel\/sdk\.js.*$/, "") : DEFAULT_API_HOST;
}

(function () {
  if (typeof window === "undefined" || typeof document === "undefined" || !window || window.__lemuLoaded) return;
  window.__lemuLoaded = true;

  const client = new LemuBrowser({ apiHost: scriptHost(), library: { name: "lemu.js", version: VERSION } });
  const api: Record<string, (...args: any[]) => unknown> = {};
  const names = ["init", "page", "track", "identify", "purchase", "reset", "flush", "setConsent", "optOut", "optIn", "anonymousId"];
  for (let i = 0; i < names.length; i++) {
    const fn = (client as any)[names[i]];
    api[names[i]] = function () {
      // eslint-disable-next-line prefer-rest-params
      return fn.apply(client, arguments);
    };
  }
  api.consent = api.setConsent;

  // Experiences and landing pages (onsite.js): loaded only when the site
  // has something live, a preview link is open, or this is a Lemu page.
  // lemu("onsite.show", "key") and friends are queued until it loads.
  window.__lemuOnsiteQ = window.__lemuOnsiteQ || [];
  function onsite(name: string, args: unknown[]): unknown {
    const runtime = window.__lemuOnsite;
    if (runtime && typeof runtime[name] === "function") return runtime[name].apply(runtime, args);
    window.__lemuOnsiteQ.push([name, args]);
    return undefined;
  }
  function loadOnsite(): void {
    const o = (client as any).options() || {};
    if (o.onsite === false || window.__lemuOnsiteLoading) return;
    window.__lemuOnsiteLoading = true;
    const host: string = (client as any).host;
    const key: string = (client as any).writeKey;
    const go = (config?: unknown) => {
      window.__lemuOnsiteConfig = config;
      const s = document.createElement("script");
      s.async = true;
      s.src = host + "/api/v1/pixel/onsite.js";
      document.head.appendChild(s);
    };
    if (/[?&]lemu_preview=/.test(window.location.search) || window.__lemuPage) return go();
    try {
      window
        .fetch(host + "/api/v1/pixel/onsite/config?k=" + encodeURIComponent(key), { credentials: "omit" })
        .then((r: any) => r.json())
        .then((c: any) => {
          if (c && c.live) go(c);
        })
        .catch(() => undefined);
    } catch (e) {
      /* no fetch: no experiences */
    }
  }
  // Experiences listen for the site's own events (add to cart, custom ones).
  function emit(type: string, event: unknown, properties: unknown): void {
    try {
      document.dispatchEvent(new CustomEvent("lemu:event", { detail: { type, event, properties } }));
    } catch (e) {
      /* old browsers: no event triggers */
    }
  }

  function call(args: ArrayLike<unknown>): unknown {
    const name = String(args[0] || "");
    const rest = Array.prototype.slice.call(args, 1);
    if (name.indexOf("onsite.") === 0) return onsite(name.slice(7), rest);
    const method = api[name];
    const out = typeof method === "function" ? method.apply(null, rest) : undefined;
    if (name === "init") loadOnsite();
    else if (name === "track") emit("track", rest[0], rest[1]);
    else if (name === "purchase") emit("track", "Purchase", rest[0]);
    else if (name === "page") emit("page", null, rest[0]);
    return out;
  }

  const pending: Array<ArrayLike<unknown>> = (window.lemu && window.lemu.q) || [];
  const lemu: any = function () {
    // eslint-disable-next-line prefer-rest-params
    return call(arguments);
  };
  for (const name in api) lemu[name] = api[name];
  lemu.init = function () {
    // eslint-disable-next-line prefer-rest-params
    return call(["init"].concat(Array.prototype.slice.call(arguments)));
  };
  lemu.track = function () {
    // eslint-disable-next-line prefer-rest-params
    return call(["track"].concat(Array.prototype.slice.call(arguments)));
  };
  lemu.onsite = function (name: string) {
    // eslint-disable-next-line prefer-rest-params
    return onsite(name, Array.prototype.slice.call(arguments, 1));
  };
  lemu.client = client;
  window.lemu = lemu;

  // Calls made before this script loaded: init first, then the rest in order.
  for (let i = 0; i < pending.length; i++) if (pending[i][0] === "init") call(pending[i]);
  for (let i = 0; i < pending.length; i++) if (pending[i][0] !== "init") call(pending[i]);
})();
