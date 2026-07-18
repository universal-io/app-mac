# Universal I/O Gateway API契約

最終更新: 2026-07-18 ／ ステータス: 現行

## 共通

- Base URL: `https://api.universal-io.com/api`
- 認証: `Authorization: Bearer <Supabase access token>`
- Content-Type: `application/json`（transcribeのみmultipart）
- macOSクライアントにローカルGateway、BYOK、別経路への自動フォールバックはない。
- `request_id` は全AIリクエストで必須。

共通JSON envelope:

```json
{
  "request_id": "uuid",
  "operation": "review",
  "input": {},
  "preferences": { "output_language": "japanese" },
  "client": { "platform": "macos", "app_version": "0.1.0" }
}
```

共通エラー:

```json
{
  "request_id": "uuid-or-null",
  "error": { "code": "BAD_REQUEST", "message": "..." }
}
```

主なcodeは `BAD_REQUEST`、`UNAUTHENTICATED`、`PAYMENT_REQUIRED`、
`QUOTA_EXCEEDED`、`RATE_LIMITED`、`PROVIDER_ERROR`、`INTERNAL_ERROR`。

## POST /ai/review

入力文章をレビューする。通常応答はSSEで、`delta`の後に最終`result`を返す。

- `operation`: `review`
- `input.draft`: 必須
- `input.context` / `input.memory`: 任意
- 実装: `web/app/api/ai/review/route.ts`
- クライアント: `GatewayReviewClient`

## POST /ai/transcribe

音声を文字起こしする。

- multipart fields: `file`, `request_id`, `language`
- 実装: `web/app/api/ai/transcribe/route.ts`
- クライアント: `GatewayTranscriber`

## POST /ai/transform

選択された受信文章を整理し、状況・依頼・返信案を返す。

- `operation`: `transform`
- `input.text`: 必須、最大16,000文字
- `input.context` / `input.memory`: 任意
- 実装: `web/app/api/ai/transform/route.ts`
- クライアント: `GatewayTransformClient`

## POST /ai/vision

固定したスクリーンショットを読み、初期説明、質問回答、次の操作、Copilot進捗を
同一契約で返す。認知コアは1回のVLM呼び出しで、旧Navigator endpointや別モデルへの
自動切り替えは行わない。

- `operation`: `vision`
- `input.capture_id`: 必須
- `input.image_base64`: 必須、PNG/JPEG
- `input.question`: 任意
- `input.turns`: 最大20件
- `input.candidates`: 同一captureから取得したAX/DOM候補、最大500件
- `input.guidance`: Copilot進捗時の目的と直前案内。`question`とは排他
- 実装: `web/app/api/ai/vision/route.ts`
- クライアント: `GatewayVisionClient`

成功応答:

```json
{
  "request_id": "uuid",
  "capture_id": "uuid",
  "result": {
    "mode": "observation",
    "message": "...",
    "observations": [],
    "uncertainties": [],
    "target_candidate_id": null
  },
  "meta": {
    "model_vendor": "openai",
    "model_id": "gpt-5.6-luna",
    "route": "snapshot_vlm",
    "api": "responses",
    "image_detail": "original",
    "reasoning_effort": "none",
    "fallback_used": false,
    "latency_ms": 0
  }
}
```

クライアントはcapture ID、モデル設定、`fallback_used == false`を検証し、不一致なら
結果を採用しない。

## POST /ai/memory/distill

送信差分またはユーザー提供サンプルから、保存候補となるスタイル情報を抽出する。

- `operation`: `distill` または `bootstrap`
- 実装: `web/app/api/ai/memory/distill/route.ts`
- クライアント: `MemoryDistiller`

## アカウント・メモリ・管理

- `GET /account`
- `GET|POST|PATCH|DELETE /memory/cards`
- `GET /admin/overview`

各routeの入力検証と認可は `web/app/api` の現行実装を正とする。
