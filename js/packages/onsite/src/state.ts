import type { Dict } from "./types";
import { load, save } from "./util";

/*
 * What the browser remembers per visitor (localStorage, never sent as is):
 * visits, the current session, per-experience history (shown, closed,
 * submitted) and recently viewed products. Frequency caps are checked here.
 */

const KEY = "_lemu_os";
const SESSION_GAP_MS = 30 * 60 * 1000;
const RECENT_MAX = 20;

export interface Seen {
  n: number; // times shown
  last: number;
  closes: number;
  lastClose: number;
  submitted: number;
  variant?: string;
  sessionShown?: string;
  started?: number; // countdown "minutes from first view"
}

export interface VisitorState {
  visits: number;
  first: number;
  last: number;
  session: string;
  sessionStart: number;
  pages: number;
  popupsThisSession: number;
  seen: Record<string, Seen>;
  recent: string[];
  cart: { value: number; items: number };
}

let state: VisitorState | null = null;
let memoryOnly = false;

export function useMemoryOnly(on: boolean): void {
  memoryOnly = on;
}

export function visitor(now = Date.now()): VisitorState {
  if (state) return state;
  const raw = (memoryOnly ? {} : load(KEY)) as Dict;
  const fresh = !raw.session || now - (raw.last || 0) > SESSION_GAP_MS;
  state = {
    visits: (raw.visits || 0) + (fresh ? 1 : 0),
    first: raw.first || now,
    last: now,
    session: fresh ? Math.random().toString(36).slice(2, 10) : raw.session,
    sessionStart: fresh ? now : raw.sessionStart || now,
    pages: (fresh ? 0 : raw.pages || 0) + 1,
    popupsThisSession: fresh ? 0 : raw.popupsThisSession || 0,
    seen: raw.seen || {},
    recent: Array.isArray(raw.recent) ? raw.recent : [],
    cart: raw.cart || { value: 0, items: 0 },
  };
  persist();
  return state;
}

export function persist(): void {
  if (state && !memoryOnly) save(KEY, state);
}

export function seen(key: string): Seen {
  const s = visitor();
  return (s.seen[key] = s.seen[key] || { n: 0, last: 0, closes: 0, lastClose: 0, submitted: 0 });
}

export function rememberProduct(sku: string | undefined): void {
  if (!sku) return;
  const s = visitor();
  s.recent = [sku, ...s.recent.filter((x) => x !== sku)].slice(0, RECENT_MAX);
  persist();
}

export function setCart(value: number, items: number): void {
  const s = visitor();
  s.cart = { value: Math.max(0, value), items: Math.max(0, items) };
  persist();
}

export function reset(): void {
  state = null;
  save(KEY, {});
}
