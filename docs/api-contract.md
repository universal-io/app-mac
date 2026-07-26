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
- `input.context`: 任意（`app_name` / `bundle_id` / `window_title` / `host`、各1,024文字まで）。
  Skill判定と画面の出所提示のためだけの参照データで保存しない。判定規則はsuggestと同じで、
  `host`が一次シグナル、ネイティブアプリは`bundle_id`。`candidate_diagnostics`には
  アプリ名・ウインドウタイトルを入れない（あちらはusageへ渡る運用情報）
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
    "target_candidate_id": null,
    "skill": { "id": "gmail", "name": "Gmail" }
  },
  "meta": {
    "model_vendor": "openai",
    "model_id": "gpt-5.6-luna",
    "route": "snapshot_vlm",
    "api": "responses",
    "image_detail": "original",
    "reasoning_effort": "none",
    "skill": "gmail",
    "fallback_used": false,
    "latency_ms": 0,
    "notices": []
  }
}
```

クライアントはcapture ID、route、画像detail、reasoning設定を検証する。モデルIDと
`fallback_used` はGatewayのSSOTを受け入れ、fallback時はnoticeを表示する。

`result.skill` はsuggestと同じ意味で、適用したSkillが無ければ`null`。macOSはVisionパネルと
Copilotストリップの両方に名前を表示する。Visionへ渡すセクションはreading / affordances /
attentionで、attentionは列挙禁止の抑制ルールとして渡す（確実で、いま聞かれたことより
緊急な場合に1件だけ）。

## POST /ai/suggest

コンポーズ起動時に前倒しで撮った同一スクリーンショットを読み、いまフォーカス中の
入力フォームに入れるべき文案を1件返す（先回りサジェスト）。Visionが「画面の解釈」なのに対し
本ルートは「入力すべき本文の生成」で、目的が逆。1回の試行につきモデル呼び出しは1回、
一次失敗時だけ共通ルーターが二次モデルを1回試す。

- `operation`: `suggest`
- `input.capture_id`: 必須
- `input.image_base64`: 必須、PNG/JPEG
- `input.context`: 任意（`app_name` / `bundle_id` / `window_title` / `host` /
  `conversation_excerpt`）。参照専用で保存しない。Skillの判定は`host`を一次シグナルとし、
  ネイティブアプリは`bundle_id`、補助として`app_name`・`window_title`を使う。
  `host`はブラウザ表示中のページのホスト名だけで、パスとクエリは送らない
- 実装: `web/app/api/ai/suggest/route.ts`
- クライアント: `GatewaySuggestClient`

成功応答:

```json
{
  "request_id": "uuid",
  "capture_id": "uuid",
  "result": {
    "draft": "フォームに入れるべき文案（提案できない時は空文字）",
    "note": "検出したフォームと提案意図の一言",
    "skill": { "id": "slack", "name": "Slack" },
    "fact_question": {
      "scope": "slack",
      "scope_label": "Slack",
      "key": "account_name",
      "label": "Slackでの表示名",
      "value": "Kaya Matsumoto",
      "question": "Slackでの表示名は「Kaya Matsumoto」ですか？"
    }
  },
  "meta": {
    "model_vendor": "openai",
    "model_id": "gpt-5.6-luna",
    "route": "snapshot_suggest",
    "api": "responses",
    "image_detail": "original",
    "reasoning_effort": "medium",
    "prompt_version": "responder-mission-v5-facts",
    "skill": "slack",
    "fallback_used": false,
    "latency_ms": 0,
    "notices": []
  }
}
```

`draft` は編集可能な提案で、ユーザーが紙飛行機を確定すると対象欄へ直接入力する。
`note` は検証中の認知表示で、最新の送信者、宛先、ユーザーの立場、添付所有者、依頼、
依頼の実行者、返信意図を示す。

`result.skill` は適用したSkill（画面上の製品に関する注入知識）で、該当が無ければ`null`。
macOSはこの名前をパネルに表示する。Skillのサイレント注入は禁止で、クライアントが表示できない
形で知識を注入しない。`meta.skill`は同じものをusage用にidだけで持つ。
画像・入力本文・回答本文はusageに保存しない（運用情報のみ）。

`result.fact_question` は**ユーザー本人に関する事実の確認質問**で、候補が無ければ`null`。
検出専用の呼び出しは作らず、この構造化出力に`fact_candidate`を1つ足すだけなので追加の
レイテンシもコストも無い。仕様:

- 1応答につき最大1件。モデルはGatewayが渡した**askableスロットのenumからidを選ぶだけ**で、
  キーを創作できない。該当が無ければ空文字を返す
- askableスロット＝有効Skill＋globalの語彙から、**保存済み・拒否済み・打ち切り済み（通算3回）**を
  除いたもの。空なら`fact_candidate`はスキーマからもプロンプトからも消え、従来と同一の呼び出しになる
- `value`は画面から読み取った文字列。Gatewayが制御文字除去・空白畳み・120文字上限で正規化し、
  `question`もGatewayが組み立てる（値は必ず引用符の中。プロンプトインジェクション対策）
- `meta`/usageには`fact_question_asked`（真偽）だけを記録し、キーも値も残さない
- 質問を返した時点で`bs_fact_prompts.ask_count`を応答後に加算する。答えずに閉じても1回として数え、
  通算3回でそのキーを打ち切る

## ユーザーファクト

`/api/facts` はSkillsが宣言したキー語彙に沿って、ユーザー本人に関する事実を保持する。
AI呼び出しもusage記録も行わない。プランが失効していても閲覧・編集できる（アカウント情報と同じ扱い）。

- `GET /api/facts` — 語彙の全スロットを返す。未登録スロットは`value: null`で含める
  （アプリが何を覚え得るかを見せるのが目的で、覚えた分だけを見せるのではない）
- `PUT /api/facts` — body `{"scope","key","value"}`。**語彙に無いキーは`UNKNOWN_FACT_KEY`で拒否**する。
  これがストア肥大化に対する唯一のガードレール。値は制御文字を除去し、連続空白を畳んで
  最大120文字
- `POST /api/facts` — body `{"scope","key","decision":"declined"}`。確認質問への「いいえ」を記録し、
  そのキーを二度とたずねない。「はい」は`PUT`だけで足りる（保存済みキーは再質問対象から外れる）
- `DELETE /api/facts` — body `{"scope","key"}`。語彙から外れた過去キーも削除できる
  （Skill廃止後に残った行をユーザーが消せなくなるため、語彙検査は書き込みだけに掛ける）
- 実装: `web/app/api/facts/route.ts` ／ クライアント: `GatewayFactsClient`
- 質問の抑制状態は`bs_fact_prompts`（`ask_count` / `declined_at`）に持ち、値そのものは
  `bs_user_facts`にしか置かない。ユーザーごとの状態参照は`web/lib/server/facts-store.ts`が唯一の窓口で、
  語彙（`web/lib/server/skills/`）は純粋なデータのまま保つ

```json
{
  "facts": [
    {
      "scope": "slack",
      "scope_label": "Slack",
      "key": "account_name",
      "label": "Slackでの表示名",
      "value": "Kaya Matsumoto",
      "updated_at": "2026-07-26T00:00:00Z"
    }
  ],
  "max_value_chars": 120
}
```

`scope`は`global`かSkillのid。`label`／`scope_label`はGateway側（Skill定義）が持ち、
macOSは表示するだけ。ツールを1つ増やしてもクライアントは変更しない。
全件でも数十行のため、cursor・差分・tombstoneは持たない。

## アカウント・管理

- `GET /account`
- `DELETE /account` — body `{"confirmation":"DELETE"}`。直近10分以内の認証を要求し、
  有効なsubscriptionがある場合は`ACTIVE_SUBSCRIPTION`で拒否する。
- `GET /admin/overview`

v3で文体・関係性メモリを廃止したため、`/ai/memory/distill` と `/memory/cards` は存在しない。
`input.memory`を送るクライアントも無い。ユーザーに関する事実の記憶はv3で別機構として設計する
（正本 [v3-tool-fit-plan.md](v3-tool-fit-plan.md)）。

各routeの入力検証と認可は `web/app/api` の現行実装を正とする。
