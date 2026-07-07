// Admin console data (docs/admin-dashboard-plan.md §5). GET returns the
// effective model configuration plus current-month usage aggregates in one
// response. Authorization: assertAdmin (Supabase JWT + ADMIN_EMAILS).
//
// The admin page is a client component (the web session lives in the browser,
// not a cookie the server can read), so it fetches this endpoint with the
// user's Bearer token — the same shape every other gateway route uses.

import { assertAdmin, effectiveConfig } from "@/lib/server/admin";
import { overviewStats } from "@/lib/server/admin-stats";
import {
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";

export async function GET(request: Request): Promise<Response> {
  try {
    await assertAdmin(request);
    const [config, stats] = await Promise.all([
      Promise.resolve(effectiveConfig()),
      overviewStats(),
    ]);
    return Response.json({ config, stats });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/admin/overview] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}
