import { describe, expect, test } from "vitest";

import { parsePlannedTask } from "./navigate-engine";

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
});
