# Auth, Billing, and AI Gateway Plan

> ⚠️ **ARCHIVED（2026-07-12）**: MVP 設計時の草案。確定した API 契約は
> [api-contract.md](../api-contract.md)、実装の経緯は [implementation-roadmap.md](implementation-roadmap.md)、
> 現行の開発正本は [foundation-rebuild-plan.md](../foundation-rebuild-plan.md)。
> データモデル草案の命名（無 prefix）は実スキーマ（`bs_` prefix）と異なり、
> Admin 節「作らない」は現状（v0 実装済み）と一致しない。

This document captures the near-term production architecture for Bomb Squad.
The goal is to ship a small MVP without putting the app into a corner as iOS,
Android, enterprise tenants, custom prompts, usage logs, and additional AI
models are added later.

## Product Requirements

- One account must work across macOS, future iOS, future Android, and the web.
- Users can sign in with Google, Apple ID, or email link.
- Free users get a monthly review allowance, initially 50 reviews per month.
- Paid users are managed through Stripe subscriptions.
- The desktop app must not contain provider API keys.
- LLM usage must be authorized and metered on the server.
- Enterprise customers may need tenant-specific prompts, routing, logging,
  retention, security controls, and model choices.
- Future AI jobs may include transcription, emotion analysis, acoustic event
  analysis, and action extraction from logs.

## Recommended MVP Stack

- Supabase Auth: shared identity across all clients.
- Supabase Postgres: profiles, tenants, entitlements, usage events, prompt
  configuration, and audit metadata.
- Stripe: subscriptions, checkout, customer portal, invoices, and payment state.
- Vercel + Next.js: product site, pricing page, auth callback helpers, Stripe
  webhooks, and the initial AI gateway API.
- macOS app: Supabase session handling and calls to the AI gateway.
- LLM providers: called only from server-side code.

AWS is not required for the first release. The architecture should still keep a
clean boundary around AI execution so selected jobs can later move to AWS
Lambda, SQS, ECS, or EC2 without changing client apps.

## High-Level Architecture

```text
macOS / iOS / Android / Web
  -> Supabase Auth session
  -> AI Gateway API
       -> authorize user and tenant
       -> check entitlement and monthly quota
       -> load prompt configuration
       -> call selected AI provider
       -> record usage event
       -> return structured result

Stripe
  -> webhook
  -> update subscription and entitlement rows

Supabase Postgres
  -> shared account state
  -> subscription state
  -> quota and usage ledger
  -> tenant and policy configuration
```

## Core Boundary

All AI operations should pass through a single server-side gateway interface:

```text
POST /api/ai/review
POST /api/ai/transform
POST /api/ai/transcribe
POST /api/ai/analyze-audio
```

The first MVP can implement only `/api/ai/review`, but the request shape should
already include these common fields:

- `operation`: `review`, `transform`, `transcribe`, `analyze_audio`, or future values.
- `input`: operation-specific payload.
- `client`: platform, app version, build number, device ID.
- `preferences`: output language and user-selected model family when allowed.
- `request_id`: client-generated idempotency key.

The app should not know whether the server runs on Vercel, Lambda, ECS, or EC2.
It should only know the gateway URL and Supabase session.

## Data Model Draft

### `profiles`

One row per Supabase user.

- `id uuid primary key references auth.users(id)`
- `display_name text`
- `email text`
- `default_tenant_id uuid`
- `created_at timestamptz`
- `updated_at timestamptz`

### `tenants`

Supports personal accounts first and enterprise accounts later.

- `id uuid primary key`
- `slug text unique`
- `name text`
- `kind text`: `personal` or `enterprise`
- `status text`: `active`, `suspended`, `deleted`
- `created_at timestamptz`
- `updated_at timestamptz`

### `tenant_members`

Maps users to tenants.

- `tenant_id uuid references tenants(id)`
- `user_id uuid references auth.users(id)`
- `role text`: `owner`, `admin`, `member`
- `created_at timestamptz`
- primary key: `(tenant_id, user_id)`

### `entitlements`

The effective access policy for a tenant.

- `tenant_id uuid primary key references tenants(id)`
- `plan text`: `free`, `pro`, `team`, `enterprise`
- `status text`: `trialing`, `active`, `past_due`, `canceled`, `suspended`
- `monthly_review_limit integer`
- `monthly_audio_seconds_limit integer`
- `allowed_models jsonb`
- `features jsonb`
- `current_period_start timestamptz`
- `current_period_end timestamptz`
- `stripe_customer_id text`
- `stripe_subscription_id text`
- `updated_at timestamptz`

For MVP, free users should get:

- `plan = free`
- `status = active`
- `monthly_review_limit = 50`

### `usage_events`

Append-only usage ledger. This is the source of truth for quotas and later
analytics.

- `id uuid primary key`
- `tenant_id uuid references tenants(id)`
- `user_id uuid references auth.users(id)`
- `operation text`
- `model_vendor text`
- `model_id text`
- `input_units integer`
- `output_units integer`
- `unit_type text`: `review`, `token`, `audio_second`, etc.
- `request_id text`
- `status text`: `success`, `error`, `blocked`
- `error_code text`
- `latency_ms integer`
- `metadata jsonb`
- `created_at timestamptz`

Use a unique constraint on `(tenant_id, request_id)` when `request_id` is
present to avoid double-counting retries.

### `prompt_profiles`

Tenant or user prompt customization.

- `id uuid primary key`
- `tenant_id uuid references tenants(id)`
- `user_id uuid null references auth.users(id)`
- `scope text`: `tenant`, `user`, `operation`
- `operation text`
- `name text`
- `system_prompt text`
- `style_rules jsonb`
- `safety_rules jsonb`
- `is_default boolean`
- `created_at timestamptz`
- `updated_at timestamptz`

MVP can keep prompts in code, but the server API should be written so prompt
loading can move to this table later.

### `ai_routing_policies`

Enterprise model routing and security policy.

- `id uuid primary key`
- `tenant_id uuid references tenants(id)`
- `operation text`
- `provider text`
- `model_id text`
- `region text`
- `data_retention text`
- `log_policy jsonb`
- `enabled boolean`
- `created_at timestamptz`
- `updated_at timestamptz`

This table can be added later, but the gateway should internally resolve a
policy object before calling any provider.

### `app_devices`

Per-device tracking across macOS, iOS, Android, and web.

- `id uuid primary key`
- `user_id uuid references auth.users(id)`
- `platform text`: `macos`, `ios`, `android`, `web`
- `device_label text`
- `app_version text`
- `last_seen_at timestamptz`
- `created_at timestamptz`

This should not be used as the primary identity. Identity remains the Supabase
user ID.

## Request Handling Flow

1. Client sends Supabase access token with the request.
2. Gateway verifies the token and extracts `user_id`.
3. Gateway resolves the active tenant.
4. Gateway loads the tenant entitlement.
5. Gateway counts usage for the current billing period.
6. Gateway rejects requests over quota before calling an AI provider.
7. Gateway resolves prompt and model routing policy.
8. Gateway calls the provider.
9. Gateway records a `usage_events` row.
10. Gateway returns the structured result.

For free users, the quota check is simply:

```text
count successful review events in current month < 50
```

Paid plans can later switch to higher fixed limits, token-based limits, or
seat-based entitlements.

## Enterprise Readiness Without Enterprise Complexity

Do these from day one:

- Use `tenant_id` on billing, entitlement, prompt, routing, and usage tables.
- Keep AI provider calls behind the gateway.
- Make prompt resolution a server-side step.
- Store usage as append-only events.
- Keep request metadata structured as JSON.
- Separate `personal` tenants from future `enterprise` tenants.

Do not build these in the MVP unless needed:

- SSO/SAML.
- Dedicated VPC.
- Customer-managed keys.
- Per-tenant database isolation.
- Async job queues.
- Custom model hosting.
- Full admin console.

This keeps the initial system small while preserving the paths enterprise
customers usually ask for.

## AWS Escalation Path

Start with synchronous Vercel API routes for review and transform. Move selected
operations to AWS when one of these becomes true:

- A job no longer fits normal request/response latency.
- Burst traffic needs queue-based smoothing.
- Audio analysis needs GPU, long-running CPU, or custom binaries.
- Provider retries need DLQ and worker-level controls.
- An enterprise customer requires AWS-native deployment or isolation.

Likely migration path:

```text
Vercel Gateway
  -> enqueue job in SQS
  -> Lambda or ECS/EC2 worker processes job
  -> worker writes result and usage event to Supabase Postgres
  -> client polls or receives result through a realtime channel
```

For heavy audio models, EC2 or ECS is a better target than Lambda. Keep that as
a later execution backend, not the first API platform.

## Logging and Data Use

There are two different classes of logs:

- Operational logs: request status, latency, token or unit counts, error codes.
- Content logs: user text, revised text, audio-derived content, extracted actions.

MVP should store operational logs by default. Content logs should be opt-in or
policy-controlled because communication text is sensitive.

For later optimization and action extraction, add content storage only behind a
clear policy:

- personal default: do not retain full content
- user opt-in: retain for history and personalization
- enterprise default: tenant policy decides retention
- sensitive tenant: no content retention, operational metadata only

## Prompt Customization

MVP:

- prompt templates live in server code
- user can choose output language
- model choice can remain limited

Next step:

- add user-level style preferences
- add tenant-level default prompt profile
- store prompt profile versions
- record prompt profile ID in `usage_events.metadata`

This allows future debugging and optimization without making the first app
configuration-heavy.

## Client Implementation Implications

The macOS app should move from provider-specific clients to a product API
client:

- current: `OpenAICompatibleClient`, `ClaudeClient`, `GroqTranscriber`
- target: `BombSquadAPIClient`

The API client should handle:

- Supabase session token retrieval
- authenticated requests to the gateway
- structured review responses
- quota and subscription errors
- app version and platform metadata

Provider selection should become a server concern. The local model selector can
remain as a user preference only when the current plan allows model choice.

## Suggested Phases

### Phase 1: Shared Account and Server Gateway

- Create Supabase project.
- Add Google, Apple, and email-link auth.
- Add the first schema: profiles, tenants, tenant_members, entitlements,
  usage_events.
- Create Vercel/Next.js app with `/api/ai/review`.
- Move provider keys to server environment variables.
- Modify macOS app to call the gateway.
- Enforce free monthly review limit of 50.

### Phase 2: Billing

- Add Stripe products and prices.
- Add Checkout and Customer Portal routes.
- Add Stripe webhook handling.
- Update entitlements from subscription events.
- Show plan and remaining quota in the macOS app.

### Phase 3: Admin and Operations

- Add minimal internal admin pages.
- Search users and tenants.
- Inspect subscription state and usage events.
- Manually suspend or grant quota.
- Add error dashboards and usage summaries.

### Phase 4: Multi-Platform Clients

- Reuse Supabase Auth and gateway API from iOS and Android.
- Register devices in `app_devices`.
- Keep account, billing, entitlement, and usage shared by tenant.

### Phase 5: Enterprise and Advanced AI

- Add prompt profiles.
- Add AI routing policies.
- Add retention policies.
- Add async worker path for audio and long-running jobs.
- Add tenant-specific security controls only when a real customer requires them.

## Immediate Decision

Proceed with Vercel, Supabase, and Stripe for MVP. Design the API and database
around tenants and append-only usage events from day one. Delay AWS until a
specific workload needs queues, workers, custom runtimes, or enterprise
isolation.
