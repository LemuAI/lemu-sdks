// Prints the size of dist/onsite.js and fails above the budget.
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";

const BUDGET = 32 * 1024;
const source = readFileSync(new URL("../dist/onsite.js", import.meta.url));
const gz = gzipSync(source, { level: 9 }).length;
console.log(`dist/onsite.js: ${source.length} bytes, ${gz} bytes gzipped (budget ${BUDGET})`);
if (gz > BUDGET) {
  console.error("dist/onsite.js is over the size budget");
  process.exit(1);
}
