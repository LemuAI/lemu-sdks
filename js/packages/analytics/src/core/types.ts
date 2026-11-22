/** Wire types for Lemu tracking protocol v1 (see sdks/spec/protocol.md). */

export type Platform = "web" | "ios" | "android" | "flutter" | "react_native" | "shopify" | "server";

export type MessageType = "page" | "screen" | "track" | "identify";

export type Properties = Record<string, unknown>;

export interface Campaign {
  source?: string;
  medium?: string;
  campaign?: string;
  term?: string;
  content?: string;
  gclid?: string;
  fbclid?: string;
  /** Set by Lemu message links (le2.in): which person the link was sent to. */
  lmclid?: string;
}

export interface Context {
  platform: Platform;
  library: { name: string; version: string };
  app?: { name?: string; version?: string; build?: string; namespace?: string };
  device?: { manufacturer?: string; model?: string; type?: "phone" | "tablet" | "desktop" | "tv" | "other" };
  os?: { name?: string; version?: string };
  screen?: { width?: number; height?: number; density?: number };
  locale?: string;
  timezone?: string;
  userAgent?: string;
  campaign?: Campaign;
  page?: { url?: string; path?: string; title?: string; referrer?: string };
  [key: string]: unknown;
}

export interface Message {
  type: MessageType;
  messageId: string;
  anonymousId?: string;
  timestamp: string;
  context: Context;
  userId?: string;
  event?: string;
  name?: string;
  properties?: Properties;
  traits?: Properties;
}

export interface BatchBody {
  writeKey: string;
  sentAt: string;
  batch: Message[];
}

/** One line item of a purchase, as Meta defines `contents`. */
export interface PurchaseContent {
  id: string;
  quantity: number;
  item_price?: number;
  title?: string;
  brand?: string;
  category?: string;
  [key: string]: unknown;
}

export interface PurchaseProperties {
  /** Order total in major units (1499.5 means Rs 1,499.50). */
  value: number;
  /** ISO 4217 code, for example "INR". */
  currency: string;
  /** Your order id. Lets Lemu count one conversion per order however many sources report it. */
  order_id: string;
  contents?: PurchaseContent[];
  content_ids?: string[];
  num_items?: number;
  [key: string]: unknown;
}

/** Options every SDK accepts in `init`. */
export interface LemuOptions {
  /** Collection host. Defaults to https://app.lemuai.com (the snippet uses the host it was loaded from). */
  apiHost?: string;
  /** Log every call, request and response to the console. */
  debug?: boolean;
  /** Hold events in memory and write nothing to storage until `setConsent(true)`. */
  requireConsent?: boolean;
  /** Send when this many messages are queued. Web 10, apps 20. */
  flushAt?: number;
  /** Send queued messages after this many milliseconds. Web 1000, apps 30000. */
  flushInterval?: number;
  /** Most messages kept in the queue. Default 1000. */
  maxQueueSize?: number;
  /** Apps: send app_installed, app_updated, app_opened and app_backgrounded. Default true. */
  trackLifecycle?: boolean;
  /** Apps: send deep_link_opened and copy UTM parameters from links. Default true. */
  trackDeepLinks?: boolean;
  /** Web snippet: load experiences and landing page forms (onsite.js) when the site has any live. Default true. */
  onsite?: boolean;
}

// ----------------------------------------------------------------------------
// Adapters
// ----------------------------------------------------------------------------

type MaybePromise<T> = T | Promise<T>;

/** Key-value storage. Synchronous (browser) or asynchronous (AsyncStorage). */
export interface StorageAdapter {
  get(key: string): MaybePromise<string | null | undefined>;
  set(key: string, value: string): MaybePromise<void>;
  remove(key: string): MaybePromise<void>;
}

export interface TransportRequest {
  url: string;
  body: string;
}

/**
 * Sends one batch. Resolves with the HTTP status (anything that is not a
 * positive number counts as delivered), rejects on a network error. A
 * rejection whose `timeout` property is true means the request may have
 * reached the server.
 */
export interface TransportAdapter {
  send(request: TransportRequest): Promise<number | undefined | void>;
  /** Fire and forget, used when the page or app is going away. Returns false when it could not queue the request. */
  beacon?(request: TransportRequest): boolean;
}

/** Context fields the platform knows. `platform` and `library` are added by the client. */
export type ContextAdapter = () => Partial<Context>;

export interface LifecycleHandlers {
  foreground(): void;
  background(): void;
}

/** Tells the client when the page or app goes to the background and comes back. */
export interface LifecycleAdapter {
  subscribe(handlers: LifecycleHandlers): (() => void) | void;
}

export interface Adapters {
  platform: Platform;
  library: { name: string; version: string };
  storage: StorageAdapter;
  transport: TransportAdapter;
  context: ContextAdapter;
  lifecycle?: LifecycleAdapter;
  /** Platform defaults for options the caller leaves out. */
  defaults?: LemuOptions;
  /** Keep the queue in storage so it survives restarts (apps). */
  persistQueue?: boolean;
  /** Extra storage keys to read at start; available through `stored(key)`. */
  extraKeys?: string[];
}
