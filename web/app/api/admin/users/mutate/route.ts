// Admin console: POST /api/admin/users/mutate (docs/admin-dashboard-plan.md
// §9-c / §10 step 2). Changes one of the three account axes and records an
// audit row. Authorization: assertAdminCanMutate (full admin only; operators
// are read-only). A reason is required on every change.

import { assertAdminCanMutate } from "@/lib/server/admin";
import {
  setUserRole,
  setTenantPlan,
  setAccountClass,
  PLATFORM_ROLES,
  ACCOUNT_CLASSES,
  type PlatformRole,
  type AccountClass,
} from "@/lib/server/admin-users";
import {
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";

type MutateBody = {
  action?: string;
  /** For set_role: the target user id. For set_plan / set_account_class: the
   * target tenant id. */
  targetId?: string;
  value?: string;
  reason?: string;
  /** Optional ISO expiry for a non-standard account class grant. */
  expiresAt?: string | null;
};

export async function POST(request: Request): Promise<Response> {
  try {
    const actor = await assertAdminCanMutate(request);

    const body = (await request.json().catch(() => null)) as MutateBody | null;
    if (!body || typeof body.targetId !== "string" || !body.targetId) {
      throw new GatewayError(400, "INVALID_REQUEST", "Missing targetId.");
    }
    const reason = (body.reason ?? "").trim();
    if (!reason) {
      throw new GatewayError(400, "REASON_REQUIRED", "A reason is required.");
    }
    if (typeof body.value !== "string" || !body.value) {
      throw new GatewayError(400, "INVALID_REQUEST", "Missing value.");
    }

    switch (body.action) {
      case "set_role": {
        if (!(PLATFORM_ROLES as readonly string[]).includes(body.value)) {
          throw new GatewayError(400, "INVALID_REQUEST", "Invalid role.");
        }
        await setUserRole(actor, body.targetId, body.value as PlatformRole, reason);
        break;
      }
      case "set_plan": {
        await setTenantPlan(actor, body.targetId, body.value, reason);
        break;
      }
      case "set_account_class": {
        if (!(ACCOUNT_CLASSES as readonly string[]).includes(body.value)) {
          throw new GatewayError(400, "INVALID_REQUEST", "Invalid account class.");
        }
        await setAccountClass(
          actor,
          body.targetId,
          body.value as AccountClass,
          reason,
          body.expiresAt ?? null,
        );
        break;
      }
      default:
        throw new GatewayError(400, "INVALID_REQUEST", "Unknown action.");
    }

    return Response.json({ ok: true });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/admin/users/mutate] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}
