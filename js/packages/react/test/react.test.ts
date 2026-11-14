// @vitest-environment jsdom
// @vitest-environment-options {"url": "https://shop.example.com/"}
import { createLemu, LemuEvent, LemuProvider, useLemu, usePageTracking } from "../src/index";
import { act, createElement, useEffect, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { expectAllValid, type Ingest, startIngest } from "../../analytics/test/helpers/ingest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;

let ingest: Ingest;
let root: Root | null = null;

beforeAll(async () => {
  ingest = await startIngest();
});
afterAll(() => ingest.close());
afterEach(() => {
  act(() => root?.unmount());
  root = null;
  expectAllValid(ingest);
  ingest.requests.length = 0;
});

function mount(node: ReturnType<typeof createElement>) {
  const el = document.createElement("div");
  document.body.appendChild(el);
  root = createRoot(el);
  act(() => root!.render(node));
}

describe("@lemuai/react", () => {
  it("LemuProvider inits the client and useLemu returns it", async () => {
    const client = createLemu();
    let seen: unknown = null;
    function Buy() {
      const lemu = useLemu();
      seen = lemu;
      useEffect(() => {
        lemu.track(LemuEvent.AddToCart, { value: 999, currency: "INR" });
      }, [lemu]);
      return null;
    }
    mount(
      createElement(
        LemuProvider,
        { writeKey: "pk_react", client, options: { apiHost: ingest.url, flushInterval: 60000 } },
        createElement(Buy),
      ),
    );
    expect(seen).toBe(client);
    await client.flush();
    const [m] = ingest.messages();
    expect(m.event).toBe("AddToCart");
    expect(m.context.platform).toBe("web");
    expect(ingest.requests[0].body.writeKey).toBe("pk_react");
    client.shutdown();
  });

  it("usePageTracking sends a page on each pathname change", async () => {
    const client = createLemu();
    let navigate: (p: string) => void = () => undefined;
    function Router() {
      const [path, setPath] = useState("/");
      navigate = (p) => {
        history.pushState({}, "", p);
        setPath(p);
      };
      usePageTracking(path);
      return null;
    }
    mount(
      createElement(
        LemuProvider,
        { writeKey: "pk_react", client, options: { apiHost: ingest.url, flushInterval: 60000 } },
        createElement(Router),
      ),
    );
    act(() => navigate("/products"));
    act(() => navigate("/products")); // same path: no new page
    act(() => navigate("/cart"));
    await client.flush();
    expect(ingest.messages().map((m) => m.properties.path)).toEqual(["/", "/products", "/cart"]);
    client.shutdown();
  });
});
