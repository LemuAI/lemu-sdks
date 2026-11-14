import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts" },
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  target: "es2017",
  sourcemap: true,
  tsconfig: "tsconfig.build.json",
  external: ["react", "@lemuai/analytics"],
  // The provider and hooks run on the client in the Next.js app router.
  banner: { js: '"use client";' },
});
