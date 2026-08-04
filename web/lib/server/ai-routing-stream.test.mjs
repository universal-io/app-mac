import assert from "node:assert/strict";
import test from "node:test";

import {
  AI_MODEL_ROUTES,
  ProviderCallError,
  runStreamWithModelFallback,
} from "./ai-routing.ts";

/** Drives the generator to completion, collecting what a caller would see. */
async function collect(attempt) {
  const events = [];
  for await (const event of runStreamWithModelFallback("vision", attempt)) {
    events.push(event);
  }
  return events;
}

/** A stream of deltas followed by a value, from a plain array. */
function scripted(...events) {
  return async function* () {
    for (const event of events) yield event;
  };
}

test("a successful primary reports no fallback and adds no notice", async () => {
  const events = await collect(scripted(
    { type: "delta", text: "left " },
    { type: "delta", text: "sidebar" },
    { type: "value", value: 42 },
  ));

  assert.deepEqual(
    events.filter((event) => event.type === "delta").map((event) => event.text),
    ["left ", "sidebar"],
  );
  const final = events.at(-1);
  assert.equal(final.type, "final");
  assert.equal(final.result.value, 42);
  assert.equal(final.result.fallbackUsed, false);
  assert.deepEqual(final.result.notices, []);
  assert.equal(final.result.modelId, AI_MODEL_ROUTES.vision.primary.modelId);
});

/** The README's contract: a recovered request always carries the same notice,
 * whether it recovered while streaming or not. */
test("falling back before any text carries the notice and needs no reset", async () => {
  const events = await collect(async function* (target) {
    if (target.modelId === AI_MODEL_ROUTES.vision.primary.modelId) {
      throw new ProviderCallError("primary refused");
    }
    yield { type: "delta", text: "from the secondary" };
    yield { type: "value", value: "ok" };
  });

  assert.equal(events.filter((event) => event.type === "reset").length, 0);
  const final = events.at(-1);
  assert.equal(final.result.fallbackUsed, true);
  assert.equal(final.result.modelId, AI_MODEL_ROUTES.vision.secondary.modelId);
  assert.equal(final.result.notices.length, 1);
});

/** The one thing streaming adds. Text already read cannot be unsaid, so a
 * primary that dies mid-answer must retract it rather than let the secondary's
 * different answer be appended to the abandoned half of the first. */
test("a primary that dies mid-answer retracts what it already sent", async () => {
  const events = await collect(async function* (target) {
    if (target.modelId === AI_MODEL_ROUTES.vision.primary.modelId) {
      yield { type: "delta", text: "open the repo" };
      throw new ProviderCallError("connection dropped");
    }
    yield { type: "delta", text: "open the reports panel" };
    yield { type: "value", value: "ok" };
  });

  assert.deepEqual(events.map((event) => event.type), [
    "delta",
    "reset",
    "delta",
    "final",
  ]);
  assert.equal(events[0].text, "open the repo");
  assert.equal(events[2].text, "open the reports panel");
});

test("a secondary that dies mid-answer throws rather than resetting to nothing", async () => {
  await assert.rejects(
    collect(async function* () {
      yield { type: "delta", text: "partial" };
      throw new ProviderCallError("both gone");
    }),
    (error) => error instanceof ProviderCallError,
  );
});

/** A stream that stops without a value produced no answer, however much text
 * it emitted. Treating it as success would show the user prose with no mode and
 * no highlight target behind it. */
test("ending without a value is a failure, not a partial success", async () => {
  await assert.rejects(
    collect(scripted({ type: "delta", text: "half an answer" })),
    (error) => /ended without a result/.test(error.message),
  );
});

test("empty deltas are dropped so they cannot look like progress", async () => {
  const events = await collect(scripted(
    { type: "delta", text: "" },
    { type: "delta", text: "real" },
    { type: "value", value: 1 },
  ));
  assert.equal(events.filter((event) => event.type === "delta").length, 1);
});

/** An empty delta must not count as text either: retracting nothing would tell
 * the client to clear a panel that never showed anything. */
test("an empty delta does not trigger a reset on fallback", async () => {
  const events = await collect(async function* (target) {
    if (target.modelId === AI_MODEL_ROUTES.vision.primary.modelId) {
      yield { type: "delta", text: "" };
      throw new ProviderCallError("primary refused");
    }
    yield { type: "value", value: "ok" };
  });
  assert.equal(events.filter((event) => event.type === "reset").length, 0);
});

test("rate limiting survives to the thrown error when both models are limited", async () => {
  await assert.rejects(
    collect(async function* () {
      throw new ProviderCallError("429", { rateLimited: true });
    }),
    (error) => error instanceof ProviderCallError && error.rateLimited === true,
  );
});
