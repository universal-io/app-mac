import { ProviderCallError } from "@/lib/server/ai-routing";

/**
 * Ceilings for a single provider call, and the arithmetic behind the routes'
 * `maxDuration`.
 *
 * Only transcribe had a timeout before R11. Vision, review, and suggest had
 * none: a provider that accepted the connection and then never answered held
 * the request open until the platform killed it, and `runWithModelFallback`
 * never reached the secondary model because nothing had thrown. The README's
 * two-model contract only held for providers that failed loudly.
 *
 * These are budgets, not expected latencies. Measured model calls sit around
 * 1-3s and full round trips around 7-8s, so these ceilings cut nothing that was
 * going to succeed.
 *
 * Every route runs its two models in series, so each `maxDuration` must clear
 * `primary + secondary + overhead`. All of them stay at or under 60s, which is
 * the lowest platform ceiling we could be deployed under — a budget that only
 * works on the current plan is a budget that fails at the worst moment.
 */
export const PROVIDER_TIMEOUT_MS = {
  vision: 25_000,
  review: 25_000,
  suggest: 20_000,
  /** Groq is the primary and is fast; whisper-1 is the fallback. 15+35 < 60. */
  transcribeGroq: 15_000,
  transcribeOpenAI: 35_000,
} as const;

export type ProviderTimeoutBudget = keyof typeof PROVIDER_TIMEOUT_MS;

/**
 * `fetch` that gives up. Turns the abort into a `ProviderCallError` so a hung
 * primary reaches the fallback path exactly like an HTTP failure does; the
 * caller cannot tell the two apart, which is the point.
 */
export async function fetchProvider(
  budget: ProviderTimeoutBudget,
  label: string,
  url: string,
  init: RequestInit,
): Promise<Response> {
  const timeoutMs = PROVIDER_TIMEOUT_MS[budget];
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    if (error instanceof DOMException && error.name === "TimeoutError") {
      throw new ProviderCallError(`${label} did not answer within ${timeoutMs}ms.`);
    }
    throw error;
  }
}
