import type { TransportAdapter, TransportRequest } from "./types";

type FetchLike = (url: string, init: Record<string, unknown>) => Promise<{ status: number } | undefined | void>;

declare const fetch: FetchLike | undefined;
declare const AbortController: { new (): { signal: unknown; abort(): void } } | undefined;

export interface FetchTransportOptions {
  /** Headers on every request, for example Content-Type and User-Agent. */
  headers?: Record<string, string>;
  /** Abort a request after this many milliseconds. Default 10000. */
  timeout?: number;
  /** Extra fetch options (keepalive, credentials). */
  init?: Record<string, unknown>;
  /** The fetch function. Defaults to the global one. */
  fetch?: FetchLike;
}

/** A transport over `fetch`. A timed-out request rejects with `{ timeout: true }`. */
export function fetchTransport(options: FetchTransportOptions = {}): TransportAdapter {
  return {
    send(request: TransportRequest) {
      const f = options.fetch || (typeof fetch !== "undefined" ? fetch : undefined);
      if (!f) return Promise.reject(new Error("fetch is not available"));
      const init: Record<string, unknown> = { method: "POST", body: request.body, headers: options.headers || {} };
      if (options.init) for (const k in options.init) init[k] = options.init[k];
      let timer: ReturnType<typeof setTimeout> | undefined;
      let timedOut = false;
      if (typeof AbortController !== "undefined") {
        const controller = new AbortController();
        init.signal = controller.signal;
        timer = setTimeout(() => {
          timedOut = true;
          controller.abort();
        }, options.timeout || 10000);
      }
      return f(request.url, init).then(
        (res) => {
          if (timer) clearTimeout(timer);
          return res ? res.status : undefined;
        },
        (err) => {
          if (timer) clearTimeout(timer);
          throw timedOut ? { timeout: true } : err;
        },
      );
    },
  };
}
