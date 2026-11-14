// @vitest-environment jsdom
// @vitest-environment-options {"url": "https://shop.example.com/p/1?utm_source=ig&utm_medium=cpc"}
/**
 * Conformance scenarios (sdks/conformance/README.md) for the browser client.
 * App-only scenarios (C13 to C16) are covered by @lemuai/react-native.
 */
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createLemu, LemuBrowser, LemuEvent } from "../src/index";
import { eventNamesFromSpec, expectAllValid, type Ingest, sleep, startIngest, UUID_V4 } from "./helpers/ingest";

let ingest: Ingest;
let client: LemuBrowser;
const clients: LemuBrowser[] = [];

function make(options: Record<string, unknown> = {}): LemuBrowser {
  const c = createLemu();
  clients.push(c);
  c.init("pk_test", { apiHost: ingest.url, flushInterval: 60000, ...options });
  return c;
}

function clearStorage(): void {
  for (const name of ["_lemu_aid", "_lemu_optout"]) document.cookie = `${name}=; path=/; max-age=-1`;
  localStorage.clear();
}

beforeAll(async () => {
  ingest = await startIngest();
});
afterAll(async () => {
  await ingest.close();
});
beforeEach(() => {
  clearStorage();
  ingest.requests.length = 0;
});
afterEach(() => {
  expectAllValid(ingest);
  while (clients.length) clients.pop()!.shutdown();
  vi.restoreAllMocks();
});

describe("web conformance", () => {
  it("C01 track then flush sends one valid request", async () => {
    client = make();
    client.track("AddToCart", { value: 999, currency: "INR" });
    await client.flush();
    expect(ingest.requests).toHaveLength(1);
    const req = ingest.requests[0];
    expect(req.headers["content-type"]).toMatch(/^text\/plain/);
    expect(req.body.writeKey).toBe("pk_test");
    const [m] = req.body.batch;
    expect(m.type).toBe("track");
    expect(m.event).toBe("AddToCart");
    expect(m.properties).toEqual({ value: 999, currency: "INR" });
    expect(m.context.platform).toBe("web");
    expect(m.context.library).toEqual({ name: "lemu-js", version: "1.0.0" });
  });

  it("C02 two tracks share the anonymousId with distinct UUID v4 messageIds", async () => {
    client = make();
    client.track("A");
    client.track("B");
    await client.flush();
    const [a, b] = ingest.messages();
    expect(a.anonymousId).toBe(b.anonymousId);
    expect(a.messageId).not.toBe(b.messageId);
    expect(a.messageId).toMatch(UUID_V4);
    expect(b.messageId).toMatch(UUID_V4);
    expect(a.anonymousId).toMatch(UUID_V4);
  });

  it("C03 identify sets userId on later messages", async () => {
    client = make();
    client.identify("u1", { email: "a@b.co" });
    client.track("X");
    await client.flush();
    const [identify, track] = ingest.messages();
    expect(identify.type).toBe("identify");
    expect(identify.userId).toBe("u1");
    expect(identify.traits).toEqual({ email: "a@b.co" });
    expect(track.userId).toBe("u1");
  });

  it("C04 reset gives a new anonymousId and clears userId", async () => {
    client = make();
    client.identify("u1", { email: "a@b.co" });
    client.track("X");
    await client.flush();
    const before = ingest.messages()[1];
    client.reset();
    client.track("X");
    await client.flush();
    const after = ingest.messages()[2];
    expect(after.anonymousId).not.toBe(before.anonymousId);
    expect(after.userId).toBeUndefined();
    expect(localStorage.getItem("_lemu_uid")).toBeNull();
  });

  it("C05 purchase is sent at once", async () => {
    client = make();
    client.purchase({ value: 1499.5, currency: "INR", order_id: "1042", content_ids: ["SKU1"] });
    await ingest.waitFor(1);
    const [m] = ingest.messages();
    expect(m.event).toBe("Purchase");
    expect(m.properties).toMatchObject({ value: 1499.5, currency: "INR", order_id: "1042", content_ids: ["SKU1"] });
  });

  it("C05 purchase accepts orderId as an alias", async () => {
    client = make();
    client.purchase({ value: 10, currency: "INR", orderId: 7 } as never);
    await ingest.waitFor(1);
    expect(ingest.messages()[0].properties).toEqual({ value: 10, currency: "INR", order_id: "7" });
  });

  it("C06 ten tracks send without flush()", async () => {
    client = make();
    for (let i = 0; i < 10; i++) client.track("E" + i);
    await ingest.waitFor(1, 500);
    expect(ingest.messages()).toHaveLength(10);
  });

  it("C06 a queued message goes out after flushInterval", async () => {
    client = make({ flushInterval: 50 });
    client.track("Timed");
    await ingest.waitFor(1, 1000);
  });

  it("C07 requireConsent holds messages and writes nothing", async () => {
    client = make({ requireConsent: true });
    client.track("X");
    await client.flush();
    await sleep(50);
    expect(ingest.requests).toHaveLength(0);
    expect(document.cookie).toBe("");
    expect(localStorage.length).toBe(0);
    expect(client.anonymousId()).toBeNull();
    client.setConsent(true);
    await client.flush();
    expect(ingest.requests).toHaveLength(1);
    expect(ingest.messages()[0].event).toBe("X");
    expect(document.cookie).toContain("_lemu_aid=");
  });

  it("C08 setConsent(false) discards held messages", async () => {
    client = make({ requireConsent: true });
    client.track("X");
    client.setConsent(false);
    client.setConsent(true);
    await client.flush();
    await sleep(50);
    expect(ingest.requests).toHaveLength(0);
  });

  it("C09 optOut stops sending and is remembered; optIn resumes", async () => {
    client = make();
    client.optOut();
    client.track("X");
    await client.flush();
    expect(ingest.requests).toHaveLength(0);
    expect(document.cookie).toContain("_lemu_optout=1");

    const second = make();
    second.track("X");
    await second.flush();
    expect(ingest.requests).toHaveLength(0);
    expect(second.anonymousId()).toBeNull();

    second.optIn();
    second.track("Y");
    await second.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["Y"]);
  });

  it("C10 a 500 is retried with backoff and delivered once", async () => {
    client = make();
    ingest.respond(500);
    client.track("X");
    await client.flush();
    expect(ingest.requests).toHaveLength(1);
    await ingest.waitFor(2, 3000);
    const [failed, ok] = ingest.requests;
    expect(failed.status).toBe(500);
    expect(ok.status).toBe(204);
    expect(ok.body.batch.map((m: { messageId: string }) => m.messageId)).toEqual(
      failed.body.batch.map((m: { messageId: string }) => m.messageId),
    );
    expect(ingest.messages()).toHaveLength(1);
  });

  it("C11 a 400 drops the batch", async () => {
    client = make();
    ingest.respond(400);
    client.track("X");
    await client.flush();
    await client.flush();
    await sleep(50);
    expect(ingest.requests).toHaveLength(1);
  });

  it("C11 a 401 drops the batch", async () => {
    client = make();
    ingest.respond(401);
    client.track("X");
    await client.flush();
    await client.flush();
    expect(ingest.requests).toHaveLength(1);
  });

  it("C12 a 413 splits the batch in half", async () => {
    client = make();
    ingest.respond(413);
    client.track("A");
    client.track("B");
    await client.flush();
    expect(ingest.requests.map((r) => r.body.batch.length)).toEqual([2, 1, 1]);
    expect(ingest.messages().map((m) => m.event)).toEqual(["A", "B"]);
  });

  it("C17 bad arguments never throw and send nothing for an empty name", async () => {
    client = make();
    const circular: Record<string, unknown> = { a: 1 };
    circular.self = circular;
    expect(() => {
      client.track("");
      client.track(null as never);
      client.track(undefined as never, { a: 1 });
      client.track("NullProps", null as never);
      client.track("Circular", circular);
      client.identify(null as never);
      client.purchase(null as never);
      client.page(42 as never);
    }).not.toThrow();
    await client.flush();
    const events = ingest.messages().filter((m) => m.type === "track");
    expect(events.map((m) => m.event)).toEqual(["NullProps", "Circular"]);
    expect(events[0].properties).toEqual({});
    expect(events[1].properties).toEqual({});
  });

  it("C17 a throwing fetch never reaches the caller", async () => {
    client = make();
    const original = window.fetch;
    window.fetch = () => {
      throw new Error("boom");
    };
    try {
      client.track("X");
      await expect(client.flush()).resolves.toBeUndefined();
    } finally {
      window.fetch = original;
    }
  });

  it("C18 sentAt is set at send time, after every timestamp", async () => {
    client = make();
    client.track("A");
    await sleep(15);
    client.track("B");
    await sleep(15);
    await client.flush();
    const body = ingest.requests[0].body;
    for (const m of body.batch) expect(Date.parse(body.sentAt)).toBeGreaterThanOrEqual(Date.parse(m.timestamp));
    expect(Date.parse(body.sentAt)).toBeGreaterThan(Date.parse(body.batch[0].timestamp));
  });

  it("C19 more than 50 messages go in requests of at most 50", async () => {
    client = make({ flushAt: 1000 });
    for (let i = 0; i < 120; i++) client.track("E" + i);
    await client.flush();
    expect(ingest.requests.map((r) => r.body.batch.length)).toEqual([50, 50, 20]);
    expect(ingest.messages()).toHaveLength(120);
  });

  it("C20 every event name in events.json is a LemuEvent constant", () => {
    const values = Object.values(LemuEvent) as string[];
    for (const name of eventNamesFromSpec()) expect(values).toContain(name);
  });
});

describe("web behaviour", () => {
  it("page() sends url, path, title, referrer and UTM campaign", async () => {
    document.title = "Kurta";
    client = make();
    client.page();
    await client.flush();
    const [m] = ingest.messages();
    expect(m.type).toBe("page");
    expect(m.properties).toMatchObject({ url: location.href, path: "/p/1", title: "Kurta" });
    expect(m.context.page.path).toBe("/p/1");
    expect(m.context.campaign).toEqual({ source: "ig", medium: "cpc" });
    expect(m.context.userAgent).toBe(navigator.userAgent);
  });

  it("keeps the visitor id from an existing _lemu_aid cookie", async () => {
    document.cookie = "_lemu_aid=legacy-visitor-1; path=/";
    client = make();
    expect(client.anonymousId()).toBe("legacy-visitor-1");
    expect(localStorage.getItem("_lemu_aid")).toBe("legacy-visitor-1");
  });

  it("falls back to localStorage when the cookie is gone", async () => {
    localStorage.setItem("_lemu_aid", "from-storage");
    client = make();
    expect(client.anonymousId()).toBe("from-storage");
    expect(document.cookie).toContain("_lemu_aid=from-storage");
  });

  it("uses sendBeacon when the page is hidden", async () => {
    const beacons: string[] = [];
    Object.defineProperty(navigator, "sendBeacon", {
      configurable: true,
      value: (_url: string, blob: Blob) => {
        const reader = new FileReader();
        reader.onload = () => beacons.push(String(reader.result));
        reader.readAsText(blob);
        return true;
      },
    });
    try {
      client = make();
      client.track("Leaving");
      window.dispatchEvent(new Event("pagehide"));
      await sleep(20);
      expect(beacons).toHaveLength(1);
      expect(JSON.parse(beacons[0]).batch[0].event).toBe("Leaving");
      await client.flush();
      expect(ingest.requests).toHaveLength(0);
    } finally {
      delete (navigator as unknown as Record<string, unknown>).sendBeacon;
    }
  });

  it("trackPageChanges sends page() on pushState and popstate", async () => {
    client = make({ trackPageChanges: true });
    history.pushState({}, "", "/checkout");
    await sleep(10);
    history.pushState({}, "", "/checkout"); // same URL: no second page
    await sleep(10);
    await client.flush();
    const pages = ingest.messages().filter((m) => m.type === "page");
    expect(pages.map((p) => p.properties.path)).toEqual(["/checkout"]);
    history.pushState({}, "", "/p/1?utm_source=ig&utm_medium=cpc");
  });

  it("calls made before init run after it", async () => {
    const c = createLemu();
    clients.push(c);
    c.track("Early");
    expect(c.anonymousId()).toBeNull();
    c.init("pk_test", { apiHost: ingest.url, flushInterval: 60000 });
    await c.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["Early"]);
  });

  it("debug mode logs calls and responses", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    client = make({ debug: true });
    client.track("X");
    await client.flush();
    const lines = log.mock.calls.map((c) => c.join(" "));
    expect(lines.some((l) => l.includes("[lemu] track"))).toBe(true);
    expect(lines.some((l) => l.includes("[lemu] request"))).toBe(true);
    expect(lines.some((l) => l.includes("[lemu] response 204"))).toBe(true);
  });
});
