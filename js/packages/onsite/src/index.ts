/*
 * onsite.js: Lemu experiences and landing page runtime
 * (plans/onsite-personalisation.md). Loaded by lemu.js after init when the
 * site has live experiences or pages, a preview link is open, or the page
 * is a Lemu landing page.
 *
 *   lemu("onsite.show", "size_alert")       show one now (manual trigger)
 *   lemu("onsite.hide", "size_alert")
 *   lemu("onsite.context", { page_type: "product", product: { sku, variant_id, title, size, price, in_stock } })
 *   lemu("onsite.on", "submit", fn)         shown | closed | submit
 *   lemu("onsite.suppress", true)           nothing new shows (e.g. during checkout)
 */
import { context, loadShopifyProduct, onContextChange, onSiteEvent, refreshShopifyCart, setContext } from "./context";
import { embedPages, hydratePage } from "./page";
import { loadPreview, previewToken, toolbar } from "./preview";
import { View } from "./render";
import { assign, frequencyAllows, scheduleOpen, whereMatches, whoMatches } from "./rules";
import { persist, reset, seen, useMemoryOnly, visitor } from "./state";
import { arm, onBackInStock } from "./triggers";
import type { Bundle, Decision, Dict, Env, Experience } from "./types";
import { d, getJSON, load, onReady, postJSON, safe, save, w } from "./util";

const OVERLAY_FORMATS = ["popup", "teaser", "slide_in"];
const DECIDE_TTL_MS = 10 * 60 * 1000;
export const PREVIEW_KEY = "__preview__";
let bootTries = 0;

const views: Record<string, View> = {};
const disarm: Record<string, () => void> = {};
const handlers: Record<string, Array<(data: Dict) => void>> = {};
let bundle: Bundle | null = null;
let env: Env | null = null;
let decision: Decision | null = null;
let suppressed = false;
let popupsThisPage = 0;

function emit(name: string, data: Dict): void {
  (handlers[name] || []).forEach((fn) => safe(() => fn(data)));
}

function makeEnv(): Env | null {
  const lemu = w.lemu;
  const client = lemu && lemu.client;
  const page = w.__lemuPage || {};
  const host = (client && client.host) || page.host;
  const key = (client && client.writeKey) || page.key || (page.host ? PREVIEW_KEY : "");
  if (!host || !key) return null;
  return {
    host: String(host).replace(/\/+$/, ""),
    key: String(key),
    anonymousId: () => safe(() => (client ? client.anonymousId() : null)) || null,
    userId: () => safe(() => (client ? client.userId() : null)) || null,
    track: (event: string, properties: Dict) => safe(() => (lemu ? lemu("track", event, properties) : undefined)),
  };
}

function visitorId(): string {
  return (env && env.anonymousId()) || visitor().session;
}

function decideKey(): string {
  const p = bundle ? context(bundle).product : undefined;
  return "_lemu_dc:" + ((p && (p.sku || p.id)) || (w.location || {}).pathname);
}

function fetchDecision(): Promise<void> {
  if (!bundle || !env || !bundle.decide) return Promise.resolve();
  const cached = load(decideKey(), true);
  if (cached.at && Date.now() - cached.at < DECIDE_TTL_MS && cached.v === bundle.v) {
    decision = cached.decision;
    return Promise.resolve();
  }
  const ctx = context(bundle);
  return postJSON(`${env.host}/api/v1/pixel/onsite/decide`, {
    writeKey: env.key,
    anonymousId: env.anonymousId(),
    userId: env.userId(),
    context: { url: ctx.url, path: ctx.path, page_type: ctx.page_type, product: ctx.product ? { id: ctx.product.id, variant_id: ctx.product.variant_id, sku: ctx.product.sku } : {} },
  })
    .then(({ data }) => {
      if (data && data.experiences) {
        decision = data;
        save(decideKey(), { at: Date.now(), v: bundle && bundle.v, decision }, true);
      }
    })
    .catch(() => undefined);
}

function capsAllow(exp: Experience): boolean {
  if (OVERLAY_FORMATS.indexOf(exp.format) < 0 || exp.preview) return true;
  const caps = (bundle && bundle.caps) || {};
  if (caps.popups_per_page != null && popupsThisPage >= caps.popups_per_page) return false;
  if (caps.popups_per_session != null && visitor().popupsThisSession >= caps.popups_per_session) return false;
  return !Object.keys(views).some((k) => OVERLAY_FORMATS.indexOf(views[k].exp.format) >= 0 && views[k].exp.format !== "slide_in");
}

function show(exp: Experience, force = false, variantKey?: string): void {
  if (!bundle || !env || (suppressed && !force)) return;
  const ctx = context(bundle);
  if (views[exp.key]) {
    // Already showing; a widget follows the page (another size chosen).
    if (exp.inline) {
      views[exp.key].ctx = ctx;
      views[exp.key].renderStep();
    }
    return;
  }
  if (!force && !capsAllow(exp)) return;
  const key = variantKey || (exp.preview ? exp.variants[0].key : assign(exp, visitorId()));
  const variant = exp.variants.filter((v) => v.key === key)[0] || exp.variants[0];
  const view = new View(exp, variant, bundle, ctx, env, {
    closed: (v, byUser) => {
      delete views[v.exp.key];
      emit("closed", { experience: v.exp.key, byUser });
    },
    submitted: (v) => emit("submit", { experience: v.exp.key, variant: v.variant.key, offer: v.offer }),
    show: (k) => api.show(k),
  });
  if (!view.mount()) return;
  views[exp.key] = view;
  const h = seen(exp.key);
  h.n++;
  h.last = Date.now();
  h.sessionShown = visitor().session;
  if (OVERLAY_FORMATS.indexOf(exp.format) >= 0) {
    popupsThisPage++;
    visitor().popupsThisSession++;
  }
  persist();
  if (!exp.preview) view.track("onsite_viewed", {});
  emit("shown", { experience: exp.key, variant: variant.key });
}

function eligible(exp: Experience): boolean {
  if (!bundle) return false;
  if (exp.platform === "app") return false;
  const ctx = context(bundle);
  if (!scheduleOpen(exp.schedule || {})) return false;
  if (!whereMatches(exp, ctx)) return false;
  if (!frequencyAllows(exp)) return false;
  return whoMatches(exp, ctx, decision, env ? env.userId() : null);
}

function evaluate(): void {
  if (!bundle) return;
  for (const exp of bundle.experiences || []) {
    if (views[exp.key] || disarm[exp.key]) continue;
    if (!eligible(exp)) continue;
    const variant = assign(exp, visitorId());
    persist();
    if (variant === "holdout") {
      const h = seen(exp.key);
      if (h.sessionShown !== visitor().session) {
        h.sessionShown = visitor().session;
        persist();
        if (env) env.track("onsite_held_out", { experience_id: exp.id, experience: exp.key, variant: "holdout", version: exp.version, page_type: context(bundle).page_type });
      }
      continue;
    }
    disarm[exp.key] = arm(exp, () => {
      if (!eligible(exp) && exp.trigger.on !== "click") return;
      show(exp);
    });
    if (exp.trigger.on === "out_of_stock_selected") {
      onBackInStock(exp.key, () => {
        const v = views[exp.key];
        if (v && v.stepIndex === 0) v.close(false);
      });
    }
  }
}

/** Page changed in a single-page app: start over for the new page. */
function newPage(): void {
  Object.keys(disarm).forEach((k) => {
    safe(disarm[k]);
    delete disarm[k];
  });
  Object.keys(views).forEach((k) => {
    if (views[k].exp.inline || views[k].exp.format === "toast") {
      views[k].destroy();
      delete views[k];
    }
  });
  popupsThisPage = 0;
  decision = null;
  Promise.all([loadShopifyProduct(), fetchDecision()]).then(evaluate, evaluate);
}

const api = {
  show(key: string): void {
    const exp = bundle && bundle.experiences.filter((e) => e.key === key)[0];
    if (exp) show(exp, true);
  },
  hide(key: string): void {
    const v = views[key];
    if (v) v.close(false);
  },
  context(values: Dict): void {
    setContext(values);
  },
  suppress(on: boolean): void {
    suppressed = on !== false;
  },
  on(name: string, fn: (data: Dict) => void): void {
    (handlers[name] = handlers[name] || []).push(fn);
  },
  reset(): void {
    reset();
  },
};

function run(b: Bundle): void {
  bundle = b;
  const client = w.lemu && w.lemu.client;
  // Without consent nothing is written to the visitor's storage.
  useMemoryOnly(!!(client && client.consent === false));
  visitor();
  d.addEventListener("lemu:event", (e: Dict) => {
    const detail = e.detail || {};
    onSiteEvent(detail);
    if (detail.type === "page") setTimeout(newPage, 0);
  });
  onContextChange(() => {
    if (!bundle) return;
    evaluate();
  });
  if (b.pages && b.pages.length && env) embedPages(b, env);
  Promise.all([loadShopifyProduct(), refreshShopifyCart()])
    .then(fetchDecision)
    .then(evaluate, evaluate);
}

function drainQueue(): void {
  const q: Array<[string, unknown[]]> = w.__lemuOnsiteQ || [];
  w.__lemuOnsiteQ = [];
  q.forEach(([name, args]) => {
    const fn = (api as Dict)[name];
    if (typeof fn === "function") safe(() => fn.apply(api, args));
  });
}

/** The experience editor's live preview: an iframe that sets
 * ``__lemuEditorPreview = {host, bundle, variant}`` before loading this
 * script. Forms answer with a pretend success. */
function editorPreview(config: Dict): void {
  env = { host: config.host, key: PREVIEW_KEY, anonymousId: () => "preview", userId: () => null, track: () => undefined };
  const b = config.bundle as Bundle;
  b.experiences.forEach((e) => (e.preview = true));
  bundle = b;
  useMemoryOnly(true);
  onReady(() => {
    const exp = b.experiences[0];
    if (exp) show(exp, true, config.variant);
  });
  w.__lemuOnsiteRefresh = (next: Dict) => {
    Object.keys(views).forEach((k) => views[k].destroy());
    Object.keys(views).forEach((k) => delete views[k]);
    editorPreview({ ...config, ...next });
  };
}

function boot(): void {
  if (w.__lemuOnsite) return;
  w.__lemuOnsite = api;
  if (w.__lemuEditorPreview) return editorPreview(w.__lemuEditorPreview);
  env = makeEnv();
  if (!env) {
    // lemu.js not initialised yet: try again shortly (for up to a minute).
    w.__lemuOnsite = null;
    if (bootTries++ < 200) setTimeout(boot, 300);
    return;
  }
  if (w.__lemuPage) hydratePage(d, env, null, w.__lemuPage.page);
  const token = previewToken();
  const start = (b: Bundle | null) => {
    if (b) run(b);
    drainQueue();
  };
  if (token) {
    loadPreview(env.host, token).then((p) => {
      if (!p) return start(null);
      p.experiences.forEach((e) => (e.preview = true));
      bundle = p;
      start(null);
      run(p);
      const exp = p.experiences[0];
      const again = (variant?: string) => {
        Object.keys(views).forEach((k) => views[k].destroy());
        Object.keys(views).forEach((k) => delete views[k]);
        if (exp) show(exp, true, variant);
      };
      onReady(() => {
        toolbar(p, { variant: (k) => again(k), again: () => again(), exit: () => Object.keys(views).forEach((k) => views[k].destroy()) });
        again();
      });
    });
    return;
  }
  const preloaded: Bundle | undefined = w.__lemuOnsiteConfig;
  if (preloaded && preloaded.experiences) return onReady(() => start(preloaded));
  getJSON(`${env.host}/api/v1/pixel/onsite/config?k=${encodeURIComponent(env.key)}`)
    .then((b: Bundle) => onReady(() => start(b && b.live ? b : null)))
    .catch(() => drainQueue());
}

safe(boot);
