// Admin console: GET /api/admin/users (docs/admin-dashboard-plan.md §10 step 2).
// Returns the user roster plus the caller's role so the client can show or hide
// mutation controls (operators view; admins change). Authorization: assertAdmin.

import { assertAdmin } from "@/lib/server/admin";
import { listUsers } from "@/lib/server/admin-users";
import {
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";

export async function GET(request: Request): Promise<Response> {
  try {
    const { role } = await assertAdmin(request);
    const users = await listUsers();
    return Response.json({ viewerRole: role, users });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/admin/users] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}
