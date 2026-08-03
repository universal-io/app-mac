import {
  apiKeyFor,
  endpointFor,
  ProviderCallError,
  runWithModelFallback,
  type AIModelTarget,
} from "@/lib/server/ai-routing";
import type { OperationalNotice } from "@/lib/server/operational-notice";
import {
  COMPOSE_SYSTEM,
  userContent,
  JSON_INSTRUCTION,
  type OutputLanguageCode,
  type SituationalContextPayload,
} from "@/lib/server/prompts";
import { fetchProvider } from "@/lib/server/provider-timeout";

export type ReviewIssue = {
  category: "typo" | "impoliteness" | "unclear";
  severity: "low" | "medium" | "high";
  excerpt: string;
  explanation: string;
  suggestion: string;
};

export type ReviewResultPayload = {
  issues: ReviewIssue[];
  revised_text: string;
  summary: string;
};

export type ReviewEngineOutput = {
  result: ReviewResultPayload;
  modelVendor: string;
  modelId: string;
  modelApi: string;
  fallbackUsed: boolean;
  inputTokens: number;
  outputTokens: number;
  notices: OperationalNotice[];
};

type EngineInput = {
  draft: string;
  language: OutputLanguageCode;
  context?: SituationalContextPayload;
};

function prepareCall(input: EngineInput, target: AIModelTarget): {
  endpoint: string;
  apiKey: string;
  body: Record<string, unknown>;
} {
  if (target.api !== "chat_completions") {
    throw new ProviderCallError(`Review cannot use API "${target.api}".`);
  }
  const user =
    userContent(input.draft, input.language, input.context) +
    "\n\n" +
    JSON_INSTRUCTION;

  const body: Record<string, unknown> = {
    model: target.modelId,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: COMPOSE_SYSTEM },
      { role: "user", content: user },
    ],
  };
  if (target.vendor === "openai") {
    body.max_completion_tokens = 2048;
    body.reasoning_effort = "none";
    body.store = false;
  } else {
    body.max_tokens = 2048;
  }
  if (target.vendor === "groq" && target.modelId.includes("gpt-oss")) {
    body.reasoning_effort = "medium";
  }

  return {
    endpoint: endpointFor(target),
    apiKey: apiKeyFor(target),
    body,
  };
}

export async function runReview(input: EngineInput): Promise<ReviewEngineOutput> {
  const routed = await runWithModelFallback("review", (target) =>
    callReviewModel(input, target)
  );
  return {
    result: routed.value.result,
    modelVendor: routed.modelVendor,
    modelId: routed.modelId,
    modelApi: routed.api,
    fallbackUsed: routed.fallbackUsed,
    inputTokens: routed.value.inputTokens,
    outputTokens: routed.value.outputTokens,
    notices: routed.notices,
  };
}

export type ReviewStreamEvent =
  | { type: "delta"; text: string }
  | { type: "final"; output: ReviewEngineOutput };

/**
 * Keeps the SSE client contract while routing and fallback finish before the
 * first event. That prevents a partially emitted primary response from being
 * mixed with a secondary result.
 */
export async function* runReviewStream(
  input: EngineInput,
): AsyncGenerator<ReviewStreamEvent> {
  const output = await runReview(input);
  if (output.result.revised_text) {
    yield { type: "delta", text: output.result.revised_text };
  }
  yield { type: "final", output };
}

async function callReviewModel(
  input: EngineInput,
  target: AIModelTarget,
): Promise<{ result: ReviewResultPayload; inputTokens: number; outputTokens: number }> {
  const { endpoint, apiKey, body } = prepareCall(input, target);
  const response = await callProvider(endpoint, apiKey, body);
  if (!response.ok) {
    throw new ProviderCallError(`Provider HTTP ${response.status}.`, {
      rateLimited: response.status === 429,
    });
  }
  const root = (await response.json()) as {
    choices?: Array<{ message?: { content?: string; refusal?: string } }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };
  const message = root.choices?.[0]?.message;
  if (message?.refusal) {
    throw new ProviderCallError(`Model refused: ${message.refusal}`);
  }
  if (!message?.content) {
    throw new ProviderCallError("Provider returned no content.");
  }
  return {
    result: parseResult(message.content),
    inputTokens: root.usage?.prompt_tokens ?? 0,
    outputTokens: root.usage?.completion_tokens ?? 0,
  };
}

function callProvider(
  endpoint: string,
  apiKey: string,
  body: Record<string, unknown>,
): Promise<Response> {
  return fetchProvider("review", "review model", endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

/** Tolerates reasoning blocks, code fences, or stray prose around the JSON. */
function parseResult(raw: string): ReviewResultPayload {
  let text = raw;
  const thinkEnd = text.lastIndexOf("</think>");
  if (thinkEnd >= 0) {
    text = text.slice(thinkEnd + "</think>".length);
  }
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new ProviderCallError("Provider response contained no JSON object.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(text.slice(start, end + 1));
  } catch {
    throw new ProviderCallError("Provider response JSON failed to parse.");
  }

  const candidate = parsed as Partial<ReviewResultPayload>;
  if (typeof candidate.revised_text !== "string" || typeof candidate.summary !== "string") {
    throw new ProviderCallError("Provider response JSON missing required fields.");
  }
  const issues = Array.isArray(candidate.issues)
    ? candidate.issues.filter(isValidIssue)
    : [];
  return {
    issues,
    revised_text: candidate.revised_text,
    summary: candidate.summary,
  };
}

function isValidIssue(value: unknown): value is ReviewIssue {
  if (typeof value !== "object" || value === null) return false;
  const issue = value as Record<string, unknown>;
  return (
    (issue.category === "typo" ||
      issue.category === "impoliteness" ||
      issue.category === "unclear") &&
    (issue.severity === "low" || issue.severity === "medium" || issue.severity === "high") &&
    typeof issue.excerpt === "string" &&
    typeof issue.explanation === "string" &&
    typeof issue.suggestion === "string"
  );
}
