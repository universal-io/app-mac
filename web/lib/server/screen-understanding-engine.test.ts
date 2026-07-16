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
    }));
    vi.stubGlobal("fetch", fetchMock);

    const output = await runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
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
      input: Array<{ content: Array<Record<string, unknown>> }>;
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
  });

  test("fails loudly without trying another model", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response("model unavailable", { status: 404 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
      language: "japanese",
    })).rejects.toThrow("GPT-5.6 Luna Responses API failed");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("rejects output outside the structured contract", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(providerResponse({
      mode: "observation",
      message: "画面です。",
    })));

    await expect(runScreenUnderstanding({
      imageDataURL: "data:image/png;base64,abc",
      turns: [],
      language: "japanese",
    })).rejects.toThrow("did not match the Challenge 3 schema");
  });
});
