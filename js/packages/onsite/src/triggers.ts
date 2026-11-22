import { onContextChange, product } from "./context";
import type { Dict, Experience } from "./types";
import { d, safe, sameEvent, w } from "./util";

/* When an experience appears. ``arm`` calls ``fire`` once (or, for
 * click / event triggers, each time) and returns a function that disarms. */

type Fire = (reason: string) => void;

export function arm(exp: Experience, fire: Fire): () => void {
  const t = exp.trigger || { on: "page_load" };
  const off: Array<() => void> = [];
  const listen = (target: Dict, name: string, fn: (e: Dict) => void, opts?: unknown) => {
    target.addEventListener(name, fn, opts);
    off.push(() => target.removeEventListener(name, fn, opts));
  };
  let done = false;
  const once = (reason: string) => {
    if (done) return;
    done = true;
    fire(reason);
  };
  switch (t.on) {
    case "page_load":
      once("page_load");
      break;
    case "delay": {
      const id = setTimeout(() => once("delay"), Math.max(0, (t.seconds || 0) * 1000));
      off.push(() => clearTimeout(id));
      break;
    }
    case "scroll": {
      const check = () => {
        const doc = d.documentElement;
        const max = Math.max(1, doc.scrollHeight - w.innerHeight);
        if ((w.scrollY / max) * 100 >= (t.percent || 50)) once("scroll");
      };
      listen(w, "scroll", check, { passive: true });
      check();
      break;
    }
    case "exit_intent": {
      // Desktop: the pointer leaves through the top. Phones: a quick scroll
      // back up after reading a while, or the tab being hidden.
      listen(d, "mouseout", (e) => {
        if (!e.relatedTarget && e.clientY <= 0) once("exit_intent");
      });
      let lastY = w.scrollY || 0;
      let lastT = Date.now();
      listen(
        w,
        "scroll",
        () => {
          const y = w.scrollY || 0;
          const now = Date.now();
          const doc = d.documentElement;
          const read = y / Math.max(1, doc.scrollHeight - w.innerHeight);
          if (lastY - y > 120 && now - lastT < 300 && read > 0.15 && w.innerWidth < 900) once("exit_intent");
          lastY = y;
          lastT = now;
        },
        { passive: true }
      );
      break;
    }
    case "inactivity": {
      let id: ReturnType<typeof setTimeout>;
      const reset = () => {
        clearTimeout(id);
        id = setTimeout(() => once("inactivity"), Math.max(5, t.seconds || 30) * 1000);
      };
      ["mousemove", "keydown", "scroll", "touchstart"].forEach((n) => listen(w, n, reset, { passive: true }));
      reset();
      off.push(() => clearTimeout(id));
      break;
    }
    case "click":
      listen(
        d,
        "click",
        (e) => {
          const el = e.target && e.target.closest && safe(() => e.target.closest(t.selector));
          if (el) {
            e.preventDefault();
            fire("click");
          }
        },
        true
      );
      break;
    case "element_visible": {
      const el = safe(() => d.querySelector(t.selector));
      if (el && w.IntersectionObserver) {
        const io = new w.IntersectionObserver((entries: Dict[]) => {
          if (entries.some((x) => x.isIntersecting)) once("element_visible");
        });
        io.observe(el);
        off.push(() => io.disconnect());
      }
      break;
    }
    case "event":
    case "add_to_cart": {
      const name = t.on === "add_to_cart" ? "AddToCart" : t.event;
      listen(d, "lemu:event", (e) => {
        if (e.detail && sameEvent(name, e.detail.event)) fire("event");
      });
      if (t.on === "add_to_cart") {
        // Shopify themes post the add-to-cart form without our event.
        listen(
          d,
          "submit",
          (e) => {
            const form = e.target;
            if (form && String(form.action || "").indexOf("/cart/add") >= 0) setTimeout(() => fire("add_to_cart"), 600);
          },
          true
        );
      }
      break;
    }
    case "out_of_stock_selected": {
      const check = () => {
        const p = product();
        if (p && p.in_stock === false) fire("out_of_stock");
        else hideIfBackInStock(exp);
      };
      onContextChange(check);
      check();
      break;
    }
    default:
      break; // manual: only lemu("onsite.show", key)
  }
  return () => off.forEach((fn) => safe(fn));
}

const backInStock: Record<string, () => void> = {};
export function onBackInStock(key: string, fn: () => void): void {
  backInStock[key] = fn;
}
function hideIfBackInStock(exp: Experience): void {
  const fn = backInStock[exp.key];
  if (fn) safe(fn);
}
