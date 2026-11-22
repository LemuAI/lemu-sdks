import type { Dict } from "./types";

/* eslint-disable @typescript-eslint/no-explicit-any */
export const w: any = typeof window !== "undefined" ? window : {};
export const d: any = typeof document !== "undefined" ? document : {};

export function safe<T>(fn: () => T, fallback?: T): T | undefined {
  try {
    return fn();
  } catch (e) {
    if (w.__lemuDebug) console.log("[lemu onsite]", e); // eslint-disable-line no-console
    return fallback;
  }
}

export function load(key: string, session = false): Dict {
  return (
    safe(() => {
      const raw = (session ? w.sessionStorage : w.localStorage).getItem(key);
      const v = raw ? JSON.parse(raw) : {};
      return v && typeof v === "object" ? v : {};
    }) || {}
  );
}

export function save(key: string, value: unknown, session = false): void {
  safe(() => (session ? w.sessionStorage : w.localStorage).setItem(key, JSON.stringify(value)));
}

/** FNV-1a: stable 0..1 bucket for (visitor, experience). */
export function bucket(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return (h >>> 0) / 0xffffffff;
}

export function esc(value: unknown): string {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Text fields: **bold**, *italic*, [link](url), line breaks; the rest escaped. */
export function md(text: unknown): string {
  let out = esc(text);
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, label, url) =>
    /^(https?:\/\/|\/|#|mailto:|tel:)/.test(url) ? `<a href="${url}" target="_top">${label}</a>` : label
  );
  out = out.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
  return out.replace(/\n/g, "<br>");
}

/** {{answers.size}}, {{product.title}}, {{offer.code}}, {{prize.label}}. */
export function fill(template: string, scopes: Dict): string {
  return String(template || "").replace(/\{\{\s*([a-z_]+)\.([a-z_0-9]+)\s*\}\}/gi, (_m, scope, key) => {
    const s = scopes[scope];
    const v = s && typeof s === "object" ? s[key] : undefined;
    return v == null ? "" : String(v);
  });
}

function truthy(v: unknown): boolean {
  if (typeof v === "string") return ["true", "1", "yes", "y"].indexOf(v.trim().toLowerCase()) >= 0;
  return !!v;
}

/** Same rules as the server's compare (api/services/onsite/decide.py). */
export function compare(actual: unknown, op: string | undefined, expected: unknown): boolean {
  op = op || "eq";
  if (op === "exists") return actual != null && actual !== "" && !(Array.isArray(actual) && !actual.length);
  if (op === "not_exists") return !compare(actual, "exists", expected);
  if (op === "in" || op === "not_in") {
    const list = Array.isArray(expected) ? expected : String(expected).split(",");
    const found = list.some((o) => String(o).trim().toLowerCase() === String(actual).trim().toLowerCase());
    return op === "in" ? found : !found;
  }
  if (op === "contains" || op === "not_contains") {
    const found = String(actual == null ? "" : actual).toLowerCase().indexOf(String(expected).toLowerCase()) >= 0;
    return op === "contains" ? found : !found;
  }
  if (op === "gt" || op === "gte" || op === "lt" || op === "lte") {
    const a = Number(actual);
    const b = Number(expected);
    if (isNaN(a) || isNaN(b)) return false;
    return op === "gt" ? a > b : op === "gte" ? a >= b : op === "lt" ? a < b : a <= b;
  }
  const equal =
    typeof expected === "boolean" || typeof actual === "boolean"
      ? truthy(actual) === truthy(expected)
      : String(actual).trim().toLowerCase() === String(expected).trim().toLowerCase();
  return op === "neq" ? !equal : equal;
}

export function onReady(fn: () => void): void {
  if (d.readyState === "loading") d.addEventListener("DOMContentLoaded", fn, { once: true });
  else fn();
}

export function sameEvent(configured: unknown, incoming: unknown): boolean {
  const norm = (v: unknown) => String(v || "").toLowerCase().replace(/[\s_-]+/g, "");
  return !!configured && norm(configured) === norm(incoming);
}

export function getJSON(url: string): Promise<any> {
  return w.fetch(url, { credentials: "omit" }).then((r: any) => (r.ok ? r.json() : null));
}

export function postJSON(url: string, body: unknown): Promise<{ status: number; data: any }> {
  return w
    .fetch(url, {
      method: "POST",
      credentials: "omit",
      headers: { "Content-Type": "text/plain" },
      body: JSON.stringify(body),
    })
    .then((r: any) => r.json().then((data: any) => ({ status: r.status, data }), () => ({ status: r.status, data: {} })));
}
