# Supabase Setup Notes

This document covers the Bomb Squad-specific setup inside the existing shared
Supabase project.

Project URL:

- `https://skcsbcyivjcvevxntvqa.supabase.co`

Product URLs:

- Production Gateway: `https://api.universal-io.com`（**移行完了済み、2026-07-03**。
  製品サイトは `https://universal-io.com`。`bombsquad.me` はレガシー）
- Local web: `http://localhost:3000`
- Native callback: `universal-io://auth/callback`（`bombsquad://` はレガシー後方互換）

Database naming rule:

- Bomb Squad-owned tables use the `bs_` prefix.
- Existing tables from other projects are left untouched.

## Current Migration Files

- `supabase/migrations/0001_bs_core_schema.sql` — コアスキーマ:
  `bs_tenants` / `bs_profiles` / `bs_tenant_members` / `bs_entitlements` /
  `bs_usage_events` / `bs_app_devices`。RLS 有効化、メンバーシップ補助関数、
  ユーザーブートストラップ RPC、既存 `auth.users` のバックフィル。
- `supabase/migrations/0004_plan_catalog.sql` — **`bs_plans`（プラン→クォータ/機能の唯一の正本）**。
  `bs_entitlements.plan` を FK 化、`monthly_review_limit` を NULL 可（NULL = プラン値に従う）に変更、
  `bs_provision_user()` 再定義。**ベータ方針（2026-07-08）: free=500件/月、他プランは無制限・
  機能ゲート無し。プラン変更はこのテーブルの行を編集する（env・コードにコピーを持たない）**。
- `supabase/migrations/20260718000000_remove_unused_tables.sql` — 使用を終了した旧画面案内テーブルを削除。
- `supabase/migrations/20260722010000_usage_retention.sql` — request単位usageを90日保持し、
  `bs_usage_monthly_rollups`へ集約して詳細行を削除する日次pg_cron jobを登録する。
- `supabase/migrations/20260725000000_drop_memory_cards.sql` — v3で文体・関係性メモリを廃止し、
  `bs_memory_cards`とscrub triggerを削除する。`0002` / `20260722000000` はこの削除で無効化された
  履歴であり、新規環境でも適用後に落ちる。

## Secrets Needed Later

These values should be prepared before client or gateway implementation starts.

### For macOS

- `BOMB_SQUAD_SUPABASE_URL`
- `BOMB_SQUAD_SUPABASE_ANON_KEY`
- Product Gateway URLは`project.yml`のInfo.plist定義に固定し、ローカル設定へ置かない。

Supabase client configuration resolution order:

1. Repository-local `BombSquad.local.plist`
2. Xcode Scheme environment variables
3. `Info.plist` keys with the same names

That behavior is implemented in
[BombSquadConfig.swift](/Users/kaya.matsumoto/projects/universal-io/app-mac/BombSquad/Services/BombSquadConfig.swift:1).

Recommended local file for macOS development:

- `/Users/kaya.matsumoto/projects/universal-io/app-mac/BombSquad.local.plist`

Optional Supabase configuration path when launching the built app outside the repo:

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

Stripeはこの2つだけを持つ。price idをenvへ置かない（`bs_plan_prices`が対応表の正本で、
1プランに複数のprice idが付く）。ホスト型Checkoutを使うためpublishable keyも持たない。
`STRIPE_SECRET_KEY`の接頭辞（`sk_test_` / `sk_live_`）が実効モードを決め、同じ接頭辞が
`bs_plan_prices.livemode`のどちら側を販売対象にするかも決める。モードは管理画面「設定」に表示する。

Provider data controls（envではなく各provider管理画面）:

- OpenAI Organization / Project: Zero Data Retention（要承認）
- Groq Data Controls: Zero Data Retention
- GatewayはOpenAI Responses / Chat Completionsで`store: false`を送るが、これはZDRの代替ではない。

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
- `monthly_review_limit = NULL`（0004 以降。NULL = `bs_plans` のプラン値に従う。
  実効値は `bs_plans.free = 500`/月。行単位の特別オーバーライドが必要な時だけ数値を入れる）

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
