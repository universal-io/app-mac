begin;

-- How often the app has asked the user to confirm a given fact, and whether
-- they said no. This is the memory that makes the confirmation question
-- tolerable: without it the same question returns every session, which is the
-- failure mode that would make the whole learning loop worse than not having
-- it at all.
--
-- Only the two suppression signals live here — asked how many times, declined
-- or not. The answer itself is a row in bs_user_facts, and a filled fact is
-- already reason enough not to ask, so nothing is duplicated between the two
-- tables. Keys come from the same closed vocabulary, so this table is bounded
-- by construction exactly like bs_user_facts.
create table if not exists public.bs_fact_prompts (
    user_id uuid not null references auth.users (id) on delete cascade,
    -- 'global', or the id of the skill that declared the key.
    scope text not null check (char_length(scope) between 1 and 64),
    key text not null check (char_length(key) between 1 and 64),
    -- Counted when the question is returned to the client, not when it is
    -- answered: a question the user closed the panel on still used up an ask.
    ask_count integer not null default 0 check (ask_count >= 0),
    -- Set once the user says no. A decline is permanent; correcting a fact is
    -- what the management screen is for.
    declined_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (user_id, scope, key)
);

comment on table public.bs_fact_prompts is
    'Suppression state for user-fact confirmation questions (v3 M4). Ask count and decline flag only; the confirmed value lives in bs_user_facts.';

alter table public.bs_fact_prompts enable row level security;

-- The gateway reads and writes with the service-role key. These policies are
-- what stops a client holding an anon key from reading or forging another
-- account's prompt state.
drop policy if exists "bs_fact_prompts_select_self" on public.bs_fact_prompts;
create policy "bs_fact_prompts_select_self"
    on public.bs_fact_prompts
    for select
    to authenticated
    using (auth.uid() = user_id);

drop policy if exists "bs_fact_prompts_insert_self" on public.bs_fact_prompts;
create policy "bs_fact_prompts_insert_self"
    on public.bs_fact_prompts
    for insert
    to authenticated
    with check (auth.uid() = user_id);

drop policy if exists "bs_fact_prompts_update_self" on public.bs_fact_prompts;
create policy "bs_fact_prompts_update_self"
    on public.bs_fact_prompts
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "bs_fact_prompts_delete_self" on public.bs_fact_prompts;
create policy "bs_fact_prompts_delete_self"
    on public.bs_fact_prompts
    for delete
    to authenticated
    using (auth.uid() = user_id);

commit;
