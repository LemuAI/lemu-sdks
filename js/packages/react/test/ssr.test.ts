// @vitest-environment node
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { createLemu, LemuProvider, useLemu, usePageTracking } from "../src/index";

describe("server rendering", () => {
  it("renders without window and the client is a no-op", async () => {
    expect(typeof window).toBe("undefined");
    const client = createLemu();
    function Page() {
      const lemu = useLemu();
      lemu.track("RenderedOnServer");
      lemu.identify("u1", { email: "a@b.co" });
      lemu.purchase({ value: 1, currency: "INR", order_id: "1" });
      usePageTracking("/");
      return createElement("p", null, "ok");
    }
    const html = renderToString(createElement(LemuProvider, { writeKey: "pk", client }, createElement(Page)));
    expect(html).toBe("<p>ok</p>");
    expect(client.anonymousId()).toBeNull();
    await expect(client.flush()).resolves.toBeUndefined();
  });
});
