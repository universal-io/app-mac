import { describe, expect, test } from "vitest";

import { renderNavigateRunInShadow } from "./navigate-run-renderer";

const snapshot = {
  current_step: 0,
  plan: {
    task: {
      steps: [
        { id: "open-report", verbal: "レポートを開く", target: "レポート", fill: null },
        { id: "read-country", verbal: "国を確認する", target: "国", fill: null },
      ],
    },
  },
} as Parameters<typeof renderNavigateRunInShadow>[0];

describe("Navigator shadow Renderer", () => {
  test("projects the next signed step after verification", () => {
    expect(renderNavigateRunInShadow(snapshot, {
      source: "rule",
      status: "verified",
      reason: "ALL_POSTCONDITIONS_MET",
      evidenceCandidateIds: [],
    })).toMatchObject({
      state: "next_step",
      step: { id: "read-country", verbal: "国を確認する", target: "国" },
    });
  });

  test("never invents a step for ambiguous or complete outcomes", () => {
    expect(renderNavigateRunInShadow(snapshot, {
      source: "rule",
      status: "ambiguous",
      reason: "INSUFFICIENT_OR_CONFLICTING_EVIDENCE",
      evidenceCandidateIds: [],
    })).toMatchObject({ state: "needs_confirmation", step: { id: "open-report" } });
    expect(renderNavigateRunInShadow(snapshot, {
      source: "rule",
      status: "complete",
      reason: "ALL_POSTCONDITIONS_MET",
      evidenceCandidateIds: [],
    })).toMatchObject({ state: "complete", step: null });
  });
});
