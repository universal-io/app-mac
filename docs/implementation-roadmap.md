# Bomb Squad Implementation Roadmap

> **2026-07-02 更新**: 製品は Universal I/O (I//O) へ方針転換した。今後の正本は
> [universal-io-master-plan.md](universal-io-master-plan.md)。このファイルは
> 認証・課金インフラの経緯資料として残す（マスタープラン M3 が参照する）。

This is the resumable execution plan after the app rename. Keep this file
updated whenever a phase starts, finishes, or changes direction.

## Current Checkpoint

> **2026-07-11 更新**: foundation redesign recovery の検証済み状態は
> `feature/foundation-redesign` に採用済み。切り替え判断とブランチ運用は
> [foundation-recovery-handoff.md](foundation-recovery-handoff.md) を参照。

- Repository: `git@github.com:universal-io/app-mac.git`
- Branch: `feature/foundation-redesign`
- Last pushed commit: `72ea035 Keep auth panel open during login`
- App target: `BombSquad`
- Bundle ID: `com.heywatchme.bombsquad`
- Generated project: `BombSquad.xcodeproj`
- Supabase core schema SQL has been applied in the shared project.
- New web shell: `web/`
- Planned production web URL: `https://bombsquad.me`
- Next session note:
  - this repo directory may be renamed from `just-a-moment` to `bomb-squad`
  - re-check cwd and local file links after reopening a new session
  - Supabase MCP should be reconnected against the Bomb Squad-only account/project
- Build check:

```bash
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug build
```

## Guiding Constraints

- Keep one shared identity across macOS, future iOS, Android, and web.
- Do not ship LLM provider keys in client apps.
- Use the existing Supabase project, but prefix app-owned tables with `bs_`.
- Treat Supabase Auth as shared infrastructure; app-specific state belongs in
  prefixed public tables.
- Start with Vercel/Supabase/Stripe. Add AWS only for queue-backed or heavy AI
  jobs that need it.
- Keep enterprise readiness lightweight: tenant IDs, usage events, prompt
  profiles, and routing policies can exist before enterprise features are fully
  built.

## Phase 0: Repository Hygiene

Status: ready

- Confirm `main` is clean before starting each phase.
- Use small commits per phase.
- Run `xcodegen generate` after `project.yml` changes.
- Run the Debug build before each push.
- Keep generated `.xcodeproj` ignored.

## Phase 1: Supabase Schema

Status: complete

Goal: create app-owned tables that can coexist with older projects in the same
Supabase instance.

Table prefix: `bs_`

Initial tables:

- `bs_profiles`
- `bs_tenants`
- `bs_tenant_members`
- `bs_entitlements`
- `bs_usage_events`
- `bs_app_devices`

Later tables:

- `bs_prompt_profiles`
- `bs_ai_routing_policies`
- `bs_audit_events`

Implementation files:

- `supabase/migrations/0001_bs_core_schema.sql`
- `docs/supabase-setup.md`

Acceptance:

- Migration can be reviewed before applying.
- RLS policies are included.
- New user bootstrap path creates a personal tenant, membership, profile, and
  free entitlement with `monthly_review_limit = 50`.
- Existing non-Bomb Squad tables are untouched.

## Phase 2: Auth Configuration

Status: in progress

Goal: make account login work before paid plans.

Providers:

- Google OAuth
- Apple ID
- Email link

Implementation files:

- `BombSquad/Services/AuthClient.swift`
- `BombSquad/ViewModels/AuthViewModel.swift`
- `BombSquad/Views/AuthView.swift`
- `BombSquad/Views/SettingsView.swift`
- `project.yml` if entitlements or URL schemes are needed

Acceptance:

- User can sign in and out.
- Session persists across app launches.
- App can retrieve a Supabase access token for API calls.
- Settings or account panel shows signed-in email and current tenant.

Current implementation checkpoint:

- Supabase runtime config is wired into the macOS app.
- Google OAuth and email-link sign-in are implemented in the macOS app.
- Successful sign-in triggers `public.bs_initialize_current_user()`.
- Web production URL is fixed at `https://bombsquad.me`.
- Google OAuth is implemented on the web surface and Supabase now has the Google client ID configured.
- macOS auth callback bug fixed: the unauthenticated login panel stays visible while Google or email-link auth moves focus to the browser or Mail.
- Apple ID remains pending.

Next macOS UX task: DONE

The on-demand management window model is implemented:

- The app stays a menu-bar/accessory app. The menu bar is the hub: it shows
  signed-in email/plan at a glance and opens each section on demand.
- Two surfaces only:
  - transient input-support panel (right Shift gesture / ⌘J): now stripped of
    management navigation (the settings gear was removed; the not-signed-in state
    is just a "ログイン / 新規登録" CTA that opens the management window).
  - a single on-demand management window: a modern `NavigationSplitView` sidebar
    (`ManagementView`) with Account, Settings, History, Pricing sections. Managed
    as one reused `NSWindow` in `AppDelegate`; never always-on, never auto-focused
    during ordinary input-support usage.
- Sign in / sign up / sign out all live in the Account section (`AccountView`).
- Settings (model/API keys/backend) moved to `GeneralSettingsView`; the old
  combined `SettingsView`/`AuthView` and the SwiftUI `Settings` scene were removed.
- History is a placeholder (no persistence layer yet). Pricing opens the web page.
- The Amical layout was used as a layout reference only; lifecycle is on-demand.

Implementation files:

- `BombSquad/Views/Management/ManagementView.swift` (+ `ManagementNavigator`, `ManagementSection`)
- `BombSquad/Views/Management/AccountView.swift`
- `BombSquad/Views/Management/GeneralSettingsView.swift`
- `BombSquad/Views/Management/HistoryPlaceholderView.swift`
- `BombSquad/Views/Management/PricingView.swift`
- `BombSquad/BombSquadApp.swift`, `BombSquad/AppDelegate.swift`
- `BombSquad/Views/StagingEditorView.swift`, `BombSquad/Views/LoginRequiredView.swift`

Native macOS windowing options to keep in mind:

- Regular Dock app with a standard main window.
- Menu-bar/accessory app with windows opened on demand.
- Menu-bar popover for small status/account controls.
- Transient floating `NSPanel` for capture/review.
- Separate Settings/Account `NSWindow` for heavier management screens.

Avoid custom focus-stealing or always-on-top behavior unless a specific product requirement justifies it.

## Phase 3: AI Gateway MVP

Status: in progress

Goal: move provider keys out of the macOS app.

Recommended package layout:

- `web/` for a Next.js app on Vercel
- `web/app/api/ai/review/route.ts`
- `web/lib/supabaseAdmin.ts`
- `web/lib/entitlements.ts`
- `web/lib/usage.ts`
- `web/lib/providers/openai-compatible.ts`
- `web/lib/providers/anthropic.ts`

Request flow:

- Verify Supabase JWT.
- Resolve tenant.
- Check entitlement and monthly quota.
- Call configured LLM provider.
- Insert `bs_usage_events`.
- Return the existing `ReviewResult` shape.

Acceptance:

- Free users are limited to 50 successful review/transform operations per month.
- Over-quota responses are structured and user-readable.
- macOS app no longer requires OpenAI/Groq/Claude keys for normal usage.

Current implementation checkpoint:

- `web/` Next.js app exists and builds.
- Product UI routes exist at `/`, `/auth`, and `/pricing`.
- Web auth currently implements email link and Google OAuth against Supabase.
- Web auth callbacks are designed for both `https://bombsquad.me/auth/callback` and `http://localhost:3000/auth/callback`.
- Apple ID remains a follow-up task.
- Stripe and `/api/ai/review` are still pending.

## Phase 4: macOS API Client Cutover

Status: pending Phase 3

Goal: replace direct provider calls with product API calls while keeping the old
provider clients available only as temporary development fallback if needed.

Implementation files:

- `BombSquad/Services/BombSquadAPIClient.swift`
- `BombSquad/Services/ReviewProvider.swift`
- `BombSquad/ViewModels/ReviewViewModel.swift`
- `BombSquad/Views/SettingsView.swift`

Acceptance:

- Review and transform work through `/api/ai/review`.
- Errors distinguish unauthenticated, over quota, payment required, and provider
  failure.
- Settings no longer presents provider API keys as the normal user path.

## Phase 5: Stripe Billing

Status: pending Phase 3

Goal: add paid plans and entitlement sync.

Implementation files:

- `web/app/pricing/page.tsx`
- `web/app/api/billing/checkout/route.ts`
- `web/app/api/billing/portal/route.ts`
- `web/app/api/stripe/webhook/route.ts`
- `web/lib/stripe.ts`

Acceptance:

- User can open Stripe Checkout from the web or app.
- User can manage billing in Stripe Customer Portal.
- Stripe webhook updates `bs_entitlements`.
- App reflects free/pro status and remaining quota.

## Phase 6: Admin and Operations

Status: pending Phase 5

Goal: make early support possible without building a large admin system.

Implementation files:

- `web/app/admin/page.tsx`
- `web/app/admin/users/page.tsx`
- `web/app/admin/tenants/page.tsx`
- `web/app/admin/usage/page.tsx`

Acceptance:

- Admin can search users and tenants.
- Admin can inspect subscription status and usage.
- Admin can manually suspend a tenant or grant temporary quota.

## Phase 7: Enterprise and Advanced AI

Status: future

Goal: add enterprise-specific controls only when real requirements appear.

Possible work:

- `bs_prompt_profiles` for tenant and user prompt customization.
- `bs_ai_routing_policies` for per-tenant provider/model/region choices.
- Content retention policies.
- SSO/SAML.
- Queue-backed jobs for audio analysis and long-running processing.
- AWS SQS + ECS/EC2 worker path for heavy audio models.

## First Five Tasks

1. Completed: define the gateway contract and environment variable names in
   `docs/api-contract.md`.
2. Completed: write `supabase/migrations/0001_bs_core_schema.sql`.
3. Completed: write `docs/supabase-setup.md` with required project URL, anon key, service
   role key, redirect URLs, and provider configuration steps.
4. Completed: add a small Supabase config layer in macOS using environment or local config.
5. Completed: add the first macOS auth client and align it with the web auth contract.
6. Completed: scaffold the Vercel-facing `web/` shell with product, auth, and pricing pages.

Next task after those:

- Implement the on-demand macOS Account/Settings window model described above.
- Then scaffold `web/` with the `/api/ai/review` route shape, but keep provider
  execution stubbed until auth is verified end-to-end.

## Contract Notes

Create `docs/api-contract.md` before implementation. It should define:

- API base URL setting names for macOS and web.
- Supabase env vars: project URL, anon key, service role key.
- AI gateway env vars: provider keys, default model, quota limits.
- Stripe env vars: secret key, webhook secret, price IDs.
- Request and response JSON for `/api/ai/review`.
- Standard error codes for unauthenticated, over quota, payment required, and
  provider failure.

## Stop/Resume Rule

At the end of each work session:

- Run `git status -sb`.
- Record the current phase and next task in this file.
- Commit only buildable or reviewable checkpoints.
- Push before switching machines or handing off.
