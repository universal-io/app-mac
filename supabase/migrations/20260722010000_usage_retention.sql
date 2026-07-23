begin;

-- Keep billing/operations trends without retaining request-level user records
-- indefinitely. Dimensions are normalized to non-null strings so one month
-- and model combination has exactly one aggregate row.
create table if not exists public.bs_usage_monthly_rollups (
    month_start date not null,
    tenant_id uuid not null references public.bs_tenants (id) on delete cascade,
    operation text not null,
    model_vendor text not null default '',
    model_id text not null default '',
    unit_type text not null,
    status text not null,
    error_code text not null default '',
    event_count bigint not null default 0 check (event_count >= 0),
    input_units bigint not null default 0 check (input_units >= 0),
    output_units bigint not null default 0 check (output_units >= 0),
    latency_ms_sum bigint not null default 0 check (latency_ms_sum >= 0),
    updated_at timestamptz not null default now(),
    primary key (
        month_start,
        tenant_id,
        operation,
        model_vendor,
        model_id,
        unit_type,
        status,
        error_code
    )
);

alter table public.bs_usage_monthly_rollups enable row level security;

drop policy if exists "bs_usage_monthly_rollups_select_member"
    on public.bs_usage_monthly_rollups;
create policy "bs_usage_monthly_rollups_select_member"
    on public.bs_usage_monthly_rollups
    for select
    to authenticated
    using (public.bs_is_tenant_member(tenant_id));

create or replace function public.bs_archive_expired_usage_events()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    cutoff timestamptz := now() - interval '90 days';
    deleted_count bigint := 0;
begin
    -- Prevent overlapping manual/cron executions from adding the same rows
    -- to the rollup twice before either transaction deletes them.
    if not pg_try_advisory_xact_lock(hashtext('bs_archive_expired_usage_events')) then
        return 0;
    end if;

    insert into public.bs_usage_monthly_rollups (
        month_start,
        tenant_id,
        operation,
        model_vendor,
        model_id,
        unit_type,
        status,
        error_code,
        event_count,
        input_units,
        output_units,
        latency_ms_sum,
        updated_at
    )
    select
        date_trunc('month', created_at at time zone 'UTC')::date,
        tenant_id,
        operation,
        coalesce(model_vendor, ''),
        coalesce(model_id, ''),
        unit_type,
        status,
        coalesce(error_code, ''),
        count(*),
        sum(input_units),
        sum(output_units),
        sum(coalesce(latency_ms, 0)),
        now()
    from public.bs_usage_events
    where created_at < cutoff
    group by 1, 2, 3, 4, 5, 6, 7, 8
    on conflict (
        month_start,
        tenant_id,
        operation,
        model_vendor,
        model_id,
        unit_type,
        status,
        error_code
    ) do update set
        event_count = public.bs_usage_monthly_rollups.event_count + excluded.event_count,
        input_units = public.bs_usage_monthly_rollups.input_units + excluded.input_units,
        output_units = public.bs_usage_monthly_rollups.output_units + excluded.output_units,
        latency_ms_sum = public.bs_usage_monthly_rollups.latency_ms_sum + excluded.latency_ms_sum,
        updated_at = now();

    delete from public.bs_usage_events where created_at < cutoff;
    get diagnostics deleted_count = row_count;
    return deleted_count;
end;
$$;

revoke all on function public.bs_archive_expired_usage_events() from public;
revoke all on function public.bs_archive_expired_usage_events() from anon;
revoke all on function public.bs_archive_expired_usage_events() from authenticated;
grant execute on function public.bs_archive_expired_usage_events() to service_role;

-- Supabase runs pg_cron jobs as the database role that creates the job. The
-- stable job name makes this migration idempotent across repair/replay.
-- Supabase's supported SQL installation places the extension objects in
-- pg_catalog; the extension itself creates the cron schema and job tables.
do $$
begin
    -- On Supabase, replaying CREATE EXTENSION IF NOT EXISTS can still invoke
    -- the provider's after-create privilege script. Avoid touching an already
    -- installed extension so repair migrations remain safe.
    if not exists (
        select 1 from pg_extension where extname = 'pg_cron'
    ) then
        execute 'create extension pg_cron with schema pg_catalog';
    end if;
end;
$$;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

do $$
declare
    existing_job_id bigint;
begin
    select jobid into existing_job_id
    from cron.job
    where jobname = 'bs-usage-retention-daily';

    if existing_job_id is not null then
        perform cron.unschedule(existing_job_id);
    end if;

    perform cron.schedule(
        'bs-usage-retention-daily',
        '17 3 * * *',
        'select public.bs_archive_expired_usage_events();'
    );
end;
$$;

commit;
