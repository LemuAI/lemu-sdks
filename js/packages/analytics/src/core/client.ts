import type {
  Adapters,
  BatchBody,
  Campaign,
  Context,
  LemuOptions,
  Message,
  MessageType,
  Properties,
  PurchaseProperties,
} from "./types";
import { cleanProps, hasKeys, isoNow, settleAll, uuid } from "./util";

export const DEFAULT_API_HOST = "https://app.lemuai.com";
export const BATCH_PATH = "/api/v1/pixel/batch";

/** Storage keys. The browser keeps `_lemu_aid` and `_lemu_optout` in a cookie too. */
export const KEYS = {
  anonymousId: "_lemu_aid",
  userId: "_lemu_uid",
  optOut: "_lemu_optout",
  queue: "_lemu_queue",
  /** "1" once consent was granted; remembered like the other SDKs do. */
  consent: "_lemu_consent",
};

const MAX_BATCH = 50;
const MAX_HELD = 50;
const MAX_PENDING_CALLS = 1000;
const HOUR = 3600e3;
const GIVE_UP_MS = 20 * HOUR;
const MAX_AGE_MS = 7 * 24 * HOUR;
const MAX_BACKOFF_MS = 300e3;

/**
 * A queued message: `q` when it was queued, `n` its place in the queue, `f`
 * when a send first failed in a way the server may have seen.
 */
interface Item {
  m: Message;
  q: number;
  n: number;
  f?: number;
}

type Outcome = number | "network" | "timeout";

declare const console: { log(...args: unknown[]): void } | undefined;

/**
 * The platform-agnostic client: queue, batching, retry with backoff, consent,
 * opt-out and identity. Platforms plug in storage, transport, context and
 * lifecycle. No method throws into the host app.
 */
export class LemuClient<O extends LemuOptions = LemuOptions> {
  protected a: Adapters;
  protected o: O = {} as O;
  protected writeKey = "";
  protected host = DEFAULT_API_HOST;
  protected campaign: Campaign = {};

  private inited = false;
  private loaded = false;
  private calls: Array<() => void> = [];
  private values: Record<string, string | null | undefined> = {};
  private aid: string | null = null;
  private uid: string | null = null;
  private consent = true;
  private out = false;
  private queue: Item[] = [];
  private flying: Item[] = [];
  /** Requests in flight, so `flush()` can wait for ones an earlier call started. */
  private posts: Array<Promise<void>> = [];
  private held: Message[] = [];
  /** Storage writes waiting for consent. `null` once consent is given. */
  private writes: Record<string, string | null> | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private retryAt = 0;
  private failures = 0;
  private seq = 0;
  private persisting = false;
  private unsubscribe: (() => void) | void = undefined;
  private closed = false;

  constructor(adapters: Adapters) {
    this.a = adapters;
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /** Starts the client. Calls made before `init` are kept and run after it. */
  init(writeKey: string, options?: O): void {
    this.safe(() => {
      if (this.inited) return this.log("init called again; ignored");
      if (!writeKey || typeof writeKey !== "string") return this.log("init needs a write key; ignored");
      const o = {} as O;
      assign(o, this.a.defaults);
      assign(o, options);
      this.o = o;
      this.inited = true;
      this.writeKey = writeKey;
      if (o.apiHost) this.host = String(o.apiHost).replace(/\/+$/, "");
      this.consent = !o.requireConsent;
      if (!this.consent) this.writes = {};
      this.log("init", writeKey, o);
      this.load();
    });
  }

  track(event: string, properties?: Properties): void {
    this.when(() => {
      if (typeof event !== "string" || !event.trim()) return this.log("track needs an event name; ignored");
      this.send("track", { event, properties: this.props(properties) });
    });
  }

  page(name?: string | Properties, properties?: Properties): void {
    this.when(() => {
      if (name && typeof name === "object") {
        properties = name;
        name = undefined;
      }
      this.send("page", { name: name ? String(name) : undefined, properties: this.props(properties) });
    });
  }

  screen(name: string, properties?: Properties): void {
    this.when(() => {
      if (typeof name !== "string" || !name.trim()) return this.log("screen needs a name; ignored");
      this.send("screen", { name, properties: this.props(properties) });
    });
  }

  /** Sets the user's id (kept until `reset()`) and sends their traits. `identify(traits)` works too. */
  identify(userId?: string | number | null | Properties, traits?: Properties): void {
    this.when(() => {
      if (userId && typeof userId === "object") {
        traits = userId;
        userId = undefined;
      }
      if (userId !== undefined && userId !== null && userId !== "") {
        this.uid = String(userId);
        this.store(KEYS.userId, this.uid);
      }
      this.send("identify", { traits: this.props(traits) });
      this.sendNow(false);
    });
  }

  /** Sends a `Purchase` event at once. `value`, `currency` and `order_id` are required. */
  purchase(purchase: PurchaseProperties): void {
    this.when(() => {
      if (!purchase || typeof purchase !== "object") return this.log("purchase needs {value, currency, order_id}; ignored");
      const p = this.props(purchase);
      if (p.order_id == null && p.orderId != null) p.order_id = p.orderId;
      delete p.orderId;
      if (typeof p.value === "string" && p.value.trim() && !isNaN(Number(p.value))) p.value = Number(p.value);
      if (typeof p.order_id === "number") p.order_id = String(p.order_id);
      if (typeof p.value !== "number" || !isFinite(p.value)) this.log("purchase: value should be a number");
      if (typeof p.currency !== "string" || !p.currency) this.log("purchase: currency is missing");
      if (typeof p.order_id !== "string" || !p.order_id) this.log("purchase: order_id is missing; Lemu can't de-duplicate this order");
      this.send("track", { event: "Purchase", properties: p });
      this.sendNow(false);
    });
  }

  /** On logout: a new anonymous id, and the user id is cleared. */
  reset(): void {
    this.when(() => {
      this.uid = null;
      this.aid = uuid();
      this.store(KEYS.userId, null);
      this.store(KEYS.anonymousId, this.aid);
      this.log("reset", this.aid);
    });
  }

  /** Sends everything queued now. Resolves when the requests have finished. */
  flush(): Promise<void> {
    return new Promise<void>((resolve) => {
      this.when(() => {
        this.sendNow(false).then(resolve, resolve);
      }, resolve);
    });
  }

  /** With `requireConsent`, starts sending (true) or discards held events and stops (false). */
  setConsent(granted: boolean): void {
    this.when(() => {
      const held = this.held;
      this.held = [];
      this.consent = !!granted;
      this.log("consent", this.consent);
      if (!this.consent) {
        this.writes = {};
        this.queue = [];
        this.write(KEYS.consent, null);
        return;
      }
      const writes = this.writes;
      this.writes = null;
      if (writes) for (const key in writes) this.store(key, writes[key]);
      this.write(KEYS.consent, "1");
      const aid = this.ensureId();
      for (let i = 0; i < held.length; i++) {
        held[i].anonymousId = aid;
        this.push(held[i]);
      }
      this.schedule();
    });
  }

  /** Stops all tracking and clears the queue. Remembered across launches. */
  optOut(): void {
    this.when(() => {
      this.out = true;
      this.queue = [];
      this.held = [];
      this.write(KEYS.optOut, "1");
      if (this.a.persistQueue) this.write(KEYS.queue, null);
      this.log("opted out");
    });
  }

  optIn(): void {
    this.when(() => {
      this.out = false;
      this.write(KEYS.optOut, null);
      this.log("opted in");
    });
  }

  /** The visitor's anonymous id, or null before consent, after opt-out, or before the client has loaded. */
  anonymousId(): string | null {
    return this.safe(() => (this.loaded && this.consent && !this.out ? this.ensureId() : null)) || null;
  }

  userId(): string | null {
    return this.uid;
  }

  /** Resolves once storage has loaded and calls made before that have run. */
  ready(): Promise<void> {
    return new Promise<void>((resolve) => this.when(resolve, resolve));
  }

  /** Stops timers and listeners. Queued messages stay in storage (apps). */
  shutdown(): void {
    this.safe(() => {
      this.closed = true;
      if (this.timer) clearTimeout(this.timer);
      this.timer = null;
      if (this.unsubscribe) this.unsubscribe();
      this.unsubscribe = undefined;
    });
  }

  // --------------------------------------------------------------------------
  // For platform packages
  // --------------------------------------------------------------------------

  /** Called once storage has loaded, before calls made earlier run. */
  protected started(): void {}

  protected onForeground(): void {}

  protected onBackground(): void {
    this.sendNow(true);
  }

  /** A value read from storage at start (keys from `adapters.extraKeys`). */
  protected stored(key: string): string | null | undefined {
    return this.values[key];
  }

  /** Writes to storage, or holds the write until consent. */
  protected store(key: string, value: string | null): void {
    if (this.writes) this.writes[key] = value;
    else this.write(key, value);
  }

  protected setCampaign(campaign: Campaign): void {
    this.campaign = campaign;
  }

  protected options(): O {
    return this.o;
  }

  /** Runs `fn` now if the client has started, otherwise after it does. Never throws. */
  protected when(fn: () => void, otherwise?: () => void): void {
    if (this.inited && this.loaded) {
      this.safe(fn);
    } else if (this.calls.length < MAX_PENDING_CALLS) {
      this.calls.push(fn);
    } else if (otherwise) {
      otherwise();
    }
  }

  protected safe<T>(fn: () => T): T | undefined {
    try {
      return fn();
    } catch (e) {
      this.log("error", e);
      return undefined;
    }
  }

  protected log(...args: unknown[]): void {
    if (this.o.debug && typeof console !== "undefined") console.log("[lemu]", ...args);
  }

  /** Sends what is queued. `beacon` uses the transport's fire-and-forget path when it has one. */
  protected sendNow(beacon: boolean): Promise<void> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (!this.writeKey || !this.consent || this.out || this.closed) return Promise.resolve();
    const now = Date.now();
    this.queue = this.queue.filter((i) => now - i.q < MAX_AGE_MS);
    const jobs: Array<Promise<void>> = [];
    while (this.queue.length) {
      const items = this.queue.splice(0, MAX_BATCH);
      if (beacon && this.a.transport.beacon) {
        const ok = this.safe(() => this.a.transport.beacon!({ url: this.url(), body: this.body(items) }));
        if (ok) {
          this.log("beacon", items.length);
          continue;
        }
      }
      jobs.push(this.post(items));
    }
    this.persist();
    return Promise.all(jobs.concat(this.posts)).then(() => undefined);
  }

  // --------------------------------------------------------------------------
  // Internals
  // --------------------------------------------------------------------------

  private load(): void {
    const keys = [KEYS.anonymousId, KEYS.userId, KEYS.optOut];
    if (this.a.persistQueue) keys.push(KEYS.queue);
    keys.push(KEYS.consent);
    const extra = this.a.extraKeys || [];
    for (let i = 0; i < extra.length; i++) keys.push(extra[i]);
    const reads = keys.map((k) => {
      try {
        return this.a.storage.get(k);
      } catch (e) {
        return null;
      }
    });
    settleAll(reads, (values) => {
      this.safe(() => {
        for (let i = 0; i < keys.length; i++) this.values[keys[i]] = values[i];
        this.out = values[2] === "1";
        this.aid = values[0] || null;
        this.uid = values[1] || null;
        if (this.a.persistQueue && values[3]) this.restore(values[3]);
        // Consent granted on an earlier launch still holds.
        if (!this.consent && this.values[KEYS.consent] === "1") {
          this.consent = true;
          this.writes = null;
        }
      });
      this.loaded = true;
      this.safe(() => {
        if (this.consent && !this.out) this.store(KEYS.anonymousId, this.ensureId());
        if (this.a.lifecycle) {
          this.unsubscribe = this.a.lifecycle.subscribe({
            foreground: () => this.safe(() => this.onForeground()),
            background: () => this.safe(() => this.onBackground()),
          });
        }
        this.started();
      });
      const calls = this.calls;
      this.calls = [];
      for (let i = 0; i < calls.length; i++) this.safe(calls[i]);
      this.safe(() => this.schedule());
    });
  }

  private restore(raw: string): void {
    const items = JSON.parse(raw);
    if (!Array.isArray(items)) return;
    const restored: Item[] = [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it && it.m && typeof it.m === "object" && typeof it.q === "number") restored.push({ m: it.m, q: it.q, n: 0, f: it.f });
    }
    for (let i = 0; i < this.queue.length; i++) restored.push(this.queue[i]);
    for (let i = 0; i < restored.length; i++) restored[i].n = ++this.seq;
    this.queue = restored;
    this.trim();
  }

  private ensureId(): string {
    if (!this.aid) {
      this.aid = uuid();
      this.store(KEYS.anonymousId, this.aid);
    }
    return this.aid;
  }

  private props(value: unknown): Properties {
    try {
      return cleanProps(value);
    } catch (e) {
      this.log("properties could not be serialised; sent as {}", e);
      return {};
    }
  }

  private context(): Context {
    const ctx = (this.a.context() || {}) as Context;
    ctx.platform = this.a.platform;
    ctx.library = this.a.library;
    if (!ctx.campaign && hasKeys(this.campaign)) ctx.campaign = assign({}, this.campaign);
    return ctx;
  }

  private send(type: MessageType, fields: Partial<Message>): void {
    if (this.out) return this.log("opted out; dropped", type);
    const m: Message = { type, messageId: uuid(), timestamp: isoNow(), context: this.context() };
    for (const k in fields) {
      const v = (fields as Record<string, unknown>)[k];
      if (v !== undefined) (m as unknown as Record<string, unknown>)[k] = v;
    }
    if (this.uid) m.userId = this.uid;
    this.log(type, m);
    if (!this.consent) {
      if (this.held.length < MAX_HELD) this.held.push(m);
      return;
    }
    m.anonymousId = this.ensureId();
    this.push(m);
    this.schedule();
  }

  private push(m: Message): void {
    this.queue.push({ m, q: Date.now(), n: ++this.seq });
    this.trim();
    this.persist();
  }

  /** Over the limit: drop the oldest message that isn't a Purchase. */
  private trim(): void {
    const max = this.o.maxQueueSize || 1000;
    while (this.queue.length > max) {
      let idx = 0;
      for (let i = 0; i < this.queue.length; i++) {
        if (this.queue[i].m.event !== "Purchase") {
          idx = i;
          break;
        }
      }
      this.queue.splice(idx, 1);
    }
  }

  private schedule(): void {
    if (!this.queue.length || !this.consent || this.out || this.closed || !this.writeKey) return;
    const now = Date.now();
    if (this.queue.length >= (this.o.flushAt || 20) && now >= this.retryAt) {
      this.sendNow(false);
      return;
    }
    if (!this.timer) {
      const delay = Math.max(this.o.flushInterval || 30000, this.retryAt - now);
      const t = setTimeout(() => {
        if (this.timer === t) this.timer = null;
        this.sendNow(false);
      }, delay);
      this.timer = t;
    }
  }

  private url(): string {
    return this.host + BATCH_PATH;
  }

  private body(items: Item[]): string {
    const body: BatchBody = { writeKey: this.writeKey, sentAt: isoNow(), batch: items.map((i) => i.m) };
    return JSON.stringify(body);
  }

  private post(items: Item[]): Promise<void> {
    this.flying = this.flying.concat(items);
    const body = this.body(items);
    this.log("request", body);
    let sent: Promise<number | undefined | void>;
    try {
      sent = this.a.transport.send({ url: this.url(), body });
    } catch (e) {
      sent = Promise.reject(e);
    }
    const done: Promise<void> = sent
      .then(
        (status) => this.settle(items, typeof status === "number" && status > 0 ? status : 204),
        (err) => this.settle(items, err && (err as { timeout?: boolean }).timeout ? "timeout" : "network"),
      )
      .then(() => {
        this.posts = this.posts.filter((p) => p !== done);
      });
    this.posts.push(done);
    return done;
  }

  private settle(items: Item[], outcome: Outcome): Promise<void> {
    return (
      this.safe(() => {
        this.flying = this.flying.filter((i) => items.indexOf(i) < 0);
        this.log("response", outcome, items.length + " messages");
        if (typeof outcome === "number" && outcome >= 200 && outcome < 300) {
          this.failures = 0;
          this.retryAt = 0;
          this.persist();
          this.schedule();
          return undefined;
        }
        if (outcome === 413) {
          if (items.length === 1) {
            this.log("message too large; dropped");
            this.persist();
            return undefined;
          }
          const half = Math.ceil(items.length / 2);
          return this.post(items.slice(0, half)).then(() => this.post(items.slice(half)));
        }
        if (outcome === "network" || outcome === "timeout" || outcome === 408 || outcome === 429 || outcome >= 500) {
          this.retry(items, outcome !== "network");
          return undefined;
        }
        // 400, 401, 403 and other client errors: retrying won't help.
        this.log("batch dropped", outcome);
        this.persist();
        return undefined;
      }) || Promise.resolve()
    );
  }

  private retry(items: Item[], reachedServer: boolean): void {
    const now = Date.now();
    const keep = items.filter((i) => {
      if (reachedServer && i.f === undefined) i.f = now;
      return i.f === undefined || now - i.f < GIVE_UP_MS;
    });
    // Batches can fail in any order; keep the queue in call order.
    this.queue = keep.concat(this.queue).sort((x, y) => x.n - y.n);
    this.trim();
    this.persist();
    if (now >= this.retryAt) {
      this.failures++;
      const base = Math.min(1000 * Math.pow(2, this.failures - 1), MAX_BACKOFF_MS);
      this.retryAt = now + base * (0.8 + Math.random() * 0.4);
    }
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (this.closed) return;
    const t = setTimeout(() => {
      if (this.timer === t) this.timer = null;
      this.sendNow(false);
    }, this.retryAt - now);
    this.timer = t;
    this.log("retry in", Math.round(this.retryAt - now), "ms");
  }

  /** Apps: write the queue (including requests in flight) to storage, at most once per tick. */
  private persist(): void {
    if (!this.a.persistQueue || this.persisting || this.writes || this.out) return;
    this.persisting = true;
    Promise.resolve().then(() => {
      this.persisting = false;
      if (this.writes || this.out) return;
      const all = this.flying.concat(this.queue).sort((x, y) => x.n - y.n);
      this.write(KEYS.queue, all.length ? JSON.stringify(all) : null);
    });
  }

  private write(key: string, value: string | null): void {
    try {
      const r = value === null ? this.a.storage.remove(key) : this.a.storage.set(key, value);
      if (r && typeof (r as Promise<void>).catch === "function") (r as Promise<void>).catch(() => undefined);
    } catch (e) {
      this.log("storage error", e);
    }
  }
}

function assign<T extends object>(target: T, source: object | undefined | null): T {
  if (source) for (const k in source) if ((source as Record<string, unknown>)[k] !== undefined) (target as Record<string, unknown>)[k] = (source as Record<string, unknown>)[k];
  return target;
}
