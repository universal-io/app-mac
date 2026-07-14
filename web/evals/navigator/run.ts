import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { navigatorEvalResultsSchema, navigatorFixtureSuiteSchema } from "./schema";
import { scoreNavigatorSuite } from "./score";

function argument(name: string): string {
  const index = process.argv.indexOf(`--${name}`);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value || value.startsWith("--")) {
    throw new Error(`Missing required --${name} <path>`);
  }
  return value;
}

async function json(path: string): Promise<unknown> {
  return JSON.parse(await readFile(resolve(process.cwd(), path), "utf8"));
}

async function main(): Promise<void> {
  const fixtures = navigatorFixtureSuiteSchema.parse(await json(argument("fixtures")));
  const results = navigatorEvalResultsSchema.parse(await json(argument("results")));
  const score = scoreNavigatorSuite(fixtures, results);

  console.log(
    `Navigator eval ${fixtures.suite_id} — ${results.run.implementation} / ${results.run.model_provider}:${results.run.model_id}`,
  );
  for (const item of score.cases) {
    const status = item.passed === item.total ? "PASS" : "FAIL";
    console.log(`${status} ${item.caseId} (${item.passed}/${item.total})`);
    for (const assertion of item.assertions.filter((candidate) => !candidate.passed)) {
      console.log(
        `  ${assertion.role}.${assertion.name}: expected=${JSON.stringify(assertion.expected)} actual=${JSON.stringify(assertion.actual)}`,
      );
    }
  }
  console.log(`Total: ${score.passed}/${score.total} (${score.percentage.toFixed(1)}%)`);
  if (score.passed !== score.total) process.exitCode = 1;
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
