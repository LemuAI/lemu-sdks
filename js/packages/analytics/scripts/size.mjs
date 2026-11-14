// Prints the size of dist/lemu.js, raw and gzipped, and fails above the budget.
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";

const BUDGET = 6 * 1024;
const source = readFileSync(new URL("../dist/lemu.js", import.meta.url));
const gz = gzipSync(source, { level: 9 }).length;
console.log(`dist/lemu.js: ${source.length} bytes, ${gz} bytes gzipped (budget ${BUDGET})`);
if (gz > BUDGET) {
  console.error("dist/lemu.js is over the size budget");
  process.exit(1);
}
