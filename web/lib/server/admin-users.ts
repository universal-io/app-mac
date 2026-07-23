// Account administration for the admin console (docs/admin-dashboard-plan.md
// §9-b / §9-c / §10 step 2). Read the user roster and change the three axes —
// platform role, product plan, account class — each writing an audit row.
// Service-role only: call exclusively after assertAdmin / assertAdminCanMutate.

import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";
import { currentMonthStartUTC, GatewayError } from "@/lib/server/gateway";
import type { AdminContext } from "@/lib/server/admin";

export const PLATFORM_ROLES = ["user", "operator", "admin"] as const;
export type PlatformRole = (typeof PLATFORM_ROLES)[number];

export const ACCOUNT_CLASSES = [
  "standard",
  "internal",
  "tester",
  "complimentary",
] as const;
export type AccountClass = (typeof ACCOUNT_CLASSES)[number];

export type AdminUserRow = {
  userId: string;
  email: string | null;
  displayName: string | null;
  role: PlatformRole;
  tenantId: string | null;
  plan: string | null;
  status: string | null;
  accountClass: AccountClass | null;
  /** Per-tenant quota override (NULL = follow the plan catalog). */
  monthlyLimitOverride: number | null;
  /** Stripe-linked plans must not be changed from the admin UI (§9-c). */
  stripeLinked: boolean;
  monthUsage: number;
  createdAt: string;
};

type ProfileRow = {
  id: string;
  email: string | null;
  display_name: string | null;
  role: string | null;
  default_tenant_id: string | null;
  created_at: string;
};

type EntitlementRow = {
  tenant_id: string;
  plan: string | null;
  status: string | null;
  account_class: string | null;
  monthly_review_limit: number | null;
  stripe_subscription_id: string | null;
};

/** The full user roster with each user's default-tenant entitlement and
 * current-month usage count. The cohort is tiny, so aggregation is in JS. */
export async function listUsers(): Promise<AdminUserRow[]> {
  const admin = getSupabaseAdminClient();

  const { data: profiles, error: profileError } = await admin
    .from("bs_profiles")
    .select("id, email, display_name, role, default_tenant_id, created_at")
    .order("created_at", { ascending: true });
  if (profileError) {
    throw new GatewayError(500, "INTERNAL_ERROR", "Failed to load profiles.");
  }
  const profileRows = (profiles ?? []) as ProfileRow[];

  const tenantIds = profileRows
    .map((p) => p.default_tenant_id)
    .filter((id): id is string => Boolean(id));

  const entitlementByTenant = new Map<string, EntitlementRow>();
  const usageByTenant = new Map<string, number>();
  if (tenantIds.length > 0) {
    const { data: entitlements } = await admin
      .from("bs_entitlements")
      .select(
        "tenant_id, plan, status, account_class, monthly_review_limit, stripe_subscription_id",
      )
      .in("tenant_id", tenantIds);
    for (const row of (entitlements ?? []) as EntitlementRow[]) {
      entitlementByTenant.set(row.tenant_id, row);
    }

    const monthStart = currentMonthStartUTC().toISOString();
    const { data: usage } = await admin
      .from("bs_usage_events")
      .select("tenant_id")
      .in("tenant_id", tenantIds)
      .gte("created_at", monthStart);
    for (const row of (usage ?? []) as { tenant_id: string }[]) {
      usageByTenant.set(row.tenant_id, (usageByTenant.get(row.tenant_id) ?? 0) + 1);
    }
  }

  return profileRows.map((p) => {
    const ent = p.default_tenant_id
      ? entitlementByTenant.get(p.default_tenant_id)
      : undefined;
    return {
      userId: p.id,
      email: p.email,
      displayName: p.display_name,
      role: normalizeRole(p.role),
      tenantId: p.default_tenant_id,
      plan: ent?.plan ?? null,
      status: ent?.status ?? null,
      accountClass: normalizeAccountClass(ent?.account_class),
      monthlyLimitOverride: ent?.monthly_review_limit ?? null,
      stripeLinked: Boolean(ent?.stripe_subscription_id),
      monthUsage: p.default_tenant_id
        ? (usageByTenant.get(p.default_tenant_id) ?? 0)
        : 0,
      createdAt: p.created_at,
    };
  });
}

// --- Mutations (each records one audit row) --------------------------------

export async function setUserRole(
  actor: AdminContext,
  targetUserId: string,
  nextRole: PlatformRole,
  reason: string,
): Promise<void> {
  const admin = getSupabaseAdminClient();
  const { data: current } = await admin
    .from("bs_profiles")
    .select("role")
    .eq("id", targetUserId)
    .maybeSingle();
  if (!current) {
    throw new GatewayError(404, "NOT_FOUND", "User not found.");
  }
  const before = normalizeRole(current.role);
  if (before === nextRole) {
    return;
  }

  // Never leave the platform without an admin: block demoting the last one.
  if (before === "admin" && nextRole !== "admin") {
    const { count } = await admin
      .from("bs_profiles")
      .select("id", { count: "exact", head: true })
      .eq("role", "admin");
    if ((count ?? 0) <= 1) {
      throw new GatewayError(
        409,
        "LAST_ADMIN",
        "Cannot remove the last remaining administrator.",
      );
    }
  }

  const { error } = await admin
    .from("bs_profiles")
    .update({ role: nextRole })
    .eq("id", targetUserId);
  if (error) {
    throw new GatewayError(500, "INTERNAL_ERROR", "Failed to update role.");
  }

  await writeAudit(actor, {
    action: "set_role",
    targetKind: "user",
    targetId: targetUserId,
    before: { role: before },
    after: { role: nextRole },
    reason,
  });
}

export async function setTenantPlan(
  actor: AdminContext,
  tenantId: string,
  nextPlan: string,
  reason: string,
): Promise<void> {
  const admin = getSupabaseAdminClient();

  const { data: plans } = await admin.from("bs_plans").select("plan");
  const validPlans = new Set((plans ?? []).map((p) => p.plan as string));
  if (!validPlans.has(nextPlan)) {
    throw new GatewayError(400, "INVALID_PLAN", `Unknown plan: ${nextPlan}`);
  }

  const { data: current } = await admin
    .from("bs_entitlements")
    .select("plan, stripe_subscription_id")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (!current) {
    throw new GatewayError(404, "NOT_FOUND", "Entitlement not found.");
  }
  // A Stripe-linked plan is owned by webhook reconciliation, not the admin UI.
  if (current.stripe_subscription_id) {
    throw new GatewayError(
      409,
      "STRIPE_LINKED",
      "This plan is managed by Stripe and cannot be changed here.",
    );
  }
  const before = current.plan as string;
  if (before === nextPlan) {
    return;
  }

  const { error } = await admin
    .from("bs_entitlements")
    .update({ plan: nextPlan })
    .eq("tenant_id", tenantId);
  if (error) {
    throw new GatewayError(500, "INTERNAL_ERROR", "Failed to update plan.");
  }

  await writeAudit(actor, {
    action: "set_plan",
    targetKind: "tenant",
    targetId: tenantId,
    before: { plan: before },
    after: { plan: nextPlan },
    reason,
  });
}

export async function setAccountClass(
  actor: AdminContext,
  tenantId: string,
  nextClass: AccountClass,
  reason: string,
  expiresAt: string | null,
): Promise<void> {
  const admin = getSupabaseAdminClient();
  const { data: current } = await admin
    .from("bs_entitlements")
    .select("account_class")
    .eq("tenant_id", tenantId)
    .maybeSingle();
  if (!current) {
    throw new GatewayError(404, "NOT_FOUND", "Entitlement not found.");
  }
  const before = normalizeAccountClass(current.account_class);
  if (before === nextClass) {
    return;
  }

  // A non-standard class is a deliberate Stripe-less grant: record who/why/when.
  const grantFields =
    nextClass === "standard"
      ? {
          account_class_reason: null,
          account_class_expires_at: null,
          account_class_granted_by: null,
          account_class_granted_at: null,
        }
      : {
          account_class_reason: reason,
          account_class_expires_at: expiresAt,
          account_class_granted_by: actor.userId,
          account_class_granted_at: new Date().toISOString(),
        };

  const { error } = await admin
    .from("bs_entitlements")
    .update({ account_class: nextClass, ...grantFields })
    .eq("tenant_id", tenantId);
  if (error) {
    throw new GatewayError(500, "INTERNAL_ERROR", "Failed to update account class.");
  }

  await writeAudit(actor, {
    action: "set_account_class",
    targetKind: "tenant",
    targetId: tenantId,
    before: { account_class: before },
    after: { account_class: nextClass, expires_at: expiresAt },
    reason,
  });
}

type AuditInput = {
  action: "set_role" | "set_plan" | "set_account_class";
  targetKind: "user" | "tenant";
  targetId: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  reason: string;
};

async function writeAudit(actor: AdminContext, input: AuditInput): Promise<void> {
  const admin = getSupabaseAdminClient();
  const { error } = await admin.from("bs_admin_audit_log").insert({
    actor_id: actor.userId,
    actor_email: actor.email,
    action: input.action,
    target_kind: input.targetKind,
    target_id: input.targetId,
    before: input.before,
    after: input.after,
    reason: input.reason,
  });
  if (error) {
    // The mutation already succeeded; a lost audit row must be loud, not silent.
    console.error("[admin-users] audit write failed:", error.message);
    throw new GatewayError(500, "AUDIT_FAILED", "Change applied but audit failed.");
  }
}

function normalizeRole(value: string | null | undefined): PlatformRole {
  return value === "admin" || value === "operator" ? value : "user";
}

function normalizeAccountClass(value: string | null | undefined): AccountClass {
  return (ACCOUNT_CLASSES as readonly string[]).includes(value ?? "")
    ? (value as AccountClass)
    : "standard";
}
