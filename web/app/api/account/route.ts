// AI gateway: GET /api/account. Read-only endpoint returning the caller's
// account state and current-month quota so clients can render a "my page"
// without performing an AI operation. Uses the shared error envelope
// (docs/api-contract.md) and records no usage events.

import {
  authenticate,
  buildQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";
import { featuresForPlan } from "@/lib/server/entitlements";

export async function GET(request: Request): Promise<Response> {
  try {
    // Account state should be visible even when the entitlement has lapsed,
    // so only the existence of the entitlement row is required here.
    const { tenantId, email, entitlement } = await authenticate(request, {
      requireActiveEntitlement: false,
    });

    // Raw current-month count (no in-flight offset: nothing is consumed here).
    const quota = await buildQuota(tenantId, entitlement);

    return Response.json({
      account: {
        email,
        tenant_id: tenantId,
        plan: entitlement.plan,
        status: entitlement.status,
        monthly_review_limit: quota.limit,
        // Additive feature flags (foundation-redesign-plan §5-c). Display
        // gating only on the client; server-side enforcement lands later.
        features: featuresForPlan(entitlement.plan),
      },
      quota,
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/account] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}
