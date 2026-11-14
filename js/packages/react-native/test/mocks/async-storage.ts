/** In-memory AsyncStorage that counts writes. */
const data: Record<string, string> = {};
let writes = 0;

const AsyncStorage = {
  getItem: async (key: string) => (key in data ? data[key] : null),
  setItem: async (key: string, value: string) => {
    writes++;
    data[key] = String(value);
  },
  removeItem: async (key: string) => {
    writes++;
    delete data[key];
  },
};

export default AsyncStorage;

export const storageMock = {
  data,
  writes: () => writes,
  clear() {
    for (const k of Object.keys(data)) delete data[k];
    writes = 0;
  },
};
