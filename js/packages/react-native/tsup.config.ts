import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts" },
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  target: "es2017",
  sourcemap: true,
  tsconfig: "tsconfig.build.json",
  // Metro resolves these from the app. react-native-device-info is optional:
  // the CJS build keeps a literal require() inside try/catch, which Metro
  // treats as an optional dependency.
  external: [
    "react",
    "react-native",
    "@react-native-async-storage/async-storage",
    "react-native-device-info",
    "@lemuai/analytics",
    "@lemuai/analytics/core",
  ],
});
