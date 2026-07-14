import { describe, expect, test } from "vitest";

import {
  groundObservationCandidate,
  parseGrounderResponse,
} from "./navigate-grounder";

describe("Navigator v4 grounder contract", () => {
  test("resolves a unique exact label without provider tokens", async () => {
    const result = await groundObservationCandidate({
      endpoint: "https://provider.invalid",
      apiKey: "unused",
      modelId: "unused",
      targetLabel: "ユーザー属性",
      context: "GA4 navigation",
      observation: {
        schema_version: 1,
        capture_id: "11111111-1111-4111-8111-111111111111",
        captured_at: "2026-07-14T00:00:00.000Z",
        capture_scope: "display",
        coordinate_space: "normalized_top_left",
        transition_state: "stable",
        candidates: [
          { id: "ax:demographics", source: "ax", label: "ユーザー属性", states: [] },
          { id: "ax:technology", source: "ax", label: "テクノロジー", states: [] },
        ],
      },
    });
    expect(result).toEqual({
      attempted: true,
      selection: {
        captureId: "11111111-1111-4111-8111-111111111111",
        candidateId: "ax:demographics",
        confidence: 1,
        method: "exact_unique",
      },
      inputTokens: 0,
      outputTokens: 0,
    });
  });

  test("accepts only an enumerated candidate id", () => {
    expect(parseGrounderResponse(
      '{"candidate_id":"ax:demographics-overview","confidence":0.94}',
      new Set(["ax:demographics-overview", "ax:technology-overview"]),
    )).toEqual({ candidateId: "ax:demographics-overview", confidence: 0.94 });
  });

  test("rejects a hallucinated candidate id", () => {
    expect(parseGrounderResponse(
      '{"candidate_id":"ax:made-up","confidence":0.99}',
      new Set(["ax:demographics-overview"]),
    )).toBeNull();
  });

  test("rejects an out-of-range confidence", () => {
    expect(parseGrounderResponse(
      '{"candidate_id":"ax:demographics-overview","confidence":1.2}',
      new Set(["ax:demographics-overview"]),
    )).toBeNull();
  });
});
