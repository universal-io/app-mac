import assert from "node:assert/strict";
import test from "node:test";

import { QuotaStateCache } from "./quota-state-cache.ts";

test("a successful local write advances the cached usage count", () => {
  const cache = new QuotaStateCache(300_000, 256);
  cache.set("tenant", { used: 7, limit: 10 }, 1_000);
  cache.increment("tenant", 2_000);
  assert.deepEqual(cache.get("tenant", 2_000), { used: 8, limit: 10 });
});

test("increment never resurrects missing or expired quota knowledge", () => {
  const cache = new QuotaStateCache(100, 256);
  cache.increment("missing", 1_000);
  assert.equal(cache.get("missing", 1_000), null);

  cache.set("expired", { used: 2, limit: 5 }, 1_000);
  cache.increment("expired", 1_101);
  assert.equal(cache.get("expired", 1_101), null);
});

test("unlimited plans retain their null limit while usage advances", () => {
  const cache = new QuotaStateCache(300_000, 256);
  cache.set("tenant", { used: 3, limit: null }, 1_000);
  cache.increment("tenant", 2_000);
  assert.deepEqual(cache.get("tenant", 2_000), { used: 4, limit: null });
});

test("an intentionally skipped count remains unknown after a local write", () => {
  const cache = new QuotaStateCache(300_000, 256);
  cache.set("tenant", { used: null, limit: null }, 1_000);
  cache.increment("tenant", 2_000);
  assert.deepEqual(cache.get("tenant", 2_000), { used: null, limit: null });
});

test("the cache remains bounded", () => {
  const cache = new QuotaStateCache(300_000, 2);
  cache.set("first", { used: 1, limit: 10 }, 1_000);
  cache.set("second", { used: 2, limit: 10 }, 1_000);
  cache.set("third", { used: 3, limit: 10 }, 1_000);

  assert.equal(cache.get("first", 1_000), null);
  assert.deepEqual(cache.get("second", 1_000), { used: 2, limit: 10 });
  assert.deepEqual(cache.get("third", 1_000), { used: 3, limit: 10 });
});
