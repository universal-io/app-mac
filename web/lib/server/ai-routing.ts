// Single source of truth for every production AI model route.
//
// Model changes belong here, not inside individual engines or route handlers.
// Every feature gets exactly two ordered targets and executes through
// `runWithModelFallback`, so fallback behavior and notices stay consistent.

import { getServerEnv } from "@/lib/server/env";
import {
  modelFallbackNotice,
  type OperationalNotice,
} from "@/lib/server/operational-notice";

export type AIFeature =
  | "review"
  | "transform"
  | "vision"
  | "suggest"
  | "transcribe"
  | "memory";

export type AIModelTarget = Readonly<{
  vendor: "openai" | "groq";
  modelId: string;
  api: "responses" | "chat_completions" | "transcriptions";
}>;

export type AIModelRoute = Readonly<{
  label: string;
  primary: AIModelTarget;
  secondary: AIModelTarget;
}>;

export const AI_MODEL_ROUTES: Readonly<Record<AIFeature, AIModelRoute>> = {
  review: {
    label: "Compose review",
    primary: { vendor: "openai", modelId: "gpt-5.6-luna", api: "chat_completions" },
    secondary: { vendor: "groq", modelId: "openai/gpt-oss-120b", api: "chat_completions" },
  },
  transform: {
    label: "Transform",
    primary: { vendor: "openai", modelId: "gpt-5.6-luna", api: "responses" },
    secondary: { vendor: "openai", modelId: "gpt-5.4-mini", api: "responses" },
  },
  vision: {
    label: "Vision / Copilot",
    primary: { vendor: "openai", modelId: "gpt-5.6-luna", api: "responses" },
    secondary: { vendor: "openai", modelId: "gpt-5.4-mini", api: "responses" },
  },
  suggest: {
    label: "Compose suggestion",
    primary: { vendor: "openai", modelId: "gpt-5.6-luna", api: "responses" },
    secondary: { vendor: "openai", modelId: "gpt-5.4-mini", api: "responses" },
  },
  transcribe: {
    label: "Transcribe",
    primary: { vendor: "groq", modelId: "whisper-large-v3", api: "transcriptions" },
    secondary: { vendor: "openai", modelId: "whisper-1", api: "transcriptions" },
  },
  memory: {
    label: "Memory distillation",
    primary: { vendor: "openai", modelId: "gpt-5.6-luna", api: "chat_completions" },
    secondary: { vendor: "groq", modelId: "openai/gpt-oss-120b", api: "chat_completions" },
  },
};

export const AI_MODELS_UNAVAILABLE_MESSAGE =
  "一次モデルと二次モデルの両方が応答しませんでした。少し待ってから再試行してください。";

export type RoutedModelResult<T> = {
  value: T;
  modelVendor: string;
  modelId: string;
  api: AIModelTarget["api"];
  fallbackUsed: boolean;
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

export type AIModelFailureContract = {
  status: 429 | 502;
  code: "RATE_LIMITED" | "PROVIDER_ERROR";
  message: string;
  detail: string;
};

/** Shared HTTP/error contract after both configured models have failed. */
export function aiModelFailureContract(error: unknown): AIModelFailureContract {
  const rateLimited = error instanceof ProviderCallError && error.rateLimited;
  return {
    status: rateLimited ? 429 : 502,
    code: rateLimited ? "RATE_LIMITED" : "PROVIDER_ERROR",
    message: AI_MODELS_UNAVAILABLE_MESSAGE,
    detail: error instanceof Error ? error.message : String(error),
  };
}

/**
 * Tries the configured primary once, then the secondary once. A recovered
 * request always carries the same user-visible MODEL_FALLBACK notice shape.
 */
export async function runWithModelFallback<T>(
  feature: AIFeature,
  attempt: (target: AIModelTarget) => Promise<T>,
): Promise<RoutedModelResult<T>> {
  const route = AI_MODEL_ROUTES[feature];
  const targets = [route.primary, route.secondary] as const;
  const failures: Array<{ target: AIModelTarget; error: unknown }> = [];

  for (const [index, target] of targets.entries()) {
    try {
      const value = await attempt(target);
      return {
        value,
        modelVendor: target.vendor,
        modelId: target.modelId,
        api: target.api,
        fallbackUsed: index === 1,
        notices: index === 1
          ? [modelFallbackNotice({
              fromVendor: route.primary.vendor,
              fromModelId: route.primary.modelId,
              toVendor: route.secondary.vendor,
              toModelId: route.secondary.modelId,
            })]
          : [],
      };
    } catch (error) {
      failures.push({ target, error });
      console.warn(
        `[ai-routing] ${feature} ${target.vendor}/${target.modelId} failed` +
          `${index === 0 ? "; trying secondary" : "; no route left"}:`,
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  const rateLimited = failures.length > 0 && failures.every(({ error }) =>
    error instanceof ProviderCallError && error.rateLimited
  );
  const detail = failures
    .map(({ target, error }) =>
      `${target.vendor}/${target.modelId}: ${error instanceof Error ? error.message : String(error)}`
    )
    .join(" | ");
  throw new ProviderCallError(
    `${route.label} primary and secondary models failed. ${detail}`,
    { rateLimited },
  );
}

export function endpointFor(target: AIModelTarget): string {
  const base = target.vendor === "openai"
    ? "https://api.openai.com/v1"
    : "https://api.groq.com/openai/v1";
  switch (target.api) {
    case "responses":
      return `${base}/responses`;
    case "chat_completions":
      return `${base}/chat/completions`;
    case "transcriptions":
      return `${base}/audio/transcriptions`;
  }
}

export function apiKeyFor(target: AIModelTarget): string {
  const env = getServerEnv();
  const key = target.vendor === "openai" ? env.openaiApiKey : env.groqApiKey;
  if (!key) {
    throw new ProviderCallError(
      `No provider key configured for vendor "${target.vendor}".`,
    );
  }
  return key;
}
