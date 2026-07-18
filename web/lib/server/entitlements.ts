// Plan -> feature flags. The matrix lives only in bs_plans.features.
//
// Enforcement is NOT wired yet — no AI endpoint consults this. Clients may
// use the `features` list from /api/account for display gating only
// (hide/lock buttons); the server stays the authority once gating lands.

import { getPlanConfig } from "@/lib/server/plans";

/** Feature identifiers exposed by the current product. */
export const ALL_FEATURES = [
  "compose",
  "transform",
  "vision",
  "copilot",
] as const;

export type Feature = (typeof ALL_FEATURES)[number];

/**
 * Features available to a plan, read from the catalog (bs_plans.features).
 * `["*"]` (the current beta policy for every plan) expands to all features.
 * An unknown plan or unavailable catalog fails the request; no second plan
 * definition exists in code.
 */
export async function featuresForPlan(plan: string): Promise<Feature[]> {
  const config = await getPlanConfig(plan);
  const allowed = config.features;
  if (allowed.includes("*")) {
    return [...ALL_FEATURES];
  }
  return ALL_FEATURES.filter((feature) => allowed.includes(feature));
}
