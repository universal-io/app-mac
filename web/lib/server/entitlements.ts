// Plan -> feature flags (docs/foundation-redesign-plan.md §5-c). The plan ×
// feature matrix lives in the plan catalog (bs_plans.features), so both the
// future server-side gates (operation checks in the AI routes) and
// GET /api/account read from that one source via plans.ts.
//
// Enforcement is NOT wired yet — no AI endpoint consults this. Clients may
// use the `features` list from /api/account for display gating only
// (hide/lock buttons); the server stays the authority once gating lands.

import { getPlanConfig } from "@/lib/server/plans";

/** Feature identifiers, matching the five product modes plus pack tiers. */
export const ALL_FEATURES = [
  "compose",
  "transform",
  "navigator",
  "copilot",
  "packs_standard",
] as const;

export type Feature = (typeof ALL_FEATURES)[number];

/**
 * Features available to a plan, read from the catalog (bs_plans.features).
 * `["*"]` (the current beta policy for every plan) expands to all features.
 * An unknown plan / config gap also grants everything — display gating must
 * fail open, never hide a feature the user actually has.
 *
 * NOTE: which plan loses copilot, where tenant packs sit, etc. is an OWNER
 * DECISION (foundation-redesign-plan §5-c table is a draft). Today every plan
 * is seeded with ["*"], so this changes nothing user-visible yet.
 */
export async function featuresForPlan(plan: string): Promise<Feature[]> {
  const config = await getPlanConfig(plan);
  const allowed = config?.features ?? ["*"];
  if (allowed.includes("*")) {
    return [...ALL_FEATURES];
  }
  return ALL_FEATURES.filter((feature) => allowed.includes(feature));
}
