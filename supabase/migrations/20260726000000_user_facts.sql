begin;

-- Facts the user confirmed about themselves, one row per (scope, key). The
-- vocabulary is closed: every key is declared by a skill in
-- web/lib/server/skills, and the gateway refuses anything outside it. That is
-- what keeps this table small enough to need no confidence score, no
-- observation count, and no decay — an upsert on a closed key set cannot grow
-- past the number of keys, which is a few dozen even with many tools.
--
-- Deliberately not the retired bs_memory_cards: no free text, no cursor sync,
-- no tombstones. All rows for a user fit in one response, so clients pull the
-- whole set.
create table if not exists public.bs_user_facts (
    user_id uuid not null references auth.users (id) on delete cascade,
    -- 'global', or the id of the skill the fact belongs to ('slack', 'gmail').
    scope text not null check (char_length(scope) between 1 and 64),
    key text not null check (char_length(key) between 1 and 64),
    value text not null check (char_length(value) between 1 and 120),
    updated_at timestamptz not null default now(),
    primary key (user_id, scope, key)
);

comment on table public.bs_user_facts is
    'User facts (v3 Skills layer). Closed key vocabulary declared by skills; upsert only, no history. Injection reads the global scope plus the current tool''s scope.';

alter table public.bs_user_facts enable row level security;

-- The gateway reads and writes with the service-role key, but these policies
-- still matter: they are what stops a client holding an anon key from reading
-- another account's facts directly.
drop policy if exists "bs_user_facts_select_self" on public.bs_user_facts;
create policy "bs_user_facts_select_self"
    on public.bs_user_facts
    for select
    to authenticated
    using (auth.uid() = user_id);

drop policy if exists "bs_user_facts_insert_self" on public.bs_user_facts;
create policy "bs_user_facts_insert_self"
    on public.bs_user_facts
    for insert
    to authenticated
    with check (auth.uid() = user_id);

drop policy if exists "bs_user_facts_update_self" on public.bs_user_facts;
create policy "bs_user_facts_update_self"
    on public.bs_user_facts
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "bs_user_facts_delete_self" on public.bs_user_facts;
create policy "bs_user_facts_delete_self"
    on public.bs_user_facts
    for delete
    to authenticated
    using (auth.uid() = user_id);

commit;
