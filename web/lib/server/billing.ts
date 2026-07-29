// Billing state reconciliation between Stripe and bs_entitlements.
//
// The division of responsibility, which nothing here may blur: bs_plans decides
// what a plan GRANTS (quota, features), bs_plan_prices says which Stripe price
// SELLS which plan, and Stripe only reports which price was bought and what
// state that subscription is in. A price id never carries an entitlement, and a
// quota number never comes from Stripe.

import type Stripe from "stripe";
import { getStripeClient, stripeLivemode } from "@/lib/server/stripe";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

/** The plan every account falls back to. Its quota still lives in bs_plans. */
const FALLBACK_PLAN = "free";

export type BillingInterval = "month" | "year";

export type PurchasablePrice = {
  priceId: string;
  plan: string;
  interval: BillingInterval;
  currency: string;
};

/**
 * The price to sell for a plan, from the mapping table only. A price id
 * supplied by a caller is never used: the client says which plan it wants and
 * the server decides which Stripe object that means, so a crafted request
 * cannot subscribe someone to an arbitrary price.
 *
 * Filters to the current key's environment. When a plan has several sellable
 * prices for the same interval (a price is immutable, so a change of price adds
 * a row rather than editing one), the newest wins and older ones keep serving
 * the subscribers already on them.
 */
export async function findPurchasablePrice(
  plan: string,
  interval: BillingInterval,
): Promise<PurchasablePrice | null> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_plan_prices")
    .select("stripe_price_id, plan, billing_interval, currency")
    .eq("plan", plan)
    .eq("billing_interval", interval)
    .eq("livemode", stripeLivemode())
    .eq("is_purchasable", true)
    .order("created_at", { ascending: false })
    .limit(1);
  if (error) {
    throw new Error(`Plan price lookup failed: ${error.message}`);
  }
  const row = data?.[0];
  if (!row) return null;
  return {
    priceId: row.stripe_price_id,
    plan: row.plan,
    interval: row.billing_interval as BillingInterval,
    currency: row.currency,
  };
}

/**
 * The plan a price belongs to, including prices retired from sale. Resolution
 * must succeed for retired prices too: a subscriber who bought last year's
 * price still holds the plan it sold.
 */
async function planForPrice(priceId: string): Promise<string | null> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_plan_prices")
    .select("plan")
    .eq("stripe_price_id", priceId)
    .maybeSingle();
  if (error) {
    throw new Error(`Price-to-plan lookup failed: ${error.message}`);
  }
  return data?.plan ?? null;
}

/**
 * The tenant's Stripe customer, created on first checkout and reused after.
 * The id is stored on the entitlement row, which is already the per-tenant
 * commercial record.
 *
 * Two concurrent checkouts could each create a customer; the conditional update
 * lets only the first one win and the loser adopts the stored id, so a tenant
 * never ends up with its subscriptions split across two customers.
 */
export async function ensureStripeCustomer(
  tenantId: string,
  userId: string,
  email: string | null,
): Promise<string> {
  const admin = getSupabaseAdminClient();
  const { data: existing, error: readError } = await admin
    .from("bs_entitlements")
    .select("stripe_customer_id")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (readError) {
    throw new Error(`Entitlement read failed: ${readError.message}`);
  }
  if (existing?.stripe_customer_id) {
    return existing.stripe_customer_id;
  }

  const stripe = getStripeClient();
  const customer = await stripe.customers.create({
    ...(email ? { email } : {}),
    // Enough to trace a Stripe customer back to a tenant during support work,
    // and nothing about what the user wrote or saw.
    metadata: { tenant_id: tenantId, user_id: userId },
  });

  const { data: claimed, error: claimError } = await admin
    .from("bs_entitlements")
    .update({ stripe_customer_id: customer.id })
    .eq("tenant_id", tenantId)
    .is("stripe_customer_id", null)
    .select("stripe_customer_id");
  if (claimError) {
    throw new Error(`Customer link failed: ${claimError.message}`);
  }
  if (claimed && claimed.length > 0) {
    return customer.id;
  }

  // Someone else linked a customer first. Use theirs and leave the one just
  // created unattached rather than competing for the row.
  const { data: winner } = await admin
    .from("bs_entitlements")
    .select("stripe_customer_id")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (!winner?.stripe_customer_id) {
    throw new Error("Customer link lost and no stored customer found.");
  }
  return winner.stripe_customer_id;
}

/** The Stripe customer already linked to a tenant, or null. */
export async function storedStripeCustomerId(
  tenantId: string,
): Promise<string | null> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_entitlements")
    .select("stripe_customer_id")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (error) {
    throw new Error(`Entitlement read failed: ${error.message}`);
  }
  return data?.stripe_customer_id ?? null;
}

export type BillingSummary = {
  /** Whether /billing/portal has a customer to open a session for. */
  hasBillingAccount: boolean;
  /** ISO date the plan is scheduled to end, or null when it renews. */
  cancelAt: string | null;
};

/**
 * The commercial facts a client needs to render an account page, in one read.
 *
 * Deliberately not folded into `authenticate`: every AI route goes through that,
 * and none of them needs to know whether a subscription is winding down.
 */
export async function billingSummary(
  tenantId: string,
): Promise<BillingSummary> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_entitlements")
    .select("stripe_customer_id, cancel_at")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (error) {
    throw new Error(`Entitlement read failed: ${error.message}`);
  }
  return {
    hasBillingAccount: data?.stripe_customer_id != null,
    cancelAt: data?.cancel_at ?? null,
  };
}

// --- Subscription state -> entitlement -------------------------------------

type EntitlementState = {
  plan: string;
  status: "trialing" | "active" | "past_due";
  keepSubscription: true;
} | {
  plan: typeof FALLBACK_PLAN;
  status: "active";
  keepSubscription: false;
};

/**
 * Maps a Stripe subscription status onto the entitlement.
 *
 * This is a translation, not a copy. Stripe has states bs_entitlements has no
 * value for (`incomplete`, `incomplete_expired`, `unpaid`, `paused`), and
 * writing one of those would violate the status check constraint and lose the
 * event. It is also a decision about access, not a formatting step:
 *
 * - `past_due` keeps the paid plan. Smart Retries run for weeks, and cutting a
 *   paying customer off at the first failed retry punishes an expiring card
 *   harder than an actual cancellation.
 * - Every terminal or never-started state falls back to free/active rather than
 *   to `canceled`. A `canceled` status fails the gateway's entitlement check, so
 *   it would take the free tier away too and leave the account unusable.
 */
function entitlementStateFor(
  status: Stripe.Subscription.Status,
  plan: string,
): EntitlementState {
  switch (status) {
    case "trialing":
      return { plan, status: "trialing", keepSubscription: true };
    case "active":
      return { plan, status: "active", keepSubscription: true };
    case "past_due":
      return { plan, status: "past_due", keepSubscription: true };
    default:
      return { plan: FALLBACK_PLAN, status: "active", keepSubscription: false };
  }
}

/**
 * The subscription's current billing period. In the pinned API version the
 * period lives on the subscription items, not on the subscription, and
 * bs_entitlements requires both ends, so this is read from the first item —
 * which is the whole cycle for the single-item subscriptions we sell.
 */
function subscriptionPeriod(
  subscription: Stripe.Subscription,
): { start: Date; end: Date } | null {
  const item = subscription.items.data[0];
  if (!item) return null;
  const start = new Date(item.current_period_start * 1000);
  const end = new Date(item.current_period_end * 1000);
  if (!(end > start)) return null;
  return { start, end };
}

/**
 * When the subscription is scheduled to stop, or null when it will renew.
 *
 * Cancelling takes effect at the end of the paid period: a customer who paid for
 * the month keeps the month, so the portal is configured to cancel at period end
 * rather than immediately. Stripe reports that as `cancel_at` and, in older API
 * versions, only as the `cancel_at_period_end` flag — both are read so the date
 * is right either way.
 *
 * Recomputed on every sync rather than only set, because the portal lets a
 * customer undo a cancellation: a stale date would keep telling someone their
 * plan ends when it no longer does.
 */
function scheduledCancellationAt(
  subscription: Stripe.Subscription,
  period: { start: Date; end: Date },
): Date | null {
  if (subscription.cancel_at) {
    return new Date(subscription.cancel_at * 1000);
  }
  if (subscription.cancel_at_period_end) {
    return period.end;
  }
  return null;
}

/** Calendar month, matching what bs_provision_user writes for a new free
 * account, so a lapsed account looks like a fresh one rather than keeping the
 * period of a subscription it no longer has. */
function fallbackPeriod(): { start: Date; end: Date } {
  const now = new Date();
  return {
    start: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)),
    end: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)),
  };
}

/** The subscription's customer id, whichever shape the field arrived in. */
function subscriptionCustomerId(
  subscription: Stripe.Subscription,
): string | null {
  return typeof subscription.customer === "string"
    ? subscription.customer
    : subscription.customer?.id ?? null;
}

async function tenantForSubscription(
  subscription: Stripe.Subscription,
): Promise<string | null> {
  const fromMetadata = subscription.metadata?.tenant_id;
  if (typeof fromMetadata === "string" && fromMetadata) {
    return fromMetadata;
  }
  // Older or externally created subscriptions may carry no metadata; the
  // customer link on the entitlement row still identifies the tenant.
  const customerId = subscriptionCustomerId(subscription);
  if (!customerId) return null;
  const admin = getSupabaseAdminClient();
  const { data } = await admin
    .from("bs_entitlements")
    .select("tenant_id")
    .eq("stripe_customer_id", customerId)
    .maybeSingle();
  return data?.tenant_id ?? null;
}

/**
 * Adopts the subscription's customer for a tenant that has none stored.
 *
 * Checkout stores the customer before the subscription exists, but a
 * subscription created any other way (the Stripe Dashboard, a CLI script, an
 * import) leaves the tenant with a plan and no customer id — and the customer
 * portal is looked up by customer id alone, so those accounts could reach a paid
 * plan with no way to cancel it.
 *
 * Conditional on the column still being null, for the same reason
 * `ensureStripeCustomer` is: whoever linked first wins, and a Stripe event is
 * never a reason to move a tenant onto a different customer.
 */
async function adoptSubscriptionCustomer(
  tenantId: string,
  subscription: Stripe.Subscription,
): Promise<void> {
  const customerId = subscriptionCustomerId(subscription);
  if (!customerId) return;
  const admin = getSupabaseAdminClient();
  const { error } = await admin
    .from("bs_entitlements")
    .update({ stripe_customer_id: customerId })
    .eq("tenant_id", tenantId)
    .is("stripe_customer_id", null);
  if (error) {
    // Not fatal: the plan still applies. Log it rather than making Stripe retry
    // an event whose entitlement write succeeded.
    console.error("[billing] customer adoption failed:", error.message);
  }
}

export type SyncOutcome = {
  tenantId: string;
  plan: string;
  status: string;
  subscriptionId: string;
  /** ISO date the plan is scheduled to end, or null when it renews. */
  cancelAt: string | null;
};

/**
 * Brings one tenant's entitlement in line with a subscription.
 *
 * The subscription is re-read from Stripe instead of trusting the event
 * payload. Events are delivered in whatever API version the endpoint was
 * configured with and can arrive out of order, so a stale `updated` event
 * could otherwise overwrite a newer state. Reading the object now means we
 * always write current truth, which also makes every event naturally
 * idempotent.
 */
export async function syncSubscriptionToEntitlement(
  subscriptionId: string,
): Promise<SyncOutcome> {
  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);

  const tenantId = await tenantForSubscription(subscription);
  if (!tenantId) {
    throw new Error(
      `Subscription ${subscriptionId} resolves to no tenant (no metadata.tenant_id and no linked customer).`,
    );
  }

  const item = subscription.items.data[0];
  const priceId = item?.price?.id;
  if (!priceId) {
    throw new Error(`Subscription ${subscriptionId} carries no price.`);
  }
  const soldPlan = await planForPrice(priceId);
  if (!soldPlan) {
    // Refuse rather than guess. Throwing leaves the event unapplied so Stripe
    // retries, which is what should happen if the mapping row is merely
    // missing: adding it makes the retry succeed.
    throw new Error(
      `Price ${priceId} has no bs_plan_prices row; cannot resolve the plan it sells.`,
    );
  }

  const state = entitlementStateFor(subscription.status, soldPlan);
  const period = state.keepSubscription
    ? (subscriptionPeriod(subscription) ?? fallbackPeriod())
    : fallbackPeriod();
  // Only meaningful while the subscription is still held; a terminal state has
  // already ended, so it clears rather than keeping the date it ended on.
  const cancelAt = state.keepSubscription
    ? scheduledCancellationAt(subscription, period)
    : null;

  // Before the state write, so a tenant that reaches a paid plan always has the
  // customer id the portal needs — including on the cancellation event, where the
  // portal is exactly what the user will want next.
  await adoptSubscriptionCustomer(tenantId, subscription);

  const admin = getSupabaseAdminClient();
  const { error } = await admin
    .from("bs_entitlements")
    .update({
      plan: state.plan,
      status: state.status,
      current_period_start: period.start.toISOString(),
      current_period_end: period.end.toISOString(),
      cancel_at: cancelAt?.toISOString() ?? null,
      // Clearing the id on a terminal state matters beyond tidiness: account
      // deletion refuses to run while a subscription id is present, so a
      // cancelled user could otherwise never withdraw.
      stripe_subscription_id: state.keepSubscription ? subscription.id : null,
      // Never touched here. account_class is who pays and monthly_review_limit
      // is a deliberate per-tenant override; a Stripe event is not a reason to
      // reset either.
    })
    .eq("tenant_id", tenantId);
  if (error) {
    throw new Error(`Entitlement update failed: ${error.message}`);
  }

  return {
    tenantId,
    plan: state.plan,
    status: state.status,
    subscriptionId: subscription.id,
    cancelAt: cancelAt?.toISOString() ?? null,
  };
}

// --- Webhook event bookkeeping ---------------------------------------------

export type EventClaim = "fresh" | "retry" | "duplicate";

/**
 * Records an event id before it is applied and reports what to do with it.
 *
 * - `fresh`: first arrival, apply it.
 * - `duplicate`: already applied, ignore it.
 * - `retry`: accepted earlier but never applied, so a previous attempt failed
 *   partway. Apply it again; every apply writes absolute state, so repeating
 *   one cannot double-count anything.
 */
export async function claimWebhookEvent(
  event: Stripe.Event,
): Promise<EventClaim> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_stripe_events")
    .insert({
      event_id: event.id,
      type: event.type,
      livemode: event.livemode,
    })
    .select("event_id");
  if (!error && data && data.length > 0) {
    return "fresh";
  }
  if (error && !isUniqueViolation(error)) {
    throw new Error(`Webhook event claim failed: ${error.message}`);
  }

  const { data: stored } = await admin
    .from("bs_stripe_events")
    .select("applied_at")
    .eq("event_id", event.id)
    .maybeSingle();
  return stored?.applied_at ? "duplicate" : "retry";
}

export async function markWebhookEventApplied(
  eventId: string,
  subscriptionId: string | null,
): Promise<void> {
  const admin = getSupabaseAdminClient();
  const { error } = await admin
    .from("bs_stripe_events")
    .update({
      applied_at: new Date().toISOString(),
      subscription_id: subscriptionId,
      error: null,
    })
    .eq("event_id", eventId);
  if (error) {
    console.error("[billing] marking event applied failed:", error.message);
  }
}

/** Records why an event did not apply. Best-effort: the response status is what
 * makes Stripe retry, this only leaves a trace for diagnosis. */
export async function markWebhookEventFailed(
  eventId: string,
  reason: string,
): Promise<void> {
  const admin = getSupabaseAdminClient();
  const { error } = await admin
    .from("bs_stripe_events")
    .update({ error: reason.slice(0, 1000) })
    .eq("event_id", eventId);
  if (error) {
    console.error("[billing] marking event failed failed:", error.message);
  }
}

function isUniqueViolation(error: { code?: string; message: string }): boolean {
  return error.code === "23505" || /duplicate key/i.test(error.message);
}
