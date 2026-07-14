import { describe, expect, test } from "vitest";

import {
  modelFallbackNotice,
  dataFallbackNotice,
  providerRetryNotice,
  roleDegradedNotice,
} from "./operational-notice";

describe("operational notices", () => {
  test("names both routes when a model fallback succeeds", () => {
    expect(modelFallbackNotice({
      fromVendor: "groq",
      fromModelId: "qwen/qwen3.6-27b",
      toVendor: "openai",
      toModelId: "gpt-5.4-mini",
    })).toEqual({
      severity: "warning",
      code: "MODEL_FALLBACK",
      message:
        "groq / qwen/qwen3.6-27b にアクセスできなかったため、" +
        "openai / gpt-5.4-mini で処理しました。",
    });
  });

  test("makes recovered role and retry failures visible", () => {
    expect(roleDegradedNotice("Grounder").message).toContain("Grounder");
    expect(providerRetryNotice("groq", "model").message).toContain("再試行");
    expect(dataFallbackNotice("Capability Pack", "組み込み版").message)
      .toContain("組み込み版");
  });
});
