import assert from "node:assert/strict";
import test from "node:test";

import { sseData } from "./provider-sse.ts";

/** A body that hands out exactly the chunks given, byte for byte. */
function bodyOf(...chunks) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) {
        controller.enqueue(chunk instanceof Uint8Array ? chunk : encoder.encode(chunk));
      }
      controller.close();
    },
  });
}

async function drain(body) {
  const out = [];
  for await (const event of sseData(body, "probe")) out.push(event);
  return out;
}

/** Serialized rather than hand-escaped: the deltas carry JSON *inside* a JSON
 * string, and writing that by hand produced a frame that silently failed to
 * parse — which the reader then skipped, exactly as designed, and the test
 * blamed the reader. */
function frame(payload) {
  return `event: ${payload.type}\ndata: ${JSON.stringify(payload)}\n\n`;
}

/** The exact event names and shapes measured against the Responses API on
 * 2026-08-05 (docs/latency-plan.md 1-e), including deltas that are fragments of
 * a JSON object. If this stops matching, the streaming path is reading a
 * contract the provider no longer speaks. */
const REAL_FRAMES = [
  frame({ type: "response.created", response: { status: "in_progress" } }),
  frame({ type: "response.output_text.delta", delta: '{"mode":"guide",', sequence_number: 5 }),
  frame({ type: "response.output_text.delta", delta: '"message":"左の', sequence_number: 6 }),
  frame({ type: "response.output_text.done" }),
  frame({
    type: "response.completed",
    response: { status: "completed", usage: { input_tokens: 4927, output_tokens: 171 } },
  }),
];

test("reads the real Responses event sequence in order", async () => {
  const events = await drain(bodyOf(REAL_FRAMES.join("")));
  assert.deepEqual(events.map((event) => event.type), [
    "response.created",
    "response.output_text.delta",
    "response.output_text.delta",
    "response.output_text.done",
    "response.completed",
  ]);
  assert.equal(events[1].delta, '{"mode":"guide",');
  assert.equal(events[4].response.usage.input_tokens, 4927);
});

/** Network chunks do not respect frame boundaries. Every split of the same
 * bytes must produce the same events. */
test("a frame split across chunks is still one event", async () => {
  const whole = REAL_FRAMES.join("");
  const expected = (await drain(bodyOf(whole))).map((event) => event.type);

  for (const at of [1, 40, 120, 200, whole.length - 3]) {
    const events = await drain(bodyOf(whole.slice(0, at), whole.slice(at)));
    assert.deepEqual(events.map((event) => event.type), expected, `split at ${at}`);
  }
});

/** A chunk boundary inside a multi-byte character would otherwise decode to
 * replacement characters — the text is Japanese, so this is the common case,
 * not an edge one. */
test("a multi-byte character split across chunks survives", async () => {
  const frame = 'data: {"type":"d","delta":"左のレポート"}\n\n';
  const bytes = new TextEncoder().encode(frame);
  const cut = bytes.indexOf(0xe5) + 1; // mid-way through 左

  const events = await drain(bodyOf(bytes.slice(0, cut), bytes.slice(cut)));
  assert.equal(events.length, 1);
  assert.equal(events[0].delta, "左のレポート");
});

test("[DONE] ends the stream and is not yielded", async () => {
  const events = await drain(bodyOf(
    'data: {"type":"a"}\n\n',
    "data: [DONE]\n\n",
    'data: {"type":"never"}\n\n',
  ));
  assert.deepEqual(events.map((event) => event.type), ["a"]);
});

test("a final frame with no trailing blank line is still read", async () => {
  const events = await drain(bodyOf('data: {"type":"last"}'));
  assert.deepEqual(events.map((event) => event.type), ["last"]);
});

test("multi-line data fields are joined", async () => {
  const events = await drain(bodyOf('data: {"type":\ndata: "split"}\n\n'));
  assert.deepEqual(events.map((event) => event.type), ["split"]);
});

/** One unreadable frame is not worth failing an answer over; the events that
 * carry the result either parse or the stream ends without one, and the caller
 * treats that as the failure it is. */
test("an unparseable frame is skipped rather than fatal", async () => {
  const events = await drain(bodyOf(
    "data: not json at all\n\n",
    'data: {"type":"after"}\n\n',
  ));
  assert.deepEqual(events.map((event) => event.type), ["after"]);
});

test("comment and non-data lines are ignored", async () => {
  const events = await drain(bodyOf(': keep-alive\n\nevent: x\ndata: {"type":"x"}\n\n'));
  assert.deepEqual(events.map((event) => event.type), ["x"]);
});

test("a missing body is an error, not an empty stream", async () => {
  await assert.rejects(drain(null), /no response body/);
});
