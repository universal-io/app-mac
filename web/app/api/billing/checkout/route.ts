// Gateway: POST /api/billing/checkout. Creates a Stripe-hosted Checkout
// session for a plan and returns its URL. The caller (macOS, or the admin
// browser) opens that URL; no client holds a Stripe credential and no client
// chooses a price.

import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";
import {
  ensureStripeCustomer,
  findPurchasablePrice,
  type BillingInterval,
} from "@/lib/server/billing";
import { getStripeClient } from "@/lib/server/stripe";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

const INTERVALS: BillingInterval[] = ["month", "year"];

export async function POST(request: Request): Promise<Response> {
  try {
    // A lapsed or cancelled account is exactly who needs to buy, so the
    // entitlement status must not gate this route.
    const { userId, tenantId, email } = await authenticate(request, {
      requireActiveEntitlement: false,
    });

    const body = (await request.json().catch(() => null)) as {
      plan?: unknown;
      interval?: unknown;
    } | null;
    const plan = typeof body?.plan === "string" ? body.plan.trim() : "";
    if (!plan) {
      return errorResponse(400, "BAD_REQUEST", "planを指定してください。", null);
    }
    const interval = body?.interval ?? "month";
    if (typeof interval !== "string" || !INTERVALS.includes(interval as BillingInterval)) {
      return errorResponse(400, "BAD_REQUEST", "課金間隔が不正です。", null);
    }

    const admin = getSupabaseAdminClient();
    const { data: entitlement, error: entitlementError } = await admin
      .from("bs_entitlements")
      .select("plan, stripe_subscription_id")
      .eq("tenant_id", tenantId)
      .maybeSingle();
    if (entitlementError) {
      console.error("[/api/billing/checkout] entitlement read failed:", entitlementError.message);
      return errorResponse(500, "INTERNAL_ERROR", "契約状態を確認できませんでした。", null);
    }
    if (entitlement?.stripe_subscription_id) {
      // Plan changes belong to the portal, where Stripe handles proration.
      // Running Checkout again would create a second subscription.
      return errorResponse(
        409,
        "SUBSCRIPTION_EXISTS",
        "すでに契約があります。プランの変更・解約はお支払い管理から行ってください。",
        null,
      );
    }

    // The price comes from bs_plan_prices, never from the request.
    const price = await findPurchasablePrice(plan, interval as BillingInterval);
    if (!price) {
      return errorResponse(
        404,
        "PLAN_NOT_PURCHASABLE",
        "このプランは現在購入できません。",
        null,
      );
    }

    const customerId = await ensureStripeCustomer(tenantId, userId, email);
    const origin = new URL(request.url).origin;
    const stripe = getStripeClient();
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: price.priceId, quantity: 1 }],
      // Both are read by the webhook when a subscription arrives without our
      // metadata, and by support when tracing a payment to an account.
      client_reference_id: tenantId,
      subscription_data: { metadata: { tenant_id: tenantId, plan: price.plan } },
      success_url: `${origin}/billing/complete`,
      cancel_url: `${origin}/billing/canceled`,
      // Sold in Japan, in JPY, to a Japanese-language app.
      locale: "ja",
    });

    if (!session.url) {
      console.error("[/api/billing/checkout] session created without a URL:", session.id);
      return errorResponse(502, "BILLING_ERROR", "決済ページを開けませんでした。", null);
    }

    return Response.json({
      url: session.url,
      plan: price.plan,
      price_id: price.priceId,
      interval: price.interval,
      currency: price.currency,
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/billing/checkout] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "決済を開始できませんでした。", null);
  }
}
