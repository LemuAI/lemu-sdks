import type { StorageAdapter } from "./types";

/** Storage that lives only as long as the process. Useful for servers and tests. */
export function memoryStorage(initial?: Record<string, string>): StorageAdapter & { data: Record<string, string> } {
  const data: Record<string, string> = {};
  if (initial) for (const k in initial) data[k] = initial[k];
  return {
    data,
    get: (key) => (Object.prototype.hasOwnProperty.call(data, key) ? data[key] : null),
    set: (key, value) => {
      data[key] = value;
    },
    remove: (key) => {
      delete data[key];
    },
  };
}
