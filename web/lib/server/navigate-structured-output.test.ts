import { describe, expect, test } from "vitest";

import { navigatorResponseFormat, parseJSONValue } from "./navigate-structured-output";

describe("Navigator structured role output", () => {
  test("uses strict JSON Schema for OpenAI", () => {
    expect(navigatorResponseFormat("openai", "result", { type: "object" })).toEqual({
      type: "json_schema",
      json_schema: {
        name: "result",
        strict: true,
        schema: { type: "object" },
      },
    });
  });

  test("uses JSON object mode for compatible providers", () => {
    expect(navigatorResponseFormat("groq", "result", { type: "object" }))
      .toEqual({ type: "json_object" });
  });

  test("rejects fenced or decorated JSON", () => {
    expect(parseJSONValue('```json\n{"ok":true}\n```')).toBeNull();
    expect(parseJSONValue('result: {"ok":true}')).toBeNull();
    expect(parseJSONValue('{"ok":true}')).toEqual({ ok: true });
  });
});
