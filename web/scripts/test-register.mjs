// Installs the `@/` resolver for `node --test`. Loaded via `--import`.
import { register } from "node:module";

register("./test-alias-hook.mjs", import.meta.url);
