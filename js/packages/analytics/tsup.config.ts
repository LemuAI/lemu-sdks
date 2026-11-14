import { defineConfig } from "tsup";

export default defineConfig([
  {
    entry: { index: "src/index.ts", core: "src/core.ts" },
    format: ["esm", "cjs"],
    dts: true,
    clean: true,
    target: "es2017",
    sourcemap: true,
    treeshake: true,
  },
  {
    // The snippet build: a single script for <script src>, ES2017, minified.
    entry: { lemu: "src/snippet.ts" },
    format: ["iife"],
    platform: "browser",
    target: "es2017",
    minify: true,
    outExtension: () => ({ js: ".js" }),
    dts: false,
    clean: false,
    sourcemap: false,
  },
]);
