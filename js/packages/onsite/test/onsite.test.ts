import { beforeEach, describe, expect, it, vi } from "vitest";

import { View } from "../src/render";
import { assign, frequencyAllows, scheduleOpen, whereMatches, whoMatches } from "../src/rules";
import { reset, seen, visitor } from "../src/state";
import type { Bundle, Context, Env, Experience } from "../src/types";
import { compare, fill, md } from "../src/util";

function experience(over: Partial<Experience> = {}): Experience {
  return {
    id: 7,
    key: "welcome",
    format: "popup",
    platform: "web",
    priority: 100,
    version: 1,
    inline: false,
    schedule: {},
    where: { include: [{ type: "any" }] },
    who: { match: "all", conditions: [], server: false },
    trigger: { on: "page_load" },
    frequency: { show: "session", stop_after_submit: true, max_closes: 2 },
    holdout_pct: 0,
    capture: { fields: { phone: { to: "identity.phone" } }, offer: true },
    variants: [
      {
        key: "a",
        weight: 100,
        kind: "blocks",
        content: {
          steps: [
            {
              id: "form",
              blocks: [
                { type: "heading", text: "Get **10%** off" },
                { type: "field", name: "phone", input: "phone", label: "Phone", required: true },
                { type: "field", name: "whatsapp_optin", input: "consent", label: "Updates on WhatsApp", checked: true },
                { type: "button", text: "Unlock" },
              ],
            },
            { id: "success", blocks: [{ type: "heading", text: "Your code" }, { type: "offer", show: "code" }] },
          ],
          layout: { size: "m" },
        },
      },
    ],
    ...over,
  };
}

const bundle: Bundle = {
  live: true,
  theme: { primary_color: "#e11d48" },
  page_types: [],
  zones: [{ name: "product.below_price", selector: ".price", position: "after" }],
  caps: {},
  experiences: [],
  pages: [],
  decide: false,
};

function ctx(over: Partial<Context> = {}): Context {
  return { url: "https://shop.test/", path: "/", referrer: "", page_type: "home", cart: { value: 0, items: 0 }, utm: {}, locale: "en", ...over };
}

const env: Env = { host: "https://api.test", key: "wk_1", anonymousId: () => "anon-1", userId: () => null, track: vi.fn() };

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  reset();
  document.body.innerHTML = "";
});

describe("util", () => {
  it("compares like the server", () => {
    expect(compare(5, "gte", 3)).toBe(true);
    expect(compare("Instagram", "eq", "instagram")).toBe(true);
    expect(compare("a", "in", ["b", "a"])).toBe(true);
    expect(compare(false, "eq", false)).toBe(true);
    expect(compare("", "exists", null)).toBe(false);
  });

  it("escapes text and keeps light formatting", () => {
    expect(md("<b>x</b> **bold**")).toBe("&lt;b&gt;x&lt;/b&gt; <strong>bold</strong>");
    expect(md("[go](javascript:alert(1))")).not.toContain("href");
    expect(fill("Size {{answers.size}} of {{product.title}}", { answers: { size: 9 }, product: { title: "Runner" } })).toBe("Size 9 of Runner");
  });
});

describe("rules", () => {
  it("matches pages and visitors", () => {
    const exp = experience({ where: { include: [{ type: "page_type", value: "product" }] } });
    expect(whereMatches(exp, ctx({ page_type: "product" }))).toBe(true);
    expect(whereMatches(exp, ctx({ page_type: "home" }))).toBe(false);
    const who = experience({ who: { match: "all", conditions: [{ kind: "cart_value", op: "gte", value: 500 }], server: false } });
    expect(whoMatches(who, ctx({ cart: { value: 999, items: 1 } }), null, null)).toBe(true);
    expect(whoMatches(who, ctx(), null, null)).toBe(false);
  });

  it("waits for the server's answer and respects it", () => {
    const exp = experience({ who: { match: "all", conditions: [], server: true, server_conditions: 1 } });
    expect(whoMatches(exp, ctx(), null, null)).toBe(false);
    expect(whoMatches(exp, ctx(), { known: true, experiences: { welcome: { match: true, hidden: false } } }, null)).toBe(true);
    expect(whoMatches(exp, ctx(), { known: true, experiences: { welcome: { match: true, hidden: true } } }, null)).toBe(false);
  });

  it("caps how often and remembers submits", () => {
    const exp = experience();
    expect(frequencyAllows(exp)).toBe(true);
    seen("welcome").sessionShown = visitor().session;
    expect(frequencyAllows(exp)).toBe(false);
    const always = experience({ frequency: { show: "always", stop_after_submit: true } });
    seen("welcome").submitted = Date.now();
    expect(frequencyAllows(always)).toBe(false);
  });

  it("keeps a visitor in one variant and honours the holdout", () => {
    const exp = experience({ holdout_pct: 50, variants: [...experience().variants, { ...experience().variants[0], key: "b" }] });
    const first = assign(exp, "visitor-x");
    expect(assign(exp, "visitor-x")).toBe(first);
    const counts: Record<string, number> = {};
    for (let i = 0; i < 2000; i++) {
      reset();
      const v = assign(exp, "v" + i);
      counts[v] = (counts[v] || 0) + 1;
    }
    expect(counts.holdout).toBeGreaterThan(800);
    expect(counts.holdout).toBeLessThan(1200);
    expect(counts.a).toBeGreaterThan(350);
  });

  it("checks schedule dates", () => {
    expect(scheduleOpen({ end: "2000-01-01T00:00:00Z" })).toBe(false);
    expect(scheduleOpen({ start: "2000-01-01T00:00:00Z" })).toBe(true);
  });
});

describe("render", () => {
  it("shows a popup in a shadow root, submits and reveals the code", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ status: 200, ok: true, json: () => Promise.resolve({ ok: true, offer: { code: "WELCOME10" } }) });
    (window as any).fetch = fetchMock;
    const closed = vi.fn();
    const view = new View(experience(), experience().variants[0], bundle, ctx(), env, { closed, submitted: vi.fn(), show: vi.fn() });
    expect(view.mount()).toBe(true);
    const root = view.root!;
    expect(root.querySelector("h2")!.innerHTML).toContain("<strong>10%</strong>");
    const input = root.querySelector('input[name="phone"]') as HTMLInputElement;
    input.value = "98765 43210";
    root.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    await new Promise((r) => setTimeout(r, 10));
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body.experience).toBe("welcome");
    expect(body.fields.phone).toBe("+919876543210");
    expect(body.fields.whatsapp_optin).toBe(true);
    expect(root.textContent).toContain("WELCOME10");
    expect(seen("welcome").submitted).toBeGreaterThan(0);
  });

  it("asks for required fields before sending", () => {
    (window as any).fetch = vi.fn();
    const view = new View(experience(), experience().variants[0], bundle, ctx(), env, { closed: vi.fn(), submitted: vi.fn(), show: vi.fn() });
    view.mount();
    view.root!.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect((window as any).fetch).not.toHaveBeenCalled();
    expect((view.root!.querySelector('[data-lx="error"]') as HTMLElement).hidden).toBe(false);
  });

  it("places a widget after its zone and closes on demand", () => {
    document.body.innerHTML = '<div class="price">₹999</div><div class="next"></div>';
    const exp = experience({ format: "widget", inline: true, where: { include: [{ type: "any" }], placement: { zone: "product.below_price" } } });
    const closed = vi.fn();
    const view = new View(exp, exp.variants[0], bundle, ctx(), env, { closed, submitted: vi.fn(), show: vi.fn() });
    expect(view.mount()).toBe(true);
    expect(document.querySelector(".price")!.nextElementSibling!.getAttribute("data-lemu-experience")).toBe("welcome");
    view.close(true);
    expect(document.querySelector("[data-lemu-experience]")).toBeNull();
    expect(closed).toHaveBeenCalledWith(view, true);
  });

  it("doesn't mount a widget whose element is missing", () => {
    const exp = experience({ format: "widget", inline: true, where: { include: [{ type: "any" }], placement: { selector: ".nope" } } });
    const view = new View(exp, exp.variants[0], bundle, ctx(), env, { closed: vi.fn(), submitted: vi.fn(), show: vi.fn() });
    expect(view.mount()).toBe(false);
  });
});
