/**
 * The snippet build (dist/lemu.js) is a drop-in replacement for the original
 * website pixel script. This runs it in Node against a minimal fake browser
 * with the assertions the original script was tested with, plus purchase()
 * and the size and syntax budgets.
 *
 * The bundle is built in memory with the settings from tsup.config.ts, so the
 * test doesn't depend on `npm run build` having run.
 */
import { parse } from "acorn";
import { build } from "esbuild";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { gzipSync } from "node:zlib";
import { beforeAll, describe, expect, it } from "vitest";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let source = "";

beforeAll(async () => {
  const out = await build({
    entryPoints: [resolve(ROOT, "src/snippet.ts")],
    bundle: true,
    format: "iife",
    platform: "browser",
    target: "es2017",
    minify: true,
    write: false,
  });
  source = out.outputFiles[0].text;
});

/* eslint-disable @typescript-eslint/no-explicit-any */
interface Sent {
  via: "fetch" | "beacon";
  url: string;
  body: string;
  type?: string;
}

// A minimal browser: cookies, localStorage, timers we fire by hand, fetch and
// sendBeacon that record what was sent. Same as the Python test's harness.
function browser(queue: unknown[][], opts: { scriptSrc?: string; cookies?: Record<string, string> } = {}) {
  const sent: Sent[] = [];
  const timers: Array<() => void> = [];
  const store: Record<string, string> = {};
  const listeners: Record<string, () => void> = {};
  const jar: Record<string, string> = { ...opts.cookies };
  const doc: any = {
    referrer: "https://www.google.com/",
    title: "Kurta",
    visibilityState: "visible",
    currentScript: { src: opts.scriptSrc ?? "https://app.test/api/v1/pixel/sdk.js" },
    getElementsByTagName: () => [],
    addEventListener: (name: string, fn: () => void) => {
      listeners[name] = fn;
    },
  };
  Object.defineProperty(doc, "cookie", {
    get: () =>
      Object.entries(jar)
        .map(([k, v]) => `${k}=${v}`)
        .join("; "),
    set: (raw: string) => {
      const [pair, ...attrs] = raw.split("; ");
      const [k, v] = pair.split("=");
      const expired = attrs.some((a) => a.startsWith("max-age=-"));
      if (expired) delete jar[k];
      else jar[k] = v;
    },
  });
  const win: any = {
    lemu: Object.assign(function () {}, { q: queue }),
    location: {
      href: "https://shop.example.com/p/1?utm_source=ig",
      pathname: "/p/1",
      search: "?utm_source=ig",
      protocol: "https:",
    },
    navigator: {
      userAgent: "Mozilla/5.0",
      language: "en-IN",
      sendBeacon: (url: string, blob: { text: string }) => {
        sent.push({ via: "beacon", url, body: blob.text });
        return true;
      },
    },
    history: { pushState() {} },
    localStorage: {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v);
      },
      removeItem: (k: string) => {
        delete store[k];
      },
    },
    crypto: {
      randomUUID: (() => {
        let n = 0;
        return () => `uuid-${++n}`;
      })(),
    },
    fetch: (url: string, init: any) => {
      sent.push({ via: "fetch", url, body: init.body, type: init.headers["Content-Type"] });
      return Promise.resolve();
    },
    addEventListener: (name: string, fn: () => void) => {
      listeners[name] = fn;
    },
  };
  const sandbox: any = {
    window: win,
    document: doc,
    URLSearchParams,
    JSON,
    Intl,
    Date,
    Math,
    RegExp,
    Object,
    Array,
    String,
    Blob: class {
      text: string;
      constructor(parts: string[]) {
        this.text = parts.join("");
      }
    },
    setTimeout: (fn: () => void) => {
      timers.push(fn);
      return timers.length;
    },
    clearTimeout: () => {},
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return {
    lemu: win.lemu,
    sent,
    jar: () => jar,
    store,
    tick: () => {
      while (timers.length) timers.shift()!();
    },
    hide: () => listeners.pagehide && listeners.pagehide(),
  };
}

function messages(sent: Sent[]): any[] {
  return sent.flatMap((s) => JSON.parse(s.body).batch);
}

describe("legacy snippet (dist/lemu.js)", () => {
  it("sends queued and live calls in batches", () => {
    const b = browser([["page"], ["init", "lpk_1"]]);
    b.lemu("track", "Added to Cart", { sku: "K1" });
    b.tick();
    b.lemu("identify", { email: "a@b.co" }); // flushes at once
    const anon = b.lemu.anonymousId();

    expect(b.sent.every((s) => s.url === "https://app.test/api/v1/pixel/batch")).toBe(true);
    expect(b.sent.every((s) => s.type === "text/plain")).toBe(true); // no CORS preflight
    const bodies = b.sent.map((s) => JSON.parse(s.body));
    expect(bodies.every((body) => body.writeKey === "lpk_1")).toBe(true);
    const ms = messages(b.sent);
    expect(ms.map((m) => m.type)).toEqual(["page", "track", "identify"]);
    expect(ms[1].event).toBe("Added to Cart");
    expect(ms[1].properties).toEqual({ sku: "K1" });
    expect(ms[2].traits).toEqual({ email: "a@b.co" });
    expect(new Set(ms.map((m) => m.anonymousId))).toEqual(new Set([anon]));
    expect(b.jar()._lemu_aid).toBe(anon);
    expect(ms[0].context.campaign).toEqual({ source: "ig" });
    expect(ms[0].context.page.path).toBe("/p/1");
    expect(ms[0].context.platform).toBe("web");
    expect(ms[0].context.library.name).toBe("lemu.js");
  });

  it("holds events in consent mode and sets no cookie", () => {
    const b = browser([["init", "lpk_2", { requireConsent: true }]]);
    b.lemu("page");
    b.tick();
    expect(b.sent).toHaveLength(0);
    expect(b.jar()).toEqual({});
    expect(b.store).toEqual({});
    b.lemu("consent", true);
    b.tick();
    const batches = b.sent.map((s) => JSON.parse(s.body).batch.map((m: any) => [m.type, m.anonymousId]));
    expect(batches).toHaveLength(1);
    expect(batches[0]).toHaveLength(1);
    expect(batches[0][0][0]).toBe("page");
    expect(batches[0][0][1]).toBeTruthy();
  });

  it("stops on opt-out and uses sendBeacon on page hide", () => {
    const b = browser([["init", "lpk_3"]]);
    b.lemu("track", "Viewed Product");
    b.hide();
    b.lemu("optOut");
    b.lemu("track", "Ignored");
    b.tick();
    expect(b.sent.map((s) => [s.via, JSON.parse(s.body).batch.map((m: any) => m.event)])).toEqual([
      ["beacon", ["Viewed Product"]],
    ]);
  });

  it("starts a new visitor on reset", () => {
    const b = browser([["init", "lpk_4"]]);
    const first = b.lemu.anonymousId();
    b.lemu("reset");
    const second = b.lemu.anonymousId();
    expect(first).toBeTruthy();
    expect(second).toBeTruthy();
    expect(first).not.toBe(second);
  });

  it("keeps an existing visitor's _lemu_aid cookie", () => {
    const b = browser([["init", "lpk_5"]], { cookies: { _lemu_aid: "old-visitor" } });
    expect(b.lemu.anonymousId()).toBe("old-visitor");
    expect(b.store._lemu_aid).toBe("old-visitor");
  });

  it("adds purchase(), sent at once", () => {
    const b = browser([["init", "lpk_6"]]);
    b.lemu("purchase", { value: 1499.5, currency: "INR", order_id: "1042" });
    const [m] = messages(b.sent);
    expect(m.event).toBe("Purchase");
    expect(m.properties).toEqual({ value: 1499.5, currency: "INR", order_id: "1042" });
  });

  it("defaults apiHost to app.lemuai.com when loaded from a CDN", () => {
    const b = browser([["init", "lpk_7"]], { scriptSrc: "https://cdn.jsdelivr.net/npm/@lemuai/analytics/dist/lemu.js" });
    b.lemu("track", "X");
    b.tick();
    expect(b.sent[0].url).toBe("https://app.lemuai.com/api/v1/pixel/batch");
  });

  it("accepts an apiHost override", () => {
    const b = browser([["init", "lpk_8", { apiHost: "https://collect.example.com/" }]]);
    b.lemu("track", "X");
    b.tick();
    expect(b.sent[0].url).toBe("https://collect.example.com/api/v1/pixel/batch");
  });

  it("is under 6 KB gzipped and parses as ES2017", () => {
    const gz = gzipSync(source, { level: 9 }).length;
    expect(gz).toBeLessThan(6 * 1024);
    expect(() => parse(source, { ecmaVersion: 2017 })).not.toThrow();
  });
});
