// Admin authorization + effective-config resolution for the admin console
// (docs/admin-dashboard-plan.md). v0: an env allowlist (ADMIN_EMAILS) decides
// who is an admin; v1 promotes this to bs_profiles.role.

import { getServerEnv } from "@/lib/server/env";
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
// Shows what the gateway ACTUALLY uses per operation, and whether each value
// comes from an env override or the code default — the 2026-07-06 incident
// (a forgotten navigate model override) is caught at a glance here.

export type ConfigSource = "env" | "default";

export type ModelConfigRow = {
  /** Operation label, e.g. "review（既定）". */
  label: string;
  vendor: string;
  vendorSource: ConfigSource;
  modelId: string;
  modelSource: ConfigSource;
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

/** Resolves the same way the engines do (getServerEnv for models, the plan
 * catalog for the free quota) and tags each value with its origin. Never
 * includes secret values, only booleans for keys. */
export async function effectiveConfig(): Promise<EffectiveConfig> {
  const env = getServerEnv();
  const freePlan = await getPlanConfig("free");
  return {
    models: [
      {
        label: "review（既定）",
        vendor: env.defaultModelVendor,
        vendorSource: sourceOf("BOMB_SQUAD_DEFAULT_MODEL_VENDOR"),
        modelId: env.defaultModelId,
        modelSource: sourceOf("BOMB_SQUAD_DEFAULT_MODEL_ID"),
      },
      {
        label: "vision",
        // The vision engine pins the vendor to OpenAI in code; only the
        // model id is env-tunable today.
        vendor: "openai",
        vendorSource: "default",
        modelId: env.visionModelId,
        modelSource: sourceOf("BOMB_SQUAD_VISION_MODEL_ID"),
      },
      {
        label: "navigate（後続ターン）",
        vendor: env.navigateModelVendor,
        vendorSource: sourceOf("BOMB_SQUAD_NAVIGATE_MODEL_VENDOR"),
        modelId: env.navigateModelId,
        modelSource: sourceOf("BOMB_SQUAD_NAVIGATE_MODEL_ID"),
      },
      {
        label: "navigate（初手・高速）",
        vendor: env.navigateFastModelVendor,
        vendorSource: sourceOf("BOMB_SQUAD_NAVIGATE_FAST_MODEL_VENDOR"),
        modelId: env.navigateFastModelId,
        modelSource: sourceOf("BOMB_SQUAD_NAVIGATE_FAST_MODEL_ID"),
      },
    ],
    freeMonthlyLimit: {
      value: freePlan?.monthlyUsageLimit ?? null,
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

/** "env" when the variable is set to a non-empty value (same normalization
 * as getServerEnv), "default" otherwise. */
function sourceOf(name: string): ConfigSource {
  return process.env[name]?.trim() ? "env" : "default";
}
