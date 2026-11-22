// The API serves the renderer from api/services/pixel/sdk/onsite.js. Inside the Lemu
// app repository (sdks/js/packages/onsite) the build copies it there; on its own
// (the lemu-sdks repository) there is no API folder and the copy is skipped.
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const HEADER = `/*
 * Lemu experiences and landing page runtime. Built from
 * sdks/js/packages/onsite with \`npm run build\` in sdks/js; do not edit here.
 * Loaded by lemu.js when a site has live experiences (plans/onsite-personalisation.md).
 */
`;
const target = new URL("../../../../../api/services/pixel/sdk/", import.meta.url);
if (existsSync(target)) {
  const source = readFileSync(new URL("../dist/onsite.js", import.meta.url), "utf8");
  writeFileSync(new URL("onsite.js", target), HEADER + source);
  console.log("copied dist/onsite.js to api/services/pixel/sdk/onsite.js");
} else {
  console.log("no api/services/pixel/sdk folder here; dist/onsite.js not copied");
}
