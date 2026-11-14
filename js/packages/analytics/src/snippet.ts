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

  function call(args: ArrayLike<unknown>): unknown {
    const method = api[args[0] as string];
    return typeof method === "function" ? method.apply(null, Array.prototype.slice.call(args, 1)) : undefined;
  }

  const pending: Array<ArrayLike<unknown>> = (window.lemu && window.lemu.q) || [];
  const lemu: any = function () {
    // eslint-disable-next-line prefer-rest-params
    return call(arguments);
  };
  for (const name in api) lemu[name] = api[name];
  lemu.client = client;
  window.lemu = lemu;

  // Calls made before this script loaded: init first, then the rest in order.
  for (let i = 0; i < pending.length; i++) if (pending[i][0] === "init") call(pending[i]);
  for (let i = 0; i < pending.length; i++) if (pending[i][0] !== "init") call(pending[i]);
})();
