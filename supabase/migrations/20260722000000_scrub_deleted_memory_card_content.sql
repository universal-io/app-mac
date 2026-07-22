begin;

-- A deletion tombstone only needs identity, kind, timestamps, and ownership.
-- Remove user-authored content retained by older clients before enforcing the
-- same boundary for every future insert or update.
update public.bs_memory_cards
set subject = null,
    content_md = ''
where deleted_at is not null
  and (subject is not null or content_md <> '');

create or replace function public.bs_scrub_deleted_memory_card_content()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new.deleted_at is not null then
        new.subject = null;
        new.content_md = '';
    end if;
    return new;
end;
$$;

drop trigger if exists bs_memory_cards_scrub_deleted_content
    on public.bs_memory_cards;
create trigger bs_memory_cards_scrub_deleted_content
    before insert or update on public.bs_memory_cards
    for each row execute function public.bs_scrub_deleted_memory_card_content();

commit;
