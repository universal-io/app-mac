import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, test } from "vitest";

import { navigatorEvalResultsSchema, navigatorFixtureSuiteSchema } from "./schema";
import { scoreNavigatorSuite } from "./score";

function fixtureJson(path: string): unknown {
  return JSON.parse(readFileSync(resolve(__dirname, path), "utf8"));
}

describe("Navigator eval contracts", () => {
  const fixtures = navigatorFixtureSuiteSchema.parse(
    fixtureJson("fixtures/ga4-smoke.v1.json"),
  );
  const reference = navigatorEvalResultsSchema.parse(
    fixtureJson("results/ga4-reference.v1.json"),
  );

  test("the GA4 fixture and reference result satisfy their strict schemas", () => {
    expect(fixtures.cases).toHaveLength(4);
    expect(reference.cases).toHaveLength(4);
  });

  test("the reference result passes every assertion", () => {
    const score = scoreNavigatorSuite(fixtures, reference);
    expect(score.percentage).toBe(100);
    expect(score.cases.every((item) => item.passed === item.total)).toBe(true);
  });

  test("the known country-to-technology regression is detected", () => {
    const wrong = structuredClone(reference);
    const result = wrong.cases.find((item) => item.case_id === "ga4-plan-country-region");
    if (!result?.planner) throw new Error("reference planner result missing");
    result.planner.steps = [
      { verbal: "レポートを開く", target: "レポート" },
      { verbal: "テクノロジーを開く", target: "テクノロジー" },
      { verbal: "概要を開く", target: "概要" },
    ];

    const score = scoreNavigatorSuite(fixtures, wrong);
    const country = score.cases.find((item) => item.caseId === "ga4-plan-country-region");
    expect(country?.assertions.find((item) => item.name === "target_sequence")?.passed).toBe(false);
    expect(score.percentage).toBeLessThan(100);
  });
});
