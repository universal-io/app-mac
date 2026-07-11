# Supabase Setup Notes

This document covers the Bomb Squad-specific setup inside the existing shared
Supabase project.

Project URL:

- `https://skcsbcyivjcvevxntvqa.supabase.co`

Product URLs:

- Production web: `https://bombsquad.me`
- Local web: `http://localhost:3000`

Database naming rule:

- Bomb Squad-owned tables use the `bs_` prefix.
- Existing tables from other projects are left untouched.

## Current Migration Files

- `supabase/migrations/0001_bs_core_schema.sql`

That migration creates:

- `bs_tenants`
- `bs_profiles`
- `bs_tenant_members`
- `bs_entitlements`
- `bs_usage_events`
- `bs_app_devices`

It also:

- enables RLS
- adds membership helper functions
- adds a Bomb Squad-specific user bootstrap RPC
- backfills existing `auth.users` rows that do not yet have `bs_` records

## Secrets Needed Later

These values should be prepared before client or gateway implementation starts.

### For macOS

- `BOMB_SQUAD_SUPABASE_URL`
- `BOMB_SQUAD_SUPABASE_ANON_KEY`
- `BOMB_SQUAD_API_BASE_URL`

Current runtime resolution order:

1. Repository-local `BombSquad.local.plist`
2. Xcode Scheme environment variables
3. `Info.plist` keys with the same names

That behavior is implemented in
[BombSquadConfig.swift](/Users/kaya.matsumoto/projects/universal-io/app-mac/BombSquad/Services/BombSquadConfig.swift:1).

Recommended local file for macOS development:

- `/Users/kaya.matsumoto/projects/universal-io/app-mac/BombSquad.local.plist`

Optional fallback path when launching the built app outside the repo:

- `~/Library/Application Support/BombSquad/local-config.plist`

### For Vercel / web

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_BOMB_SQUAD_API_BASE_URL`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

### For billing and AI gateway

- `OPENAI_API_KEY`
- `GROQ_API_KEY`
- `ANTHROPIC_API_KEY`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_PRO_MONTHLY`
- `STRIPE_PRICE_TEAM_MONTHLY`
- `STRIPE_PRICE_ENTERPRISE_MONTHLY`

The canonical names are defined in [api-contract.md](api-contract.md).

## Auth Providers

Planned providers:

- Google OAuth
- Apple ID
- Email link

Current decision:

- Supabase Auth is the shared identity layer across macOS, future iOS,
  Android, and web.
- Bomb Squad の現在のログイン方式は `Google OAuth` と `メールリンク認証`。
- `認証コード入力` は現在の仕様には含めない。
- App-specific user/account state lives in `bs_` tables, not in custom auth
  tables.
- Because this Supabase project is shared, Bomb Squad does **not** attach a
  global trigger to `auth.users`. Instead, the client or backend calls
  `public.bs_initialize_current_user()` after a successful Bomb Squad sign-in.

Important clarification:

- Supabase のクライアント API では、メールリンク送信にも
  `signInWithOTP(email:redirectTo:)` を使う。
- ただし Bomb Squad の Supabase メールテンプレートは
  `{{ .ConfirmationURL }}` 前提なので、ユーザーに届くのはログインリンクであり、
  入力用コードではない。
- もしテンプレートを `{{ .Token }}` ベースに変えると、同じ API 呼び出しでも
  認証コード方式に変わってしまう。Bomb Squad ではそれを採用しない。

## Redirects And Deep Links

Current web values:

- Production site URL: `https://bombsquad.me`（将来 `https://universal-io.com` へ移行予定。
  製品サイト・サインイン・課金・Gateway API を集約する。メールは Cloudflare + Resend 予定）
- Local site URL: `http://localhost:3000`
- Shared web auth callback path: `/auth/callback`
- Supabase provider callback: `https://skcsbcyivjcvevxntvqa.supabase.co/auth/v1/callback`
- Native macOS callback: `universal-io://auth/callback`（C4 リブランド、2026-07-03。
  旧 `bombsquad://auth/callback` は移行期間中 Redirect URLs に残し、行き渡ったら削除）

Current provider configuration notes:

- Google Cloud OAuth client:
  - Authorized JavaScript origins:
    - `https://bombsquad.me`
    - `http://localhost:3000`
  - Authorized redirect URIs:
    - `https://skcsbcyivjcvevxntvqa.supabase.co/auth/v1/callback`
- Supabase Auth URL configuration should include:
  - Site URL: `https://bombsquad.me`
  - Redirect URLs:
    - `https://bombsquad.me/auth/callback`
    - `http://localhost:3000/auth/callback`
    - `universal-io://auth/callback`（C4 以降の必須エントリ）
    - `bombsquad://auth/callback`（旧クライアント向け。移行完了後に削除可）

Expected categories:

- local web auth callback for the product site
- production web auth callback for the product site
- macOS app callback / deep link
- future iOS app callback
- future Android app callback

Apple ID is still pending and should reuse the same production and local web
callback assumptions where applicable.

## Applying The Migration

Two safe paths:

1. Review the SQL file in advance, then paste it into the Supabase SQL editor.
2. Apply it through Supabase CLI once local Supabase project wiring is added.

Because this Supabase project is shared with older work, review points before
running:

- confirm every new object is `bs_` prefixed
- confirm there is no global `auth.users` trigger for Bomb Squad bootstrap
- confirm the backfill only touches auth users missing `bs_profiles`
- confirm no existing project tables are altered or dropped

### Required for current web auth

If Google or email-link sign-in succeeds but the app then fails with an error
like:

```text
Could not find the function public.bs_initialize_current_user without parameters in the schema cache
```

that means the Bomb Squad schema migration has not been applied to this
Supabase project yet.

In that case:

1. Open Supabase Dashboard for `https://skcsbcyivjcvevxntvqa.supabase.co`
2. Go to SQL Editor
3. Paste the contents of `supabase/migrations/0001_bs_core_schema.sql`
4. Run it once
5. Re-test login

The current web auth flow depends on `public.bs_initialize_current_user()` to
provision `bs_profiles`, `bs_tenants`, `bs_tenant_members`, and
`bs_entitlements` after successful sign-in.

## Expected Result After Apply

For each existing auth user:

- one personal tenant in `bs_tenants`
- one row in `bs_profiles`
- one owner membership in `bs_tenant_members`
- one free entitlement in `bs_entitlements`

For each new Bomb Squad auth user after migration:

- the app or backend calls `select public.bs_initialize_current_user();`
- that call creates the same tenant/profile/membership/entitlement set if absent

Default free plan values:

- `plan = free`
- `status = active`
- `monthly_review_limit = 50`

## Manual Verification Queries

After applying the migration, run checks like these:

```sql
select count(*) from public.bs_profiles;
select count(*) from public.bs_tenants;
select count(*) from public.bs_tenant_members;
select count(*) from public.bs_entitlements;
```

```sql
select p.id, p.email, p.default_tenant_id, e.plan, e.monthly_review_limit
from public.bs_profiles p
join public.bs_entitlements e
  on e.tenant_id = p.default_tenant_id
order by p.created_at desc
limit 20;
```

```sql
select tablename
from pg_tables
where schemaname = 'public'
  and tablename like 'bs_%'
order by tablename;
```

## Next Work After Setup

- Verify Google OAuth end-to-end on both `https://bombsquad.me` and `http://localhost:3000`.
- Verify Google OAuth end-to-end on native macOS with `bombsquad://auth/callback`.
- Add Apple ID later using the same auth callback surface.
- Scaffold the web AI gateway.

## Current macOS Auth Checkpoint

- The macOS app now expects `BOMB_SQUAD_SUPABASE_URL` and
  `BOMB_SQUAD_SUPABASE_ANON_KEY`.
- Settings includes the Bomb Squad account section.
- The implemented macOS auth methods are:
  - Google OAuth
  - email link
- Native Google sign-in uses Supabase OAuth with the callback URL
  `bombsquad://auth/callback`.
- Native email sign-in also uses the callback URL `bombsquad://auth/callback`.
- After successful sign-in, the app calls `public.bs_initialize_current_user()`.
- Apple ID remains pending.

## Current web Auth Checkpoint

- The Vercel-facing UI now lives under `web/`.
- The planned production origin is `https://bombsquad.me`.
- The main routes are:
  - `/`
  - `/auth`
  - `/auth/callback`
  - `/pricing`
- The web app expects:
  - `NEXT_PUBLIC_SUPABASE_URL`
  - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
  - `NEXT_PUBLIC_BOMB_SQUAD_API_BASE_URL`
- A starter env file exists at `web/.env.example`.
- The current web auth methods are:
  - email link
  - Google OAuth
- Apple ID remains pending.
