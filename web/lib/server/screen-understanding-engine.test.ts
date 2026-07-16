import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import {
  runScreenUnderstanding,
  SCREEN_UNDERSTANDING_MAX_OUTPUT_TOKENS,
  SCREEN_UNDERSTANDING_MODEL_ID,
} from "./screen-understanding-engine";

function providerResponse(result: Record<string, unknown>): Response {
  return new Response(JSON.stringify({
    status: "completed",
    output: [{
      type: "message",
      content: [{ type: "output_text", text: JSON.stringify(result) }],
    }],
    usage: { input_tokens: 123, output_tokens: 45 },
  }), { status: 200, headers: { "content-type": "application/json" } });
}

describe("Challenge 3 screen understanding engine", () => {
  beforeEach(() => {
    vi.stubEnv("SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("SUPABASE_ANON_KEY", "anon");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role");
    vi.stubEnv("OPENAI_API_KEY", "test-openai-key");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  test("pins the active comparison request and returns strict metadata", async () => {
    const fetchMock = vi.fn().mockResolvedValue(providerResponse({
      mode: "observation",
      message: "Google Analyticsのユーザー属性画面です。",
      observations: ["国別の表が表示されています。"],
      uncertainties: [],
      targetCandidateId: null,
    }));
    vi.stubGlobal("fetch", fetchMock);

    const output = await runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
      candidates: [],
      language: "japanese",
    });

    expect(output).toMatchObject({
      modelVendor: "openai",
      modelId: SCREEN_UNDERSTANDING_MODEL_ID,
      inputTokens: 123,
      outputTokens: 45,
      result: { mode: "observation" },
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const init = fetchMock.mock.calls[0][1] as RequestInit;
    const body = JSON.parse(init.body as string) as {
      model: string;
      store: boolean;
      max_output_tokens: number;
      reasoning: { effort: string };
      text: { format: { type: string; strict: boolean } };
      input: Array<{ content: Array<{ type: string; text?: string }> }>;
    };
    expect(body).toMatchObject({
      model: "gpt-5.6-luna",
      store: false,
      max_output_tokens: SCREEN_UNDERSTANDING_MAX_OUTPUT_TOKENS,
      reasoning: { effort: "none" },
      text: { format: { type: "json_schema", strict: true } },
    });
    expect(body.input[1].content[1]).toEqual({
      type: "input_image",
      image_url: "data:image/png;base64,abc",
      detail: "original",
    });
    expect(body.input[0].content[0].text).toContain(
      "Never mention candidates, candidate IDs, AX, DOM",
    );
  });

  test("fails loudly without trying another model", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response("model unavailable", { status: 404 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
      candidates: [],
      language: "japanese",
    })).rejects.toThrow("GPT-5.6 Luna Responses API failed");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("rejects output outside the structured contract", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(providerResponse({
      mode: "observation",
      message: "画面です。",
      targetCandidateId: null,
    })));

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
      candidates: [],
      language: "japanese",
    })).rejects.toThrow("did not match the Challenge 3 schema");
  });

  test("rejects internal implementation vocabulary in user-visible output", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(providerResponse({
      mode: "clarification",
      message: "現在の候補IDには対応する操作対象がありません。",
      observations: [],
      uncertainties: ["AX候補が不足しています。"],
      targetCandidateId: null,
    })));

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      question: "次は何をしたらいいですか？",
      turns: [],
      candidates: [],
      language: "japanese",
    })).rejects.toThrow("internal implementation vocabulary");
  });

  test("uses the same screenshot and fixed candidates for action guidance", async () => {
    const fetchMock = vi.fn().mockResolvedValue(providerResponse({
      mode: "guide",
      message: "テクノロジーを開いてください。",
      observations: [],
      uncertainties: [],
      targetCandidateId: "ax:technology",
    }));
    vi.stubGlobal("fetch", fetchMock);

    const output = await runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      question: "デバイス別の利用状況を見るには何をしたらいいですか？",
      turns: [],
      candidates: [{
        id: "ax:technology",
        source: "ax",
        role: "link",
        label: "テクノロジー",
        parentLabel: "ユーザー",
        states: [],
      }],
      language: "japanese",
    });

    expect(output.route).toBe("snapshot_vlm");
    expect(output.modelId).toBe(SCREEN_UNDERSTANDING_MODEL_ID);
    expect(output.result.targetCandidateId).toBe("ax:technology");
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string) as {
      input: Array<{ content: Array<{ type: string; text?: string }> }>;
    };
    expect(body.input.flatMap((item) => item.content).some(
      (content) => content.type === "input_image",
    )).toBe(true);
    expect(body.input[1].content[0].text).toContain(
      "A missing target must never suppress or weaken the verbal guidance.",
    );
  });

  test("recomputes one next step from a new capture while preserving only the goal", async () => {
    const fetchMock = vi.fn().mockResolvedValue(providerResponse({
      mode: "guide",
      message: "「ユーザーの環境の詳細」を選択してください。",
      observations: [],
      uncertainties: [],
      targetCandidateId: "ax:environment-detail",
    }));
    vi.stubGlobal("fetch", fetchMock);

    await runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,new-screen",
      turns: [],
      candidates: [{
        id: "ax:environment-detail",
        source: "ax",
        role: "link",
        label: "ユーザーの環境の詳細",
        parentLabel: "テクノロジー",
        states: [],
      }],
      guidance: {
        goal: "デバイス別のアクセス状況を確認したい",
        previousInstruction: "テクノロジーを開いてください。",
      },
      language: "japanese",
    });

    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string) as {
      input: Array<{ content: Array<{ type: string; text?: string }> }>;
    };
    const task = body.input[1].content[0].text ?? "";
    expect(task).toContain("newly captured screen");
    expect(task).toContain("デバイス別のアクセス状況を確認したい");
    expect(task).toContain("テクノロジーを開いてください。");
    expect(task).toContain("Do not repeat the previous instruction");
  });

  test("rejects a model-selected candidate outside the supplied AX set", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(providerResponse({
      mode: "guide",
      message: "ここを押してください。",
      observations: [],
      uncertainties: [],
      targetCandidateId: "ax:invented",
    })));

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      question: "次は何をしたらいいですか？",
      turns: [],
      candidates: [{
        id: "ax:real",
        source: "ax",
        role: "button",
        label: "実在するボタン",
        states: [],
      }],
      language: "japanese",
    })).rejects.toThrow("unknown candidate ID");
  });
});
