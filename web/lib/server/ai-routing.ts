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
  | "vision"
  | "suggest"
  | "transcribe";

export type AIModelTarget = Readonly<{
  vendor: "openai" | "groq" | "cerebras";
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
  vision: {
    label: "Vision / Copilot",
    // The Cerebras gemma-4-31b trial ended on 2026-08-04: it could not read the
    // contents of an opened pulldown on a real screen. That is not a corner
    // case — GA4, Kinsta, and most admin tools put the destination BEHIND a
    // menu, so a guide that cannot read an open menu cannot guide.
    //
    // The two paths are not even asking for the same thing: the responses path
    // sends `detail: VISION_IMAGE_DETAIL` ("original"), while chat_completions
    // sends the image with no detail request at all and takes whatever the
    // vendor's default downscaling gives. See docs/guidance-accuracy-plan.md.
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
    primary: { vendor: "groq", modelId: "whisper-large-v3-turbo", api: "transcriptions" },
    secondary: { vendor: "openai", modelId: "whisper-1", api: "transcriptions" },
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

/** What a streaming attempt hands back as it runs. */
export type ModelStreamEvent<T> =
  | { type: "delta"; text: string }
  | { type: "value"; value: T };

/**
 * What a caller of `runStreamWithModelFallback` sees. `reset` means text
 * already sent must be thrown away: the primary died partway through its
 * answer and the secondary is starting a different one from the beginning.
 */
export type RoutedStreamEvent<T> =
  | { type: "delta"; text: string }
  | { type: "reset" }
  | { type: "final"; result: RoutedModelResult<T> };

/**
 * The same primary-then-secondary contract as `runWithModelFallback`, for
 * attempts that produce their answer incrementally.
 *
 * It lives beside its non-streaming twin on purpose. Fallback behaviour and the
 * notice a recovered request carries are policy, and policy that exists in two
 * places drifts — which is the reason this file is the single source of truth
 * for routes at all.
 *
 * The one thing streaming adds is that a failure can arrive after the user has
 * already read part of an answer. That text cannot be unsaid, so it is
 * retracted explicitly rather than left on screen with a different answer
 * appended to it.
 */
export async function* runStreamWithModelFallback<T>(
  feature: AIFeature,
  attempt: (target: AIModelTarget) => AsyncGenerator<ModelStreamEvent<T>>,
): AsyncGenerator<RoutedStreamEvent<T>> {
  const route = AI_MODEL_ROUTES[feature];
  const targets = [route.primary, route.secondary] as const;
  const failures: Array<{ target: AIModelTarget; error: unknown }> = [];

  for (const [index, target] of targets.entries()) {
    let sentText = false;
    try {
      for await (const event of attempt(target)) {
        if (event.type === "delta") {
          if (event.text.length === 0) continue;
          sentText = true;
          yield { type: "delta", text: event.text };
          continue;
        }
        yield {
          type: "final",
          result: {
            value: event.value,
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
          },
        };
        return;
      }
      throw new ProviderCallError(
        `${target.vendor}/${target.modelId} stream ended without a result.`,
      );
    } catch (error) {
      failures.push({ target, error });
      console.warn(
        `[ai-routing] ${feature} ${target.vendor}/${target.modelId} stream failed` +
          `${index === 0 ? "; trying secondary" : "; no route left"}:`,
        error instanceof Error ? error.message : String(error),
      );
      if (sentText && index === 0) {
        yield { type: "reset" };
      }
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
    : target.vendor === "groq"
    ? "https://api.groq.com/openai/v1"
    : "https://api.cerebras.ai/v1";
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
  const key = target.vendor === "openai"
    ? env.openaiApiKey
    : target.vendor === "groq"
    ? env.groqApiKey
    : env.cerebrasApiKey;
  if (!key) {
    throw new ProviderCallError(
      `No provider key configured for vendor "${target.vendor}".`,
    );
  }
  return key;
}
