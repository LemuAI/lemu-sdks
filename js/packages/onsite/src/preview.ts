import type { Bundle } from "./types";
import { d, esc, getJSON, safe, w } from "./util";

/*
 * Preview links (?lemu_preview=TOKEN from the experience editor): the draft
 * shows on the brand's real site whatever its rules, with a toolbar to
 * switch variants, show it again, and pick an element for inline
 * placement (the selector goes back to the editor).
 */

const KEY = "_lemu_preview";

export function previewToken(): string | null {
  const m = String((w.location || {}).search || "").match(/[?&]lemu_preview=([^&#]+)/);
  if (m) {
    safe(() => w.sessionStorage.setItem(KEY, decodeURIComponent(m[1])));
    return decodeURIComponent(m[1]);
  }
  return safe(() => w.sessionStorage.getItem(KEY)) || null;
}

export function loadPreview(host: string, token: string): Promise<Bundle | null> {
  return getJSON(`${host}/api/v1/pixel/onsite/preview?t=${encodeURIComponent(token)}`).catch(() => null);
}

export function selectorFor(el: Element): string {
  if (el.id && /^[A-Za-z][\w-]*$/.test(el.id)) return `#${el.id}`;
  const parts: string[] = [];
  let node: Element | null = el;
  while (node && node.nodeType === 1 && parts.length < 4 && node !== d.body) {
    let part = node.tagName.toLowerCase();
    const classes = Array.from(node.classList).filter((c) => /^[A-Za-z][\w-]*$/.test(c) && !/active|selected|open|hover|is-/.test(c)).slice(0, 2);
    if (classes.length) part += "." + classes.join(".");
    const parent: Element | null = node.parentElement;
    if (parent && !classes.length) {
      const same = Array.from(parent.children).filter((c) => c.tagName === node!.tagName);
      if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
    }
    parts.unshift(part);
    if (node.id) {
      parts[0] = `#${node.id}`;
      break;
    }
    node = parent;
  }
  return parts.join(" > ");
}

export function toolbar(bundle: Bundle, actions: { variant(key: string): void; again(): void; exit(): void }): void {
  const exp = bundle.experiences[0];
  if (!exp || d.getElementById("lemu-preview-bar")) return;
  const bar = d.createElement("div");
  bar.id = "lemu-preview-bar";
  bar.style.cssText =
    "position:fixed;left:50%;transform:translateX(-50%);bottom:12px;z-index:2147483646;background:#111827;color:#fff;font:13px system-ui;padding:8px 10px;border-radius:999px;display:flex;gap:8px;align-items:center;box-shadow:0 8px 24px rgba(0,0,0,.3)";
  const btn = (label: string, id: string) => `<button data-p="${id}" style="all:unset;cursor:pointer;padding:4px 10px;border-radius:999px;background:#374151">${esc(label)}</button>`;
  bar.innerHTML =
    `<strong style="padding:0 6px">Preview: ${esc((bundle.preview || { name: exp.key }).name)}</strong>` +
    exp.variants.map((v) => btn(`Variant ${v.key.toUpperCase()}`, "v:" + v.key)).join("") +
    btn("Show again", "again") +
    btn("Pick element", "pick") +
    btn("Exit", "exit");
  bar.addEventListener("click", (e: Event) => {
    const id = ((e.target as HTMLElement).getAttribute && (e.target as HTMLElement).getAttribute("data-p")) || "";
    if (id.indexOf("v:") === 0) actions.variant(id.slice(2));
    else if (id === "again") actions.again();
    else if (id === "pick") pick(bar);
    else if (id === "exit") {
      safe(() => w.sessionStorage.removeItem(KEY));
      bar.remove();
      actions.exit();
    }
  });
  d.body.appendChild(bar);
}

function pick(bar: HTMLElement): void {
  const outline = d.createElement("div");
  outline.style.cssText = "position:fixed;pointer-events:none;border:2px solid #6366f1;background:rgba(99,102,241,.12);z-index:2147483645;transition:all .05s";
  d.body.appendChild(outline);
  const move = (e: MouseEvent) => {
    const el = e.target as Element;
    if (!el || bar.contains(el)) return;
    const r = el.getBoundingClientRect();
    outline.style.left = r.left + "px";
    outline.style.top = r.top + "px";
    outline.style.width = r.width + "px";
    outline.style.height = r.height + "px";
  };
  const click = (e: MouseEvent) => {
    const el = e.target as Element;
    if (!el || bar.contains(el)) return;
    e.preventDefault();
    e.stopPropagation();
    const selector = selectorFor(el);
    d.removeEventListener("mousemove", move, true);
    d.removeEventListener("click", click, true);
    outline.remove();
    safe(() => w.navigator.clipboard.writeText(selector));
    safe(() => w.opener && w.opener.postMessage({ type: "lemu:selector", selector }, "*"));
    w.alert(`Selector copied:\n\n${selector}\n\nPaste it in the experience's placement (it was also sent to the editor if it's open).`);
  };
  d.addEventListener("mousemove", move, true);
  d.addEventListener("click", click, true);
}
