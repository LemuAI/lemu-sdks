import type { Block, Bundle, Condition, Decision, Dict, Experience, ExperienceState, ScreenRule, Seen, Variant } from "./types";

/*
 * Which in-app messages may show, for whom and how often. The same rules as
 * the website's onsite.js (packages/onsite/src/rules.ts and util.ts), with
 * screens in place of URLs and only the targeting an app can answer.
 */

/** Formats an app can show. */
export const APP_FORMATS = ["popup", "slide_in", "toast", "bar"];
/** Formats that count toward the popup caps. */
export const OVERLAY_FORMATS = ["popup", "slide_in"];

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;

function obj(v: unknown): Dict {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Dict) : {};
}

function num(v: unknown, fallback: number): number {
  const n = Number(v);
  return v == null || v === "" || isNaN(n) ? fallback : n;
}

/** The parts of a config bundle an app uses, or null when nothing is live. */
export function parseBundle(raw: unknown): Bundle | null {
  const b = obj(raw);
  if (!b.live) return null;
  const experiences: Experience[] = [];
  for (const item of Array.isArray(b.experiences) ? b.experiences : []) {
    const e = obj(item);
    if (!e.key || APP_FORMATS.indexOf(String(e.format)) < 0) continue;
    if (e.platform && e.platform !== "app" && e.platform !== "any") continue;
    const variants: Variant[] = (Array.isArray(e.variants) ? e.variants : [])
      .map((v: unknown) => obj(v))
      .filter((v: Dict) => v.key)
      .map((v: Dict) => ({ key: String(v.key), weight: num(v.weight, 0), kind: String(v.kind || "blocks"), content: obj(v.content) }));
    if (!variants.length) continue;
    experiences.push({
      id: num(e.id, 0),
      key: String(e.key),
      format: String(e.format),
      platform: String(e.platform || "any"),
      priority: num(e.priority, 0),
      version: num(e.version, 1),
      schedule: obj(e.schedule),
      where: obj(e.where),
      who: obj(e.who),
      trigger: obj(e.trigger),
      frequency: obj(e.frequency),
      holdout_pct: num(e.holdout_pct, 0),
      capture: obj(e.capture),
      variants,
    });
  }
  return {
    live: true,
    v: b.v ? String(b.v) : undefined,
    theme: obj(b.theme),
    caps: obj(b.caps),
    experiences,
    decide: !!b.decide,
  };
}

// ── Comparisons ─────────────────────────────────────────────────────────────

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

/** Event names match ignoring case, spaces, `_` and `-` (AddToCart = add_to_cart). */
export function sameEvent(configured: unknown, incoming: unknown): boolean {
  const norm = (v: unknown) =>
    String(v || "")
      .toLowerCase()
      .replace(/[\s_-]+/g, "");
  return !!norm(configured) && norm(configured) === norm(incoming);
}

// ── Where, who, when ────────────────────────────────────────────────────────

export function screenMatches(rule: ScreenRule, screen: string): boolean {
  const s = String(screen || "").trim().toLowerCase();
  const v = String(rule.value || "").trim().toLowerCase();
  switch (rule.type) {
    case "any":
      return true;
    case "screen_equals":
      return s === v;
    case "screen_prefix":
      return s.indexOf(v) === 0;
    default:
      return false;
  }
}

export function whereMatches(exp: Experience, screen: string): boolean {
  const include = exp.where.include && exp.where.include.length ? exp.where.include : [{ type: "any" }];
  if (!include.some((r) => screenMatches(r, screen))) return false;
  return !(exp.where.exclude || []).some((r) => screenMatches(r, screen));
}

const APP_CONDITIONS = ["visitor", "visit_count", "identified"];

function appCondition(c: Condition, state: ExperienceState, userId: string | null): boolean {
  switch (c.kind) {
    case "visitor":
      return compare(state.visits > 1 ? "returning" : "new", c.op, c.value);
    case "visit_count":
      return compare(state.visits, c.op, c.value);
    default:
      return compare(!!userId, c.op, c.value === undefined || c.value === null ? true : c.value);
  }
}

/** App conditions plus the server's answer, with the experience's all / any
 * rule. Website-only conditions (cart, UTM, device...) are left out. */
export function whoMatches(exp: Experience, decision: Decision | null, userId: string | null, state: ExperienceState): boolean {
  const results = (exp.who.conditions || []).filter((c) => APP_CONDITIONS.indexOf(c.kind) >= 0).map((c) => appCondition(c, state, userId));
  const server = decision && decision.experiences ? decision.experiences[exp.key] : undefined;
  if (exp.who.server && !server) return false; // not answered yet
  if (server && server.hidden) return false;
  const serverCount = exp.who.server_conditions || 0;
  if (exp.who.match === "any") {
    if (!results.length && !serverCount) return true;
    return results.some(Boolean) || (serverCount > 0 && !!server && server.match === true);
  }
  return results.every(Boolean) && (serverCount === 0 || !server || server.match !== false);
}

function localParts(timezone: string, now: number): { day: number; minutes: number } {
  try {
    const parts = new Intl.DateTimeFormat("en-GB", { timeZone: timezone, weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(now));
    const get = (t: string) => (parts.filter((p) => p.type === t)[0] || { value: "" }).value;
    const day = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(get("weekday"));
    const minutes = (Number(get("hour")) % 24) * 60 + Number(get("minute"));
    if (day >= 0 && !isNaN(minutes)) return { day, minutes };
  } catch (e) {
    /* no Intl time zones on this engine: device time */
  }
  const d = new Date(now);
  return { day: (d.getDay() + 6) % 7, minutes: d.getHours() * 60 + d.getMinutes() };
}

export function scheduleOpen(schedule: Dict, now = Date.now()): boolean {
  if (schedule.start && now < Date.parse(schedule.start)) return false;
  if (schedule.end && now >= Date.parse(schedule.end)) return false;
  const { day, minutes } = localParts(schedule.timezone || "Asia/Kolkata", now);
  if (Array.isArray(schedule.days_of_week) && schedule.days_of_week.length && schedule.days_of_week.indexOf(day) < 0) return false;
  const hours = obj(schedule.hours);
  if (hours.from && hours.to) {
    const toMin = (t: string) => Number(String(t).split(":")[0]) * 60 + Number(String(t).split(":")[1] || 0);
    const from = toMin(hours.from);
    const to = toMin(hours.to);
    if (from <= to ? minutes < from || minutes >= to : minutes < from && minutes >= to) return false;
  }
  return true;
}

export function frequencyAllows(exp: Experience, h: Seen, state: ExperienceState, now = Date.now()): boolean {
  const f = exp.frequency || {};
  if (f.stop_after_submit !== false && h.submitted) return false;
  if (f.max_closes && h.closes >= f.max_closes) return false;
  const cooldown = (f.cooldown_hours_after_close == null ? 24 : f.cooldown_hours_after_close) * HOUR;
  if (h.lastClose && cooldown && now - h.lastClose < cooldown) return false;
  switch (f.show || "session") {
    case "always":
      return true;
    case "session":
      return h.sessionShown !== state.session;
    case "day":
      return !h.last || now - h.last > DAY;
    case "days":
      return !h.last || now - h.last > (f.days || 7) * DAY;
    case "ever":
      return !h.n;
    default:
      return true;
  }
}

// ── Variants ────────────────────────────────────────────────────────────────

/** FNV-1a: stable 0..1 bucket for (visitor, experience). */
export function bucket(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return (h >>> 0) / 0xffffffff;
}

/** Sticky variant (or "holdout") for this visitor; kept in `h.variant`. */
export function assign(exp: Experience, visitorId: string, h: Seen): string {
  const active = exp.variants.map((v) => v.key);
  if (h.variant && (h.variant === "holdout" ? exp.holdout_pct > 0 : active.indexOf(h.variant) >= 0)) return h.variant;
  const roll = bucket(visitorId + ":" + exp.id);
  let chosen: string;
  if (roll * 100 < exp.holdout_pct) chosen = "holdout";
  else {
    const rest = (roll * 100 - exp.holdout_pct) / (100 - exp.holdout_pct || 1);
    const total = exp.variants.reduce((a, v) => a + Math.max(0, v.weight), 0) || 1;
    let acc = 0;
    chosen = exp.variants[exp.variants.length - 1].key;
    for (const v of exp.variants) {
      acc += Math.max(0, v.weight) / total;
      if (rest < acc) {
        chosen = v.key;
        break;
      }
    }
  }
  h.variant = chosen;
  return chosen;
}

// ── Text and theme ──────────────────────────────────────────────────────────

/** `{{answers.size}}`, `{{offer.code}}`. */
export function fill(template: unknown, scopes: Dict): string {
  return String(template == null ? "" : template).replace(/\{\{\s*([a-z_]+)\.([a-z_0-9]+)\s*\}\}/gi, (_m, scope, key) => {
    const s = scopes[scope];
    const v = s && typeof s === "object" ? s[key] : undefined;
    return v == null ? "" : String(v);
  });
}

/** Text without the website's light markdown: `**bold**`, `*italic*`, `[label](url)`. */
export function plainText(text: unknown): string {
  return String(text == null ? "" : text)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, "$1")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1$2")
    .replace(/\*\*/g, "");
}

/** A colour React Native accepts, or the fallback: #rgb, #rrggbb, #rrggbbaa, rgb(), rgba(). */
export function color(value: unknown, fallback: string): string {
  const v = String(value == null ? "" : value).trim();
  if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(v)) return v;
  if (/^rgba?\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+\s*(,\s*[\d.]+\s*)?\)$/i.test(v)) return v;
  return fallback;
}

export interface Theme {
  primary: string;
  text: string;
  background: string;
  muted: string;
  buttonText: string;
  overlay: string;
  radius: number;
  buttonRadius: number;
}

/** The bundle's theme with the variant's style overrides. */
export function theme(base: Dict, style: Dict): Theme {
  const pick = (k: string, styleKey = k) => (style[styleKey] != null && style[styleKey] !== "" ? style[styleKey] : base[k]);
  const radius = style.radius != null ? style.radius : base.radius != null ? base.radius : 12;
  return {
    primary: color(pick("primary_color"), "#111827"),
    text: color(pick("text_color"), "#111827"),
    background: color(pick("background_color", "background"), "#ffffff"),
    muted: color(pick("muted_color"), "#6b7280"),
    buttonText: color(pick("button_text_color"), "#ffffff"),
    overlay: color(pick("overlay_color"), "rgba(17,24,39,0.55)"),
    radius: Number(radius) || 0,
    buttonRadius: base.button_style === "pill" ? 999 : num(base.button_radius, 8),
  };
}

/** Choices of a select / chips / rating / nps field. */
export function options(b: Block): { value: string; label: string }[] {
  if (b.input === "rating") return [1, 2, 3, 4, 5].map((i) => ({ value: String(i), label: String(i) }));
  if (b.input === "nps") return Array.from({ length: 11 }, (_, i) => ({ value: String(i), label: String(i) }));
  return (Array.isArray(b.options) ? b.options : []).map((o: unknown) =>
    o && typeof o === "object" ? { value: String((o as Dict).value), label: String((o as Dict).label || (o as Dict).value) } : { value: String(o), label: String(o) },
  );
}
