import { describe, expect, test } from "vitest";

import { parseModelVerifierResponse } from "./navigate-model-verifier";

const allowed = new Set(["ax:country", "ax:heading"]);

describe("Navigator model Verifier contract", () => {
  test("accepts one strict supported result and maps final-step completion", () => {
    expect(parseModelVerifierResponse(JSON.stringify({
      status: "verified",
      reason: "MODEL_POSTCONDITIONS_SUPPORTED",
      evidence_candidate_ids: ["ax:country"],
      confidence: 0.94,
    }), allowed, true)).toEqual({
      source: "model",
      status: "complete",
      reason: "MODEL_POSTCONDITIONS_SUPPORTED",
      evidenceCandidateIds: ["ax:country"],
      confidence: 0.94,
    });
  });

  test("rejects invented evidence, mismatched reasons, and surrounding prose", () => {
    expect(parseModelVerifierResponse(JSON.stringify({
      status: "verified",
      reason: "MODEL_POSTCONDITIONS_SUPPORTED",
      evidence_candidate_ids: ["invented"],
      confidence: 0.9,
    }), allowed, false)).toBeNull();
    expect(parseModelVerifierResponse(JSON.stringify({
      status: "blocked",
      reason: "MODEL_POSTCONDITIONS_SUPPORTED",
      evidence_candidate_ids: [],
      confidence: 0.5,
    }), allowed, false)).toBeNull();
    expect(parseModelVerifierResponse(
      'result: {"status":"ambiguous"}',
      allowed,
      false,
    )).toBeNull();
  });
});
