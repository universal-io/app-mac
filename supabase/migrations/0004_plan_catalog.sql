begin;

-- Plan catalog: the single source of truth for "what each plan grants"
-- (docs/foundation-redesign-plan.md §5-c). Before this, plan-level limits had
-- no home: bs_provision_user() hardcoded a monthly_review_limit literal, the
-- column carried its own default, and the gateway env carried a third — three
-- copies that drifted (new signups got 50 while the admin console showed 500).
--
-- After this migration:
--   * bs_plans decides quota + features per plan. Edit HERE (or a future admin
--     "プラン設定" screen) to change what a plan grants.
--   * bs_entitlements.monthly_review_limit is demoted to an OPTIONAL per-tenant
--     override (NULL = follow the plan). Provisioning no longer sets it.
--   * The gateway resolves: override ?? bs_plans[plan].monthly_usage_limit
--     (NULL = unlimited). No env, no provisioning literal.
create table if not exists public.bs_plans (
    plan text primary key
        check (plan in ('free', 'standard', 'pro', 'team', 'enterprise')),
    -- Monthly cap across ALL AI operations (1 request = 1 unit). NULL = unlimited.
    monthly_usage_limit integer
        check (monthly_usage_limit is null or monthly_usage_limit >= 0),
    -- Allowed product feature ids.
    -- ["*"] means every feature — the current beta policy (no feature gating).
    features jsonb not null default '["*"]'::jsonb,
    updated_at timestamptz not null default now()
);

comment on table public.bs_plans is
    'Single source of truth for plan -> quota/features (foundation-redesign-plan §5-c). Read by the gateway with the service-role key. Change what a plan grants HERE, never in provisioning code or per-account rows.';

-- Beta policy (owner decision 2026-07-08): only the free plan carries a real
-- quota; every other plan is unlimited for now; all plans allow all features.
insert into public.bs_plans (plan, monthly_usage_limit, features) values
    ('free',       500,  '["*"]'::jsonb),
    ('standard',   null, '["*"]'::jsonb),
    ('pro',        null, '["*"]'::jsonb),
    ('team',       null, '["*"]'::jsonb),
    ('enterprise', null, '["*"]'::jsonb)
on conflict (plan) do nothing;

drop trigger if exists bs_plans_touch_updated_at on public.bs_plans;
create trigger bs_plans_touch_updated_at
    before update on public.bs_plans
    for each row
    execute function public.bs_touch_updated_at();

-- RLS on, NO policies: plan config is gateway-internal (service-role only).
-- End users read their effective plan via
-- GET /api/account, never this table directly.
alter table public.bs_plans enable row level security;

-- Point bs_entitlements.plan at the catalog so the set of valid plans also
-- lives in one place. Replaces the inline CHECK (which also lacked 'standard').
alter table public.bs_entitlements
    drop constraint if exists bs_entitlements_plan_check;
alter table public.bs_entitlements
    add constraint bs_entitlements_plan_fkey
    foreign key (plan) references public.bs_plans (plan);

-- Demote the per-account limit to an OPTIONAL override. NULL (the new default)
-- means "follow the plan catalog"; a non-null value is a deliberate per-tenant
-- exception (e.g. a B2B special allowance).
alter table public.bs_entitlements
    alter column monthly_review_limit drop not null,
    alter column monthly_review_limit drop default;

-- Clear values that were merely copies of the old provisioning default so
-- these accounts follow the catalog instead of a frozen number. 50 = the old
-- function literal; 500 = the value two rows were hand-set to (both were the
-- intended free quota, not deliberate per-tenant overrides).
update public.bs_entitlements
    set monthly_review_limit = null
    where monthly_review_limit in (50, 500);

-- Provisioning must not decide plan limits: assign the plan, leave the override
-- NULL. Body is identical to 0001 minus the monthly_review_limit column.
create or replace function public.bs_provision_user(user_id uuid, user_email text, user_meta jsonb)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    tenant_uuid uuid := gen_random_uuid();
    tenant_slug text := 'bs-personal-' || replace(user_id::text, '-', '');
    display_name text := public.bs_derived_display_name(user_email, user_meta);
    period_start timestamptz := date_trunc('month', now());
    period_end timestamptz := date_trunc('month', now()) + interval '1 month';
begin
    if exists (select 1 from public.bs_profiles profile where profile.id = user_id) then
        return;
    end if;

    insert into public.bs_tenants (id, slug, name, kind, status)
    values (tenant_uuid, tenant_slug, display_name, 'personal', 'active');

    insert into public.bs_profiles (id, display_name, email, default_tenant_id)
    values (user_id, display_name, user_email, tenant_uuid);

    insert into public.bs_tenant_members (tenant_id, user_id, role)
    values (tenant_uuid, user_id, 'owner');

    insert into public.bs_entitlements (
        tenant_id,
        plan,
        status,
        monthly_audio_seconds_limit,
        allowed_models,
        features,
        current_period_start,
        current_period_end
    )
    values (
        tenant_uuid,
        'free',
        'active',
        0,
        '[]'::jsonb,
        jsonb_build_object('ai_review', true),
        period_start,
        period_end
    );
end;
$$;

commit;
