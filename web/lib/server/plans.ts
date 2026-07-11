// Plan catalog (docs/foundation-redesign-plan.md §5-c): the single source of
// truth for "what each plan grants" — the monthly usage cap and the allowed
// feature set, keyed by plan. Rows of `bs_plans` are read through the
// service-role client behind a short in-memory cache, so changing a plan's
// quota/features is a row UPDATE — no deploy, no provisioning-code edit.
//
// Same shape as harness.ts: the in-code SEED_PLANS below is the fallback when
// the table is empty or unreachable, so a DB blip never silently drops the
// free-tier cap. Resolution never touches env — bs_plans (or this seed) is the
// only source.

import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

export type PlanConfig = {
  /** Monthly cap across all AI operations (1 request = 1 unit). null = unlimited. */
  monthlyUsageLimit: number | null;
  /** Allowed feature ids. ["*"] means every feature (current beta policy). */
  features: string[];
};

// Beta policy (owner decision 2026-07-08), mirrored from 0004_plan_catalog.sql:
// only the free plan carries a real quota; every other plan is unlimited; all
// plans allow all features. Used verbatim when bs_plans is empty/unreachable.
const SEED_PLANS: Record<string, PlanConfig> = {
  free: { monthlyUsageLimit: 500, features: ["*"] },
  standard: { monthlyUsageLimit: null, features: ["*"] },
  pro: { monthlyUsageLimit: null, features: ["*"] },
  team: { monthlyUsageLimit: null, features: ["*"] },
  enterprise: { monthlyUsageLimit: null, features: ["*"] },
};

const PLAN_CACHE_TTL_MS = 60_000;

let planCache: { plans: Map<string, PlanConfig>; expiresAt: number } | null = null;

/** All plan configs, read at most every PLAN_CACHE_TTL_MS. Any failure
 * (missing table, network, malformed rows) falls back to SEED_PLANS — plan
 * resolution must never take the gateway down. */
async function loadPlans(): Promise<Map<string, PlanConfig>> {
  const now = Date.now();
  if (planCache && now < planCache.expiresAt) {
    return planCache.plans;
  }

  const plans = new Map<string, PlanConfig>(Object.entries(SEED_PLANS));
  try {
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_plans")
      .select("plan, monthly_usage_limit, features");
    if (error) {
      throw new Error(error.message);
    }
    for (const row of data ?? []) {
      const config = planFromRow(row);
      if (config) {
        plans.set(String(row.plan), config);
      }
    }
  } catch (error) {
    console.error(
      "[plans] catalog load failed, using built-in seed:",
      error instanceof Error ? error.message : error,
    );
  }
  planCache = { plans, expiresAt: now + PLAN_CACHE_TTL_MS };
  return plans;
}

type PlanRow = {
  plan: string | null;
  monthly_usage_limit: number | null;
  features: unknown;
};

function planFromRow(row: PlanRow): PlanConfig | null {
  if (!row.plan) return null;
  const limit =
    typeof row.monthly_usage_limit === "number" ? row.monthly_usage_limit : null;
  const features = Array.isArray(row.features)
    ? row.features.filter((f): f is string => typeof f === "string")
    : ["*"];
  return { monthlyUsageLimit: limit, features };
}

/** The config for a plan, or null if the plan is unknown even in the seed
 * (callers treat a null config as "unlimited, all features" — fail open). */
export async function getPlanConfig(plan: string): Promise<PlanConfig | null> {
  return (await loadPlans()).get(plan) ?? null;
}
