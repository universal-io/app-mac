begin;

-- Memory cards (persona / relationship profiles) synced from each client's
-- local SQLite store so a signed-in user's cards are shared across their
-- Macs. Row ids are client-generated UUIDs so retried inserts stay
-- idempotent and cross-device upserts can target the same primary key.
create table if not exists public.bs_memory_cards (
    id uuid primary key,
    tenant_id uuid not null references public.bs_tenants (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    kind text not null check (kind in ('persona', 'relationship')),
    subject text,
    content_md text not null,
    source text not null check (source in ('bootstrap', 'distilled', 'user_edited')),
    created_at timestamptz not null,
    updated_at timestamptz not null,
    deleted_at timestamptz
);

-- NOTE: updated_at is assigned by the Gateway and used as the server version
-- for cursor pulls and compare-and-swap conflict detection. It must not be
-- overwritten by a generic trigger, so no bs_touch_updated_at trigger is
-- attached to this table.

create index if not exists bs_memory_cards_user_updated_at_idx
    on public.bs_memory_cards (user_id, updated_at desc);

alter table public.bs_memory_cards enable row level security;

drop policy if exists "bs_memory_cards_select_self" on public.bs_memory_cards;
create policy "bs_memory_cards_select_self"
    on public.bs_memory_cards
    for select
    to authenticated
    using (auth.uid() = user_id);

drop policy if exists "bs_memory_cards_insert_self" on public.bs_memory_cards;
create policy "bs_memory_cards_insert_self"
    on public.bs_memory_cards
    for insert
    to authenticated
    with check (auth.uid() = user_id);

drop policy if exists "bs_memory_cards_update_self" on public.bs_memory_cards;
create policy "bs_memory_cards_update_self"
    on public.bs_memory_cards
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "bs_memory_cards_delete_self" on public.bs_memory_cards;
create policy "bs_memory_cards_delete_self"
    on public.bs_memory_cards
    for delete
    to authenticated
    using (auth.uid() = user_id);

commit;
