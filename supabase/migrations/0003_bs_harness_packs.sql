begin;

-- Tool harness packs (docs/foundation-redesign-plan.md §5-b). A pack is the
-- data form of what web/lib/server/harness.ts hardcodes today: matching
-- rules, UI-map prose, task recipes, and an extra system-prompt block for a
-- known tool (GA4, freee, Salesforce, ...). Adding tool support becomes a
-- row insert — no app release, no gateway deploy. The in-code harnesses stay
-- as seed data and as the fallback when this table is empty or unreachable.
create table if not exists public.bs_harness_packs (
    id uuid primary key default gen_random_uuid(),
    -- Stable tool identifier ('ga4' | 'freee' | 'salesforce' | ...). Reported
    -- back to clients / usage metadata as the harness id.
    tool_id text not null,
    -- 'global' packs apply to every tenant; 'tenant' packs are per-company
    -- add-on packages (B2B upsell) and require tenant_id.
    scope text not null check (scope in ('global', 'tenant')),
    tenant_id uuid references public.bs_tenants (id) on delete cascade,
    -- Matching rule against the client hints (app name, window title, URL).
    -- Shape consumed by the gateway: {"contains": ["analytics.google.com", ...]}
    -- — case-insensitive substring match, any term matches.
    match_hints jsonb not null,
    -- Prose knowledge of the tool's screen structure (the "UI マップ" block).
    ui_map text,
    -- Task recipes: verified step plans the planner adopts verbatim. Shape:
    -- [{"goal": "...", "steps": [{"verbal": "...", "target": "...", "fill": "..."}]}]
    -- (target/fill optional per step). Doubles as the golden set for evals.
    recipes jsonb,
    -- Additional system-prompt block prepended for this tool.
    prompt text,
    -- Minimum plan required to receive this pack. Not enforced yet
    -- (entitlements feature gating lands separately; §5-c).
    min_plan text not null default 'standard',
    enabled boolean not null default true,
    updated_at timestamptz not null default now(),
    -- Tenant-scoped packs must name their tenant; global packs must not
    -- accidentally carry one.
    check (scope <> 'tenant' or tenant_id is not null)
);

comment on table public.bs_harness_packs is
    'Data-driven tool harness packs for the screen navigator (foundation-redesign-plan §5-b). Read by the gateway with the service-role key only.';

-- One global pack per tool; one pack per (tool, tenant) for tenant scope.
create unique index if not exists bs_harness_packs_global_tool_key
    on public.bs_harness_packs (tool_id)
    where scope = 'global';

create unique index if not exists bs_harness_packs_tenant_tool_key
    on public.bs_harness_packs (tool_id, tenant_id)
    where scope = 'tenant';

-- The gateway loads enabled global packs on a short in-memory cache.
create index if not exists bs_harness_packs_scope_enabled_idx
    on public.bs_harness_packs (scope, enabled);

-- Keep updated_at fresh on edits (same trigger function as the core schema).
drop trigger if exists bs_harness_packs_touch_updated_at on public.bs_harness_packs;
create trigger bs_harness_packs_touch_updated_at
    before update on public.bs_harness_packs
    for each row
    execute function public.bs_touch_updated_at();

-- RLS on, NO policies: packs are gateway-internal data. Only the service-role
-- client (which bypasses RLS) may read or write them; end users never see
-- pack contents directly (zero-integration principle — harnesses stay an
-- invisible accuracy add-on).
alter table public.bs_harness_packs enable row level security;

commit;
