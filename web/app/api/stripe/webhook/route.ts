// Gateway: POST /api/stripe/webhook. The only path by which Stripe changes an
// entitlement. Unauthenticated by design — the signature is the credential —
// so nothing here may trust the body before constructEvent has verified it.

import type Stripe from "stripe";
import { getStripeClient } from "@/lib/server/stripe";
import { getServerEnv } from "@/lib/server/env";
import {
  claimWebhookEvent,
  markWebhookEventApplied,
  markWebhookEventFailed,
  syncSubscriptionToEntitlement,
} from "@/lib/server/billing";

/**
 * Events this endpoint acts on. Every one of them means the same thing to us —
 * "a subscription may have changed" — so all six converge on one reconciliation
 * that re-reads the subscription from Stripe. Anything else Stripe sends is
 * acknowledged and ignored, because a 4xx would make Stripe retry an event we
 * will never handle.
 */
const HANDLED_EVENTS = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.paid",
  "invoice.payment_failed",
]);

export async function POST(request: Request): Promise<Response> {
  const secret = getServerEnv().stripeWebhookSecret;
  if (!secret) {
    // Without the signing secret nothing can be verified, so accepting the body
    // would mean trusting an anonymous caller with plan assignment.
    console.error("[stripe/webhook] STRIPE_WEBHOOK_SECRET is not configured.");
    return new Response("Webhook not configured", { status: 503 });
  }

  const signature = request.headers.get("stripe-signature");
  if (!signature) {
    return new Response("Missing stripe-signature", { status: 400 });
  }

  // The raw body, byte for byte: the signature covers the exact bytes sent, so
  // it must not be parsed or re-serialized first.
  const payload = await request.text();

  let event: Stripe.Event;
  try {
    event = getStripeClient().webhooks.constructEvent(payload, signature, secret);
  } catch (error) {
    // A bad signature is a rejected request, not a server fault. 400 stops
    // Stripe from retrying something that can never verify.
    console.error("[stripe/webhook] signature verification failed:", error);
    return new Response("Signature verification failed", { status: 400 });
  }

  if (!HANDLED_EVENTS.has(event.type)) {
    return Response.json({ received: true, handled: false });
  }

  let claim;
  try {
    claim = await claimWebhookEvent(event);
  } catch (error) {
    // Bookkeeping failed, so we cannot tell a first delivery from a repeat.
    // Ask for a retry rather than apply an event we cannot record.
    console.error("[stripe/webhook] event claim failed:", error);
    return new Response("Event bookkeeping failed", { status: 500 });
  }
  if (claim === "duplicate") {
    return Response.json({ received: true, duplicate: true });
  }

  const subscriptionId = subscriptionIdFor(event);
  if (!subscriptionId) {
    // A handled type that carries no subscription (a one-off invoice, a
    // Checkout session that was not a subscription) is complete on arrival.
    await markWebhookEventApplied(event.id, null);
    return Response.json({ received: true, handled: false });
  }

  try {
    const outcome = await syncSubscriptionToEntitlement(subscriptionId);
    await markWebhookEventApplied(event.id, outcome.subscriptionId);
    // Operational only: which tenant moved to which plan. No payment amounts,
    // no customer details.
    console.log(
      `[stripe/webhook] ${event.type} -> tenant ${outcome.tenantId} plan=${outcome.plan} status=${outcome.status}`,
    );
    return Response.json({ received: true, handled: true });
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`[stripe/webhook] ${event.type} failed:`, reason);
    await markWebhookEventFailed(event.id, reason);
    // 500 leaves applied_at null and asks Stripe to retry. That is the right
    // outcome even for a missing bs_plan_prices row: adding the row makes the
    // retry succeed instead of losing the purchase.
    return new Response("Event handling failed", { status: 500 });
  }
}

/** The subscription an event refers to, across the three payload shapes. */
function subscriptionIdFor(event: Stripe.Event): string | null {
  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object as Stripe.Checkout.Session;
      return idOf(session.subscription);
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const subscription = event.data.object as Stripe.Subscription;
      return subscription.id;
    }
    case "invoice.paid":
    case "invoice.payment_failed": {
      // In the pinned API version an invoice no longer has a `subscription`
      // field; the link moved under `parent.subscription_details`.
      const invoice = event.data.object as Stripe.Invoice;
      return idOf(invoice.parent?.subscription_details?.subscription);
    }
    default:
      return null;
  }
}

function idOf(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}
