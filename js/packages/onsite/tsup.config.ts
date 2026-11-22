import { defineConfig } from "tsup";

export default defineConfig({
  // One script for <script src>: /api/v1/pixel/onsite.js
  entry: { onsite: "src/index.ts" },
  format: ["iife"],
  platform: "browser",
  target: "es2017",
  minify: true,
  outExtension: () => ({ js: ".js" }),
  dts: false,
  clean: true,
  sourcemap: false,
});
