// Gateway: POST /api/billing/portal. Returns a Stripe customer portal URL so
// cancellation, plan changes and payment-method updates stay with Stripe. We do
// not rebuild any of that: the money screens are Stripe's
// (docs/admin-dashboard-plan.md §7).

import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";
import { storedStripeCustomerId } from "@/lib/server/billing";
import { getStripeClient } from "@/lib/server/stripe";

export async function POST(request: Request): Promise<Response> {
  try {
    // Someone whose payment failed must still reach the portal to fix the card,
    // so entitlement status cannot gate this either.
    const { tenantId } = await authenticate(request, {
      requireActiveEntitlement: false,
    });

    const customerId = await storedStripeCustomerId(tenantId);
    if (!customerId) {
      return errorResponse(
        404,
        "NO_BILLING_ACCOUNT",
        "お支払い情報がまだありません。",
        null,
      );
    }

    const origin = new URL(request.url).origin;
    const stripe = getStripeClient();
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: `${origin}/billing/complete`,
      locale: "ja",
    });

    return Response.json({ url: session.url });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/billing/portal] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "お支払い管理を開けませんでした。", null);
  }
}
