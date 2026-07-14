import type { ServerEnv } from "@/lib/server/env";

const VENDOR_ENDPOINTS: Record<string, string> = {
  groq: "https://api.groq.com/openai/v1/chat/completions",
  openai: "https://api.openai.com/v1/chat/completions",
  gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
};

export type NavigateProviderRoute = {
  vendor: string;
  modelId: string;
  apiKey: string;
  endpoint: string;
  fallbackFrom?: { vendor: string; modelId: string };
};

/** Resolves one role route and makes a missing preferred key an explicit fallback. */
export function resolveNavigateRoleRoute(
  env: ServerEnv,
  preferredVendor: string,
  preferredModelId: string,
  fallbackVendor: string,
  fallbackModelId: string,
): NavigateProviderRoute | null {
  const choices = [
    { vendor: preferredVendor, modelId: preferredModelId, isFallback: false },
    { vendor: fallbackVendor, modelId: fallbackModelId, isFallback: true },
  ];
  for (const { vendor, modelId, isFallback } of choices) {
    const apiKey = navigateAPIKey(vendor, env);
    const endpoint = VENDOR_ENDPOINTS[vendor];
    if (apiKey && endpoint) {
      return {
        vendor,
        modelId,
        apiKey,
        endpoint,
        fallbackFrom: isFallback
          && (vendor !== preferredVendor || modelId !== preferredModelId)
          ? { vendor: preferredVendor, modelId: preferredModelId }
          : undefined,
      };
    }
  }
  return null;
}

export function navigateAPIKey(vendor: string, env: ServerEnv): string | null {
  switch (vendor) {
    case "groq":
      return env.groqApiKey;
    case "openai":
      return env.openaiApiKey;
    case "gemini":
      return env.geminiApiKey;
    default:
      return null;
  }
}

export function navigateEndpoint(vendor: string): string | undefined {
  return VENDOR_ENDPOINTS[vendor];
}
