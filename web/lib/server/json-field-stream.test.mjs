import assert from "node:assert/strict";
import test from "node:test";

import { JSONStringFieldStream } from "./json-field-stream.ts";

/** Feeds the text one character at a time — the worst split a provider can
 * produce, and the only way to be sure no boundary is special. */
function drainCharByChar(field, json) {
  const stream = new JSONStringFieldStream(field);
  let out = "";
  for (const char of json) out += stream.push(char);
  return { out, finished: stream.finished };
}

test("streams the field's decoded value and stops at its closing quote", () => {
  const json = '{"mode":"guide","message":"左のレポートを開きます","observations":[]}';
  const { out, finished } = drainCharByChar("message", json);
  assert.equal(out, "左のレポートを開きます");
  assert.ok(finished);
});

test("emits nothing for fields that come after the streamed one", () => {
  const json = '{"message":"done","uncertainties":["should not appear"]}';
  const { out } = drainCharByChar("message", json);
  assert.equal(out, "done");
});

test("decodes escapes into display text rather than JSON source", () => {
  const json = '{"message":"line one\\nline \\"two\\"\\\\end\\u3002"}';
  const { out } = drainCharByChar("message", json);
  assert.equal(out, 'line one\nline "two"\\end。');
});

/** The failure this class exists to avoid: a chunk boundary inside `\uXXXX`
 * must not surface as the literal characters `\`, `u`, `3`, `0`. */
test("holds back an escape split across chunks instead of emitting it raw", () => {
  const stream = new JSONStringFieldStream("message");
  assert.equal(stream.push('{"message":"a\\u30'), "a");
  assert.equal(stream.push('42b"'), "あb");
  assert.ok(stream.finished);
});

test("holds back a lone trailing backslash", () => {
  const stream = new JSONStringFieldStream("message");
  assert.equal(stream.push('{"message":"x\\'), "x");
  assert.equal(stream.push('nY"'), "\nY");
});

test("survives the key itself being split across chunks", () => {
  const stream = new JSONStringFieldStream("message");
  assert.equal(stream.push('{"mode":"answer","mes'), "");
  assert.equal(stream.push('sage":"hi"'), "hi");
  assert.ok(stream.finished);
});

/** An increment is decoded as text by the client, so a lone surrogate does not
 * survive the trip — it becomes a replacement character and the emoji is lost
 * to wherever the chunk boundary happened to fall. The half is held back until
 * its partner arrives, so no increment is ever unpaired. */
test("never emits half a surrogate pair, whatever the split", () => {
  const stream = new JSONStringFieldStream("message");
  assert.equal(stream.push('{"message":"ok \\ud83d'), "ok ");
  assert.equal(stream.push('\\ude00 done"'), "😀 done");
  assert.ok(stream.finished);

  const perChar = drainCharByChar("message", '{"message":"ok \\ud83d\\ude00 done"}');
  assert.equal(perChar.out, "ok 😀 done");
});

/** A closing quote inside the value is escaped, so it must not end the read. */
test("does not end the value on an escaped quote", () => {
  const json = '{"message":"say \\"go\\" now","mode":"guide"}';
  const { out } = drainCharByChar("message", json);
  assert.equal(out, 'say "go" now');
});

test("stops cleanly when the field is not a string", () => {
  const stream = new JSONStringFieldStream("message");
  assert.equal(stream.push('{"message":null,"mode":"answer"}'), "");
  assert.ok(stream.finished);
});

test("ignores a key-shaped run that is not followed by a value", () => {
  const json = '{"note":"the \\"message\\" field","message":"real"}';
  const { out } = drainCharByChar("message", json);
  assert.equal(out, "real");
});
