/**
 * In-app messages: the rules (same as onsite.js), the manager with a fake
 * network, and the host component rendered to markup.
 */
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ExperiencesHost } from "../src/experiences/host";
import { type ExperienceClient, ExperienceManager, type LemuExperienceEvent, STATE_KEY } from "../src/experiences/manager";
import {
  assign,
  bucket,
  color,
  compare,
  frequencyAllows,
  parseBundle,
  plainText,
  sameEvent,
  scheduleOpen,
  theme,
  whereMatches,
  whoMatches,
} from "../src/experiences/rules";
import type { Dict, Experience, ExperienceState, Seen } from "../src/experiences/types";
import { MESSAGES } from "../src/experiences/view";
import { createLemu, LemuExperiences } from "../src/index";
import { storageMock } from "./mocks/async-storage";
import { mock, opened } from "./mocks/react-native";

const flush = () => new Promise((r) => setTimeout(r, 0));
async function settle(times = 5): Promise<void> {
  for (let i = 0; i < times; i++) await flush();
}

function exp(over: Partial<Experience> = {}): Experience {
  return {
    id: 42,
    key: "welcome",
    format: "popup",
    platform: "app",
    priority: 0,
    version: 3,
    schedule: {},
    where: {},
    who: { match: "all", conditions: [], server: false, server_conditions: 0 },
    trigger: { on: "page_load" },
    frequency: { show: "session", stop_after_submit: true, max_closes: 2, cooldown_hours_after_close: 24 },
    holdout_pct: 0,
    variants: [{ key: "a", weight: 1, kind: "blocks", content: { steps: [{ id: "main", blocks: [{ type: "heading", text: "Hello" }] }] } }],
    ...over,
  };
}

function state(over: Partial<ExperienceState> = {}): ExperienceState {
  return { visits: 1, first: 0, last: 0, session: "s1", sessionStart: 0, popupsThisSession: 0, seen: {}, ...over };
}

function seen(over: Partial<Seen> = {}): Seen {
  return { n: 0, last: 0, closes: 0, lastClose: 0, submitted: 0, ...over };
}

describe("rules", () => {
  it("bucket matches the website's FNV-1a", () => {
    expect(bucket("").toFixed(10)).toBe("0.5043429000");
    expect(bucket("a").toFixed(10)).toBe("0.8908105597");
    expect(bucket("abc:1").toFixed(10)).toBe("0.0781538687");
    expect(bucket("visitor-1:42").toFixed(10)).toBe("0.3183784358");
    expect(bucket("3f1c2d4e-0000-4000-8000-000000000001:7").toFixed(10)).toBe("0.0275701222");
  });

  it("assign gives the same variants as the website, and sticks", () => {
    const e = exp({ id: 42, holdout_pct: 10, variants: [{ key: "a", weight: 50, kind: "blocks", content: {} }, { key: "b", weight: 50, kind: "blocks", content: {} }] });
    const want = ["a", "a", "holdout", "b", "a", "b", "b", "a", "b", "b", "b", "holdout"];
    want.forEach((v, i) => expect(assign(e, "visitor-" + (i + 1), seen())).toBe(v));
    const e2 = exp({ id: 7, variants: [{ key: "control", weight: 1, kind: "blocks", content: {} }, { key: "new", weight: 3, kind: "blocks", content: {} }] });
    const want2 = ["control", "new", "new", "new", "new", "new", "new", "control", "new", "control", "control", "control"];
    want2.forEach((v, i) => expect(assign(e2, "visitor-" + (i + 1), seen())).toBe(v));
    const h = seen({ variant: "b" });
    expect(assign(e, "visitor-1", h)).toBe("b");
    const gone = seen({ variant: "zzz" });
    expect(assign(e, "visitor-1", gone)).toBe("a");
    expect(gone.variant).toBe("a");
    const held = seen({ variant: "holdout" });
    expect(assign({ ...e, holdout_pct: 0 }, "visitor-1", held)).toBe("a");
  });

  it("compare follows the server's rules", () => {
    expect(compare("Returning", "eq", "returning")).toBe(true);
    expect(compare(3, "gte", "3")).toBe(true);
    expect(compare("x", "gt", 1)).toBe(false);
    expect(compare("b", "in", "a, b")).toBe(true);
    expect(compare("b", "not_in", ["a"])).toBe(true);
    expect(compare("Hello", "contains", "ell")).toBe(true);
    expect(compare(true, "eq", "yes")).toBe(true);
    expect(compare(false, "neq", true)).toBe(true);
    expect(compare("", "exists", null)).toBe(false);
    expect(compare([], "not_exists", null)).toBe(true);
  });

  it("sameEvent ignores case, spaces, underscores and dashes", () => {
    expect(sameEvent("AddToCart", "add_to_cart")).toBe(true);
    expect(sameEvent("signup done", "Signup-Done")).toBe(true);
    expect(sameEvent("", "")).toBe(false);
    expect(sameEvent("A", "B")).toBe(false);
  });

  it("whereMatches screens", () => {
    expect(whereMatches(exp(), "")).toBe(true);
    const e = exp({ where: { include: [{ type: "screen_equals", value: "Home" }, { type: "screen_prefix", value: "Product" }], exclude: [{ type: "screen_equals", value: "ProductReviews" }] } });
    expect(whereMatches(e, "home")).toBe(true);
    expect(whereMatches(e, "ProductDetail")).toBe(true);
    expect(whereMatches(e, "ProductReviews")).toBe(false);
    expect(whereMatches(e, "Cart")).toBe(false);
    expect(whereMatches(exp({ where: { include: [{ type: "url_contains", value: "/" }] } }), "Home")).toBe(false);
  });

  it("whoMatches app conditions and the server's answer", () => {
    const returning = exp({ who: { match: "all", conditions: [{ kind: "visitor", op: "eq", value: "returning" }] } });
    expect(whoMatches(returning, null, null, state({ visits: 1 }))).toBe(false);
    expect(whoMatches(returning, null, null, state({ visits: 2 }))).toBe(true);
    const known = exp({ who: { match: "all", conditions: [{ kind: "identified" }, { kind: "cart_value", op: "gt", value: 100 }] } });
    expect(whoMatches(known, null, "u1", state())).toBe(true); // cart_value is website only: left out
    expect(whoMatches(known, null, null, state())).toBe(false);
    const any = exp({ who: { match: "any", conditions: [{ kind: "visit_count", op: "gte", value: 3 }], server: true, server_conditions: 1 } });
    expect(whoMatches(any, null, null, state({ visits: 5 }))).toBe(false); // not answered yet
    expect(whoMatches(any, { known: true, experiences: { welcome: { match: false, hidden: false } } }, null, state({ visits: 5 }))).toBe(true);
    expect(whoMatches(any, { known: true, experiences: { welcome: { match: true, hidden: false } } }, null, state({ visits: 1 }))).toBe(true);
    expect(whoMatches(any, { known: true, experiences: { welcome: { match: true, hidden: true } } }, null, state({ visits: 5 }))).toBe(false);
    const all = exp({ who: { match: "all", conditions: [], server: true, server_conditions: 1 } });
    expect(whoMatches(all, { known: true, experiences: { welcome: { match: false, hidden: false } } }, null, state())).toBe(false);
    expect(whoMatches(all, { known: true, experiences: { welcome: { match: null, hidden: false } } }, null, state())).toBe(true);
  });

  it("frequencyAllows", () => {
    const now = 1_700_000_000_000;
    const s = state({ session: "s1" });
    expect(frequencyAllows(exp(), seen(), s, now)).toBe(true);
    expect(frequencyAllows(exp(), seen({ sessionShown: "s1" }), s, now)).toBe(false);
    expect(frequencyAllows(exp(), seen({ submitted: now - 1 }), s, now)).toBe(false);
    expect(frequencyAllows(exp({ frequency: { show: "always", stop_after_submit: false } }), seen({ submitted: now - 1 }), s, now)).toBe(true);
    expect(frequencyAllows(exp({ frequency: { show: "always", max_closes: 2 } }), seen({ closes: 2 }), s, now)).toBe(false);
    expect(frequencyAllows(exp({ frequency: { show: "always" } }), seen({ closes: 1, lastClose: now - 3600e3 }), s, now)).toBe(false);
    expect(frequencyAllows(exp({ frequency: { show: "always", cooldown_hours_after_close: 0 } }), seen({ closes: 1, lastClose: now - 1 }), s, now)).toBe(true);
    expect(frequencyAllows(exp({ frequency: { show: "day" } }), seen({ last: now - 3600e3 }), s, now)).toBe(false);
    expect(frequencyAllows(exp({ frequency: { show: "day" } }), seen({ last: now - 25 * 3600e3 }), s, now)).toBe(true);
    expect(frequencyAllows(exp({ frequency: { show: "days", days: 3 } }), seen({ last: now - 2 * 86400e3 }), s, now)).toBe(false);
    expect(frequencyAllows(exp({ frequency: { show: "ever" } }), seen({ n: 1 }), s, now)).toBe(false);
  });

  it("scheduleOpen", () => {
    const now = Date.parse("2026-11-23T06:30:00Z"); // Monday 12:00 in Asia/Kolkata
    expect(scheduleOpen({}, now)).toBe(true);
    expect(scheduleOpen({ start: "2026-11-24T00:00:00Z" }, now)).toBe(false);
    expect(scheduleOpen({ end: "2026-11-23T00:00:00Z" }, now)).toBe(false);
    expect(scheduleOpen({ days_of_week: [0], hours: { from: "09:00", to: "21:00" } }, now)).toBe(true);
    expect(scheduleOpen({ days_of_week: [5, 6] }, now)).toBe(false);
    expect(scheduleOpen({ hours: { from: "13:00", to: "21:00" } }, now)).toBe(false);
    expect(scheduleOpen({ hours: { from: "22:00", to: "13:00" } }, now)).toBe(true);
  });

  it("parseBundle keeps app experiences in app formats", () => {
    expect(parseBundle({ live: false })).toBeNull();
    expect(parseBundle(null)).toBeNull();
    const b = parseBundle({
      live: true,
      v: "abc",
      decide: true,
      theme: { primary_color: "#ff0000" },
      caps: { popups_per_session: 2 },
      experiences: [
        { id: 1, key: "a", format: "popup", platform: "app", variants: [{ key: "x", weight: 1, kind: "blocks", content: {} }] },
        { id: 2, key: "b", format: "inline", platform: "app", variants: [{ key: "x", weight: 1, content: {} }] },
        { id: 3, key: "c", format: "bar", platform: "web", variants: [{ key: "x", weight: 1, content: {} }] },
        { id: 4, key: "d", format: "toast", platform: "any", variants: [] },
        { id: 5, key: "e", format: "slide_in", platform: "any", variants: [{ key: "x", weight: 1, content: {} }] },
      ],
    });
    expect(b!.experiences.map((e) => e.key)).toEqual(["a", "e"]);
    expect(b!.decide).toBe(true);
    expect(b!.caps.popups_per_session).toBe(2);
  });

  it("text and theme helpers", () => {
    expect(plainText("Get **10% off** your *first* order. [Terms](https://x.co)")).toBe("Get 10% off your first order. Terms");
    expect(color("#abc", "#000")).toBe("#abc");
    expect(color("rgba(17,24,39,.55)", "#000")).toBe("rgba(17,24,39,.55)");
    expect(color("var(--x)", "#000")).toBe("#000");
    const t = theme({ primary_color: "#112233", radius: 4, button_style: "pill" }, { background: "#fafafa" });
    expect(t).toMatchObject({ primary: "#112233", background: "#fafafa", radius: 4, buttonRadius: 999, text: "#111827" });
  });
});

// ── Manager ─────────────────────────────────────────────────────────────────

const FORM = {
  steps: [
    {
      id: "form",
      blocks: [
        { type: "heading", text: "Get 10% off" },
        { type: "field", name: "email", input: "email", required: true, label: "Email" },
        { type: "field", name: "phone", input: "phone", default_country: "+91" },
        { type: "field", name: "whatsapp", input: "consent", label: "Send me offers on WhatsApp" },
        { type: "button", text: "Get my code", action: "submit" },
        { type: "close", text: "No thanks" },
      ],
    },
    { id: "success", blocks: [{ type: "heading", text: "Your code" }, { type: "offer", show: "both" }] },
  ],
};

function rawExp(over: Dict = {}): Dict {
  return {
    id: 42,
    key: "welcome",
    format: "popup",
    platform: "app",
    priority: 0,
    version: 3,
    schedule: {},
    where: { include: [{ type: "screen_equals", value: "Home" }] },
    who: { match: "all", conditions: [], server: false, server_conditions: 0 },
    trigger: { on: "page_load" },
    frequency: { show: "session", stop_after_submit: true, max_closes: 2, cooldown_hours_after_close: 24 },
    holdout_pct: 0,
    variants: [{ key: "a", weight: 1, kind: "blocks", content: FORM }],
    ...over,
  };
}

interface Fake {
  client: ExperienceClient;
  tracked: Array<[string, Dict]>;
  requests: Array<{ url: string; init: Dict; body: Dict | null }>;
  store: Record<string, string>;
  events: LemuExperienceEvent[];
  copied: string[];
  urls: string[];
  set(o: { config?: Dict; decide?: Dict; submit?: Dict; submitStatus?: number; fail?: boolean }): void;
  flags: { optedOut: boolean; storageAllowed: boolean; anonymousId: string | null; userId: string | null };
}

function fake(config: Dict): Fake {
  const answers: { config?: Dict; decide?: Dict; submit?: Dict; submitStatus?: number; fail?: boolean } = { config, submit: { ok: true } };
  const f: Fake = {
    tracked: [],
    requests: [],
    store: {},
    events: [],
    copied: [],
    urls: [],
    flags: { optedOut: false, storageAllowed: true, anonymousId: "visitor-1", userId: null },
    set: (o) => Object.assign(answers, o),
    client: undefined as unknown as ExperienceClient,
  };
  f.client = {
    writeKey: () => "pk_app",
    host: () => "https://lemu.test",
    anonymousId: () => f.flags.anonymousId,
    userId: () => f.flags.userId,
    track: (event, props) => f.tracked.push([event, props]),
    storage: () => ({
      get: (k: string) => Promise.resolve(f.store[k] || null),
      set: (k: string, v: string) => {
        f.store[k] = v;
        return Promise.resolve();
      },
      remove: (k: string) => {
        delete f.store[k];
        return Promise.resolve();
      },
    }),
    headers: () => ({ "User-Agent": "lemu-react-native/1.0.0 (iOS 17.2; unknown)" }),
    optedOut: () => f.flags.optedOut,
    storageAllowed: () => f.flags.storageAllowed,
    platform: () => "ios",
    log: () => undefined,
    openUrl: (u) => f.urls.push(u),
    copy: (t) => f.copied.push(t),
    fetch: (url: string, init?: Dict) => {
      const body = init && init.body ? JSON.parse(init.body) : null;
      f.requests.push({ url, init: init || {}, body });
      if (answers.fail) return Promise.reject(new Error("offline"));
      let data: Dict | undefined = {};
      let status = 200;
      if (url.indexOf("/onsite/config") >= 0) data = answers.config;
      else if (url.indexOf("/onsite/decide") >= 0) data = answers.decide;
      else if (url.indexOf("/onsite/submit") >= 0) {
        data = answers.submit;
        status = answers.submitStatus || 200;
      }
      return Promise.resolve({ ok: status < 300, status, json: () => Promise.resolve(data) });
    },
  };
  return f;
}

async function started(config: Dict, before?: (f: Fake, m: ExperienceManager) => void): Promise<{ f: Fake; m: ExperienceManager }> {
  const f = fake(config);
  const m = new ExperienceManager(f.client);
  m.on("shown", (e) => f.events.push(e));
  m.on("closed", (e) => f.events.push(e));
  m.on("submitted", (e) => f.events.push(e));
  m.on("clicked", (e) => f.events.push(e));
  if (before) before(f, m);
  await m.start();
  await settle();
  return { f, m };
}

const names = (f: Fake) => f.tracked.map((t) => t[0]);

describe("experience manager", () => {
  const managers: ExperienceManager[] = [];
  afterEach(() => {
    while (managers.length) managers.pop()!.shutdown();
    vi.useRealTimers();
  });

  async function run(config: Dict, before?: (f: Fake, m: ExperienceManager) => void) {
    const r = await started(config, before);
    managers.push(r.m);
    return r;
  }

  it("fetches the config with the write key and shows page_load on a matching screen", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()], theme: {}, caps: {} });
    expect(f.requests[0].url).toBe("https://lemu.test/api/v1/pixel/onsite/config?k=pk_app");
    expect(m.getCurrent()).toBeNull(); // no screen yet; the rule wants Home
    m.onScreen("Settings");
    await settle();
    expect(m.getCurrent()).toBeNull();
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()!.exp.key).toBe("welcome");
    expect(f.tracked).toEqual([["onsite_viewed", { experience_id: 42, experience: "welcome", variant: "a", version: 3, format: "popup", screen: "Home" }]]);
    expect(f.events).toEqual([{ type: "shown", experience: "welcome", variant: "a" }]);
    const saved = JSON.parse(f.store[STATE_KEY]);
    expect(saved.visits).toBe(1);
    expect(saved.seen.welcome).toMatchObject({ n: 1, variant: "a", sessionShown: saved.session });
  });

  it("live: false shows nothing", async () => {
    const { m, f } = await run({ live: false });
    m.onScreen("Home");
    await settle();
    expect(m.show("welcome")).toBe(false);
    expect(f.tracked).toEqual([]);
  });

  it("a user close is counted and the session rule stops a repeat", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()] });
    m.onScreen("Home");
    await settle();
    m.getCurrent()!.close(true);
    expect(m.getCurrent()).toBeNull();
    expect(names(f)).toEqual(["onsite_viewed", "onsite_closed"]);
    expect(f.events[1]).toEqual({ type: "closed", experience: "welcome", variant: "a", byUser: true });
    expect(JSON.parse(f.store[STATE_KEY]).seen.welcome.closes).toBe(1);
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()).toBeNull();
  });

  it("holdout sends onsite_held_out once a session and shows nothing", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp({ holdout_pct: 100, where: {} })] });
    m.onScreen("Home");
    m.onScreen("Cart");
    await settle();
    expect(m.getCurrent()).toBeNull();
    expect(f.tracked).toEqual([["onsite_held_out", { experience_id: 42, experience: "welcome", variant: "holdout", version: 3, format: "popup", screen: "" }]]);
    expect(m.show("welcome")).toBe(false);
    expect(names(f)).toEqual(["onsite_held_out"]);
  });

  it("event triggers, setEnabled and show", async () => {
    const config = { live: true, experiences: [rawExp({ where: {}, trigger: { on: "event", event: "AddToCart" }, frequency: { show: "always", stop_after_submit: false } })] };
    const { f, m } = await run(config);
    m.setEnabled(false);
    expect(m.isEnabled()).toBe(false);
    m.onTrack("add_to_cart", {});
    await settle();
    expect(m.getCurrent()).toBeNull();
    m.setEnabled(true);
    m.onTrack("onsite_viewed", {});
    await settle();
    expect(m.getCurrent()).toBeNull();
    m.onTrack("Add To Cart", {});
    await settle();
    expect(m.getCurrent()).not.toBeNull();
    m.hide();
    expect(names(f)).toEqual(["onsite_viewed"]); // hide is not a user close
    m.setEnabled(false);
    expect(m.show("welcome")).toBe(true);
    expect(m.show("welcome")).toBe(false); // one at a time
    expect(m.show("nope")).toBe(false);
  });

  it("delay triggers wait and stop on a new screen", async () => {
    const { m } = await run({ live: true, experiences: [rawExp({ where: {}, trigger: { on: "delay", seconds: 0.05 } })] });
    m.onScreen("A");
    m.onScreen("B");
    await new Promise((r) => setTimeout(r, 120));
    expect(m.getCurrent()!.exp.key).toBe("welcome");
  });

  it("show before the config arrives shows once it does", async () => {
    let release: () => void = () => undefined;
    const gate = new Promise<void>((r) => (release = r));
    const f = fake({ live: true, experiences: [rawExp({ trigger: { on: "manual" } })] });
    const inner = f.client.fetch!;
    f.client.fetch = (url, init) => gate.then(() => inner(url, init));
    const m = new ExperienceManager(f.client);
    managers.push(m);
    const starting = m.start();
    await settle();
    expect(m.show("welcome")).toBe(false);
    release();
    await starting;
    await settle();
    expect(m.getCurrent()!.exp.key).toBe("welcome");
  });

  it("asks decide first when the audience needs the server", async () => {
    const config = { live: true, decide: true, experiences: [rawExp({ who: { match: "all", conditions: [], server: true, server_conditions: 1 } })] };
    const { f, m } = await run(config, (fk) => fk.set({ decide: { known: true, experiences: { welcome: { match: true, hidden: false } } } }));
    m.onTrack("ViewContent", { content_ids: ["SKU1", "SKU2"] });
    m.onScreen("Home", { sku: "SKU9" });
    await settle();
    const decide = f.requests.filter((r) => r.url.indexOf("/decide") >= 0);
    expect(decide).toHaveLength(1);
    expect(decide[0].body).toEqual({ writeKey: "pk_app", anonymousId: "visitor-1", userId: null, context: { screen: "Home", product: { sku: "SKU9" } } });
    expect(decide[0].init.headers["Content-Type"]).toBe("application/json");
    expect(m.getCurrent()).not.toBeNull();
  });

  it("decide saying hidden keeps it away", async () => {
    const config = { live: true, decide: true, experiences: [rawExp({ who: { match: "all", conditions: [], server: true, server_conditions: 1 } })] };
    const { m } = await run(config, (fk) => fk.set({ decide: { known: true, experiences: { welcome: { match: true, hidden: true } } } }));
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()).toBeNull();
  });

  it("popups_per_session caps automatic popups", async () => {
    const two = [rawExp({ where: {} }), rawExp({ id: 43, key: "second", where: {} })];
    const { m } = await run({ live: true, experiences: two, caps: { popups_per_session: 1 } });
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()!.exp.key).toBe("welcome");
    m.getCurrent()!.close(true);
    m.onScreen("Cart");
    await settle();
    expect(m.getCurrent()).toBeNull();
  });

  it("validates, submits and shows the success step with the offer", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()] }, (fk) =>
      fk.set({ submit: { ok: true, offer: { code: "WELCOME10", headline: "10% off", terms: "One use" } } }),
    );
    m.onScreen("Home");
    await settle();
    const v = m.getCurrent()!;
    await v.submit();
    expect(v.error).toBe(MESSAGES.required);
    expect(v.invalid).toEqual(["email"]);
    v.setValue("email", "not-an-email");
    await v.submit();
    expect(v.error).toBe(MESSAGES.email);
    v.setValue("email", "a@b.co");
    v.setValue("phone", "098765 43210");
    v.setValue("whatsapp", true);
    await v.submit();
    await settle();
    const submit = f.requests.filter((r) => r.url.indexOf("/submit") >= 0);
    expect(submit).toHaveLength(1);
    expect(submit[0].body).toEqual({
      writeKey: "pk_app",
      experience: "welcome",
      variant: "a",
      anonymousId: "visitor-1",
      userId: null,
      fields: { email: "a@b.co", phone: "+919876543210", whatsapp: true },
      context: { screen: "Home", platform: "ios", phone_country: "+91" },
    });
    expect(submit[0].init.headers["Content-Type"]).toBe("application/json");
    expect(v.step!.id).toBe("success");
    expect(v.offer!.code).toBe("WELCOME10");
    expect(f.events.filter((e) => e.type === "submitted")).toEqual([
      { type: "submitted", experience: "welcome", variant: "a", fields: { email: "a@b.co", phone: "+919876543210", whatsapp: true }, offerCode: "WELCOME10" },
    ]);
    expect(JSON.parse(f.store[STATE_KEY]).seen.welcome.submitted).toBeGreaterThan(0);
    v.copyCode();
    expect(f.copied).toEqual(["WELCOME10"]);
    expect(v.copied).toBe(true);
    expect(f.tracked[f.tracked.length - 1]).toEqual(["onsite_clicked", expect.objectContaining({ experience: "welcome", target: "copy_code" })]);
  });

  it("asks for the WhatsApp code and sends it", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()] }, (fk) => fk.set({ submit: { ok: false, verify: true } }));
    m.onScreen("Home");
    await settle();
    const v = m.getCurrent()!;
    v.setValue("email", "a@b.co");
    await v.submit();
    expect(v.otpPending).toBe(true);
    f.set({ submit: { ok: true } });
    v.setOtp("12a34 56");
    await v.submit();
    await settle();
    const bodies = f.requests.filter((r) => r.url.indexOf("/submit") >= 0).map((r) => r.body!);
    expect(bodies[1].otp).toBe("123456");
    expect(v.step!.id).toBe("success");
  });

  it("shows server errors, rate limits and network failures", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()] }, (fk) => fk.set({ submit: { ok: false, errors: { email: "This email can't be used" } } }));
    m.onScreen("Home");
    await settle();
    const v = m.getCurrent()!;
    v.setValue("email", "a@b.co");
    await v.submit();
    expect(v.error).toBe("This email can't be used");
    f.set({ submit: { ok: false }, submitStatus: 429 });
    await v.submit();
    expect(v.error).toBe(MESSAGES.rateLimited);
    f.set({ fail: true });
    await v.submit();
    expect(v.error).toBe(MESSAGES.offline);
    expect(v.busy).toBe(false);
  });

  it("a url button tracks the click, opens the link and closes", async () => {
    const content = { steps: [{ id: "s", blocks: [{ type: "text", text: "Sale" }, { type: "button", text: "Shop", action: "url", url: "https://brand.test/sale" }] }] };
    const { f, m } = await run({ live: true, experiences: [rawExp({ format: "bar", variants: [{ key: "a", weight: 1, kind: "blocks", content }] })] });
    m.onScreen("Home");
    await settle();
    const v = m.getCurrent()!;
    v.press(v.blocks[1]);
    expect(f.urls).toEqual(["https://brand.test/sale"]);
    expect(names(f)).toEqual(["onsite_viewed", "onsite_clicked"]);
    expect(f.tracked[1][1].target).toBe("https://brand.test/sale");
    expect(m.getCurrent()).toBeNull();
    expect(f.events.map((e) => e.type)).toEqual(["shown", "clicked", "closed"]);
  });

  it("a toast hides itself", async () => {
    const content = { layout: { auto_hide_seconds: 0.05 }, steps: [{ id: "s", blocks: [{ type: "text", text: "23 people bought this today" }] }] };
    const { f, m } = await run({ live: true, experiences: [rawExp({ format: "toast", variants: [{ key: "a", weight: 1, kind: "blocks", content }] })] });
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()).not.toBeNull();
    await new Promise((r) => setTimeout(r, 100));
    expect(m.getCurrent()).toBeNull();
    expect(names(f)).toEqual(["onsite_viewed"]);
  });

  it("opted out: nothing shows; consent pending: nothing is written", async () => {
    const { f, m } = await run({ live: true, experiences: [rawExp()] }, (fk) => {
      fk.flags.optedOut = true;
    });
    m.onScreen("Home");
    await settle();
    expect(m.getCurrent()).toBeNull();
    expect(m.show("welcome")).toBe(false);
    f.flags.optedOut = false;
    const r = await run({ live: true, experiences: [rawExp()] }, (fk) => {
      fk.flags.storageAllowed = false;
      fk.flags.anonymousId = null;
    });
    r.m.onScreen("Home");
    await settle();
    expect(r.m.getCurrent()).not.toBeNull();
    expect(r.f.store[STATE_KEY]).toBeUndefined();
  });

  it("refreshes on foreground only after 5 minutes", async () => {
    let now = 1_700_000_000_000;
    const { f, m } = await run({ live: true, experiences: [] }, (fk) => {
      fk.client.now = () => now;
    });
    expect(f.requests).toHaveLength(1);
    now += 60_000;
    m.onForeground();
    await settle();
    expect(f.requests).toHaveLength(1);
    now += 5 * 60_000;
    m.onForeground();
    await settle();
    expect(f.requests).toHaveLength(2);
    const saved = JSON.parse(f.store[STATE_KEY]);
    expect(saved.visits).toBe(1);
    now += 31 * 60_000;
    m.onForeground();
    await settle();
    expect(JSON.parse(f.store[STATE_KEY]).visits).toBe(2);
  });
});

// ── Host component and the client ───────────────────────────────────────────

describe("LemuExperiences", () => {
  beforeEach(() => {
    storageMock.clear();
    mock.reset();
  });

  it("renders a popup's blocks and a close button", async () => {
    const f = fake({ live: true, experiences: [rawExp({ where: {} })] });
    const m = new ExperienceManager(f.client);
    await m.start();
    await settle();
    expect(m.getCurrent()).not.toBeNull();
    const html = renderToStaticMarkup(createElement(ExperiencesHost, { manager: m }));
    expect(html).toContain("<lemu-modal");
    expect(html).toContain("Get 10% off");
    expect(html).toContain('data-accessibilitylabel="Close"');
    expect(html).toContain("No thanks");
    expect(html).toContain("Send me offers on WhatsApp");
    expect(html).toContain("+91");
    m.shutdown();
    expect(renderToStaticMarkup(createElement(ExperiencesHost, { manager: m }))).toBe("");
  });

  it("works through the client: config, screen(), onsite_viewed in the batch", async () => {
    const requests: Array<{ url: string; init: Dict }> = [];
    const config = { live: true, experiences: [rawExp({ format: "bar", variants: [{ key: "a", weight: 1, kind: "blocks", content: { steps: [{ id: "s", blocks: [{ type: "text", text: "Free shipping over **999**" }, { type: "button", text: "Shop", action: "url", url: "https://brand.test" }] }] } }] })] };
    vi.stubGlobal("fetch", (url: string, init: Dict) => {
      requests.push({ url, init });
      const data = url.indexOf("/onsite/config") >= 0 ? config : {};
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(data) });
    });
    const c = createLemu();
    try {
      c.init("pk_app", { apiHost: "https://lemu.test", flushInterval: 60000, trackLifecycle: false, trackDeepLinks: false, deviceInfo: null });
      await c.ready();
      await settle(10);
      expect(requests[0].url).toBe("https://lemu.test/api/v1/pixel/onsite/config?k=pk_app");
      expect(requests[0].init.headers["User-Agent"]).toMatch(/^lemu-react-native\//);
      c.screen("Home");
      await settle(10);
      const html = renderToStaticMarkup(createElement(LemuExperiences, { client: c }));
      expect(html).toContain("Free shipping over 999");
      c.experiences.getCurrent()!.press({ type: "button", action: "url", url: "https://brand.test" });
      expect(opened).toEqual(["https://brand.test"]);
      await c.flush();
      const batch = requests.filter((r) => r.url.indexOf("/pixel/batch") >= 0).flatMap((r) => JSON.parse(r.init.body).batch);
      expect(batch.map((m: Dict) => m.event || m.type)).toEqual(["screen", "onsite_viewed", "onsite_clicked"]);
      expect(batch[1].properties).toEqual({ experience_id: 42, experience: "welcome", variant: "a", version: 3, format: "bar", screen: "Home" });
    } finally {
      c.shutdown();
      vi.unstubAllGlobals();
    }
  });

  it("inAppMessages: false fetches nothing", async () => {
    const requests: string[] = [];
    vi.stubGlobal("fetch", (url: string) => {
      requests.push(url);
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) });
    });
    const c = createLemu();
    try {
      c.init("pk_app", { apiHost: "https://lemu.test", flushInterval: 60000, trackLifecycle: false, trackDeepLinks: false, deviceInfo: null, inAppMessages: false });
      await c.ready();
      await settle(10);
      c.screen("Home");
      await settle(10);
      expect(requests.filter((u) => u.indexOf("/onsite/") >= 0)).toEqual([]);
      expect(c.experiences.show("welcome")).toBe(false);
    } finally {
      c.shutdown();
      vi.unstubAllGlobals();
    }
  });
});
