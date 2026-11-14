/** The platform-agnostic core with in-process adapters and fake timers. */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  type Adapters,
  fetchTransport,
  KEYS,
  LemuClient,
  LemuEvent,
  memoryStorage,
  parseCampaign,
  type StorageAdapter,
  type TransportRequest,
  uuid,
  VERSION,
} from "../src/core";
import { eventNamesFromSpec, startIngest, UUID_V4, validateBatch } from "./helpers/ingest";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** A transport that answers with queued statuses (204 by default) and records bodies. */
function fakeTransport() {
  const statuses: Array<number | "network" | "timeout"> = [];
  const bodies: any[] = []; // eslint-disable-line @typescript-eslint/no-explicit-any
  return {
    statuses,
    bodies,
    send(req: TransportRequest) {
      const body = JSON.parse(req.body);
      bodies.push(body);
      if (!validateBatch(body)) throw new Error("invalid body " + req.body);
      const s = statuses.length ? statuses.shift()! : 204;
      if (s === "network") return Promise.reject(new Error("offline"));
      if (s === "timeout") return Promise.reject({ timeout: true });
      return Promise.resolve(s);
    },
  };
}

function client(overrides: Partial<Adapters> = {}) {
  const transport = fakeTransport();
  const storage = memoryStorage();
  const c = new LemuClient({
    platform: "server",
    library: { name: "lemu-test", version: VERSION },
    storage,
    transport,
    context: () => ({}),
    persistQueue: true,
    ...overrides,
  });
  return { c, transport, storage };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
  vi.spyOn(Math, "random").mockReturnValue(0.5); // no jitter
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

async function settle() {
  for (let i = 0; i < 10; i++) await Promise.resolve();
}

describe("core", () => {
  it("backs off 1 s, 2 s, 4 s ... capped at 5 minutes", async () => {
    const { c, transport } = client();
    c.init("k", { flushInterval: 1e9 });
    for (let i = 0; i < 12; i++) transport.statuses.push(503);
    c.track("X");
    await c.flush();
    const gaps: number[] = [];
    let last = Date.now();
    for (let i = 0; i < 11; i++) {
      const before = transport.bodies.length;
      while (transport.bodies.length === before) {
        await vi.advanceTimersByTimeAsync(100);
      }
      gaps.push(Math.round((Date.now() - last) / 100) * 100);
      last = Date.now();
    }
    expect(gaps).toEqual([1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000, 256000, 300000, 300000]);
    c.shutdown();
  });

  it("jitter stays within plus or minus 20%", async () => {
    vi.spyOn(Math, "random").mockReturnValue(0.999);
    const { c, transport } = client();
    c.init("k", { flushInterval: 1e9 });
    transport.statuses.push(500);
    c.track("X");
    await c.flush();
    await vi.advanceTimersByTimeAsync(1150);
    expect(transport.bodies).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(100);
    expect(transport.bodies).toHaveLength(2);
    c.shutdown();
  });

  it("429 and timeouts are retried; 403 is dropped", async () => {
    const { c, transport } = client();
    c.init("k", { flushInterval: 1e9 });
    transport.statuses.push(429, "timeout", 403);
    c.track("X");
    await c.flush();
    await vi.advanceTimersByTimeAsync(1000);
    await vi.advanceTimersByTimeAsync(2000);
    expect(transport.bodies).toHaveLength(3);
    await vi.advanceTimersByTimeAsync(600000);
    expect(transport.bodies).toHaveLength(3);
    c.shutdown();
  });

  it("gives up 20 hours after the server first failed", async () => {
    const { c, transport } = client();
    c.init("k", { flushInterval: 1e9 });
    for (let i = 0; i < 1000; i++) transport.statuses.push(500);
    c.track("X");
    await c.flush();
    await vi.advanceTimersByTimeAsync(21 * 3600e3);
    const sent = transport.bodies.length;
    await vi.advanceTimersByTimeAsync(3600e3);
    expect(transport.bodies.length).toBe(sent);
    c.shutdown();
  });

  it("keeps offline messages up to 7 days, then drops them", async () => {
    const { c, transport } = client();
    c.init("k", { flushInterval: 1e9 });
    for (let i = 0; i < 100000; i++) transport.statuses.push("network");
    c.track("X");
    await c.flush();
    await vi.advanceTimersByTimeAsync(6 * 24 * 3600e3);
    const sent = transport.bodies.length;
    await vi.advanceTimersByTimeAsync(600e3);
    expect(transport.bodies.length).toBeGreaterThan(sent); // still retrying on day 6
    await vi.advanceTimersByTimeAsync(2 * 24 * 3600e3);
    const after = transport.bodies.length;
    await vi.advanceTimersByTimeAsync(3600e3);
    expect(transport.bodies.length).toBe(after);
    c.shutdown();
  });

  it("waits for async storage, keeping calls made meanwhile", async () => {
    const data: Record<string, string> = { [KEYS.anonymousId]: "stored-id", [KEYS.userId]: "u9" };
    const storage: StorageAdapter = {
      get: (k) => new Promise((r) => setTimeout(() => r(data[k] ?? null), 5)),
      set: async (k, v) => {
        data[k] = v;
      },
      remove: async (k) => {
        delete data[k];
      },
    };
    const { c, transport } = client({ storage });
    c.init("k", { flushInterval: 1e9 });
    c.track("Early");
    expect(c.anonymousId()).toBeNull();
    await vi.advanceTimersByTimeAsync(10);
    await c.flush();
    expect(transport.bodies[0].batch[0]).toMatchObject({ event: "Early", anonymousId: "stored-id", userId: "u9" });
    c.shutdown();
  });

  it("never throws when storage and transport throw", async () => {
    const bad: StorageAdapter = {
      get: () => {
        throw new Error("get");
      },
      set: () => {
        throw new Error("set");
      },
      remove: () => Promise.reject(new Error("remove")),
    };
    const { c } = client({
      storage: bad,
      transport: {
        send: () => {
          throw new Error("send");
        },
      },
      context: () => {
        throw new Error("context");
      },
    });
    expect(() => {
      c.init("k");
      c.track("X");
      c.identify("u");
      c.reset();
      c.optOut();
      c.optIn();
      c.anonymousId();
    }).not.toThrow();
    await expect(c.flush()).resolves.toBeUndefined();
    c.shutdown();
  });

  it("persists the queue and restores it in a new instance", async () => {
    const storage = memoryStorage();
    const first = client({ storage });
    first.c.init("k", { flushInterval: 1e9 });
    first.transport.statuses.push("network");
    first.c.track("A");
    await first.c.flush();
    await settle();
    first.c.shutdown();
    expect(JSON.parse(storage.data[KEYS.queue])).toHaveLength(1);
    const second = client({ storage });
    second.c.init("k", { flushInterval: 1e9 });
    await second.c.flush();
    expect(second.transport.bodies[0].batch.map((m: { event: string }) => m.event)).toEqual(["A"]);
    await settle();
    expect(storage.data[KEYS.queue]).toBeUndefined();
    second.c.shutdown();
  });

  it("does not throw on a second init and ignores a missing write key", () => {
    const { c } = client();
    expect(() => c.init("" as never)).not.toThrow();
    c.init("k");
    expect(() => c.init("k2")).not.toThrow();
    c.shutdown();
  });
});

describe("helpers", () => {
  it("uuid() is v4", () => {
    for (let i = 0; i < 20; i++) expect(uuid()).toMatch(UUID_V4);
  });

  it("parseCampaign reads UTM, gclid and fbclid", () => {
    expect(parseCampaign("myapp://p/1?utm_source=ig&utm_medium=story&utm_campaign=diwali%20sale&gclid=G&x=1#top")).toEqual({
      source: "ig",
      medium: "story",
      campaign: "diwali sale",
      gclid: "G",
    });
    expect(parseCampaign("https://x.test/")).toEqual({});
    expect(parseCampaign(undefined)).toEqual({});
  });

  it("fetchTransport sends headers and reports the status", async () => {
    vi.useRealTimers();
    const ingest = await startIngest();
    try {
      ingest.respond(429);
      const t = fetchTransport({ headers: { "Content-Type": "application/json", "User-Agent": "lemu-test/1.0.0 (Node 22; x)" } });
      const status = await t.send({ url: ingest.url + "/api/v1/pixel/batch", body: "{}" });
      expect(status).toBe(429);
      expect(ingest.requests[0].headers["user-agent"]).toBe("lemu-test/1.0.0 (Node 22; x)");
    } finally {
      await ingest.close();
    }
  });

  it("C20 LemuEvent has every event in events.json", () => {
    const values = Object.values(LemuEvent) as string[];
    const names = eventNamesFromSpec();
    expect(names.length).toBeGreaterThan(20);
    for (const name of names) expect(values).toContain(name);
  });

  it("VERSION matches package.json", () => {
    const pkg = JSON.parse(readFileSync(resolve(ROOT, "package.json"), "utf8"));
    expect(VERSION).toBe(pkg.version);
  });
});
