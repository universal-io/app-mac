begin;

-- Every Stripe webhook event we accepted, one row per event id.
--
-- Why this table exists: Stripe redelivers. A retry after a timeout, a manual
-- resend from the dashboard, and at-least-once delivery all mean the same event
-- can arrive more than once. The primary key on the event id is what makes the
-- second arrival a no-op.
--
-- received_at is written before the entitlement is touched and applied_at only
-- after it succeeds. The two timestamps are what distinguish "already handled,
-- ignore it" from "we accepted this event and then died before applying it",
-- which must be retried rather than skipped. A row with applied_at still null
-- long after received_at is an event that never landed.
--
-- No content from the event is stored. type, livemode and the subscription id
-- are enough to trace what happened; the payload itself stays in Stripe, which
-- is the source of truth for money.
create table if not exists public.bs_stripe_events (
    -- Stripe's own event id (evt_...). The uniqueness we depend on.
    event_id text primary key,
    type text not null,
    -- Sandbox and live events can both reach one deployment during bring-up, so
    -- record which environment produced the event rather than inferring it.
    livemode boolean not null,
    -- The subscription the event resolved to, when it had one. Null for events
    -- that carry no subscription.
    subscription_id text,
    received_at timestamptz not null default now(),
    applied_at timestamptz,
    -- Last failure reason, kept so a stuck event can be diagnosed without
    -- replaying it. Cleared when the event finally applies.
    error text
);

comment on table public.bs_stripe_events is
    'Accepted Stripe webhook event ids. Primary key makes redelivery a no-op; applied_at separates "handled" from "accepted but not applied".';

-- Ordered scans for "what has not applied yet" and for pruning old rows once
-- volume justifies it. Retention is not automated: at current volume the table
-- is negligible, and deleting an event id would make that event replayable.
create index if not exists bs_stripe_events_received_at_idx
    on public.bs_stripe_events (received_at desc);

-- Same posture as bs_plans and bs_plan_prices: row level security on with no
-- policies, so only the service-role Gateway can read or write it.
alter table public.bs_stripe_events enable row level security;

commit;
