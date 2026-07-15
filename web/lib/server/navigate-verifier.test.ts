import { describe, expect, test } from "vitest";

import { visionObservationSchema, type VisionObservation } from "@/lib/context/observation";
import { verifyPostconditions } from "./navigate-verifier";

function observation(overrides: Partial<VisionObservation> = {}): VisionObservation {
  return visionObservationSchema.parse({
    schema_version: 1,
    capture_id: crypto.randomUUID(),
    captured_at: "2026-07-14T00:00:00.000Z",
    capture_scope: "display",
    coordinate_space: "normalized_top_left",
    transition_state: "stable",
    environment: {
      app_name: "Google Chrome",
      window_title: "アナリティクス",
      url: "https://analytics.google.com/",
    },
    candidates: [
      { id: "ax:detail", source: "ax", role: "link", label: "ユーザー属性の詳細" },
    ],
    ...overrides,
  });
}

describe("rule-first Navigator Verifier", () => {
  test("verifies the GA4 country page from typed environment and candidate evidence", () => {
    const before = observation();
    const after = observation({
      environment: {
        app_name: "Google Chrome",
        window_title: "ユーザー属性の詳細 - アナリティクス",
        url: "https://analytics.google.com/analytics/web/#/reports/demographics-details",
      },
      candidates: [
        {
          id: "ax:title", source: "ax", role: "heading",
          label: "ユーザー属性の詳細", states: [],
        },
        { id: "ax:country", source: "ax", role: "button", label: "国", states: [] },
      ],
    });

    expect(verifyPostconditions({
      before,
      after,
      postconditions: [
        { kind: "environment_matches", url_contains: "/reports/demographics-details" },
        { kind: "candidate_present", selector: { label: "ユーザー属性の詳細", role: "heading" } },
        { kind: "candidate_present", selector: { label: "国" } },
      ],
    })).toEqual({
      source: "rule",
      status: "verified",
      reason: "ALL_POSTCONDITIONS_MET",
      evidenceCandidateIds: ["ax:title", "ax:country"],
    });
  });

  test("reports not_changed only when the visible state is equivalent", () => {
    const before = observation();
    const after = observation({ capture_id: crypto.randomUUID() });
    expect(verifyPostconditions({
      before,
      after,
      postconditions: [
        { kind: "environment_matches", url_contains: "/reports/demographics-details" },
      ],
    })).toMatchObject({ status: "not_changed", reason: "NO_VISIBLE_CHANGE" });
  });

  test("returns ambiguous for unstable, scope-changed, or conflicting evidence", () => {
    const before = observation();
    expect(verifyPostconditions({
      before,
      after: observation({ transition_state: "settling" }),
      postconditions: [{ kind: "environment_changed", field: "url" }],
    })).toMatchObject({ status: "ambiguous", reason: "OBSERVATION_UNSTABLE" });
    expect(verifyPostconditions({
      before,
      after: observation({ capture_scope: "region" }),
      postconditions: [{ kind: "environment_changed", field: "url" }],
    })).toMatchObject({ status: "ambiguous", reason: "CAPTURE_SCOPE_CHANGED" });
    expect(verifyPostconditions({
      before,
      after: observation({
        environment: {
          app_name: "Google Chrome",
          window_title: "別のレポート",
          url: "https://analytics.google.com/analytics/web/#/reports/other",
        },
      }),
      postconditions: [
        { kind: "environment_matches", url_contains: "/reports/demographics-details" },
      ],
    })).toMatchObject({
      status: "ambiguous",
      reason: "INSUFFICIENT_OR_CONFLICTING_EVIDENCE",
    });
  });

  test("blocks when the required state target is disabled", () => {
    const before = observation();
    const after = observation({
      candidates: [{
        id: "ax:option",
        source: "ax",
        role: "checkbox",
        label: "国",
        states: ["disabled"],
      }],
    });
    expect(verifyPostconditions({
      before,
      after,
      postconditions: [{
        kind: "candidate_state",
        selector: { label: "国" },
        state: "selected",
      }],
    })).toMatchObject({
      status: "blocked",
      reason: "TARGET_DISABLED",
      evidenceCandidateIds: ["ax:option"],
    });
  });

  test("never verifies an empty condition list", () => {
    expect(verifyPostconditions({
      before: observation(),
      after: observation(),
      postconditions: [],
      completesTask: true,
    })).toMatchObject({ status: "ambiguous", reason: "NO_POSTCONDITIONS" });
  });

  test("keeps the capture safety gate ahead of NO_POSTCONDITIONS", () => {
    const before = observation();
    // Owner decision 2026-07-15: an empty condition list now escalates to
    // the generic model Verifier (navigate-run-verifier.ts), but unstable or
    // scope-changed captures must still short-circuit to ambiguous first.
    expect(verifyPostconditions({
      before,
      after: observation({ transition_state: "settling" }),
      postconditions: [],
    })).toMatchObject({ status: "ambiguous", reason: "OBSERVATION_UNSTABLE" });
    expect(verifyPostconditions({
      before,
      after: observation({ capture_scope: "region" }),
      postconditions: [],
    })).toMatchObject({ status: "ambiguous", reason: "CAPTURE_SCOPE_CHANGED" });
  });
});
