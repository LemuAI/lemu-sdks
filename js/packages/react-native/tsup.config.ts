import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts" },
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  target: "es2017",
  sourcemap: true,
  tsconfig: "tsconfig.build.json",
  // Metro resolves these from the app. react-native-device-info and
  // @react-native-clipboard/clipboard are optional:
  // the CJS build keeps a literal require() inside try/catch, which Metro
  // treats as an optional dependency.
  external: [
    "react",
    "react-native",
    "@react-native-async-storage/async-storage",
    "react-native-device-info",
    "@react-native-clipboard/clipboard",
    "@lemuai/analytics",
    "@lemuai/analytics/core",
  ],
});
