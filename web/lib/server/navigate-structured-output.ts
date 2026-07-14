export type JSONSchema = Record<string, unknown>;

/**
 * Non-streaming Navigator roles always request provider-enforced JSON.
 * OpenAI supports strict JSON Schema on Chat Completions; compatible vendors
 * keep JSON object mode until their schema adherence is verified separately.
 */
export function navigatorResponseFormat(
  vendor: string,
  name: string,
  schema: JSONSchema,
): Record<string, unknown> {
  if (vendor === "openai") {
    return {
      type: "json_schema",
      json_schema: { name, strict: true, schema },
    };
  }
  return { type: "json_object" };
}

/** Accept exactly one JSON value. Fences or explanatory text are a failure. */
export function parseJSONValue(content: string): unknown | null {
  try {
    return JSON.parse(content.trim());
  } catch {
    return null;
  }
}
