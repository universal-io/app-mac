// Admin authorization + effective-config resolution for the admin console
// (docs/admin-dashboard-plan.md §9-b). Authorization is a DB role
// (bs_profiles.role): 'operator'/'admin' may enter; only 'admin' may mutate.
// The ADMIN_EMAILS env allowlist survives as a bootstrap fallback (union) so a
// misconfigured role column can never lock the owner out of /admin — prod
// Vercel has no ADMIN_EMAILS set, so the DB role is the effective gate there.

import { getServerEnv } from "@/lib/server/env";
import { AI_MODEL_ROUTES } from "@/lib/server/ai-routing";
import { authenticate, GatewayError } from "@/lib/server/gateway";
import { getPlanConfig } from "@/lib/server/plans";
import { stripeMode } from "@/lib/server/stripe";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

/** Platform authority (bs_profiles.role), separate from the tenant-scoped
 * bs_tenant_members.role. Only these two may reach the admin console. */
export type AdminRole = "operator" | "admin";

export type AdminContext = { userId: string; email: string | null; role: AdminRole };

/**
 * Verifies the Supabase JWT (reusing the gateway's authenticate helper) and
 * requires the caller to be an operator or admin — by DB role, or by the
 * ADMIN_EMAILS bootstrap allowlist (treated as admin). Every admin surface —
 * page data loads and aggregate APIs alike — must pass through here before
 * touching the service-role client.
 */
export async function assertAdmin(request: Request): Promise<AdminContext> {
  // Admin visibility must not depend on the owner's own plan being active,
  // so only the entitlement row's existence is required.
  const { userId, email } = await authenticate(request, {
    requireActiveEntitlement: false,
  });

  const dbRole = await fetchProfileRole(userId);
  const bootstrapAdmin = Boolean(
    email && getServerEnv().adminEmails.includes(email.toLowerCase()),
  );

  // Union: DB role wins, env allowlist is a bootstrap that counts as admin.
  const role: AdminRole | null =
    dbRole === "admin" || bootstrapAdmin
      ? "admin"
      : dbRole === "operator"
        ? "operator"
        : null;

  if (!role) {
    throw new GatewayError(403, "FORBIDDEN", "This account is not an administrator.");
  }
  return { userId, email, role };
}

/**
 * Requires the caller to be a full admin (not merely an operator). Use before
 * any privileged mutation; operators get read-only entry.
 */
export async function assertAdminCanMutate(request: Request): Promise<AdminContext> {
  const context = await assertAdmin(request);
  if (context.role !== "admin") {
    throw new GatewayError(
      403,
      "FORBIDDEN",
      "Operators can view but not change accounts.",
    );
  }
  return context;
}

async function fetchProfileRole(userId: string): Promise<AdminRole | "user" | null> {
  const admin = getSupabaseAdminClient();
  const { data } = await admin
    .from("bs_profiles")
    .select("role")
    .eq("id", userId)
    .maybeSingle();
  const role = data?.role;
  return role === "admin" || role === "operator" || role === "user" ? role : null;
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

/**
 * Which Stripe environment the Gateway is actually wired to, and what it can
 * currently sell. Production runs on a sandbox key while billing is brought up,
 * so `mode: "sandbox"` on a live deployment is the state this exists to make
 * visible — the same idea as the app's warning bar for a non-production Gateway.
 */
export type BillingConfig = {
  /** null = no STRIPE_SECRET_KEY, or a key whose prefix we do not recognise. */
  mode: "live" | "sandbox" | null;
  /** Presence only. Without it every webhook is rejected. */
  webhookSecretPresent: boolean;
  /** Prices sellable in the current mode, from bs_plan_prices. */
  purchasablePrices: {
    plan: string;
    priceId: string;
    interval: string;
    currency: string;
  }[];
};

export type EffectiveConfig = {
  models: ModelConfigRow[];
  billing: BillingConfig;
  /** Free-tier monthly cap, sourced from the plan catalog (bs_plans, §5-c).
   * `value: null` means unlimited. `source` is always "plan" now that the
   * catalog is the single knob — kept as a field so the UI can label it. */
  freeMonthlyLimit: { value: number | null; source: "plan" };
  /** Presence only — key values must never leave the server. */
  apiKeys: { groq: boolean; openai: boolean; gemini: boolean; anthropic: boolean; cerebras: boolean };
};

/** Reads the same routing object as the engines. Never includes secret values,
 * only booleans for key presence. */
export async function effectiveConfig(): Promise<EffectiveConfig> {
  const env = getServerEnv();
  const freePlan = await getPlanConfig("free");
  return {
    billing: await billingConfig(),
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
      cerebras: Boolean(env.cerebrasApiKey),
    },
  };
}

async function billingConfig(): Promise<BillingConfig> {
  const env = getServerEnv();
  const mode = stripeMode();
  if (!mode) {
    return { mode: null, webhookSecretPresent: Boolean(env.stripeWebhookSecret), purchasablePrices: [] };
  }

  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_plan_prices")
    .select("plan, stripe_price_id, billing_interval, currency")
    .eq("livemode", mode === "live")
    .eq("is_purchasable", true)
    .order("plan", { ascending: true });
  if (error) {
    console.error("[admin] plan price load failed:", error.message);
  }

  return {
    mode,
    webhookSecretPresent: Boolean(env.stripeWebhookSecret),
    purchasablePrices: (data ?? []).map((row) => ({
      plan: row.plan,
      priceId: row.stripe_price_id,
      interval: row.billing_interval,
      currency: row.currency,
    })),
  };
}
