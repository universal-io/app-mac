begin;

-- When a subscription is scheduled to stop, or null when it will renew.
--
-- Cancelling takes effect at the end of the paid period, not immediately:
-- someone who paid for the month keeps the month. That policy creates a state
-- the entitlement row previously could not express — plan 'standard', status
-- 'active', and yet ending on a known date. Without this column the account
-- page can only say "有効", so a user who just cancelled sees no trace of it and
-- has to guess whether it worked.
--
-- A timestamp rather than a boolean copy of Stripe's cancel_at_period_end: the
-- useful fact is the date the user should be told, and a date also covers a
-- cancellation scheduled for some other moment. Null means renewing, which is
-- also what a terminal state resets it to.
--
-- Not an access check. Entitlement is decided by plan and status; this column is
-- only ever read for display. Access ends when Stripe finally cancels and the
-- deleted event drops the row to free.
alter table public.bs_entitlements
    add column if not exists cancel_at timestamptz;

comment on column public.bs_entitlements.cancel_at is
    'When the subscription is scheduled to stop (Stripe cancel_at / cancel_at_period_end). Null = renewing. Display only; never an access check.';

commit;
