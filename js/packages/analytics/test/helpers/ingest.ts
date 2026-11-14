/**
 * A fake Lemu ingest server on 127.0.0.1: records every request and answers
 * with the statuses a test queues (204 once the queue is empty). Every body is
 * checked against sdks/conformance/batch.schema.json.
 */
import Ajv2020 from "ajv/dist/2020";
import { readFileSync } from "node:fs";
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// sdks/ is five levels up from this file (sdks/js/packages/analytics/test/helpers).
const SDKS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../../../..");
export const SPEC_DIR = SDKS_DIR + "/spec/";
export const CONFORMANCE_DIR = SDKS_DIR + "/conformance/";

const schema = JSON.parse(readFileSync(CONFORMANCE_DIR + "batch.schema.json", "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: false });
export const validateBatch = ajv.compile(schema);

export const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface Recorded {
  body: any; // eslint-disable-line @typescript-eslint/no-explicit-any
  raw: string;
  headers: IncomingHttpHeaders;
  status: number;
  schemaErrors: unknown;
}

export interface Ingest {
  url: string;
  requests: Recorded[];
  /** Statuses for the next requests, in order. */
  respond(...statuses: number[]): void;
  /** Resolves once at least `n` requests have arrived. */
  waitFor(n: number, timeoutMs?: number): Promise<Recorded[]>;
  messages(): any[]; // eslint-disable-line @typescript-eslint/no-explicit-any
  close(): Promise<void>;
}

export async function startIngest(): Promise<Ingest> {
  const requests: Recorded[] = [];
  const statuses: number[] = [];
  const server: Server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const status = statuses.length ? statuses.shift()! : 204;
      let body: unknown = null;
      try {
        body = JSON.parse(raw);
      } catch (e) {
        body = null;
      }
      const ok = validateBatch(body);
      requests.push({ body, raw, headers: req.headers, status, schemaErrors: ok ? null : validateBatch.errors });
      res.writeHead(status, { "Access-Control-Allow-Origin": "*" });
      res.end();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    respond: (...s) => statuses.push(...s),
    async waitFor(n, timeoutMs = 5000) {
      const start = Date.now();
      while (requests.length < n) {
        if (Date.now() - start > timeoutMs) throw new Error(`expected ${n} requests, got ${requests.length}`);
        await sleep(10);
      }
      return requests;
    },
    messages: () => requests.filter((r) => r.status >= 200 && r.status < 300).flatMap((r) => r.body.batch),
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

/** A URL nothing listens on, for "server down". */
export async function deadUrl(): Promise<string> {
  const server = createServer();
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  await new Promise<void>((r) => server.close(() => r()));
  return `http://127.0.0.1:${port}`;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** Every recorded body is valid against the schema. */
export function expectAllValid(ingest: Ingest): void {
  for (const r of ingest.requests) {
    if (r.schemaErrors) throw new Error("invalid batch: " + JSON.stringify(r.schemaErrors) + "\n" + r.raw);
  }
}

export function eventNamesFromSpec(): string[] {
  const spec = JSON.parse(readFileSync(SPEC_DIR + "events.json", "utf8"));
  return [...spec.meta_events, ...spec.lifecycle_events].map((e: { name: string }) => e.name);
}
