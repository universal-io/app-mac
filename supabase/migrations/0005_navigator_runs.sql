begin;

-- Short-lived execution state for Navigator v4. The row deliberately stores
-- no screenshots, OCR, AX candidates, conversation, free-form model output,
-- or Task body. The signed Task snapshot stays client-transported; this row
-- pins only its identity/hash and the authoritative progress revision.
create table if not exists public.bs_navigator_runs (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.bs_tenants (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    pack_id text not null,
    pack_version text not null,
    plan_id uuid not null,
    plan_version integer not null check (plan_version >= 1),
    plan_hash text not null check (length(plan_hash) between 16 and 200),
    current_step integer not null default 0 check (current_step >= 0),
    status text not null default 'active'
        check (status in (
            'active', 'ambiguous', 'blocked', 'complete',
            'cancelled', 'expired'
        )),
    revision integer not null default 0 check (revision >= 0),
    expires_at timestamptz not null default (now() + interval '24 hours'),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.bs_navigator_runs is
    'Short-lived Gateway-owned Navigator v4 progress. No screen/conversation/Task body; expire after 24 hours of inactivity and purge terminal rows within 24 hours.';

create index if not exists bs_navigator_runs_tenant_user_updated_idx
    on public.bs_navigator_runs (tenant_id, user_id, updated_at desc);

create index if not exists bs_navigator_runs_expires_at_idx
    on public.bs_navigator_runs (expires_at);

drop trigger if exists bs_navigator_runs_touch_updated_at on public.bs_navigator_runs;
create trigger bs_navigator_runs_touch_updated_at
    before update on public.bs_navigator_runs
    for each row
    execute function public.bs_touch_updated_at();

-- Gateway service-role only. The client reaches this state through the
-- authenticated Navigate API and can never select/update another tenant row.
alter table public.bs_navigator_runs enable row level security;

commit;
