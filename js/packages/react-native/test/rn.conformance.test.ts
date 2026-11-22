/**
 * Conformance scenarios (sdks/conformance/README.md) for React Native, with
 * react-native and AsyncStorage replaced by test doubles (vitest.config.ts).
 */
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  deadUrl,
  eventNamesFromSpec,
  expectAllValid,
  type Ingest,
  sleep,
  startIngest,
  UUID_V4,
} from "../../analytics/test/helpers/ingest";
import { createLemu, type DeviceInfoLike, LemuEvent, type LemuReactNative, type ReactNativeOptions, trackNavigationState } from "../src/index";
import { storageMock } from "./mocks/async-storage";
import { mock } from "./mocks/react-native";

let ingest: Ingest;
const clients: LemuReactNative[] = [];

/** Lifecycle and deep links are off unless a test turns them on. In-app
 * messages are off too (their config request isn't a batch; see experiences.test.ts). */
async function make(options: ReactNativeOptions = {}): Promise<LemuReactNative> {
  const c = createLemu();
  clients.push(c);
  c.init("pk_rn", {
    apiHost: ingest.url,
    flushInterval: 60000,
    trackLifecycle: false,
    trackDeepLinks: false,
    appVersion: "1.0.0",
    appBuild: "1",
    deviceInfo: null,
    inAppMessages: false,
    ...options,
  });
  await c.ready();
  await settle();
  return c;
}

/** Lets AsyncStorage reads and writes and Linking.getInitialURL settle. */
async function settle(): Promise<void> {
  await sleep(5);
}

function stop(c: LemuReactNative) {
  c.shutdown();
  clients.splice(clients.indexOf(c), 1);
}

beforeAll(async () => {
  ingest = await startIngest();
});
afterAll(() => ingest.close());
beforeEach(() => {
  storageMock.clear();
  mock.reset();
  ingest.requests.length = 0;
});
afterEach(() => {
  expectAllValid(ingest);
  while (clients.length) clients.pop()!.shutdown();
});

describe("react native conformance", () => {
  it("C01 track then flush sends one valid request with a lemu- User-Agent", async () => {
    const c = await make();
    c.track("AddToCart", { value: 999, currency: "INR" });
    await c.flush();
    expect(ingest.requests).toHaveLength(1);
    const req = ingest.requests[0];
    expect(req.headers["user-agent"]).toBe("lemu-react-native/1.0.0 (iOS 17.2; unknown)");
    expect(req.headers["content-type"]).toBe("application/json");
    const [m] = req.body.batch;
    expect(m).toMatchObject({ type: "track", event: "AddToCart", properties: { value: 999, currency: "INR" } });
    expect(m.context.platform).toBe("react_native");
    expect(m.context.library).toEqual({ name: "lemu-react-native", version: "1.0.0" });
    expect(m.context.app).toEqual({ version: "1.0.0", build: "1" });
    expect(m.context.os).toEqual({ name: "iOS", version: "17.2" });
    expect(m.context.device).toEqual({ type: "phone" });
    expect(m.context.screen).toEqual({ width: 1179, height: 2556, density: 3 });
  });

  it("C01 uses react-native-device-info when available", async () => {
    const info: DeviceInfoLike = {
      getVersion: () => "3.2.0",
      getBuildNumber: () => "320",
      getApplicationName: () => "Brand",
      getBundleId: () => "com.brand.app",
      getModel: () => "iPhone15,2",
      getManufacturerSync: () => "Apple",
      getSystemVersion: () => "17.4",
      getDeviceType: () => "Handset",
    };
    const c = await make({ deviceInfo: info });
    c.track("X");
    await c.flush();
    const req = ingest.requests[0];
    expect(req.headers["user-agent"]).toBe("lemu-react-native/1.0.0 (iOS 17.4; iPhone15,2)");
    expect(req.body.batch[0].context.app).toEqual({ name: "Brand", version: "3.2.0", build: "320", namespace: "com.brand.app" });
    expect(req.body.batch[0].context.device).toEqual({ manufacturer: "Apple", model: "iPhone15,2", type: "phone" });
  });

  it("C02 two tracks share the anonymousId with distinct UUID v4 messageIds", async () => {
    const c = await make();
    c.track("A");
    c.track("B");
    await c.flush();
    const [a, b] = ingest.messages();
    expect(a.anonymousId).toBe(b.anonymousId);
    expect(a.anonymousId).toMatch(UUID_V4);
    expect(a.messageId).toMatch(UUID_V4);
    expect(b.messageId).toMatch(UUID_V4);
    expect(a.messageId).not.toBe(b.messageId);
  });

  it("C03 identify sets userId on later messages, also after a restart", async () => {
    const c = await make();
    c.identify("u1", { email: "a@b.co" });
    c.track("X");
    await c.flush();
    const [identify, track] = ingest.messages();
    expect(identify).toMatchObject({ type: "identify", userId: "u1", traits: { email: "a@b.co" } });
    expect(track.userId).toBe("u1");
    await settle();
    stop(c);
    const again = await make();
    again.track("Y");
    await again.flush();
    expect(ingest.messages()[2].userId).toBe("u1");
  });

  it("C04 reset gives a new anonymousId and clears userId", async () => {
    const c = await make();
    c.identify("u1", { email: "a@b.co" });
    c.track("X");
    await c.flush();
    const before = ingest.messages()[1];
    c.reset();
    c.track("X");
    await c.flush();
    const after = ingest.messages()[2];
    expect(after.anonymousId).not.toBe(before.anonymousId);
    expect(after.userId).toBeUndefined();
    await settle();
    expect(storageMock.data._lemu_aid).toBe(after.anonymousId);
    expect(storageMock.data._lemu_uid).toBeUndefined();
  });

  it("C05 purchase is sent at once", async () => {
    const c = await make();
    c.purchase({ value: 1499.5, currency: "INR", order_id: "1042", num_items: 2 });
    await ingest.waitFor(1);
    const [m] = ingest.messages();
    expect(m.event).toBe(LemuEvent.Purchase);
    expect(m.properties).toEqual({ value: 1499.5, currency: "INR", order_id: "1042", num_items: 2 });
  });

  it("C06 twenty tracks send without flush()", async () => {
    const c = await make();
    for (let i = 0; i < 19; i++) c.track("E" + i);
    await sleep(50);
    expect(ingest.requests).toHaveLength(0);
    c.track("E19");
    await ingest.waitFor(1, 1000);
    expect(ingest.messages()).toHaveLength(20);
  });

  it("C07 requireConsent holds messages and writes nothing to storage", async () => {
    const c = await make({ requireConsent: true, trackLifecycle: true });
    c.track("X");
    await c.flush();
    await settle();
    expect(ingest.requests).toHaveLength(0);
    expect(storageMock.writes()).toBe(0);
    expect(c.anonymousId()).toBeNull();
    c.setConsent(true);
    await c.flush();
    expect(ingest.requests).toHaveLength(1);
    expect(ingest.messages().map((m) => m.event)).toEqual(["app_installed", "app_opened", "X"]);
    await settle();
    expect(storageMock.data._lemu_aid).toBe(c.anonymousId());
    expect(storageMock.data._lemu_app_version).toBe("1.0.0");
  });

  it("C08 setConsent(false) discards held messages", async () => {
    const c = await make({ requireConsent: true });
    c.track("X");
    c.setConsent(false);
    c.setConsent(true);
    await c.flush();
    await sleep(30);
    expect(ingest.requests).toHaveLength(0);
  });

  it("C07b granted consent is remembered after a restart; setConsent(false) forgets it", async () => {
    const c = await make({ requireConsent: true });
    c.setConsent(true);
    await settle();
    expect(storageMock.data._lemu_consent).toBe("1");
    stop(c);
    const again = await make({ requireConsent: true });
    again.track("X");
    await again.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["X"]);
    again.setConsent(false);
    await settle();
    expect(storageMock.data._lemu_consent).toBeUndefined();
    stop(again);
    const third = await make({ requireConsent: true });
    third.track("Y");
    await third.flush();
    await sleep(30);
    expect(ingest.messages().map((m) => m.event)).toEqual(["X"]);
  });

  it("C09 optOut stops sending, survives a restart, and optIn resumes", async () => {
    const c = await make();
    c.optOut();
    c.track("X");
    await c.flush();
    await settle();
    expect(ingest.requests).toHaveLength(0);
    stop(c);
    const again = await make();
    again.track("X");
    await again.flush();
    expect(ingest.requests).toHaveLength(0);
    again.optIn();
    again.track("Y");
    await again.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["Y"]);
  });

  it("C10 a 500 is retried and delivered once with the same messageIds", async () => {
    const c = await make();
    ingest.respond(500);
    c.track("X");
    await c.flush();
    await ingest.waitFor(2, 3000);
    const [failed, ok] = ingest.requests;
    expect(failed.status).toBe(500);
    expect(ok.status).toBe(204);
    expect(ok.body.batch[0].messageId).toBe(failed.body.batch[0].messageId);
    expect(ingest.messages()).toHaveLength(1);
  });

  it("C11 a 400 drops the batch", async () => {
    const c = await make();
    ingest.respond(400);
    c.track("X");
    await c.flush();
    await c.flush();
    await settle();
    expect(ingest.requests).toHaveLength(1);
    expect(storageMock.data._lemu_queue).toBeUndefined();
  });

  it("C12 a 413 splits a 2-message batch into two", async () => {
    const c = await make();
    ingest.respond(413);
    c.track("A");
    c.track("B");
    await c.flush();
    expect(ingest.requests.map((r) => r.body.batch.length)).toEqual([2, 1, 1]);
  });

  it("C13 the queue survives a restart while the server is down", async () => {
    const down = await deadUrl();
    const c = await make({ apiHost: down });
    c.track("A");
    c.track("B");
    c.track("C");
    await c.flush();
    await settle();
    expect(JSON.parse(storageMock.data._lemu_queue)).toHaveLength(3);
    stop(c);
    const again = await make();
    await again.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["A", "B", "C"]);
  });

  it("C14 at most 1,000 messages are kept and a Purchase is never the one dropped", async () => {
    const down = await deadUrl();
    const c = await make({ apiHost: down, flushAt: 5000 });
    c.purchase({ value: 1, currency: "INR", order_id: "o-1" });
    for (let i = 0; i < 1000; i++) c.track("E" + i);
    await c.flush();
    await settle();
    const stored = JSON.parse(storageMock.data._lemu_queue);
    expect(stored).toHaveLength(1000);
    expect(stored.some((i: { m: { event: string } }) => i.m.event === "Purchase")).toBe(true);
    stop(c);
    const again = await make({ flushAt: 5000 });
    await again.flush();
    const events = ingest.messages().map((m) => m.event);
    expect(events).toHaveLength(1000);
    expect(events[0]).toBe("Purchase");
    expect(events).not.toContain("E0");
    expect(ingest.requests.every((r) => r.body.batch.length <= 50)).toBe(true);
  });

  it("C14 messages older than 7 days are dropped before sending", async () => {
    const old = Date.now() - 8 * 24 * 3600e3;
    const message = {
      type: "track",
      event: "Old",
      properties: {},
      messageId: "6f1c1d1e-0000-4000-8000-000000000000",
      anonymousId: "a",
      timestamp: new Date(old).toISOString(),
      context: { platform: "react_native", library: { name: "lemu-react-native", version: "1.0.0" } },
    };
    storageMock.data._lemu_queue = JSON.stringify([{ m: message, q: old, n: 1 }]);
    const c = await make();
    c.track("New");
    await c.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["New"]);
  });

  it("C15 app_installed on first launch, app_updated after an upgrade", async () => {
    const first = await make({ trackLifecycle: true });
    await first.flush();
    const installed = ingest.messages().find((m) => m.event === "app_installed");
    expect(installed.properties).toEqual({ version: "1.0.0", build: "1" });
    await settle();
    stop(first);

    ingest.requests.length = 0;
    const second = await make({ trackLifecycle: true, appVersion: "1.1.0", appBuild: "2" });
    await second.flush();
    const events = ingest.messages().map((m) => m.event);
    expect(events).not.toContain("app_installed");
    const updated = ingest.messages().find((m) => m.event === "app_updated");
    expect(updated.properties).toEqual({ version: "1.1.0", build: "2", previous_version: "1.0.0", previous_build: "1" });
    await settle();
    stop(second);

    ingest.requests.length = 0;
    const third = await make({ trackLifecycle: true, appVersion: "1.1.0", appBuild: "2" });
    await third.flush();
    expect(ingest.messages().map((m) => m.event)).toEqual(["app_opened"]);
  });

  it("C16 screen sends a screen message", async () => {
    const c = await make();
    c.screen("Checkout", { step: 2 });
    await c.flush();
    expect(ingest.messages()[0]).toMatchObject({ type: "screen", name: "Checkout", properties: { step: 2 } });
  });

  it("C17 bad arguments never throw and send nothing for an empty name", async () => {
    const c = await make();
    expect(() => {
      c.track("");
      c.track(null as never);
      c.track("NullProps", null as never);
      c.screen("");
      c.screen(undefined as never);
      c.identify(undefined, "nope" as never);
      c.purchase(undefined as never);
      c.init(null as never);
    }).not.toThrow();
    await c.flush();
    const tracks = ingest.messages().filter((m) => m.type !== "identify");
    expect(tracks.map((m) => m.event)).toEqual(["NullProps"]);
    expect(tracks[0].properties).toEqual({});
  });

  it("C18 sentAt is set at send time, after every timestamp", async () => {
    const c = await make();
    c.track("A");
    await sleep(10);
    c.track("B");
    await sleep(10);
    await c.flush();
    const body = ingest.requests[0].body;
    for (const m of body.batch) expect(Date.parse(body.sentAt)).toBeGreaterThanOrEqual(Date.parse(m.timestamp));
  });

  it("C19 more than 50 messages go in requests of at most 50", async () => {
    const c = await make({ flushAt: 1000 });
    for (let i = 0; i < 101; i++) c.track("E" + i);
    await c.flush();
    expect(ingest.requests.map((r) => r.body.batch.length)).toEqual([50, 50, 1]);
  });

  it("C20 every event name in events.json is a LemuEvent constant", () => {
    const values = Object.values(LemuEvent) as string[];
    for (const name of eventNamesFromSpec()) expect(values).toContain(name);
  });
});

describe("react native lifecycle and deep links", () => {
  it("app_opened on start, app_backgrounded with a flush, app_opened from background", async () => {
    const c = await make({ trackLifecycle: true });
    await c.flush();
    expect(ingest.messages().map((m) => [m.event, m.properties])).toEqual([
      ["app_installed", { version: "1.0.0", build: "1" }],
      ["app_opened", { from_background: false }],
    ]);
    c.track("Browse");
    mock.setAppState("inactive");
    mock.setAppState("background");
    await ingest.waitFor(2, 1000); // flushed without flush()
    expect(ingest.requests[1].body.batch.map((m: { event: string }) => m.event)).toEqual(["Browse", "app_backgrounded"]);
    mock.setAppState("active");
    await c.flush();
    expect(ingest.messages().pop()).toMatchObject({ event: "app_opened", properties: { from_background: true } });
  });

  it("the link that opened the app is recorded and its UTM parameters kept", async () => {
    mock.setInitialURL("brand://promo/diwali?utm_source=ig&utm_medium=story&utm_campaign=diwali&referrer=partner");
    const c = await make({ trackLifecycle: true, trackDeepLinks: true });
    c.track("AddToCart");
    await c.flush();
    const byEvent = Object.fromEntries(ingest.messages().map((m) => [m.event, m]));
    expect(byEvent.app_opened.properties).toEqual({ from_background: false, url: "brand://promo/diwali?utm_source=ig&utm_medium=story&utm_campaign=diwali&referrer=partner" });
    expect(byEvent.deep_link_opened.properties.referrer).toBe("partner");
    const campaign = { source: "ig", medium: "story", campaign: "diwali" };
    expect(byEvent.deep_link_opened.context.campaign).toEqual(campaign);
    expect(byEvent.AddToCart.context.campaign).toEqual(campaign);
  });

  it("links opened while running send deep_link_opened", async () => {
    const c = await make({ trackDeepLinks: true });
    mock.openURL("brand://p/1?utm_source=wa");
    c.track("After");
    await c.flush();
    const [link, after] = ingest.messages();
    expect(link).toMatchObject({ event: "deep_link_opened", properties: { url: "brand://p/1?utm_source=wa" } });
    expect(after.context.campaign).toEqual({ source: "wa" });
  });

  it("trackNavigationState sends screen() on route changes", async () => {
    const c = await make();
    let route = { name: "Home" };
    const listeners: Array<() => void> = [];
    const ref = {
      isReady: () => true,
      getCurrentRoute: () => route,
      addListener: (_e: "state", cb: () => void) => {
        listeners.push(cb);
        return () => listeners.splice(listeners.indexOf(cb), 1);
      },
    };
    const stopTracking = trackNavigationState(ref, c);
    route = { name: "Product" };
    listeners.forEach((l) => l());
    listeners.forEach((l) => l()); // same route: nothing new
    route = { name: "Cart" };
    listeners.forEach((l) => l());
    stopTracking();
    expect(listeners).toHaveLength(0);
    await c.flush();
    expect(ingest.messages().map((m) => [m.type, m.name])).toEqual([
      ["screen", "Home"],
      ["screen", "Product"],
      ["screen", "Cart"],
    ]);
  });

  it("trackNavigationState waits for the container to be ready", async () => {
    const c = await make();
    let ready = false;
    const ref = {
      current: {
        isReady: () => ready,
        getCurrentRoute: () => ({ name: "Splash" }),
        addListener: () => () => undefined,
      },
    };
    const stopTracking = trackNavigationState(ref as never, c);
    await sleep(50);
    ready = true;
    await sleep(150);
    stopTracking();
    await c.flush();
    expect(ingest.messages().map((m) => m.name)).toEqual(["Splash"]);
  });
});
