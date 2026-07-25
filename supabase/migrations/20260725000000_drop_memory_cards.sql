-- v3 M0: remove the style/relationship memory feature.
--
-- The persona/relationship card model never produced learning worth injecting,
-- and v3 replaces it with a different mechanism (Skills plus a closed-vocabulary
-- user fact store). Nothing reads bs_memory_cards after this migration: the
-- gateway routes (/api/memory/cards, /api/ai/memory/distill) and the macOS
-- store are deleted in the same change.
--
-- This drops user content on purpose. The product is pre-release with a single
-- user, so there is no compatibility window to preserve.

drop table if exists public.bs_memory_cards cascade;

-- The scrub trigger only ever guarded that table's tombstones.
drop function if exists public.bs_scrub_deleted_memory_card_content() cascade;
