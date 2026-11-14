import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "@lemuai/analytics/core": here("../analytics/src/core.ts"),
      "react-native": here("test/mocks/react-native.ts"),
      "@react-native-async-storage/async-storage": here("test/mocks/async-storage.ts"),
    },
  },
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    testTimeout: 20000,
  },
});
