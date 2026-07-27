begin;

-- Which Stripe price maps to which plan. Applied to production on 2026-07-27
-- via the SQL editor; this file exists so the repository records the shape
-- rather than only the database knowing it.
--
-- Why a table and not two columns on bs_plans: a plan accumulates price ids.
-- Sandbox and live ids are different objects, a Stripe price cannot be edited
-- so every price change creates a new id while existing subscribers keep the
-- old one, and adding a yearly interval or a second currency adds more still.
-- Columns could hold today's price; only a mapping can answer "which plan does
-- this subscription's price belong to" for a subscriber who signed up a year
-- ago at a price no longer sold.
--
-- The division of responsibility is deliberate: bs_plans stays the single
-- source of truth for what a plan GRANTS (quota, features), and this table only
-- says which Stripe object SELLS it. Nothing about entitlement lives here.
create table if not exists public.bs_plan_prices (
    stripe_price_id text primary key,
    plan text not null references public.bs_plans (plan),
    -- Sandbox and live ids coexist here, so the gateway can resolve a webhook
    -- from either environment without a second table or an env-var switch.
    livemode boolean not null,
    billing_interval text not null check (billing_interval in ('month', 'year')),
    -- Lowercase ISO code, as Stripe reports it ('jpy', 'usd'). JPY is a
    -- zero-decimal currency in Stripe: 2000 means 2000 yen, while 2000 in USD
    -- would mean $20.00.
    currency text not null check (char_length(currency) = 3),
    -- False retires a price from new purchases without touching the
    -- subscriptions already on it. Replacing a price is the normal case here,
    -- not an exception.
    is_purchasable boolean not null default true,
    created_at timestamptz not null default now()
);

comment on table public.bs_plan_prices is
    'Stripe price id -> plan mapping. A plan accumulates price ids (sandbox/live, immutable prices, intervals, currencies); bs_plans remains the sole source of truth for what a plan grants.';

-- Same posture as bs_plans: row level security on with no policies, so no
-- client key can read it and only the service-role gateway can. Prices are not
-- secret, but this is configuration, and configuration is not client data.
alter table public.bs_plan_prices enable row level security;

commit;
