// Provider execution for the AI gateway. v1 routes everything to an
// OpenAI-compatible endpoint (Groq by default, OpenAI as a secondary vendor);
// Anthropic lands with model routing in a later phase.

import { getServerEnv } from "@/lib/server/env";
import {
  modelFallbackNotice,
  providerRetryNotice,
  type OperationalNotice,
} from "@/lib/server/operational-notice";
import {
  enrichedSystem,
  userContent,
  JSON_INSTRUCTION,
  type MemoryPayload,
  type OutputLanguageCode,
  type ReviewMode,
  type SituationalContextPayload,
} from "@/lib/server/prompts";

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
  inputTokens: number;
  outputTokens: number;
  notices: OperationalNotice[];
};

export class ProviderCallError extends Error {
  readonly rateLimited: boolean;

  constructor(message: string, options?: { rateLimited?: boolean }) {
    super(message);
    this.name = "ProviderCallError";
    this.rateLimited = options?.rateLimited ?? false;
  }
}

type EngineInput = {
  mode: ReviewMode;
  draft: string;
  language: OutputLanguageCode;
  context?: SituationalContextPayload;
  memory?: MemoryPayload;
  preferredVendor?: string;
  preferredModelId?: string;
};

const VENDOR_ENDPOINTS: Record<string, string> = {
  groq: "https://api.groq.com/openai/v1/chat/completions",
  openai: "https://api.openai.com/v1/chat/completions",
};

/** Resolves vendor/model/endpoint and builds the provider request body. */
function prepareCall(input: EngineInput): {
  vendor: string;
  modelId: string;
  endpoint: string;
  apiKey: string;
  body: Record<string, unknown>;
  notices: OperationalNotice[];
} {
  const env = getServerEnv();

  // Model preference is advisory (docs/api-contract.md); only vendors the
  // gateway actually has keys for are honored, otherwise fall back to default.
  let vendor = input.preferredVendor ?? env.defaultModelVendor;
  let modelId = input.preferredModelId ?? env.defaultModelId;
  const preferred = { vendor, modelId };
  const notices: OperationalNotice[] = [];
  if (!apiKeyFor(vendor)) {
    vendor = env.defaultModelVendor;
    modelId = env.defaultModelId;
    if (vendor !== preferred.vendor || modelId !== preferred.modelId) {
      notices.push(modelFallbackNotice({
        fromVendor: preferred.vendor,
        fromModelId: preferred.modelId,
        toVendor: vendor,
        toModelId: modelId,
      }));
    }
  }
  const apiKey = apiKeyFor(vendor);
  const endpoint = VENDOR_ENDPOINTS[vendor];
  if (!apiKey || !endpoint) {
    throw new ProviderCallError(`No provider key configured for vendor "${vendor}".`);
  }

  const system = enrichedSystem(input.mode, input.memory);
  const user =
    userContent(input.mode, input.draft, input.language, input.context) +
    "\n\n" +
    JSON_INSTRUCTION;

  const body: Record<string, unknown> = {
    model: modelId,
    // 2048 is plenty for a review result, and on Groq the reservation counts
    // toward the tokens-per-minute limit — 4096 made a single context-heavy
    // review eat half the free-tier minute budget.
    max_tokens: 2048,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
  };
  if (vendor === "groq" && modelId.includes("gpt-oss")) {
    body.reasoning_effort = "medium";
  }

  return { vendor, modelId, endpoint, apiKey, body, notices };
}

export async function runReview(input: EngineInput): Promise<ReviewEngineOutput> {
  const { vendor, modelId, endpoint, apiKey, body, notices } = prepareCall(input);

  let response = await callProvider(endpoint, apiKey, body);

  // One retry on upstream rate limits, honoring the suggested wait when the
  // provider announces it (Groq puts "try again in Xs" in the error body).
  if (response.status === 429) {
    const detail = await response.text();
    const waitMs = suggestedWaitMs(response, detail);
    await sleep(Math.min(waitMs, 6500));
    response = await callProvider(endpoint, apiKey, body);
    if (response.ok) notices.push(providerRetryNotice(vendor, modelId));
    if (response.status === 429) {
      throw new ProviderCallError(
        "AI エンジンが混雑しています。数秒おいてから再試行してください。",
        { rateLimited: true },
      );
    }
  }

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    throw new ProviderCallError(`Provider HTTP ${response.status}: ${detail}`);
  }

  const root = (await response.json()) as {
    choices?: Array<{ message?: { content?: string; refusal?: string } }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };

  const message = root.choices?.[0]?.message;
  if (message?.refusal) {
    throw new ProviderCallError(`Model refused: ${message.refusal}`);
  }
  const content = message?.content;
  if (!content) {
    throw new ProviderCallError("Provider returned no content.");
  }

  const result = parseResult(content);
  return {
    result,
    modelVendor: vendor,
    modelId,
    inputTokens: root.usage?.prompt_tokens ?? 0,
    outputTokens: root.usage?.completion_tokens ?? 0,
    notices,
  };
}

export type ReviewStreamEvent =
  | { type: "delta"; text: string }
  | { type: "final"; output: ReviewEngineOutput };

/**
 * Streaming variant of `runReview`. Yields `delta` events carrying increments
 * of `revised_text` as the model produces them (the JSON instruction puts
 * `revised_text` first so the deliverable streams immediately), then a single
 * `final` event with the fully parsed result and token usage.
 */
export async function* runReviewStream(
  input: EngineInput,
): AsyncGenerator<ReviewStreamEvent> {
  const { vendor, modelId, endpoint, apiKey, body, notices } = prepareCall(input);
  body.stream = true;
  // OpenAI-compatible: ask for a usage block on the last chunk.
  body.stream_options = { include_usage: true };

  let response = await callProvider(endpoint, apiKey, body);

  // Same single retry on upstream rate limits as the non-streaming path;
  // safe because nothing has been streamed yet.
  if (response.status === 429) {
    const detail = await response.text();
    const waitMs = suggestedWaitMs(response, detail);
    await sleep(Math.min(waitMs, 6500));
    response = await callProvider(endpoint, apiKey, body);
    if (response.ok) notices.push(providerRetryNotice(vendor, modelId));
    if (response.status === 429) {
      throw new ProviderCallError(
        "AI エンジンが混雑しています。数秒おいてから再試行してください。",
        { rateLimited: true },
      );
    }
  }

  if (!response.ok || !response.body) {
    const detail = (await response.text()).slice(0, 500);
    throw new ProviderCallError(`Provider HTTP ${response.status}: ${detail}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const extractor = new RevisedTextExtractor();
  let rawContent = "";
  let sseBuffer = "";
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      sseBuffer += decoder.decode(value, { stream: true });

      // Provider SSE: lines of `data: {json}` separated by newlines.
      const lines = sseBuffer.split("\n");
      sseBuffer = lines.pop() ?? "";
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const payload = trimmed.slice(5).trim();
        if (payload === "[DONE]") continue;

        let chunk: {
          choices?: Array<{ delta?: { content?: string } }>;
          usage?: { prompt_tokens?: number; completion_tokens?: number } | null;
          x_groq?: { usage?: { prompt_tokens?: number; completion_tokens?: number } };
        };
        try {
          chunk = JSON.parse(payload);
        } catch {
          continue;
        }

        const usage = chunk.usage ?? chunk.x_groq?.usage;
        if (usage) {
          inputTokens = usage.prompt_tokens ?? inputTokens;
          outputTokens = usage.completion_tokens ?? outputTokens;
        }

        const content = chunk.choices?.[0]?.delta?.content;
        if (typeof content === "string" && content.length > 0) {
          rawContent += content;
          const delta = extractor.push(rawContent);
          if (delta) {
            yield { type: "delta", text: delta };
          }
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  const result = parseResult(rawContent);
  yield {
    type: "final",
    output: {
      result,
      modelVendor: vendor,
      modelId,
      inputTokens,
      outputTokens,
      notices,
    },
  };
}

/**
 * Incrementally decodes the value of the `"revised_text"` field out of a
 * growing JSON document. `push` takes the full accumulated raw content and
 * returns only the newly decoded characters since the previous call.
 */
class RevisedTextExtractor {
  private emitted = 0;

  push(rawContent: string): string {
    const decoded = RevisedTextExtractor.decodeSoFar(rawContent);
    if (decoded.length <= this.emitted) return "";
    const delta = decoded.slice(this.emitted);
    this.emitted = decoded.length;
    return delta;
  }

  private static decodeSoFar(rawContent: string): string {
    const keyMatch = /"revised_text"\s*:\s*"/.exec(rawContent);
    if (!keyMatch) return "";
    let index = keyMatch.index + keyMatch[0].length;
    let decoded = "";
    while (index < rawContent.length) {
      const char = rawContent[index];
      if (char === '"') break; // closing quote — value complete
      if (char !== "\\") {
        decoded += char;
        index += 1;
        continue;
      }
      // Escape sequence; stop if it is still incomplete at the buffer end.
      const next = rawContent[index + 1];
      if (next === undefined) break;
      if (next === "u") {
        const hex = rawContent.slice(index + 2, index + 6);
        if (hex.length < 4) break;
        const code = Number.parseInt(hex, 16);
        decoded += Number.isNaN(code) ? "" : String.fromCharCode(code);
        index += 6;
        continue;
      }
      const simple: Record<string, string> = {
        '"': '"', "\\": "\\", "/": "/", n: "\n", t: "\t", r: "\r", b: "\b", f: "\f",
      };
      decoded += simple[next] ?? next;
      index += 2;
    }
    return decoded;
  }
}

function callProvider(
  endpoint: string,
  apiKey: string,
  body: Record<string, unknown>,
): Promise<Response> {
  return fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function suggestedWaitMs(response: Response, detail: string): number {
  const retryAfter = Number.parseFloat(response.headers.get("retry-after") ?? "");
  if (Number.isFinite(retryAfter) && retryAfter > 0) {
    return retryAfter * 1000;
  }
  const match = detail.match(/try again in ([\d.]+)s/i);
  if (match) {
    return Number.parseFloat(match[1]) * 1000 + 500;
  }
  return 3000;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function apiKeyFor(vendor: string): string | null {
  const env = getServerEnv();
  switch (vendor) {
    case "groq":
      return env.groqApiKey;
    case "openai":
      return env.openaiApiKey;
    default:
      return null;
  }
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
