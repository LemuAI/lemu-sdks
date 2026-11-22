import { seen, visitor } from "./state";
import type { Condition, Context, Decision, Dict, Experience } from "./types";
import { bucket, compare, safe, w } from "./util";
import { urlMatches } from "./context";

/* Which experiences may show on this page for this visitor. */

export function whereMatches(exp: Experience, ctx: Context): boolean {
  const include = exp.where.include && exp.where.include.length ? exp.where.include : [{ type: "any" }];
  if (!include.some((r) => urlMatches(r, ctx.page_type))) return false;
  return !(exp.where.exclude || []).some((r) => urlMatches(r, ctx.page_type));
}

function device(): string {
  const ua = String((w.navigator || {}).userAgent || "");
  if (/iPad|Tablet/i.test(ua)) return "tablet";
  if (/Mobi|Android|iPhone/i.test(ua) || (w.innerWidth && w.innerWidth < 768)) return "mobile";
  return "desktop";
}

function urlParam(name: string): string | null {
  const m = String((w.location || {}).search || "").match(new RegExp("[?&]" + name + "=([^&#]*)"));
  return m ? decodeURIComponent(m[1]) : null;
}

export function browserCondition(c: Condition, ctx: Context, userId: string | null): boolean {
  const s = visitor();
  const p = ctx.product || {};
  switch (c.kind) {
    case "visitor":
      return compare(s.visits > 1 ? "returning" : "new", c.op, c.value);
    case "visit_count":
      return compare(s.visits, c.op, c.value);
    case "pages_in_session":
      return compare(s.pages, c.op, c.value);
    case "seconds_on_site":
      return compare((Date.now() - s.sessionStart) / 1000, c.op, c.value);
    case "device":
      return compare(device(), c.op, c.value);
    case "utm_source":
    case "utm_medium":
    case "utm_campaign":
      return compare(ctx.utm[c.kind.slice(4)] || "", c.op, c.value);
    case "referrer":
      return compare(ctx.referrer, c.op || "contains", c.value);
    case "landing_path":
      return compare(ctx.path, c.op || "eq", c.value);
    case "cart_value":
      return compare(ctx.cart.value, c.op, c.value);
    case "cart_items":
      return compare(ctx.cart.items, c.op, c.value);
    case "product_in_stock":
      return p.in_stock === undefined ? false : compare(p.in_stock, c.op, c.value);
    case "product_price":
      return compare(p.price, c.op, c.value);
    case "language":
      return compare(ctx.locale.slice(0, 2), c.op, c.value);
    case "url_param":
      return compare(urlParam(String(c.name || c.param || "")), c.op, c.value);
    case "identified":
      return compare(!!userId, c.op, c.value === undefined ? true : c.value);
    default:
      return true;
  }
}

/** Browser conditions plus the server's answer, with the experience's
 * all / any rule (the server answers its own conditions with the same rule). */
export function whoMatches(exp: Experience, ctx: Context, decision: Decision | null, userId: string | null): boolean {
  const results = (exp.who.conditions || []).map((c) => browserCondition(c, ctx, userId));
  const server = decision ? decision.experiences[exp.key] : undefined;
  if (exp.who.server && !server && !exp.preview) return false; // not answered yet
  if (server && server.hidden) return false;
  const serverCount = exp.who.server_conditions || 0;
  if (exp.who.match === "any") {
    if (!results.length && !serverCount) return true;
    return results.some(Boolean) || (serverCount > 0 && !!server && server.match === true);
  }
  return results.every(Boolean) && (serverCount === 0 || !server || server.match !== false);
}

function localParts(timezone: string): { day: number; minutes: number } {
  const now = new Date();
  const parts = safe(() =>
    new Intl.DateTimeFormat("en-GB", { timeZone: timezone, weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(now)
  );
  if (!parts) return { day: (now.getDay() + 6) % 7, minutes: now.getHours() * 60 + now.getMinutes() };
  const get = (t: string) => (parts.filter((p) => p.type === t)[0] || { value: "" }).value;
  const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  return { day: days.indexOf(get("weekday")), minutes: (Number(get("hour")) % 24) * 60 + Number(get("minute")) };
}

export function scheduleOpen(schedule: Dict): boolean {
  const now = Date.now();
  if (schedule.start && now < Date.parse(schedule.start)) return false;
  if (schedule.end && now >= Date.parse(schedule.end)) return false;
  const tz = schedule.timezone || "Asia/Kolkata";
  const { day, minutes } = localParts(tz);
  if (schedule.days_of_week && schedule.days_of_week.length && schedule.days_of_week.indexOf(day) < 0) return false;
  if (schedule.hours && schedule.hours.from && schedule.hours.to) {
    const toMin = (t: string) => Number(t.split(":")[0]) * 60 + Number(t.split(":")[1] || 0);
    const from = toMin(schedule.hours.from);
    const to = toMin(schedule.hours.to);
    if (from <= to ? minutes < from || minutes >= to : minutes < from && minutes >= to) return false;
  }
  return true;
}

export function frequencyAllows(exp: Experience): boolean {
  const f = exp.frequency || { show: "session" };
  const h = seen(exp.key);
  const s = visitor();
  if (f.stop_after_submit !== false && h.submitted) return false;
  if (f.max_closes && h.closes >= f.max_closes) return false;
  const cooldown = (f.cooldown_hours_after_close == null ? 24 : f.cooldown_hours_after_close) * 3600 * 1000;
  if (h.lastClose && cooldown && Date.now() - h.lastClose < cooldown && !exp.inline) return false;
  switch (f.show) {
    case "always":
      return true;
    case "session":
      return h.sessionShown !== s.session;
    case "day":
      return !h.last || Date.now() - h.last > 24 * 3600 * 1000;
    case "days":
      return !h.last || Date.now() - h.last > (f.days || 7) * 24 * 3600 * 1000;
    case "ever":
      return !h.n;
    default:
      return true;
  }
}

/** Sticky variant (or "holdout") for this visitor. */
export function assign(exp: Experience, visitorId: string): string {
  const h = seen(exp.key);
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
