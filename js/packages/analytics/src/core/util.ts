import type { Campaign, Properties } from "./types";

declare const crypto: { randomUUID?: () => string; getRandomValues?: (a: Uint8Array) => Uint8Array } | undefined;

/** UUID v4. Uses the platform's crypto when there is one. */
export function uuid(): string {
  const c = typeof crypto !== "undefined" ? crypto : undefined;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  const bytes = new Uint8Array(16);
  if (c && typeof c.getRandomValues === "function") c.getRandomValues(bytes);
  else for (let i = 0; i < 16; i++) bytes[i] = (Math.random() * 256) | 0;
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  let hex = "";
  for (let i = 0; i < 16; i++) hex += (bytes[i] + 0x100).toString(16).slice(1);
  return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
}

export function isoNow(): string {
  return new Date().toISOString();
}

export function isThenable<T>(value: unknown): value is Promise<T> {
  return !!value && typeof (value as { then?: unknown }).then === "function";
}

/** Calls `done` with the resolved values, synchronously when none of them is a promise. */
export function settleAll<T>(values: Array<T | Promise<T>>, done: (resolved: Array<T | undefined>) => void): void {
  if (values.some(isThenable)) {
    Promise.all(values.map((v) => Promise.resolve(v).catch(() => undefined))).then(done, () => done([]));
  } else {
    done(values as T[]);
  }
}

/** A JSON-safe copy of a plain object, or `{}` for anything else. */
export function cleanProps(value: unknown): Properties {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const copy = JSON.parse(JSON.stringify(value));
  return copy && typeof copy === "object" ? copy : {};
}

const CAMPAIGN_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid"];

/** UTM parameters (without `utm_`) plus gclid and fbclid from a URL or query string. */
export function parseCampaign(url: string | null | undefined): Campaign {
  const out: Record<string, string> = {};
  if (!url) return out;
  const q = url.indexOf("?");
  if (q < 0) return out;
  const query = url.slice(q + 1).split("#")[0];
  const parts = query.split("&");
  for (let i = 0; i < parts.length; i++) {
    const eq = parts[i].indexOf("=");
    const key = decode(eq < 0 ? parts[i] : parts[i].slice(0, eq));
    const value = eq < 0 ? "" : decode(parts[i].slice(eq + 1));
    if (value && CAMPAIGN_KEYS.indexOf(key) >= 0 && !out[key.replace("utm_", "")]) {
      out[key.replace("utm_", "")] = value;
    }
  }
  return out;
}

function decode(s: string): string {
  try {
    return decodeURIComponent(s.replace(/\+/g, " "));
  } catch (e) {
    return s;
  }
}

export function hasKeys(o: object | undefined): boolean {
  if (!o) return false;
  for (const k in o) if (Object.prototype.hasOwnProperty.call(o, k)) return true;
  return false;
}
