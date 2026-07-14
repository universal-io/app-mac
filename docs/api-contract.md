# Bomb Squad API Contract

This document fixes the first stable contract between Bomb Squad clients and
the server-side product API.

Scope:

- macOS app
- future iOS app
- future Android app
- future web client
- initial Vercel-hosted AI gateway

The purpose of this file is to freeze the names and payload shapes before
implementation starts, so the client and server can move independently without
drift.

## Versioning

- Contract version: `v1`
- Base path: `/api`
- Implemented routes:
  - `POST /api/ai/review`
  - `POST /api/ai/transcribe` (2026-07-02, M3-B)
  - `POST /api/ai/memory/distill` (2026-07-02, M3-B)
  - `POST /api/ai/vision` (2026-07-02, M3-B)
  - `GET/PUT /api/memory/cards` (2026-07-02, M3-B)
  - `POST /api/ai/navigate` (2026-07-06, Navigator v3 — 契約は下記「Navigate」節)
  - `GET /api/account` (アカウント要約＋quota)
  - `GET /api/admin/overview` (admin console v0、`ADMIN_EMAILS` ゲート)

Future routes will reuse the same authentication and envelope conventions:

- `POST /api/ai/transform`
- `POST /api/ai/analyze-audio`

## Authentication

All product API requests must carry a Supabase access token.

Required header:

```http
Authorization: Bearer <supabase_access_token>
```

Optional header:

```http
X-Bomb-Squad-Request-Id: <uuid-or-client-generated-id>
```

Rules:

- The gateway verifies the Supabase JWT on every request.
- The gateway resolves `user_id` from the token, never from client-supplied
  body data.
- The client may send a request ID in both header and body. If both are
  present, they must match.

## Environment Variables

### macOS App

These names are reserved now, even if the first implementation reads them from
scheme environment variables, a plist, or a local config wrapper.

- `BOMB_SQUAD_API_BASE_URL`
- `BOMB_SQUAD_SUPABASE_URL`
- `BOMB_SQUAD_SUPABASE_ANON_KEY`

Notes:

- No server-side secret goes into the app.
- The app must never contain `SUPABASE_SERVICE_ROLE_KEY`.
- The app must never contain LLM provider API keys in the production path.

### Web / Vercel

Public client vars:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_BOMB_SQUAD_API_BASE_URL`

Server-only vars:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `BOMB_SQUAD_DEFAULT_MODEL_VENDOR`
- `BOMB_SQUAD_DEFAULT_MODEL_ID`
- `BOMB_SQUAD_VISION_MODEL_ID`
- `BOMB_SQUAD_NAVIGATE_MODEL_VENDOR`
- `BOMB_SQUAD_NAVIGATE_MODEL_ID`
- `BOMB_SQUAD_NAVIGATE_FAST_MODEL_VENDOR`
- `BOMB_SQUAD_NAVIGATE_FAST_MODEL_ID`
- `BOMB_SQUAD_NAVIGATE_PLANNER_MODEL_VENDOR`
- `BOMB_SQUAD_NAVIGATE_PLANNER_MODEL_ID`
- `BOMB_SQUAD_NAVIGATE_GROUNDER_MODEL_VENDOR`
- `BOMB_SQUAD_NAVIGATE_GROUNDER_MODEL_ID`
- `BOMB_SQUAD_NAVIGATE_V4_ENABLED`
- ~~`BOMB_SQUAD_FREE_MONTHLY_REVIEW_LIMIT`~~ **廃止（2026-07-08）**: free 枠上限は DB の
  `bs_plans` テーブルが正本（migration 0004。env にコピーを持たない）
- `OPENAI_API_KEY`
- `GROQ_API_KEY`
- `ANTHROPIC_API_KEY`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_PRO_MONTHLY`
- `STRIPE_PRICE_TEAM_MONTHLY`
- `STRIPE_PRICE_ENTERPRISE_MONTHLY`

Rules:

- `SUPABASE_URL` should match `NEXT_PUBLIC_SUPABASE_URL`.
- `SUPABASE_ANON_KEY` is available to both product site and client auth flows.
- `SUPABASE_SERVICE_ROLE_KEY` is server-only.
- Provider keys stay server-only.
- Planner/Grounderの役割別model envが未設定なら、通常Navigateのvendor/modelを継承する。

## API Conventions

### JSON

- Request and response bodies are JSON.
- Keys use `snake_case`.
- Unknown response keys should be ignored by clients.

### Idempotency

- `request_id` is required for all AI operations.
- The gateway uses `tenant_id + request_id` to prevent duplicate usage events.
- Client retries must reuse the same `request_id`.

### Time

- All timestamps are ISO 8601 UTC strings.

## POST /api/ai/review

This is the first route. It covers both current macOS modes:

- outgoing draft review: `mode = compose`
- received-message restructuring: `mode = transform`

### Request Body

```json
{
  "request_id": "8d74bb7a-54aa-4b7b-a947-b68f4a34b5d2",
  "operation": "review",
  "mode": "compose",
  "input": {
    "draft": "今日の会議なんだけど、先方の対応がかなり雑で困っています。"
  },
  "preferences": {
    "output_language": "japanese",
    "model_preference": {
      "vendor": "groq",
      "model_id": "openai/gpt-oss-120b"
    }
  },
  "client": {
    "platform": "macos",
    "app_version": "0.1.0",
    "build_number": "1",
    "device_id": "2f7e7e3b-6bdb-49f6-91f0-8f8f9c7d4f0f"
  }
}
```

### Optional Input Extensions (added 2026-07-02, Universal I/O M3)

`input` accepts two optional objects. Both are reference material for the
prompt; the gateway never persists them.

```json
{
  "input": {
    "draft": "...",
    "context": {
      "app_name": "Slack",
      "window_title": "Threads - Wealth Park",
      "conversation_excerpt": "（周辺会話の抜粋、最大2500文字目安）"
    },
    "memory": {
      "persona_md": "（ユーザーのスタイルプロファイル Markdown）",
      "relationship_subject": "Yumi Mukai",
      "relationship_md": "（相手カード Markdown）"
    }
  }
}
```

- `input.context`: L1 situational context captured at panel summon time.
- `input.memory`: persona/relationship cards. These live client-side until the
  memory sync API ships; clients send the already-selected cards per request.
- The gateway records only boolean flags (`has_context`, `has_memory`) in
  usage metadata, never the content.

### Streaming (added 2026-07-02, Universal I/O M3-C)

Set `"stream": true` at the top level of the request body to receive the
response as Server-Sent Events (`text/event-stream`):

- `event: delta` — `{"text": "..."}`, increments of `revised_text` as the
  model produces them (the prompt orders `revised_text` first so the
  deliverable streams immediately)
- `event: result` — the same JSON as the non-streaming success response
  (including `quota`); always the last event on success
- `event: error` — the same JSON as the error contract (auth/quota errors
  before the stream starts still return plain JSON status responses)

Usage is recorded exactly once per stream, after the provider stream ends.

### Request Fields

- `request_id`: required string
- `operation`: required string, must be `review` in v1
- `stream`: optional boolean (SSE response; see Streaming above)
- `mode`: required string, `compose` or `transform`
- `input.draft`: required string
- `preferences.output_language`: required string, `japanese` or `english`
- `preferences.model_preference.vendor`: optional string
- `preferences.model_preference.model_id`: optional string
- `client.platform`: required string, `macos`, `ios`, `android`, or `web`
- `client.app_version`: required string
- `client.build_number`: optional string
- `client.device_id`: optional string

Rules:

- If `mode = transform`, the route is still `/api/ai/review` in v1.
- `model_preference` is advisory. The gateway may ignore it based on plan,
  policy, or availability.
- Empty or whitespace-only `input.draft` is rejected with `BAD_REQUEST`.

### Success Response

```json
{
  "request_id": "8d74bb7a-54aa-4b7b-a947-b68f4a34b5d2",
  "result": {
    "issues": [
      {
        "category": "impoliteness",
        "severity": "medium",
        "excerpt": "かなり雑",
        "explanation": "相手への評価が直接的で、受け手に防御反応を起こしやすい表現です。",
        "suggestion": "事実ベースの困りごとに言い換えると伝わりやすくなります。"
      }
    ],
    "revised_text": "今日の会議について、先方対応で確認したい点がいくつかありました。",
    "summary": "表現のトゲを抑えつつ要点を残しました。"
  },
  "meta": {
    "mode": "compose",
    "output_language": "japanese",
    "model_vendor": "groq",
    "model_id": "openai/gpt-oss-120b",
    "latency_ms": 842
  },
  "quota": {
    "plan": "free",
    "used": 12,
    "limit": 500,
    "remaining": 38,
    "resets_at": "2026-07-01T00:00:00Z"
  }
}
```

### Success Response Notes

- `result` matches the existing macOS `ReviewResult` shape.
- `issues[].category` values:
  - `typo`
  - `impoliteness`
  - `unclear`
- `issues[].severity` values:
  - `low`
  - `medium`
  - `high`
- `quota` is returned on success so clients can show remaining allowance
  without a separate request.

## Error Contract

Error responses must follow this shape:

```json
{
  "error": {
    "code": "QUOTA_EXCEEDED",
    "message": "Free plan monthly review limit reached.",
    "details": {
      "plan": "free",
      "used": 50,
      "limit": 500,
      "resets_at": "2026-07-01T00:00:00Z"
    }
  },
  "request_id": "8d74bb7a-54aa-4b7b-a947-b68f4a34b5d2"
}
```

### Standard Error Codes

- `BAD_REQUEST`
  - HTTP 400
  - Invalid body, missing fields, empty draft
- `UNAUTHENTICATED`
  - HTTP 401
  - Missing or invalid Supabase token
- `TENANT_ACCESS_DENIED`
  - HTTP 403
  - User token valid but tenant access invalid
- `PAYMENT_REQUIRED`
  - HTTP 402
  - Plan or entitlement does not allow requested operation/model
- `QUOTA_EXCEEDED`
  - HTTP 429
  - Free or paid usage cap reached
- `PROVIDER_ERROR`
  - HTTP 502
  - Upstream LLM provider failed
- `INTERNAL_ERROR`
  - HTTP 500
  - Unclassified server failure

Client behavior:

- `UNAUTHENTICATED`: prompt sign-in
- `TENANT_ACCESS_DENIED`: show account/tenant error
- `PAYMENT_REQUIRED`: show upgrade/paywall path
- `QUOTA_EXCEEDED`: show remaining-cycle limit message
- `PROVIDER_ERROR`: retryable server-side failure message

## Mapping To Existing macOS Models

Current macOS types already match most of the response contract:

- `ReviewResult`
- `ReviewIssue`
- `IssueCategory`
- `Severity`
- `ReviewMode`
- `OutputLanguage`

Expected client mapping:

- `response.result` -> `ReviewResult`
- `response.meta.latency_ms` -> `ReviewViewModel.lastDurationMs`
- `response.meta.model_vendor + model_id` -> display string
- `response.quota` -> future account/quota UI

## POST /api/ai/transcribe

Added 2026-07-02 (Universal I/O M3-B). Speech-to-text proxy.
The gateway owns the provider keys and the hallucination filter.

Updated 2026-07-03（可用性の原則）: primary は Groq `whisper-large-v3`（15秒
タイムアウト）。プロバイダ障害・レート制限・タイムアウト時は **OpenAI
`whisper-1` へ自動フォールバック**する（別ベンダーなので Groq 全断でも共倒れ
しない）。`meta.model_vendor` / `model_id` に実際に使ったエンジンが入り、
`bs_usage_events` にも記録される。全エンジン失敗時のみ `PROVIDER_ERROR`。

### Request (multipart/form-data)

- `request_id`: required string
- `platform`: required string, `macos`, `ios`, `android`, or `web`
- `app_version`: optional string
- `file`: required audio upload (m4a; max 25MB)

### Success Response

```json
{
  "request_id": "...",
  "result": { "text": "文字起こし結果" },
  "meta": {
    "model_vendor": "groq",
    "model_id": "whisper-large-v3",
    "duration_seconds": 4.2,
    "latency_ms": 950
  }
}
```

### Rules

- Entitlement must be active or trialing; there is no hard ASR quota yet.
  Usage events are recorded (`operation = transcribe`, `unit_type = seconds`,
  `input_units` = rounded audio duration) so a cap can be enforced later.
- The audio content is never persisted by the gateway.

## POST /api/ai/memory/distill

Added 2026-07-02 (Universal I/O M3-B). Memory-card LLM calls: persona
bootstrap (onboarding) and post-deploy distillation. Card storage stays
client-side until the memory sync API ships; the gateway never persists
any of this content.

### Request Body

```json
{
  "request_id": "...",
  "operation": "bootstrap",
  "input": {
    "samples": "（bootstrap: 過去メッセージのサンプル）",
    "original": "（distill: ユーザーの下書き）",
    "suggestion": "（distill: AI 提案文）",
    "final": "（distill: 実際に送信した文）",
    "context": { "app_name": "Slack", "window_title": "...", "conversation_excerpt": "..." }
  },
  "client": { "platform": "macos", "app_version": "0.1.0" }
}
```

- `operation`: required, `bootstrap` or `distill`
- `bootstrap` requires `input.samples`; `distill` requires
  `input.original` / `input.suggestion` / `input.final` (`input.context` optional)

### Success Response

- `bootstrap`: `result = { "persona_md": "（スタイルプロファイル Markdown）" }`
- `distill`: `result = { "persona_note": string | null, "relationship_subject": string | null, "relationship_note": string | null }`
- `meta`: `operation`, `model_vendor`, `model_id`, `latency_ms`

Usage events: `operation = memory_distill`, `unit_type = call`, token counts
in `input_units` / `output_units`.

## POST /api/ai/vision

Added 2026-07-02 (Universal I/O M3-B). Interpretation of a screenshot or a
received message (OpenAI Responses API). Neither source is persisted by the
gateway.

Updated 2026-07-03 (M4): the response schema became "see → understand →
respond" (`situation` / `extracted` / `asks` / `suggested_actions` with reply
drafts), and the request accepts the same optional `context` / `memory`
blocks as `POST /api/ai/review` (prompt-only, never stored).

Updated 2026-07-03 (M4-B): the receiving side is a special case of
interpretation — `input.text`（受信メッセージ、最大16,000文字）を
`input.image_base64` の代わりに渡せる。**どちらか一方が必須**（両方・ゼロは
`BAD_REQUEST`）。text の場合 `extracted` は「攻撃性・感情・皮肉を除いた
中立な整理版」になる。

### Request Body

```json
{
  "request_id": "...",
  "operation": "vision",
  "input": {
    "image_base64": "（base64。最大4M文字 ≒ 3MB。text と排他）",
    "media_type": "image/png",
    "text": "（受信メッセージ。image_base64 と排他。最大16,000文字）",
    "instruction": "（任意の追加指示）",
    "context": {
      "app_name": "Mail",
      "window_title": "（任意）",
      "conversation_excerpt": "（任意。AX で取れた周辺テキスト）"
    },
    "memory": {
      "persona_md": "（任意。L3 Persona Card）",
      "relationship_subject": "（任意）",
      "relationship_md": "（任意。L2 Relationship Card）"
    }
  },
  "preferences": { "output_language": "japanese" },
  "client": { "platform": "macos", "app_version": "0.1.0" }
}
```

- `media_type`: `image/png` or `image/jpeg`. Clients should re-encode large
  PNG captures as JPEG to stay under the size limit (Vercel body cap ~4.5MB).
- `context` / `memory` are optional and used only to build the prompt
  (recipient/tone inference and persona-aware reply drafts).

### Success Response

`result` is the interpretation JSON as produced by the model; clients decode
it flexibly (legacy `summary` / `visible_text` shapes are still accepted
client-side):

```json
{
  "situation": "この画面で何が起きているかの要約（1-2文）",
  "extracted": "画面から読み取った本文（構造化 Markdown）",
  "asks": ["あなたに求められていること（依頼・期限・事実）"],
  "suggested_actions": [
    {
      "title": "田中さんへ返信する",
      "kind": "reply | fill_form | task | info_only",
      "draft": "kind=reply の場合、Persona/Relationship を反映した返信文案"
    }
  ]
}
```

`meta` carries `output_language`, `model_vendor`, `model_id`, `latency_ms`.

Usage events: `operation = vision`, `unit_type = call`, with
`input_kind`（`image` / `text`）and `has_context` / `has_memory` flags in the
metadata. There is no hard Vision quota yet (same policy as transcribe).

## GET/PUT /api/memory/cards

Added 2026-07-02 (Universal I/O M3-B). Memory-card sync: persona/relationship
cards authored client-side (bootstrap, distill, user edits) live in local
SQLite; this route is the only place they leave the device, so a signed-in
user's cards are shared across their Macs. There is no separate quota check
beyond the standard entitlement gate, and no usage event is recorded (these
are not LLM calls).

There is no `DELETE`. A deletion is expressed as a tombstone: the client sets
`deleted_at` on the card and sends it through `PUT` like any other update.

### Card Object

All timestamps are epoch seconds (`number`), matching the client's SQLite
representation -- this is the one place in the contract where timestamps are
not ISO 8601 strings, since the card's `created_at`/`updated_at` are compared
directly against the client's local logical clock.

```json
{
  "id": "8d74bb7a-54aa-4b7b-a947-b68f4a34b5d2",
  "kind": "persona",
  "subject": null,
  "content_md": "（カード本文 Markdown）",
  "source": "bootstrap",
  "created_at": 1751500800.0,
  "updated_at": 1751500800.0,
  "deleted_at": null
}
```

- `id`: required, client-generated UUID. Stable across syncs; also the
  server-side primary key.
- `kind`: required, `persona` or `relationship`.
- `subject`: optional string, null for `persona` cards; the counterpart name
  for `relationship` cards.
- `content_md`: required string.
- `source`: required, `bootstrap`, `distilled`, or `user_edited`.
- `created_at` / `updated_at`: required numbers (epoch seconds). `updated_at`
  is the client's logical clock, not a server timestamp, and is what conflict
  resolution compares.
- `deleted_at`: number or `null`. Non-null marks the card as a tombstone.

### GET /api/memory/cards

Returns every card owned by the authenticated user, including tombstones, so
the client can reconcile local deletes with cards it hasn't seen yet.

```json
{ "cards": [ /* Card Object, see above */ ] }
```

### PUT /api/memory/cards

Body: the client's full local card set.

```json
{ "cards": [ /* Card Object, see above; max 200 entries */ ] }
```

Rules:

- `cards` is required, an array, and capped at 200 entries; a malformed card
  (bad `kind`/`source` enum, wrong field type, missing required field) or an
  oversized array is rejected with `BAD_REQUEST` for the whole request.
- `tenant_id` and `user_id` are never read from the request body; the gateway
  stamps every written row with the values resolved from the caller's access
  token.
- **Conflict resolution is last-write-wins on `updated_at`.** For each
  incoming card:
  - if no row with that `id` exists yet, it is inserted;
  - if a row exists and belongs to the caller, it is overwritten only when
    `incoming.updated_at` is strictly greater than the stored value;
  - if a row exists but belongs to a different user (an `id` collision), the
    incoming card is silently skipped rather than overwritten.
- The response is the **merged full server state** for the caller (same
  shape as `GET`), so a single `PUT` round trip also completes a pull --
  clients do not need to follow a `PUT` with a `GET`.

### Success Response

```json
{ "cards": [ /* Card Object, see above */ ] }
```

## Deferred Routes

These are reserved but not implemented in the first pass.

### POST /api/ai/analyze-audio

Expected future use:

- emotion analysis
- acoustic event analysis
- long-running or async worker path

## Navigate（画面ナビゲーター、2026-07-06 追加・実装済み）

`POST /api/ai/navigate` — Navigator/Copilot の中核。**常に SSE**（`accept: text/event-stream`）。
実装: `web/app/api/ai/navigate/route.ts` + `web/lib/server/navigate-engine.ts`（プロンプト・
モデル段階選択・ハーネス選択はサーバー所有）。クライアント: `GatewayNavigateClient`。

**2026-07-14 v4 shadow contract**: user messageは、従来の画像/OCRに加えて同じcaptureの
`observation` v1を任意で送れる。Gatewayはstrictに検証して計測するが、現段階のprovider promptと
レスポンスはv3のまま。旧クライアントは`observation`無しで引き続き動く。1リクエストに送れるのは
最新Observation 1件だけで、assistant messageには付けられない。

リクエスト（共通エンベロープ準拠）:

```json
{
  "request_id": "uuid",
  "operation": "navigate",
  "input": {
    "messages": [
      { "role": "user",
        "text": "任意（auto first turn は text 無しの画像のみ）",
        "image_base64": "最新キャプチャのみ", "media_type": "image/jpeg",
        "ocr_text": "最新キャプチャのローカルOCR全文",
        "observation": {
          "schema_version": 1,
          "capture_id": "uuid",
          "captured_at": "ISO 8601 UTC",
          "capture_scope": "display | region | unknown",
          "coordinate_space": "normalized_top_left",
          "pixel_size": { "width": 1600, "height": 1000 },
          "screen_rect": { "x": 0, "y": 0, "width": 1440, "height": 900 },
          "environment": {
            "app_name": "Google Chrome",
            "bundle_id": "com.google.Chrome",
            "window_title": "アナリティクス",
            "url": "https://analytics.google.com/"
          },
          "transition_state": "stable",
          "candidates": [
            {
              "id": "ocr:0",
              "source": "ocr",
              "role": "text",
              "label": "ユーザー属性",
              "rect": { "x": 0.1, "y": 0.2, "width": 0.2, "height": 0.05 },
              "parent_label": "任意",
              "states": ["expanded"]
            }
          ]
        } }
    ],
    "hints": { "app_name": "...", "window_title": "..." },
    "task": {
      "goal": "...",
      "steps": [{ "verbal": "...", "target": "画面上の正確なラベル", "fill": "任意" }],
      "current_step": 0
    }
  },
  "preferences": { "output_language": "japanese" },
  "client": { "platform": "macos", "app_version": "...", "build_number": "..." }
}
```

- v3の`input.task`はクライアント輸送のステッププラン（プランはデータであり、モデルが毎ターン
  再導出しない）。無ければ通常の Q&A ターン。v4では下記のGateway-owned Runへ移す。
- 画像・OCR は**最新キャプチャの1つだけ**が乗る（過去分はテキストプレースホルダ化）。
- `observation.capture_id` はcaptureのUUID。candidate IDは同一capture内で安定し、別captureを
  またいだ同一性は保証しない。
- candidate `rect` は画像左上原点、0〜1正規化。画像外にはみ出すrect、500件超のcandidate、
  未知フィールドは`BAD_REQUEST`。
- candidate `states` は `selected / expanded / collapsed / disabled / focused / loading /
  checked / unchecked` の既知状態だけを受理する。
- `environment` は画面認識の状況であり、認証identityではない。`tenant_id` / `user_id` は
  クライアントObservationから絶対に受け取らず、従来どおりJWTからGatewayが確定する。
- `hints` はv3互換の移行用。v4ではObservation environmentからContextを解決するが、shadow期間は
  provider/harnessの挙動を変えないため従来hintsも併送する。
- Gateway usage metadataには本文を保存せず、Observation有無、schema version、capture scope、
  transition state、candidate件数/sourceだけを記録する。

### v4 Run snapshot（移行先・未有効）

v4 feature flagでRunを有効にした後は、Gatewayがrunの唯一のwriterとなる。clientは直前の
`run_snapshot`をrequestでechoし、responseのsnapshotで必ず置換する。

```json
{
  "run_snapshot": {
    "run_id": "uuid",
    "pack": { "id": "ga4", "version": "1" },
    "plan": {
      "id": "uuid",
      "version": 1,
      "hash": "sha256:...",
      "signature": "gateway-signed-token",
      "task": {
        "goal": "...",
        "steps": [
          {
            "id": "step-1",
            "verbal": "...",
            "target": "...",
            "fill": null,
            "postconditions": []
          }
        ]
      }
    },
    "current_step": 0,
    "status": "active",
    "revision": 3,
    "expires_at": "ISO 8601 UTC"
  }
}
```

- `tenant_id` / `user_id` はsnapshotにもrequest bodyにも含めずJWTから確定する。Gatewayのrun rowは
  `run_id / tenant_id / user_id / pack id+version / plan id+version+hash / current_step / status /
  revision / created_at / updated_at / expires_at` だけを保存する。
- clientが送ったrevision、plan hash/signatureがrun rowと一致しない場合はstepを進めない。
  Gatewayは最新snapshotを返し、clientは再同期する。client単独の`current_step`更新は禁止。
- `status` は `active / ambiguous / blocked / complete / cancelled / expired`。active/terminalとも
  最終操作から24時間以内にpurgeする。
- screenshot、OCR、candidate label/rect、会話、モデル自由文はrun row/usage traceへ保存しない。
  signed Task snapshotはclientが輸送し、server rowにはhashだけを置く。
- step更新はtyped postconditionのrule-first Verifier結果だけで行う。曖昧時はmodel verifierへ
  strict schemaでescalateするが、自由文本文や`[[step:done]]`をrevision更新の根拠にしない。

SSE イベント: `delta`（`{"text": "..."}` の増分）→ `result`
（`{"result": {"text", "harness", "task", "grounding"}, "meta": {"model_id"}}`）。
feature flag下の `grounding` は `{capture_id, candidate_id, confidence, method}` または `null` の
加算フィールドで、
`BOMB_SQUAD_NAVIGATE_V4_ENABLED` が未設定／falseの間は常に `null`。shadow期間は従来markerを
置き換えない。エラーは `error` イベント
または非 2xx の JSON（共通エラー契約）。`result.text` には決定論マーカー
`[[target:ラベル]]` / `[[loc:x0,y0,x1,y1]]` / `[[step:done]]` / `[[fill:テキスト]]` が埋め込まれ、
クライアント（`NavigatorLocator`）が抽出して OCR grounding と突き合わせる
（詳細は [navigator-copilot-plan.md](navigator-copilot-plan.md)）。

## Account / Admin（実装済み・簡易記載）

- `GET /api/account` — アカウント要約（email / tenant_id / plan / status /
  monthly_review_limit）＋ `quota` エンベロープ。プラン→機能は `bs_plans` 由来の
  `features` を含む。
- `GET /api/admin/overview` — 管理コンソール v0 の集計。`ADMIN_EMAILS` に列挙された
  メールのユーザーのみ 200（それ以外 403）。読み取り専用。

## Implementation Rule

Before building the macOS `BombSquadAPIClient` or the Next.js route handler,
both sides should use this document as the source of truth for:

- environment variable names
- request body fields
- response envelope
- error codes
