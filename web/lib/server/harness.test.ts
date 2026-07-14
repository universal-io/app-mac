import { describe, expect, test } from "vitest";

import { builtInHarness } from "./harness";

describe("built-in Capability Pack v1", () => {
  test("pins the GA4 demographics path to stable recipe/step IDs and evidence", () => {
    const pack = builtInHarness("ga4");
    const recipe = pack?.recipes?.find((candidate) => candidate.id === "demographics");

    expect(pack?.version).toBe("1");
    expect(recipe?.steps.map((step) => step.id)).toEqual([
      "demographics.step-1",
      "demographics.step-2",
      "demographics.step-3",
      "demographics.step-4",
    ]);
    expect(recipe?.steps[2].postconditions).toEqual([
      { kind: "environment_matches", url_contains: "/reports/demographics-details" },
      {
        kind: "candidate_present",
        selector: { label: "ユーザー属性の詳細", role: "heading" },
      },
      { kind: "candidate_present", selector: { label: "国" } },
    ]);
  });
});
