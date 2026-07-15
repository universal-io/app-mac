import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// Regression coverage for the Copilot progress-capture turn being
// misrouted to the fast first-turn model (fix/copilot-turn-routing).
// A Copilot progress-capture turn is textless and history-free (one
// image message, no text) — the exact wire shape of the real hotkey
// auto first turn. `task` presence is the only signal that tells them
// apart, so `runNavigateStream` must not fast-route whenever a Task
// rides along, regardless of message shape.
const mocks = vi.hoisted(() => ({
  getServerEnv: vi.fn(),
}));

vi.mock("@/lib/server/env", () => ({ getServerEnv: mocks.getServerEnv }));

import { runNavigateStream, type NavigateEngineInput } from "@/lib/server/navigate-engine";

const baseEnv = {
  groqApiKey: "groq-test-key",
  openaiApiKey: "openai-test-key",
  geminiApiKey: null,
  navigateModelVendor: "openai",
  navigateModelId: "gpt-5.4-mini",
  navigateFastModelVendor: "groq",
  navigateFastModelId: "qwen/qwen3.6-27b",
  navigatePlannerModelVendor: "openai",
  navigatePlannerModelId: "gpt-5.4-mini",
  navigateGrounderModelVendor: "openai",
  navigateGrounderModelId: "gpt-5.4-mini",
  navigateV4Enabled: false,
};

function sseResponse(content: string): Response {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(
        encoder.encode(`data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`),
      );
      controller.enqueue(
        encoder.encode(
          `data: ${JSON.stringify({ usage: { prompt_tokens: 1, completion_tokens: 1 } })}\n\n`,
        ),
      );
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

describe("Navigator fast/main model routing", () => {
  beforeEach(() => {
    mocks.getServerEnv.mockReturnValue(baseEnv);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("routes the real hotkey auto first turn (no task) to the fast model", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(sseResponse("経費精算の画面のようです。")));
    const input: NavigateEngineInput = {
      messages: [{ role: "user", imageDataURL: "data:image/png;base64,AAAA" }],
      language: "japanese",
    };

    let output;
    for await (const event of runNavigateStream(input)) {
      if (event.type === "final") output = event.output;
    }

    expect(output?.modelVendor).toBe("groq");
    expect(output?.modelId).toBe("qwen/qwen3.6-27b");
  });

  test("routes a same-shaped Copilot progress-capture turn (task present) to the main model", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(sseResponse("先月のセッションは154件です。[[target:テスト]][[step:done]]")),
    );
    const input: NavigateEngineInput = {
      messages: [{ role: "user", imageDataURL: "data:image/png;base64,AAAA" }],
      language: "japanese",
      task: {
        goal: "先月のセッション数を確認する",
        steps: [{ verbal: "レポートを開く" }],
        currentStep: 0,
      },
    };

    let output;
    for await (const event of runNavigateStream(input)) {
      if (event.type === "final") output = event.output;
    }

    expect(output?.modelVendor).toBe("openai");
    expect(output?.modelId).toBe("gpt-5.4-mini");
  });
});
