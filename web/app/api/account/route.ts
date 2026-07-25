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
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

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
        features: await featuresForPlan(entitlement.plan),
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

export async function DELETE(request: Request): Promise<Response> {
  try {
    const body = (await request.json().catch(() => null)) as { confirmation?: unknown } | null;
    if (body?.confirmation !== "DELETE") {
      return errorResponse(400, "BAD_REQUEST", "退会確認が完了していません。", null);
    }

    const { userId, tenantId } = await authenticate(request, {
      requireActiveEntitlement: false,
    });
    if (!hasRecentAuthentication(request)) {
      return errorResponse(
        401,
        "REAUTH_REQUIRED",
        "安全のため、ログアウトして再ログインしてから退会を実行してください。",
        null,
      );
    }
    const admin = getSupabaseAdminClient();

    const [tenantResult, entitlementResult, membersResult] = await Promise.all([
      admin.from("bs_tenants").select("kind").eq("id", tenantId).maybeSingle(),
      admin
        .from("bs_entitlements")
        .select("stripe_subscription_id")
        .eq("tenant_id", tenantId)
        .maybeSingle(),
      admin
        .from("bs_tenant_members")
        .select("user_id", { count: "exact", head: true })
        .eq("tenant_id", tenantId),
    ]);
    if (tenantResult.error || entitlementResult.error || membersResult.error) {
      console.error("[/api/account] deletion preflight failed:", {
        tenant: tenantResult.error?.message,
        entitlement: entitlementResult.error?.message,
        members: membersResult.error?.message,
      });
      return errorResponse(
        500,
        "ACCOUNT_DELETE_PREFLIGHT_FAILED",
        "退会前の契約・データ確認に失敗しました。時間をおいて再試行してください。",
        null,
      );
    }
    const tenant = tenantResult.data;
    const entitlement = entitlementResult.data;
    const memberCount = membersResult.count;

    if (entitlement?.stripe_subscription_id) {
      return errorResponse(
        409,
        "ACTIVE_SUBSCRIPTION",
        "有効な契約を先に解約してから退会してください。",
        null,
      );
    }

    // Auth user deletion cascades every user-owned row: profile, membership,
    // usage, and device records. The personal tenant is removed next
    // so its entitlement cannot remain as an orphan. Enterprise/shared
    // tenants are never deleted by one member's withdrawal.
    const { error: userDeleteError } = await admin.auth.admin.deleteUser(userId);
    if (userDeleteError) {
      console.error("[/api/account] auth user deletion failed:", userDeleteError.message);
      return errorResponse(500, "ACCOUNT_DELETE_FAILED", "アカウントを削除できませんでした。", null);
    }

    let cleanupWarning = false;
    if (tenant?.kind === "personal" && memberCount === 1) {
      const { error: tenantDeleteError } = await admin
        .from("bs_tenants")
        .delete()
        .eq("id", tenantId);
      if (tenantDeleteError) {
        // The identity and all user content are already gone. Return success
        // so the client wipes its local data; log the non-personal orphan for
        // operational cleanup instead of trapping the deleted user in-app.
        cleanupWarning = true;
        console.error("[/api/account] personal tenant cleanup failed:", tenantDeleteError.message);
      }
    }

    return Response.json({ deleted: true, cleanup_warning: cleanupWarning });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/account] DELETE internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "アカウントを削除できませんでした。", null);
  }
}

function hasRecentAuthentication(request: Request): boolean {
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
  const payload = token.split(".")[1];
  if (!payload) return false;
  try {
    const decoded = JSON.parse(
      Buffer.from(payload, "base64url").toString("utf8"),
    ) as { iat?: unknown };
    if (typeof decoded.iat !== "number") return false;
    const ageSeconds = Math.floor(Date.now() / 1000) - decoded.iat;
    return ageSeconds >= -60 && ageSeconds <= 10 * 60;
  } catch {
    return false;
  }
}
