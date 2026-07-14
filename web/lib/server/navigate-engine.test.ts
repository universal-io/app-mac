import { describe, expect, test } from "vitest";

import { parsePlannedTask } from "./navigate-engine";
import type { Recipe } from "./harness";

describe("Navigator planner contract", () => {
  const taskJSON = JSON.stringify({
    feasible: true,
    goal: "国別の利用状況を確認する",
    steps: [
      { verbal: "ユーザー属性を開きます", target: "ユーザー属性", fill: null },
      { verbal: "国を確認します", target: "国", fill: null },
    ],
  });

  test("accepts one complete bounded Task value", () => {
    expect(parsePlannedTask(taskJSON)).toEqual({
      goal: "国別の利用状況を確認する",
      currentStep: 0,
      steps: [
        { verbal: "ユーザー属性を開きます", target: "ユーザー属性" },
        { verbal: "国を確認します", target: "国" },
      ],
    });
  });

  test("rejects fenced or decorated Task JSON", () => {
    expect(parsePlannedTask(`\`\`\`json\n${taskJSON}\n\`\`\``)).toBeNull();
    expect(parsePlannedTask(`Task: ${taskJSON}`)).toBeNull();
  });

  test("reconstructs v4 recipe steps and postconditions from stable Pack IDs", () => {
    const recipes: Recipe[] = [{
      id: "demographics",
      goal: "訪問者の国・地域を見る",
      steps: [
        {
          id: "demographics.step-1",
          verbal: "ユーザー属性を開く",
          target: "ユーザー属性",
          postconditions: [{
            kind: "candidate_present",
            selector: { label: "ユーザー属性の詳細" },
          }],
        },
        {
          id: "demographics.step-2",
          verbal: "ユーザー属性の詳細を開く",
          target: "ユーザー属性の詳細",
          postconditions: [{
            kind: "environment_matches",
            url_contains: "/reports/demographics-details",
          }],
        },
      ],
    }];
    const modelOutput = JSON.stringify({
      feasible: true,
      recipe_id: "demographics",
      goal: "モデルが変更したgoal",
      steps: [
        {
          recipe_step_id: "demographics.step-1",
          verbal: "モデルが変更した説明",
          target: "誤った対象",
          fill: null,
        },
        {
          recipe_step_id: "demographics.step-2",
          verbal: "モデルが変更した説明2",
          target: "誤った対象2",
          fill: null,
        },
      ],
    });

    expect(parsePlannedTask(modelOutput, recipes, true)).toEqual({
      recipeId: "demographics",
      goal: "訪問者の国・地域を見る",
      currentStep: 0,
      steps: recipes[0].steps,
    });
  });

  test("rejects invented or reordered v4 recipe step IDs", () => {
    const recipes: Recipe[] = [{
      id: "known",
      goal: "known",
      steps: [
        { id: "known.step-1", verbal: "one", postconditions: [] },
        { id: "known.step-2", verbal: "two", postconditions: [] },
      ],
    }];
    const output = (ids: string[]) => JSON.stringify({
      feasible: true,
      recipe_id: "known",
      goal: "known",
      steps: ids.map((id) => ({
        recipe_step_id: id,
        verbal: "ignored",
        target: null,
        fill: null,
      })),
    });
    expect(parsePlannedTask(output(["known.step-2", "known.step-1"]), recipes, true))
      .toBeNull();
    expect(parsePlannedTask(output(["known.step-1", "invented"]), recipes, true))
      .toBeNull();
  });
});
