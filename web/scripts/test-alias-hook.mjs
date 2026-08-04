// Teaches `node --test` the `@/` path alias that tsconfig gives the app.
//
// Without this, any server module that imports through the alias is untestable
// outside Next.js — which excluded ai-routing.ts, the single source of truth for
// model routing and fallback policy. Bending production imports to suit the test
// runner would be the wrong way round; the runner learns the alias instead.

import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const webRoot = dirname(dirname(fileURLToPath(import.meta.url)));

/** Node's ESM resolver needs a real filename; TypeScript's does not. */
const EXTENSIONS = ["", ".ts", ".tsx", ".mjs", ".js", "/index.ts"];

export function resolve(specifier, context, nextResolve) {
  if (!specifier.startsWith("@/")) {
    return nextResolve(specifier, context);
  }
  const base = join(webRoot, specifier.slice(2));
  for (const extension of EXTENSIONS) {
    const candidate = `${base}${extension}`;
    if (existsSync(candidate)) {
      return nextResolve(pathToFileURL(candidate).href, context);
    }
  }
  return nextResolve(specifier, context);
}
