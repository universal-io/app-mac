// Admin authorization + effective-config resolution for the admin console
// (docs/admin-dashboard-plan.md). v0: an env allowlist (ADMIN_EMAILS) decides
// who is an admin; v1 promotes this to bs_profiles.role.

import { getServerEnv } from "@/lib/server/env";
import { AI_MODEL_ROUTES } from "@/lib/server/ai-routing";
import { authenticate, GatewayError } from "@/lib/server/gateway";
import { getPlanConfig } from "@/lib/server/plans";

/**
 * Verifies the Supabase JWT (reusing the gateway's authenticate helper) and
 * requires the caller's email to be in ADMIN_EMAILS. Every admin surface —
 * page data loads and aggregate APIs alike — must pass through here before
 * touching the service-role client.
 */
export async function assertAdmin(request: Request): Promise<{ email: string }> {
  // Admin visibility must not depend on the owner's own plan being active,
  // so only the entitlement row's existence is required.
  const { email } = await authenticate(request, { requireActiveEntitlement: false });
  const allowed = getServerEnv().adminEmails;
  if (!email || !allowed.includes(email.toLowerCase())) {
    throw new GatewayError(403, "FORBIDDEN", "This account is not an administrator.");
  }
  return { email };
}

// --- Effective model configuration (admin-dashboard-plan §3-a) -------------
// Shows the primary and secondary targets from the same routing SSOT used by
// every engine.

export type ModelConfigRow = {
  /** Operation label, e.g. "review（既定）". */
  label: string;
  priority: "primary" | "secondary";
  vendor: string;
  modelId: string;
  api: string;
};

export type EffectiveConfig = {
  models: ModelConfigRow[];
  /** Free-tier monthly cap, sourced from the plan catalog (bs_plans, §5-c).
   * `value: null` means unlimited. `source` is always "plan" now that the
   * catalog is the single knob — kept as a field so the UI can label it. */
  freeMonthlyLimit: { value: number | null; source: "plan" };
  /** Presence only — key values must never leave the server. */
  apiKeys: { groq: boolean; openai: boolean; gemini: boolean; anthropic: boolean };
};

/** Reads the same routing object as the engines. Never includes secret values,
 * only booleans for key presence. */
export async function effectiveConfig(): Promise<EffectiveConfig> {
  const env = getServerEnv();
  const freePlan = await getPlanConfig("free");
  return {
    models: Object.values(AI_MODEL_ROUTES).flatMap((route) => [
      {
        label: route.label,
        priority: "primary" as const,
        vendor: route.primary.vendor,
        modelId: route.primary.modelId,
        api: route.primary.api,
      },
      {
        label: route.label,
        priority: "secondary" as const,
        vendor: route.secondary.vendor,
        modelId: route.secondary.modelId,
        api: route.secondary.api,
      },
    ]),
    freeMonthlyLimit: {
      value: freePlan.monthlyUsageLimit,
      source: "plan",
    },
    apiKeys: {
      groq: Boolean(env.groqApiKey),
      openai: Boolean(env.openaiApiKey),
      gemini: Boolean(env.geminiApiKey),
      anthropic: Boolean(env.anthropicApiKey),
    },
  };
}
