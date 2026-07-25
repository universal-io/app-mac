# Universal I/O Gateway API契約

最終更新: 2026-07-25 ／ ステータス: 現行

## 共通

- Base URL: `https://api.universal-io.com/api`
- 認証: `Authorization: Bearer <Supabase access token>`
- Content-Type: `application/json`（transcribeのみmultipart）
- macOSクライアントにローカルGateway、BYOK、別endpointへのfallbackはない。
- Gateway内のモデル順序は `web/lib/server/ai-routing.ts` が唯一の正本。全AI機能が一次・二次を
  1つずつ持ち、一次失敗時だけ二次を1回実行する。
- `request_id` は全AIリクエストで必須。
- `review`、`transcribe`、`transform`、`vision`、`suggest`の各routeは
  認証付きGETをウォームアップとして受け付ける。認証・quota前処理だけを実行して成功時`204`を返し、
  providerを呼ばずusageも記録しない。
- POSTのusage記録は応答後に実行するため、成功・モデルエラーとも記録DBの待ち時間を応答へ加えない。

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

主なcodeは `BAD_REQUEST`、`UNAUTHENTICATED`、`REAUTH_REQUIRED`、`PAYMENT_REQUIRED`、
`QUOTA_EXCEEDED`、`RATE_LIMITED`、`PROVIDER_ERROR`、`INTERNAL_ERROR`。

全AI成功応答の `meta` は次のモデル情報を持つ。

```json
{
  "model_vendor": "openai",
  "model_id": "gpt-5.6-luna",
  "api": "responses",
  "fallback_used": false,
  "notices": []
}
```

二次モデルで成功した場合は `fallback_used: true` とし、`notices` に必ず次を返す。

```json
{
  "severity": "warning",
  "code": "MODEL_FALLBACK",
  "message": "一次モデルにアクセスできなかったため、二次モデルで処理しました。"
}
```

macOSはnoticeをユーザーへ表示する。両モデルが失敗した場合は `PROVIDER_ERROR` と共通文言
「一次モデルと二次モデルの両方が応答しませんでした。少し待ってから再試行してください。」
を返す。三番目のモデルや別endpointは試さない。

## POST /ai/review

入力文章をレビューする。通常応答はSSEで、`delta`の後に最終`result`を返す。

- `operation`: `review`
- `input.draft`: 必須
- `input.context`: 任意
- 実装: `web/app/api/ai/review/route.ts`
- クライアント: `GatewayReviewClient`

## POST /ai/transcribe

音声を文字起こしする。一次はGroq `whisper-large-v3-turbo`、二次はOpenAI `whisper-1`。
16 kHz mono WAVを推奨する。

- multipart fields: `file`, `request_id`, `platform`, `app_version`（任意）、`language`（`ja` / `en`、任意）
- 実装: `web/app/api/ai/transcribe/route.ts`
- クライアント: `GatewayTranscriber`

POST成功応答の`meta.timing_ms`と`Server-Timing`は
`auth` / `quota` / `provider` / `usage` / `total`のミリ秒内訳を返す。

## POST /ai/transform

選択された受信文章を整理し、状況・依頼・返信案を返す。

- `operation`: `transform`
- `input.text`: 必須、最大16,000文字
- `input.context`: 任意
- 実装: `web/app/api/ai/transform/route.ts`
- クライアント: `GatewayTransformClient`

## POST /ai/vision

固定したスクリーンショットを読み、初期説明、質問回答、次の操作、Copilot進捗を
同一契約で返す。1回の試行につきVLM呼び出しは1回とし、一次失敗時だけ共通ルーターが
二次モデルを1回試す。旧Navigator endpointへは切り替えない。

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
    "latency_ms": 0,
    "notices": []
  }
}
```

クライアントはcapture ID、route、画像detail、reasoning設定を検証する。モデルIDと
`fallback_used` はGatewayのSSOTを受け入れ、fallback時はnoticeを表示する。

## POST /ai/suggest

コンポーズ起動時に前倒しで撮った同一スクリーンショットを読み、いまフォーカス中の
入力フォームに入れるべき文案を1件返す（先回りサジェスト）。Visionが「画面の解釈」なのに対し
本ルートは「入力すべき本文の生成」で、目的が逆。1回の試行につきモデル呼び出しは1回、
一次失敗時だけ共通ルーターが二次モデルを1回試す。

- `operation`: `suggest`
- `input.capture_id`: 必須
- `input.image_base64`: 必須、PNG/JPEG
- `input.context`: 任意（`app_name` / `bundle_id` / `window_title` / `conversation_excerpt`）。
  参照専用で保存しない。`bundle_id`等から該当するアプリ文脈添付を選ぶ
- 実装: `web/app/api/ai/suggest/route.ts`
- クライアント: `GatewaySuggestClient`

成功応答:

```json
{
  "request_id": "uuid",
  "capture_id": "uuid",
  "result": {
    "draft": "フォームに入れるべき文案（提案できない時は空文字）",
    "note": "検出したフォームと提案意図の一言"
  },
  "meta": {
    "model_vendor": "openai",
    "model_id": "gpt-5.6-luna",
    "route": "snapshot_suggest",
    "api": "responses",
    "image_detail": "original",
    "reasoning_effort": "medium",
    "prompt_version": "speaker-grounding-v2",
    "context_package": "slack",
    "fallback_used": false,
    "latency_ms": 0,
    "notices": []
  }
}
```

`draft` は編集可能な提案で、ユーザーが紙飛行機を確定すると対象欄へ直接入力する。
`note` は検証中の認知表示で、最新の送信者、宛先、ユーザーの立場、添付所有者、依頼、返信意図を示す。
`context_package`は適用無しの場合`null`。
画像・入力本文・回答本文はusageに保存しない（運用情報のみ）。

## アカウント・管理

- `GET /account`
- `DELETE /account` — body `{"confirmation":"DELETE"}`。直近10分以内の認証を要求し、
  有効なsubscriptionがある場合は`ACTIVE_SUBSCRIPTION`で拒否する。
- `GET /admin/overview`

v3で文体・関係性メモリを廃止したため、`/ai/memory/distill` と `/memory/cards` は存在しない。
`input.memory`を送るクライアントも無い。ユーザーに関する事実の記憶はv3で別機構として設計する
（正本 [v3-tool-fit-plan.md](v3-tool-fit-plan.md)）。

各routeの入力検証と認可は `web/app/api` の現行実装を正とする。
