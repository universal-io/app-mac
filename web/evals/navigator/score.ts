import type { NavigatorEvalResults, NavigatorFixtureSuite } from "./schema";

export type AssertionScore = {
  role: "planner" | "grounding" | "verifier";
  name: string;
  passed: boolean;
  expected: unknown;
  actual: unknown;
};

export type CaseScore = {
  caseId: string;
  assertions: AssertionScore[];
  passed: number;
  total: number;
};

export type SuiteScore = {
  cases: CaseScore[];
  passed: number;
  total: number;
  percentage: number;
};

function normalized(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/\s+/gu, "");
}

function sameStrings(actual: string[], expected: string[]): boolean {
  return (
    actual.length === expected.length &&
    actual.every((value, index) => normalized(value) === normalized(expected[index]))
  );
}

export function scoreNavigatorSuite(
  fixtures: NavigatorFixtureSuite,
  results: NavigatorEvalResults,
): SuiteScore {
  const resultByCase = new Map(results.cases.map((item) => [item.case_id, item]));
  const cases: CaseScore[] = fixtures.cases.map((fixture) => {
    const actual = resultByCase.get(fixture.id);
    const assertions: AssertionScore[] = [];

    if (fixture.expected.planner) {
      const expected = fixture.expected.planner;
      assertions.push({
        role: "planner",
        name: "feasible",
        passed: actual?.planner?.feasible === expected.feasible,
        expected: expected.feasible,
        actual: actual?.planner?.feasible,
      });
      for (const fragment of expected.goal_contains) {
        assertions.push({
          role: "planner",
          name: `goal_contains:${fragment}`,
          passed: normalized(actual?.planner?.goal ?? "").includes(normalized(fragment)),
          expected: fragment,
          actual: actual?.planner?.goal,
        });
      }
      const actualTargets = (actual?.planner?.steps ?? [])
        .map((step) => step.target)
        .filter((target): target is string => Boolean(target));
      assertions.push({
        role: "planner",
        name: "target_sequence",
        passed: sameStrings(actualTargets, expected.target_sequence),
        expected: expected.target_sequence,
        actual: actualTargets,
      });
    }

    if (fixture.expected.grounding) {
      assertions.push({
        role: "grounding",
        name: "candidate_id",
        passed: actual?.grounding?.candidate_id === fixture.expected.grounding.candidate_id,
        expected: fixture.expected.grounding.candidate_id,
        actual: actual?.grounding?.candidate_id,
      });
    }

    if (fixture.expected.verifier) {
      assertions.push({
        role: "verifier",
        name: "status",
        passed: actual?.verifier?.status === fixture.expected.verifier.status,
        expected: fixture.expected.verifier.status,
        actual: actual?.verifier?.status,
      });
    }

    const passed = assertions.filter((assertion) => assertion.passed).length;
    return { caseId: fixture.id, assertions, passed, total: assertions.length };
  });

  const passed = cases.reduce((sum, item) => sum + item.passed, 0);
  const total = cases.reduce((sum, item) => sum + item.total, 0);
  return { cases, passed, total, percentage: total === 0 ? 0 : (passed / total) * 100 };
}
