begin;

-- Account model v1 (docs/admin-dashboard-plan.md §9-b / §10 step 1).
-- Separates the three axes that were previously conflated or absent:
--   1. platform role      -> bs_profiles.role        (who may enter/operate /admin)
--   2. product plan        -> bs_entitlements.plan     (already exists; quota/features)
--   3. account class       -> bs_entitlements.account_class (who pays / exemptions)
-- Plus an admin audit log so every privileged mutation records who/what/why.

-- --- 1. Platform role -------------------------------------------------------
-- Platform-wide authority for the admin console. Distinct from
-- bs_tenant_members.role, which is a tenant-scoped membership role. Default
-- 'user' so every existing and future signup is a plain user until promoted.
alter table public.bs_profiles
    add column if not exists role text not null default 'user'
        check (role in ('user', 'operator', 'admin'));

-- Bootstrap the sole administrator. Until now /admin authorized via the
-- ADMIN_EMAILS env allowlist; this makes the DB the source of truth.
update public.bs_profiles
    set role = 'admin'
    where lower(email) = 'matsumotokaya@gmail.com';

-- --- 2. Account class -------------------------------------------------------
-- bs_entitlements is the per-tenant commercial SSOT, so account class (who
-- pays / how quota, trial and deletion rules apply) lives here alongside plan.
-- 'standard' = pays via the normal flow; 'internal'/'tester'/'complimentary'
-- are Stripe-less grants that must carry reason, expiry and grantor.
alter table public.bs_entitlements
    add column if not exists account_class text not null default 'standard'
        check (account_class in ('standard', 'internal', 'tester', 'complimentary')),
    add column if not exists account_class_reason text,
    add column if not exists account_class_expires_at timestamptz,
    add column if not exists account_class_granted_by uuid references public.bs_profiles (id),
    add column if not exists account_class_granted_at timestamptz;

-- Existing accounts follow the default 'standard' (no explicit backfill needed;
-- verified read-side after apply).

-- --- 3. Admin audit log -----------------------------------------------------
-- Every privileged change (role / plan / account class) writes one row here
-- with before/after and a required reason. Gateway-internal (service-role
-- only): RLS on, NO policies, so no end user can read or write it.
create table if not exists public.bs_admin_audit_log (
    id uuid primary key default gen_random_uuid(),
    actor_id uuid not null references public.bs_profiles (id),
    actor_email text,
    action text not null check (action in ('set_role', 'set_plan', 'set_account_class')),
    target_kind text not null check (target_kind in ('user', 'tenant')),
    target_id uuid not null,
    before jsonb,
    after jsonb,
    reason text,
    created_at timestamptz not null default now()
);

create index if not exists bs_admin_audit_log_created_at_idx
    on public.bs_admin_audit_log (created_at desc);

alter table public.bs_admin_audit_log enable row level security;

commit;
