// Shared plumbing for AI gateway routes: Supabase JWT verification, tenant
// resolution, entitlement check, usage-event recording, and the error
// envelope (docs/api-contract.md). Route handlers own their own request
// validation and quota policy.

import { getPlanConfig } from "@/lib/server/plans";
import {
  authContextCacheKey,
  jwtIdentityFromClaims,
  type JWTVerificationMode,
} from "@/lib/server/jwt-identity";
import {
  QuotaStateCache,
  type QuotaState,
} from "@/lib/server/quota-state-cache";
import { createHash } from "node:crypto";
import { after } from "next/server";
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
  /**
   * Which cold preflight work this call actually performed, in milliseconds.
   * AI routes verify the asymmetric JWT locally; sensitive routes ask Auth for
   * the current user. Absent on a cache hit.
   */
  timings?: AuthTimings;
};

export type AuthTimings = {
  verifyJWTMs: number;
  tenantEntitlementMs: number;
};

export type QuotaTimings = {
  planMs: number;
  countMs: number;
};

export type AuthenticateOptions = {
  /**
   * When false, skips the entitlement status check (active/trialing) so
   * read-only endpoints can show account state even for lapsed plans.
   * A missing entitlement row still fails with 402. Defaults to true.
   */
  requireActiveEntitlement?: boolean;
  /**
   * AI routes may verify an asymmetric signed JWT locally. Sensitive account,
   * billing, facts, and admin routes keep the default Auth-server lookup so a
   * deleted user is observed immediately rather than at token expiry.
   */
  verification?: JWTVerificationMode;
};

const PREFLIGHT_CACHE_TTL_MS = 5 * 60 * 1000;
const MAX_PREFLIGHT_CACHE_ENTRIES = 256;
const authCache = new Map<string, { value: AuthContext; expiresAt: number }>();
const quotaStateCache = new QuotaStateCache(
  PREFLIGHT_CACHE_TTL_MS,
  MAX_PREFLIGHT_CACHE_ENTRIES,
);

/**
 * Entitlement statuses that may use the product.
 *
 * `past_due` is included as a grace state. Stripe's Smart Retries run for weeks
 * after a card fails, and cutting a paying customer off at the first failed
 * retry punishes an expiring card harder than a real cancellation. When the
 * retries are finally exhausted Stripe cancels the subscription, and the
 * webhook drops the account to free/active rather than to a blocking status —
 * so losing access is the end of that process, not its beginning.
 */
export function isUsableEntitlementStatus(status: string): boolean {
  return status === "active" || status === "trialing" || status === "past_due";
}

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
  const verification = options?.verification ?? "auth-server";
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : null;
  if (!token) {
    throw new GatewayError(401, "UNAUTHENTICATED", "Missing Supabase access token.");
  }

  // The plan catalog is keyed by nothing — `loadPlans` selects every row — so it
  // has no reason to sit behind the three round trips below. Started here and
  // awaited later (or never, on a cache hit); its own in-process cache absorbs
  // the result. Failures surface where it is awaited, not here.
  void warmPlanCatalog();

  const tokenDigest = createHash("sha256").update(token).digest("base64url");
  const cacheKey = authContextCacheKey(tokenDigest, verification);
  const cached = authCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    if (
      requireActiveEntitlement
      && !isUsableEntitlementStatus(cached.value.entitlement.status)
    ) {
      throw new GatewayError(
        402,
        "PAYMENT_REQUIRED",
        "The current plan does not allow this operation.",
      );
    }
    return cached.value;
  }
  if (cached) authCache.delete(cacheKey);

  const admin = getSupabaseAdminClient();
  const verifyJWTStarted = performance.now();
  let identity: { userId: string; email: string | null } | null = null;
  if (verification === "local-jwt") {
    const { data, error } = await admin.auth.getClaims(token);
    if (!error) identity = jwtIdentityFromClaims(data?.claims);
  } else {
    const { data, error } = await admin.auth.getUser(token);
    if (!error && data?.user) {
      identity = { userId: data.user.id, email: data.user.email ?? null };
    }
  }
  const verifyJWTMs = performance.now() - verifyJWTStarted;
  if (!identity) {
    throw new GatewayError(401, "UNAUTHENTICATED", "Invalid Supabase access token.");
  }
  const { userId, email } = identity;

  const tenantEntitlementStarted = performance.now();
  let tenantContext = await fetchDefaultTenantContext(userId);
  if (!tenantContext?.tenantId) {
    const userClient = getSupabaseUserClient(token);
    await userClient.rpc("bs_initialize_current_user");
    tenantContext = await fetchDefaultTenantContext(userId);
  }
  if (!tenantContext?.tenantId) {
    throw new GatewayError(403, "TENANT_ACCESS_DENIED", "No tenant found for this user.");
  }
  const { tenantId, entitlement } = tenantContext;
  const tenantEntitlementMs = performance.now() - tenantEntitlementStarted;
  if (
    !entitlement ||
    (requireActiveEntitlement && !isUsableEntitlementStatus(entitlement.status))
  ) {
    throw new GatewayError(
      402,
      "PAYMENT_REQUIRED",
      "The current plan does not allow this operation.",
    );
  }

  const result = { userId, tenantId, email, entitlement };
  pruneCache(authCache);
  // The cached copy carries no timings: a later hit made no round trips, and
  // reporting the ones this call made would attribute them to a request that
  // did not pay them.
  authCache.set(cacheKey, {
    value: result,
    expiresAt: Date.now() + PREFLIGHT_CACHE_TTL_MS,
  });
  return { ...result, timings: { verifyJWTMs, tenantEntitlementMs } };
}

/** AI-only authentication boundary. Authorization still comes from database
 * tenant/entitlement rows; only signature verification moves off Auth. */
export function authenticateAIRequest(request: Request): Promise<AuthContext> {
  return authenticate(request, { verification: "local-jwt" });
}

/** Loads the plan catalog into its in-process cache, swallowing failures so a
 * speculative warm cannot fail a request that has not needed plans yet. */
async function warmPlanCatalog(): Promise<void> {
  try {
    await getPlanConfig("free");
  } catch {
    // The real await inside effectiveMonthlyLimit reports any real problem.
  }
}

type DefaultTenantContext = {
  tenantId: string;
  entitlement: Entitlement | null;
};

async function fetchDefaultTenantContext(
  userId: string,
): Promise<DefaultTenantContext | null> {
  const admin = getSupabaseAdminClient();
  const { data } = await admin
    .from("bs_profiles")
    .select(`
      default_tenant_id,
      tenant:bs_tenants!bs_profiles_default_tenant_id_fkey(
        entitlement:bs_entitlements!bs_entitlements_tenant_id_fkey(
          plan,
          status,
          monthly_review_limit
        )
      )
    `)
    .eq("id", userId)
    .maybeSingle();
  const row = data as unknown as {
    default_tenant_id: string | null;
    tenant: { entitlement: Entitlement | null } | null;
  } | null;
  if (!row?.default_tenant_id) return null;
  return {
    tenantId: row.default_tenant_id,
    entitlement: row.tenant?.entitlement ?? null,
  };
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
  const duplicate = error?.code === "23505" || error?.message.includes("duplicate");
  if (error && !duplicate) {
    console.error(
      `[gateway] usage event insert failed (${usage.operation}):`,
      error.message,
    );
  }
  if (!error && usage.status === "success") {
    // This instance just wrote the value its next quota check would otherwise
    // fetch again. Advance the known count without extending its TTL.
    quotaStateCache.increment(quotaCacheKey(tenantId));
  } else if (duplicate) {
    // A retry may have been recorded by another instance. Forget local
    // knowledge so the next request reconciles with Postgres.
    quotaStateCache.delete(quotaCacheKey(tenantId));
  }
}

/**
 * Persists operational usage after the response has been released. AI output
 * must not wait on a bookkeeping insert; Next keeps the request context alive
 * for this task on the deployed serverless runtime.
 */
export function recordUsageAfterResponse(
  tenantId: string,
  userId: string,
  usage: UsageInput,
): void {
  after(() => recordUsage(tenantId, userId, usage));
}

/**
 * GET handler shared by every AI route. It warms the exact route function and
 * fills its auth/quota caches without invoking a provider or recording usage.
 */
export async function warmAIRequest(request: Request): Promise<Response> {
  try {
    const { tenantId, entitlement } = await authenticateAIRequest(request);
    await enforceQuota(tenantId, entitlement);
    return new Response(null, {
      status: 204,
      headers: {
        "cache-control": "private, no-store",
        "x-ai-warm": "ready",
      },
    });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    return errorResponse(500, "INTERNAL_ERROR", "AI warm-up failed.", null);
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
  return plan.monthlyUsageLimit;
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
 * Counts successful usage events of every AI operation for the tenant in the
 * current UTC month.
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
): Promise<QuotaTimings | null> {
  const { state, timings } = await loadQuotaState(tenantId, entitlement);
  if (state.limit !== null && (state.used ?? 0) >= state.limit) {
    throw new GatewayError(429, "QUOTA_EXCEEDED", "Monthly usage limit reached.");
  }
  return timings;
}

async function loadQuotaState(
  tenantId: string,
  entitlement: Entitlement,
  requireUsageCount = false,
): Promise<{ state: QuotaState; timings: QuotaTimings | null }> {
  // Include the UTC billing month so a five-minute entry created just before
  // midnight cannot carry the previous month's count into the new month.
  const cacheKey = quotaCacheKey(tenantId);
  const cached = quotaStateCache.get(cacheKey);
  if (cached && (!requireUsageCount || cached.used !== null)) {
    return { state: cached, timings: null };
  }

  // The count depends only on the tenant, and the limit only on the plan, so
  // there is no reason for them to queue behind each other. Started together;
  // an unlimited plan discards a count it did not need, which costs one query
  // nobody waits for.
  const countStarted = performance.now();
  const counting = countMonthlyUsage(tenantId);
  const planStarted = performance.now();
  const limit = await effectiveMonthlyLimit(entitlement);
  const planMs = performance.now() - planStarted;
  if (limit === null && !requireUsageCount) {
    void counting.catch(() => {});
    const state = { used: null, limit };
    quotaStateCache.set(cacheKey, state);
    return { state, timings: { planMs, countMs: 0 } };
  }
  const used = await counting;
  const countMs = performance.now() - countStarted;
  const state = { used, limit };
  quotaStateCache.set(cacheKey, state);
  return { state, timings: { planMs, countMs } };
}

function quotaCacheKey(tenantId: string): string {
  return `${tenantId}:${currentMonthStartUTC().toISOString()}`;
}

function pruneCache<T>(cache: Map<string, T>): void {
  if (cache.size < MAX_PREFLIGHT_CACHE_ENTRIES) return;
  const oldestKey = cache.keys().next().value;
  if (oldestKey) cache.delete(oldestKey);
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
  const { state } = await loadQuotaState(tenantId, entitlement, true);
  return quotaInfo(entitlement, (state.used ?? 0) + usedOffset, state.limit);
}

export function currentMonthStartUTC(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

export function nextMonthStartUTC(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}
