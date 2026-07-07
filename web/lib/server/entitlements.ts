// Plan -> feature flags (docs/foundation-redesign-plan.md §5-c). Minimal
// scaffolding: this module is the single place the plan × feature matrix
// lives, so both the future server-side gates (operation checks in the AI
// routes) and GET /api/account read from one source.
//
// Enforcement is NOT wired yet — no AI endpoint consults this. Clients may
// use the `features` list from /api/account for display gating only
// (hide/lock buttons); the server stays the authority once gating lands.

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
 * Features available to a plan.
 *
 * NOTE: the actual plan × feature matrix (which plan loses copilot, where
 * tenant packs sit, etc.) is an OWNER DECISION (foundation-redesign-plan
 * §5-c table is a draft). Until it is decided, every existing plan maps to
 * every feature, so shipping this field changes nothing user-visible.
 */
export function featuresForPlan(plan: string): Feature[] {
  void plan; // Intentionally unused until the matrix is decided.
  return [...ALL_FEATURES];
}
