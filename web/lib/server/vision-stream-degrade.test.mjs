import assert from "node:assert/strict";
import test from "node:test";

// getServerEnv() is strict about Supabase config; the engine only needs the
// provider key. Set before importing so module-level code sees them.
process.env.SUPABASE_URL ??= "https://example.supabase.co";
process.env.SUPABASE_ANON_KEY ??= "anon";
process.env.SUPABASE_SERVICE_ROLE_KEY ??= "service";
process.env.OPENAI_API_KEY ??= "sk-test";

const { runVisionStream } = await import("./vision-engine.ts");

const INPUT = {
  imageDataURL: "data:image/png;base64,aGVsbG8=",
  turns: [],
  candidates: [],
  language: "japanese",
};

const ANSWER = {
  mode: "guide",
  message: "左のレポートを開きます",
  observations: [],
  uncertainties: [],
  targetCandidateId: null,
};

function sseBody(...frames) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const frame of frames) controller.enqueue(encoder.encode(frame));
      controller.close();
    },
  });
}

function frame(payload) {
  return `event: ${payload.type}\ndata: ${JSON.stringify(payload)}\n\n`;
}

/** A complete Responses stream that answers with ANSWER, split so that two of
 * the cuts land *inside* the message value — the real provider sent 183 deltas,
 * so a split that happens to align with a field boundary proves nothing. */
function goodStream() {
  const json = JSON.stringify(ANSWER);
  const at = json.indexOf(ANSWER.message);
  const cuts = [json.slice(0, at + 3), json.slice(at + 3, at + 7), json.slice(at + 7)];
  return sseBody(
    ...cuts.map((delta) => frame({ type: "response.output_text.delta", delta })),
    frame({
      type: "response.completed",
      response: {
        status: "completed",
        output: [{ type: "message", content: [{ type: "output_text", text: json }] }],
        usage: { input_tokens: 10, output_tokens: 20 },
      },
    }),
  );
}

/** The ordinary non-streaming Responses body. */
function plainBody() {
  return JSON.stringify({
    status: "completed",
    output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(ANSWER) }] }],
    usage: { input_tokens: 10, output_tokens: 20 },
  });
}

/** Serves each call from the given queue of responses, recording the requests. */
function stubFetch(responses) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ streamRequested: body.stream === true });
    const next = responses.shift();
    if (!next) throw new Error("unexpected extra provider call");
    return next();
  };
  return calls;
}

async function collect(generator) {
  const events = [];
  for await (const event of generator) events.push(event);
  return events;
}

test.afterEach(() => { delete globalThis.fetch; });

test("a healthy stream reports text incrementally and is not marked degraded", async () => {
  stubFetch([() => new Response(goodStream(), { status: 200 })]);

  const events = await collect(runVisionStream(INPUT));
  const deltas = events.filter((event) => event.type === "delta");
  const final = events.at(-1);

  assert.ok(deltas.length > 1, "should arrive in more than one piece");
  assert.equal(deltas.map((event) => event.text).join(""), ANSWER.message);
  assert.equal(final.output.result.message, ANSWER.message);
  assert.equal(final.output.streamDegraded, false);
});

/** The safety net. Streaming is an optimization, so if it breaks the user must
 * get a slow answer rather than no answer — a broken optimization taking the
 * feature down with it is the outcome this exists to prevent. */
test("a stream that fails before any text falls back to the ordinary call", async () => {
  const calls = stubFetch([
    () => new Response("upstream exploded", { status: 500 }),
    () => new Response(plainBody(), { status: 200 }),
  ]);

  const events = await collect(runVisionStream(INPUT));
  const final = events.at(-1);

  assert.deepEqual(calls, [{ streamRequested: true }, { streamRequested: false }]);
  assert.equal(final.output.result.message, ANSWER.message);
  assert.equal(final.output.fallbackUsed, false, "same model, not the secondary");
  assert.equal(
    final.output.streamDegraded,
    true,
    "a silent degrade would make the streaming latency numbers describe a path that never ran",
  );
});

/** A stream that dies mid-answer cannot be redone quietly: the user has already
 * read part of it. That case belongs to the model fallback, which retracts the
 * text first. */
test("a stream that fails after sending text does not silently re-run", async () => {
  const truncated = sseBody(
    frame({ type: "response.output_text.delta", delta: '{"mode":"guide","message":"左の' }),
  );
  const calls = stubFetch([
    () => new Response(truncated, { status: 200 }),
    // The secondary model, reached through the ordinary fallback path.
    () => new Response(goodStream(), { status: 200 }),
  ]);

  const events = await collect(runVisionStream(INPUT));

  assert.deepEqual(calls, [{ streamRequested: true }, { streamRequested: true }]);
  assert.deepEqual(events.map((event) => event.type).slice(0, 2), ["delta", "reset"]);
  assert.equal(events.at(-1).output.fallbackUsed, true);
  assert.equal(events.at(-1).output.streamDegraded, false);
});
