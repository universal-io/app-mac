import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

export type PlanConfig = {
  monthlyUsageLimit: number | null;
  features: string[];
};

const PLAN_CACHE_TTL_MS = 60_000;

let planCache: { plans: Map<string, PlanConfig>; expiresAt: number } | null = null;

async function loadPlans(): Promise<Map<string, PlanConfig>> {
  const now = Date.now();
  if (planCache && now < planCache.expiresAt) {
    return planCache.plans;
  }

  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_plans")
    .select("plan, monthly_usage_limit, features");
  if (error) {
    throw new Error(`Plan catalog load failed: ${error.message}`);
  }

  const plans = new Map<string, PlanConfig>();
  for (const row of data ?? []) {
    if (typeof row.plan !== "string" || !Array.isArray(row.features)) continue;
    plans.set(row.plan, {
      monthlyUsageLimit:
        typeof row.monthly_usage_limit === "number" ? row.monthly_usage_limit : null,
      features: row.features.filter((feature): feature is string => typeof feature === "string"),
    });
  }
  if (plans.size === 0) {
    throw new Error("Plan catalog is empty.");
  }

  planCache = { plans, expiresAt: now + PLAN_CACHE_TTL_MS };
  return plans;
}

export async function getPlanConfig(plan: string): Promise<PlanConfig> {
  const config = (await loadPlans()).get(plan);
  if (!config) {
    throw new Error(`Unknown plan: ${plan}`);
  }
  return config;
}
