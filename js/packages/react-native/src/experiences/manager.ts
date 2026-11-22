import type { StorageAdapter } from "@lemuai/analytics/core";
import { assign, frequencyAllows, OVERLAY_FORMATS, parseBundle, sameEvent, scheduleOpen, theme, whereMatches, whoMatches } from "./rules";
import type { Bundle, Decision, Dict, Experience, ExperienceState, Seen } from "./types";
import { ExperienceView, type SubmitResult } from "./view";

/*
 * In-app messages: the same experiences the website shows (onsite.js), for
 * apps. Fetches the source's config, follows the app's screens and events,
 * decides what may show (rules.ts), remembers what was shown, sends the
 * onsite_* events and the form submits. <LemuExperiences /> draws it.
 */

export const STATE_KEY = "_lemu_os";
const SESSION_GAP_MS = 30 * 60 * 1000;
const REFRESH_MS = 5 * 60 * 1000;
const DECIDE_TTL_MS = 10 * 60 * 1000;
const TIMEOUT_MS = 15000;

export type LemuExperienceEventType = "shown" | "closed" | "submitted" | "clicked";

export interface LemuExperienceEvent {
  type: LemuExperienceEventType;
  /** The experience's key. */
  experience: string;
  variant: string;
  /** closed: true when the user closed it. */
  byUser?: boolean;
  /** clicked: the URL, or "copy_code". */
  target?: string;
  /** submitted: the values the user entered. */
  fields?: Dict;
  /** submitted: the offer code the server returned, if any. */
  offerCode?: string;
}

type FetchLike = (url: string, init?: Dict) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

/** What the manager needs from the client. */
export interface ExperienceClient {
  writeKey(): string;
  host(): string;
  anonymousId(): string | null;
  userId(): string | null;
  track(event: string, properties: Dict): void;
  storage(): StorageAdapter;
  headers(): Record<string, string>;
  optedOut(): boolean;
  storageAllowed(): boolean;
  platform(): string;
  log(...args: unknown[]): void;
  fetch?: FetchLike;
  openUrl?(url: string): void;
  copy?(text: string): void;
  now?(): number;
}

function newSession(): string {
  return Math.random().toString(36).slice(2, 10).padEnd(8, "0");
}

function seenOf(state: ExperienceState, key: string): Seen {
  return (state.seen[key] = state.seen[key] || { n: 0, last: 0, closes: 0, lastClose: 0, submitted: 0 });
}

function firstSku(properties: Dict | undefined): string {
  const p = properties || {};
  const ids = p.content_ids;
  if (Array.isArray(ids) && ids.length && ids[0] != null) return String(ids[0]);
  if (p.sku != null) return String(p.sku);
  if (p.content_id != null) return String(p.content_id);
  return "";
}

export class ExperienceManager {
  private bundle: Bundle | null = null;
  private loaded = false;
  private fetchedAt = 0;
  private fetching: Promise<void> | null = null;
  private state: ExperienceState | null = null;
  private enabled = true;
  private started = false;
  private stopped = false;
  private screenName = "";
  private sku = "";
  private screenToken = 0;
  private popupsThisScreen = 0;
  private timers: Array<ReturnType<typeof setTimeout>> = [];
  private autoHide: ReturnType<typeof setTimeout> | null = null;
  private pendingShow: string | null = null;
  private decisions: Record<string, { at: number; decision: Decision }> = {};
  private handlers: Record<string, Array<(e: LemuExperienceEvent) => void>> = {};
  private subscribers: Array<() => void> = [];
  private current: ExperienceView | null = null;

  constructor(private c: ExperienceClient) {}

  // ── Public API ────────────────────────────────────────────────────────────

  /** Shows an experience now (its trigger, screens, audience and frequency
   * are not checked; holdout is). False when nothing could show. */
  show(key: string): boolean {
    try {
      if (!this.started || this.stopped || this.c.optedOut()) return false;
      if (!this.loaded) {
        this.pendingShow = key;
        return false;
      }
      const exp = this.find(key);
      if (!exp || this.current) return false;
      return this.present(exp, true);
    } catch (e) {
      this.c.log("experiences: show failed", e);
      return false;
    }
  }

  /** Closes the message on screen, if any (not counted as a close by the user). */
  hide(): void {
    if (this.current) this.current.close(false);
  }

  /** false: no automatic messages until set back to true. `show(key)` still works. */
  setEnabled(on: boolean): void {
    this.enabled = on !== false;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  /** Fetches the config now. */
  refresh(): Promise<void> {
    if (!this.started || this.stopped) return Promise.resolve();
    return this.fetchBundle();
  }

  /** shown | closed | submitted | clicked. Returns a function that stops listening. */
  on(type: LemuExperienceEventType, fn: (event: LemuExperienceEvent) => void): () => void {
    const list = (this.handlers[type] = this.handlers[type] || []);
    list.push(fn);
    return () => {
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    };
  }

  /** The message on screen (for the host component). */
  getCurrent(): ExperienceView | null {
    return this.current;
  }

  /** Called whenever the message on screen changes (for the host component). */
  subscribe(fn: () => void): () => void {
    this.subscribers.push(fn);
    return () => {
      const i = this.subscribers.indexOf(fn);
      if (i >= 0) this.subscribers.splice(i, 1);
    };
  }

  // ── From the client ───────────────────────────────────────────────────────

  /** Storage has loaded: read the history and fetch the config. */
  start(): Promise<void> {
    if (this.started || this.stopped) return Promise.resolve();
    this.started = true;
    return this.loadState()
      .then(() => {
        this.touch();
        return this.fetchBundle();
      })
      .then(() => this.screenTriggers())
      .catch((e) => this.c.log("experiences: start failed", e));
  }

  onScreen(name: string, properties?: Dict): void {
    this.screenName = String(name || "");
    this.sku = firstSku(properties);
    this.popupsThisScreen = 0;
    this.screenToken++;
    this.clearTimers();
    if (this.state && this.loaded) this.screenTriggers();
  }

  onTrack(event: string, properties?: Dict): void {
    if (!event || event.indexOf("onsite_") === 0) return;
    if (sameEvent("ViewContent", event)) {
      const sku = firstSku(properties);
      if (sku) this.sku = sku;
    }
    if (!this.bundle || !this.state) return;
    const candidates = this.bundle.experiences.filter((e) => {
      const on = e.trigger.on || "page_load";
      return (on === "event" && sameEvent(e.trigger.event, event)) || (on === "add_to_cart" && sameEvent("AddToCart", event));
    });
    this.firstOf(candidates, this.screenToken, false);
  }

  onForeground(): void {
    if (!this.started || this.stopped) return;
    const run = () => {
      this.touch();
      if (this.now() - this.fetchedAt > REFRESH_MS) {
        const before = this.bundle ? this.bundle.v : undefined;
        this.fetchBundle().then(() => {
          if (this.bundle && this.bundle.v !== before) this.screenTriggers();
        });
      }
    };
    if (this.state) run();
    else this.loadState().then(run);
  }

  onBackground(): void {
    if (!this.state) return;
    this.state.last = this.now();
    this.persist();
  }

  /** Stops timers. The client calls it on shutdown. */
  shutdown(): void {
    this.stopped = true;
    this.clearTimers();
    if (this.autoHide) clearTimeout(this.autoHide);
    this.autoHide = null;
    if (this.current) {
      const v = this.current;
      this.current = null;
      v.closed = true;
      this.notify();
    }
  }

  // ── Config and decide ─────────────────────────────────────────────────────

  private now(): number {
    return this.c.now ? this.c.now() : Date.now();
  }

  private fetcher(): FetchLike | null {
    if (this.c.fetch) return this.c.fetch;
    const f = (globalThis as Dict).fetch;
    return typeof f === "function" ? (f as FetchLike) : null;
  }

  private request(url: string, init: Dict): Promise<{ status: number; data: Dict } | null> {
    const f = this.fetcher();
    if (!f) return Promise.resolve(null);
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), TIMEOUT_MS);
      let p: Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;
      try {
        p = f(url, init);
      } catch (e) {
        clearTimeout(timer);
        return resolve(null);
      }
      p.then((r) =>
        r.json().then(
          (data) => ({ status: r.status, data: (data && typeof data === "object" ? data : {}) as Dict }),
          () => ({ status: r.status, data: {} }),
        ),
      ).then(
        (out) => {
          clearTimeout(timer);
          resolve(out);
        },
        () => {
          clearTimeout(timer);
          resolve(null);
        },
      );
    });
  }

  private post(path: string, body: Dict): Promise<{ status: number; data: Dict } | null> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    const extra = this.c.headers();
    for (const k in extra) headers[k] = extra[k];
    return this.request(this.c.host() + path, { method: "POST", headers, body: JSON.stringify(body) });
  }

  private fetchBundle(): Promise<void> {
    if (this.fetching) return this.fetching;
    const url = this.c.host() + "/api/v1/pixel/onsite/config?k=" + encodeURIComponent(this.c.writeKey());
    const headers: Record<string, string> = {};
    const extra = this.c.headers();
    for (const k in extra) if (k.toLowerCase() !== "content-type") headers[k] = extra[k];
    this.fetching = this.request(url, { method: "GET", headers })
      .then((res) => {
        if (res && res.status >= 200 && res.status < 300) {
          this.bundle = parseBundle(res.data);
          this.fetchedAt = this.now();
          this.decisions = {};
        }
        this.c.log("experiences: config", this.bundle ? this.bundle.experiences.length + " live" : "none");
      })
      .catch((e) => this.c.log("experiences: config failed", e))
      .then(() => {
        this.fetching = null;
        this.loaded = true;
        const key = this.pendingShow;
        this.pendingShow = null;
        if (key) this.show(key);
      });
    return this.fetching;
  }

  private decide(): Promise<Decision | null> {
    const cacheKey = this.screenName + "|" + this.sku;
    const cached = this.decisions[cacheKey];
    if (cached && this.now() - cached.at < DECIDE_TTL_MS) return Promise.resolve(cached.decision);
    return this.post("/api/v1/pixel/onsite/decide", {
      writeKey: this.c.writeKey(),
      anonymousId: this.c.anonymousId(),
      userId: this.c.userId(),
      context: { screen: this.screenName, product: this.sku ? { sku: this.sku } : {} },
    }).then((res) => {
      const data = res && res.status < 300 ? res.data : null;
      if (!data || !data.experiences || typeof data.experiences !== "object") return null;
      const decision = { known: !!data.known, experiences: data.experiences } as Decision;
      this.decisions[cacheKey] = { at: this.now(), decision };
      return decision;
    });
  }

  // ── State ─────────────────────────────────────────────────────────────────

  private loadState(): Promise<void> {
    let read: Promise<string | null | undefined>;
    try {
      read = Promise.resolve(this.c.storageAllowed() ? this.c.storage().get(STATE_KEY) : null);
    } catch (e) {
      read = Promise.resolve(null);
    }
    return read
      .catch(() => null)
      .then((raw) => {
        let saved: Dict = {};
        try {
          const parsed = raw ? JSON.parse(raw) : null;
          if (parsed && typeof parsed === "object") saved = parsed;
        } catch (e) {
          saved = {};
        }
        if (this.state) return;
        this.state = {
          visits: Number(saved.visits) || 0,
          first: Number(saved.first) || this.now(),
          last: Number(saved.last) || 0,
          session: saved.session ? String(saved.session) : "",
          sessionStart: Number(saved.sessionStart) || 0,
          popupsThisSession: Number(saved.popupsThisSession) || 0,
          seen: saved.seen && typeof saved.seen === "object" ? saved.seen : {},
        };
      });
  }

  /** A new session after 30 minutes away. */
  private touch(): void {
    const s = this.state;
    if (!s) return;
    const now = this.now();
    if (!s.session || now - s.last > SESSION_GAP_MS) {
      s.visits++;
      s.session = newSession();
      s.sessionStart = now;
      s.popupsThisSession = 0;
    }
    s.last = now;
    this.persist();
  }

  private persist(): void {
    if (!this.state || !this.c.storageAllowed()) return;
    try {
      const done = this.c.storage().set(STATE_KEY, JSON.stringify(this.state));
      if (done && typeof (done as Promise<void>).catch === "function") (done as Promise<void>).catch(() => undefined);
    } catch (e) {
      this.c.log("experiences: storage write failed", e);
    }
  }

  // ── Triggers and rules ────────────────────────────────────────────────────

  private find(key: string): Experience | undefined {
    return this.bundle ? this.bundle.experiences.filter((e) => e.key === key)[0] : undefined;
  }

  private clearTimers(): void {
    this.timers.forEach((t) => clearTimeout(t));
    this.timers = [];
  }

  private screenTriggers(): void {
    if (!this.bundle || !this.state || this.stopped) return;
    const token = this.screenToken;
    const onLoad = this.bundle.experiences.filter((e) => (e.trigger.on || "page_load") === "page_load");
    this.firstOf(onLoad, token, true);
    for (const exp of this.bundle.experiences) {
      if (exp.trigger.on !== "delay") continue;
      const ms = Math.max(0, Number(exp.trigger.seconds) || 0) * 1000;
      this.timers.push(
        setTimeout(() => {
          if (this.screenToken === token) this.firstOf([exp], token, true);
        }, ms),
      );
    }
  }

  /** Tries each in order until one shows. */
  private firstOf(list: Experience[], token: number, sameScreen: boolean): void {
    const next = (i: number): Promise<void> => {
      if (i >= list.length) return Promise.resolve();
      return this.consider(list[i], token, sameScreen).then((shown) => (shown ? undefined : next(i + 1)));
    };
    next(0).catch((e) => this.c.log("experiences: evaluate failed", e));
  }

  /** Everything but the audience (which may need decide). */
  private eligible(exp: Experience): boolean {
    const state = this.state;
    if (!state || !this.bundle || !this.enabled || this.stopped || this.current || this.c.optedOut()) return false;
    if (!scheduleOpen(exp.schedule || {}, this.now())) return false;
    if (!whereMatches(exp, this.screenName)) return false;
    if (!frequencyAllows(exp, seenOf(state, exp.key), state, this.now())) return false;
    if (OVERLAY_FORMATS.indexOf(exp.format) >= 0) {
      const caps = this.bundle.caps || {};
      if (caps.popups_per_page != null && this.popupsThisScreen >= caps.popups_per_page) return false;
      if (caps.popups_per_session != null && state.popupsThisSession >= caps.popups_per_session) return false;
    }
    return true;
  }

  private consider(exp: Experience, token: number, sameScreen: boolean): Promise<boolean> {
    if (!this.eligible(exp)) return Promise.resolve(false);
    const needsServer = !!exp.who.server && !!this.bundle && this.bundle.decide;
    const decision = needsServer ? this.decide() : Promise.resolve(null);
    return decision.then((d) => {
      if (sameScreen && token !== this.screenToken) return false;
      if (!this.eligible(exp) || !this.state) return false;
      if (!whoMatches(exp, d, this.c.userId(), this.state)) return false;
      return this.present(exp, false);
    });
  }

  private props(exp: Experience, variant: string): Dict {
    return { experience_id: exp.id, experience: exp.key, variant, version: exp.version, format: exp.format, screen: this.screenName };
  }

  /** Assigns the variant and shows it (or records the holdout). */
  private present(exp: Experience, manual: boolean): boolean {
    const state = this.state;
    if (!state || !this.bundle || this.current) return false;
    const h = seenOf(state, exp.key);
    const key = assign(exp, this.c.anonymousId() || state.session, h);
    this.persist();
    if (key === "holdout") {
      if (h.sessionShown !== state.session) {
        h.sessionShown = state.session;
        this.persist();
        this.c.track("onsite_held_out", this.props(exp, "holdout"));
      }
      return false;
    }
    const variant = exp.variants.filter((v) => v.key === key)[0];
    if (!variant || variant.kind !== "blocks") return false;
    const steps = variant.content.steps;
    if (!Array.isArray(steps) || !steps.length) return false;
    const view = new ExperienceView(exp, variant, theme(this.bundle.theme || {}, variant.content.style || {}), {
      submit: (v, fields, otp) => this.submit(v, fields, otp),
      closed: (v, byUser) => this.closed(v, byUser),
      submitted: (v, fields) => this.submitted(v, fields),
      clicked: (v, target) => {
        this.c.track("onsite_clicked", { ...this.props(v.exp, v.variant.key), target });
        this.emit({ type: "clicked", experience: v.exp.key, variant: v.variant.key, target });
      },
      openUrl: (url) => {
        try {
          if (this.c.openUrl) this.c.openUrl(url);
        } catch (e) {
          this.c.log("experiences: open url failed", e);
        }
      },
      copy: (text) => {
        try {
          if (this.c.copy) this.c.copy(text);
        } catch (e) {
          this.c.log("experiences: copy failed", e);
        }
      },
      changed: () => this.notify(),
    });
    this.current = view;
    h.n++;
    h.last = this.now();
    h.sessionShown = state.session;
    state.last = h.last;
    if (OVERLAY_FORMATS.indexOf(exp.format) >= 0) {
      state.popupsThisSession++;
      this.popupsThisScreen++;
    }
    this.persist();
    this.c.track("onsite_viewed", this.props(exp, variant.key));
    this.emit({ type: "shown", experience: exp.key, variant: variant.key });
    if (exp.format === "toast") {
      const secs = Number(view.layout.auto_hide_seconds == null ? 8 : view.layout.auto_hide_seconds);
      if (secs > 0) this.autoHide = setTimeout(() => view.close(false), secs * 1000);
    }
    this.c.log("experiences: showing", exp.key, variant.key, manual ? "(show)" : "");
    this.notify();
    return true;
  }

  private submit(v: ExperienceView, fields: Dict, otp?: string): Promise<SubmitResult | null> {
    const body: Dict = {
      writeKey: this.c.writeKey(),
      experience: v.exp.key,
      variant: v.variant.key,
      anonymousId: this.c.anonymousId(),
      userId: this.c.userId(),
      fields,
      context: { screen: this.screenName, platform: this.c.platform(), phone_country: v.phoneCountry() },
    };
    if (otp) body.otp = otp;
    return this.post("/api/v1/pixel/onsite/submit", body);
  }

  private submitted(v: ExperienceView, fields: Dict): void {
    const state = this.state;
    if (state) {
      seenOf(state, v.exp.key).submitted = this.now();
      this.persist();
    }
    const code = v.offer && v.offer.code ? String(v.offer.code) : undefined;
    this.emit({ type: "submitted", experience: v.exp.key, variant: v.variant.key, fields, offerCode: code });
  }

  private closed(v: ExperienceView, byUser: boolean): void {
    if (this.current === v) this.current = null;
    if (this.autoHide) clearTimeout(this.autoHide);
    this.autoHide = null;
    if (byUser && this.state) {
      const h = seenOf(this.state, v.exp.key);
      h.closes++;
      h.lastClose = this.now();
      this.persist();
      this.c.track("onsite_closed", this.props(v.exp, v.variant.key));
    }
    this.emit({ type: "closed", experience: v.exp.key, variant: v.variant.key, byUser });
    this.notify();
  }

  private emit(event: LemuExperienceEvent): void {
    (this.handlers[event.type] || []).slice().forEach((fn) => {
      try {
        fn(event);
      } catch (e) {
        this.c.log("experiences: listener failed", e);
      }
    });
  }

  private notify(): void {
    this.subscribers.slice().forEach((fn) => {
      try {
        fn();
      } catch (e) {
        this.c.log("experiences: render failed", e);
      }
    });
  }
}
