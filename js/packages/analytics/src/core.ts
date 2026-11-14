/**
 * @lemuai/analytics/core: the platform-agnostic client. Bring your own
 * storage, transport, context and lifecycle adapters.
 */
export { LemuClient, DEFAULT_API_HOST, BATCH_PATH, KEYS } from "./core/client";
export { LemuEvent } from "./core/events";
export type { LemuEventName } from "./core/events";
export { fetchTransport } from "./core/fetch-transport";
export type { FetchTransportOptions } from "./core/fetch-transport";
export { memoryStorage } from "./core/memory-storage";
export { parseCampaign, uuid } from "./core/util";
export { VERSION } from "./version";
export type * from "./core/types";
