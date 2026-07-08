// Shared plumbing for AI gateway routes: Supabase JWT verification, tenant
// resolution, entitlement check, usage-event recording, and the error
// envelope (docs/api-contract.md). Route handlers own their own request
// validation and quota policy.

import { getPlanConfig } from "@/lib/server/plans";
import {
  getSupabaseAdminClient,
  getSupabaseUserClient,
} from "@/lib/server/supabase-admin";

export type Entitlement = {
  plan: string;
  status: string;
  monthly_review_limit: number | null;
};

export type AuthContext = {
  userId: string;
  tenantId: string;
  email: string | null;
  entitlement: Entitlement;
};

export type AuthenticateOptions = {
  /**
   * When false, skips the entitlement status check (active/trialing) so
   * read-only endpoints can show account state even for lapsed plans.
   * A missing entitlement row still fails with 402. Defaults to true.
   */
  requireActiveEntitlement?: boolean;
};

/** Thrown by shared helpers; route handlers convert it via `errorResponse`. */
export class GatewayError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: Record<string, unknown>;

  constructor(
    status: number,
    code: string,
    message: string,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "GatewayError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/**
 * Verifies the Bearer token, resolves the default tenant (bootstrapping the
 * user lazily on first request), and checks the entitlement is usable.
 * Throws `GatewayError` on any failure.
 */
export async function authenticate(
  request: Request,
  options?: AuthenticateOptions,
): Promise<AuthContext> {
  const requireActiveEntitlement = options?.requireActiveEntitlement ?? true;
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : null;
  if (!token) {
    throw new GatewayError(401, "UNAUTHENTICATED", "Missing Supabase access token.");
  }

  const admin = getSupabaseAdminClient();
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData?.user) {
    throw new GatewayError(401, "UNAUTHENTICATED", "Invalid Supabase access token.");
  }
  const userId = userData.user.id;
  const email = userData.user.email ?? null;

  let tenantId = await fetchDefaultTenantId(userId);
  if (!tenantId) {
    const userClient = getSupabaseUserClient(token);
    await userClient.rpc("bs_initialize_current_user");
    tenantId = await fetchDefaultTenantId(userId);
  }
  if (!tenantId) {
    throw new GatewayError(403, "TENANT_ACCESS_DENIED", "No tenant found for this user.");
  }

  const { data: entitlement } = await admin
    .from("bs_entitlements")
    .select("plan, status, monthly_review_limit")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (
    !entitlement ||
    (requireActiveEntitlement &&
      entitlement.status !== "active" &&
      entitlement.status !== "trialing")
  ) {
    throw new GatewayError(
      402,
      "PAYMENT_REQUIRED",
      "The current plan does not allow this operation.",
    );
  }

  return { userId, tenantId, email, entitlement };
}

async function fetchDefaultTenantId(userId: string): Promise<string | null> {
  const admin = getSupabaseAdminClient();
  const { data } = await admin
    .from("bs_profiles")
    .select("default_tenant_id")
    .eq("id", userId)
    .maybeSingle();
  return data?.default_tenant_id ?? null;
}

export type UsageInput = {
  operation: string;
  unitType: string;
  requestId: string;
  status: "success" | "error" | "blocked";
  modelVendor?: string;
  modelId?: string;
  inputUnits?: number;
  outputUnits?: number;
  errorCode?: string;
  latencyMs?: number;
  metadata: Record<string, unknown>;
};

export async function recordUsage(
  tenantId: string,
  userId: string,
  usage: UsageInput,
): Promise<void> {
  const admin = getSupabaseAdminClient();
  // Idempotency: (tenant_id, request_id) is unique. A duplicate insert means a
  // client retry of an already-counted request; ignore the conflict. Only
  // success rows carry the request_id so a failed attempt can be retried.
  const { error } = await admin.from("bs_usage_events").insert({
    tenant_id: tenantId,
    user_id: userId,
    operation: usage.operation,
    model_vendor: usage.modelVendor ?? null,
    model_id: usage.modelId ?? null,
    input_units: usage.inputUnits ?? 0,
    output_units: usage.outputUnits ?? 0,
    unit_type: usage.unitType,
    request_id: usage.status === "success" ? usage.requestId : null,
    status: usage.status,
    error_code: usage.errorCode ?? null,
    latency_ms: usage.latencyMs ?? null,
    metadata: usage.metadata,
  });
  if (error && !error.message.includes("duplicate")) {
    console.error(
      `[gateway] usage event insert failed (${usage.operation}):`,
      error.message,
    );
  }
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
  requestId: string | null,
  details?: Record<string, unknown>,
): Response {
  return Response.json(
    {
      error: { code, message, ...(details ? { details } : {}) },
      request_id: requestId,
    },
    { status },
  );
}

export function gatewayErrorResponse(
  error: GatewayError,
  requestId: string | null,
): Response {
  return errorResponse(error.status, error.code, error.message, requestId, error.details);
}

export type QuotaInfo = {
  plan: string;
  used: number;
  /** null = unlimited (plan carries no cap). */
  limit: number | null;
  /** null = unlimited. */
  remaining: number | null;
  resets_at: string;
};

/**
 * Effective monthly usage limit (caps ALL AI operations, one request = one
 * unit). Resolution order: per-tenant override (bs_entitlements.
 * monthly_review_limit, normally null) then the plan catalog
 * (bs_plans.monthly_usage_limit). null = unlimited — including when the plan
 * is unknown, so a config gap fails open rather than blocking the user
 * (availability principle, master-plan §3.3).
 */
export async function effectiveMonthlyLimit(
  entitlement: Entitlement,
): Promise<number | null> {
  if (entitlement.monthly_review_limit != null) {
    return entitlement.monthly_review_limit;
  }
  const plan = await getPlanConfig(entitlement.plan);
  return plan ? plan.monthlyUsageLimit : null;
}

/** Builds the quota envelope for a given usage count and resolved limit
 * (no I/O). `limit === null` means unlimited. */
export function quotaInfo(
  entitlement: Entitlement,
  used: number,
  limit: number | null,
): QuotaInfo {
  return {
    plan: entitlement.plan,
    used,
    limit,
    remaining: limit === null ? null : Math.max(0, limit - used),
    resets_at: nextMonthStartUTC().toISOString(),
  };
}

/**
 * Counts successful usage events of EVERY operation (review, navigate,
 * vision, transcribe, distill…) for the tenant in the current UTC month.
 * One request = one unit: screenshots and dictation consume resources the
 * same way reviews do, and a single number keeps the mental model simple.
 */
export async function countMonthlyUsage(tenantId: string): Promise<number> {
  const admin = getSupabaseAdminClient();
  const { count } = await admin
    .from("bs_usage_events")
    .select("id", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .eq("status", "success")
    .gte("created_at", currentMonthStartUTC().toISOString());
  return count ?? 0;
}

/**
 * Rejects with QUOTA_EXCEEDED when the tenant's monthly budget is spent.
 * Shared by every metered AI route except review, which needs the count
 * for its response envelope and checks inline.
 */
export async function enforceQuota(
  tenantId: string,
  entitlement: Entitlement,
): Promise<void> {
  const limit = await effectiveMonthlyLimit(entitlement);
  if (limit === null) return; // unlimited plan
  const used = await countMonthlyUsage(tenantId);
  if (used >= limit) {
    throw new GatewayError(429, "QUOTA_EXCEEDED", "Monthly usage limit reached.");
  }
}

/**
 * Counts current-month usage and returns the quota envelope. `usedOffset`
 * lets callers report in-flight usage (e.g. `+1` after a successful review)
 * without a second count query.
 */
export async function buildQuota(
  tenantId: string,
  entitlement: Entitlement,
  usedOffset = 0,
): Promise<QuotaInfo> {
  const limit = await effectiveMonthlyLimit(entitlement);
  const used = (await countMonthlyUsage(tenantId)) + usedOffset;
  return quotaInfo(entitlement, used, limit);
}

export function currentMonthStartUTC(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

export function nextMonthStartUTC(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}
