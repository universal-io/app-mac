import { loadEnvConfig } from "@next/env";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import type { NavigateEngineOutput } from "../../lib/server/navigate-engine";
import { navigatorFixtureSuiteSchema, type NavigatorEvalResults } from "./schema";

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
  loadEnvConfig(process.cwd());
  const [{ runNavigateStream }, { getServerEnv }] = await Promise.all([
    import("../../lib/server/navigate-engine"),
    import("../../lib/server/env"),
  ]);

  const fixtures = navigatorFixtureSuiteSchema.parse(await json(argument("fixtures")));
  const outputPath = resolve(process.cwd(), argument("output"));
  const env = getServerEnv();
  const cases: NavigatorEvalResults["cases"] = [];
  const observedPacks = new Set<string>();

  for (const fixture of fixtures.cases) {
    if (!fixture.expected.planner) {
      cases.push({ case_id: fixture.id });
      continue;
    }

    const started = performance.now();
    let finalOutput: NavigateEngineOutput | undefined;
    for await (const event of runNavigateStream({
      messages: [
        {
          role: "user",
          text: fixture.input.question,
          ocrText: fixture.input.observation.ocr_text,
        },
      ],
      hints: {
        app_name: fixture.input.observation.environment?.app_name,
        window_title: fixture.input.observation.environment?.window_title,
        url: fixture.input.observation.environment?.url,
      },
      language: fixture.input.language,
    })) {
      if (event.type === "final") finalOutput = event.output;
    }
    if (!finalOutput) throw new Error(`${fixture.id}: current v3 stream returned no final output`);
    if (finalOutput.harnessId) observedPacks.add(`${finalOutput.harnessId}@unversioned-v3`);

    const task = finalOutput.proposedTask;
    cases.push({
      case_id: fixture.id,
      planner: task
        ? { feasible: true, goal: task.goal, steps: task.steps }
        : { feasible: false, goal: "", steps: [] },
      metrics: {
        duration_ms: Math.round(performance.now() - started),
        input_tokens: finalOutput.inputTokens,
        output_tokens: finalOutput.outputTokens,
      },
    });
  }

  const results: NavigatorEvalResults = {
    schema_version: 1,
    run: {
      run_id: `current-v3-${new Date().toISOString()}`,
      created_at: new Date().toISOString(),
      implementation: "navigator-v3-live-provider",
      model_provider: env.navigateModelVendor,
      model_id: env.navigateModelId,
      pack_versions: [...observedPacks],
    },
    cases,
  };
  await writeFile(outputPath, `${JSON.stringify(results, null, 2)}\n`, "utf8");
  console.log(`Wrote ${fixtures.cases.length} cases to ${outputPath}`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
