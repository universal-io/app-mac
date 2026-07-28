// Stripe client and mode detection. Server-only: never import from a client
// component. The macOS app never talks to Stripe — it asks this Gateway for a
// hosted URL and opens it in the browser.

import Stripe from "stripe";
import { getServerEnv } from "@/lib/server/env";
import { GatewayError } from "@/lib/server/gateway";

/**
 * Which Stripe environment the configured key belongs to. Production runs on a
 * sandbox key while billing is being brought up, so this is derived from the
 * key itself rather than assumed from the deployment — a live deployment still
 * holding a sandbox key is a state we need to be able to see (master-plan
 * "次期開発: アカウント、課金、テスター運用").
 */
export type StripeMode = "live" | "sandbox";

let cachedClient: Stripe | null = null;
let cachedForKey: string | null = null;

/**
 * The Stripe API version is whatever this SDK pins (`stripe/esm/apiVersion`),
 * deliberately not overridden here: the response shapes we read must match the
 * types we compiled against. In the pinned version a subscription's billing
 * period lives on its items, not on the subscription — see
 * `subscriptionPeriod` in lib/server/billing.ts.
 */
export function getStripeClient(): Stripe {
  const key = getServerEnv().stripeSecretKey;
  if (!key) {
    throw new GatewayError(
      503,
      "BILLING_UNAVAILABLE",
      "課金は現在利用できません。時間をおいて再試行してください。",
    );
  }
  if (!cachedClient || cachedForKey !== key) {
    cachedClient = new Stripe(key);
    cachedForKey = key;
  }
  return cachedClient;
}

/** Mode of the configured key, or null when no key is configured. Restricted
 * keys (`rk_`) carry the same test/live marker as secret keys. */
export function stripeMode(): StripeMode | null {
  const key = getServerEnv().stripeSecretKey;
  if (!key) return null;
  if (key.startsWith("sk_live_") || key.startsWith("rk_live_")) return "live";
  if (key.startsWith("sk_test_") || key.startsWith("rk_test_")) return "sandbox";
  return null;
}

/**
 * The `livemode` value that sellable prices must carry. Sandbox and live price
 * ids coexist in bs_plan_prices, so the key decides which half is in play and a
 * mode switch needs no code or env change beyond the key itself.
 */
export function stripeLivemode(): boolean {
  const mode = stripeMode();
  if (!mode) {
    throw new GatewayError(
      503,
      "BILLING_UNAVAILABLE",
      "課金は現在利用できません。時間をおいて再試行してください。",
    );
  }
  return mode === "live";
}
