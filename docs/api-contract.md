# Universal I/O Gateway API契約

最終更新: 2026-08-01 ／ ステータス: 現行（`v0.2.1`正式公開済み）＋R10 Selection Extension契約

R9 A7でproduction buildのroute一覧とmacOSクライアントを再照合し、AI endpointが
`review`、`suggest`、`transcribe`、`vision`の4つだけであることを確認した。
旧`transform` routeと互換endpointは存在しない。署名付きアプリによる本番機能確認も完了し、
Focused Visionは`0.2.1` build `5`で正式採用した。

2026-07-30にmain `6bc471a`を本番へdeployし、認証なしprobeで現行4 routeが共通JSON
`UNAUTHENTICATED`を返し、旧`/api/ai/transform`が404であることを確認した。

R10の`selection`契約は2026-08-01に`feat/vision-selection-extension`から`main`／本番Gatewayへ
macOS候補版より先に配備した。旧`focus_target`／`visual_selection_hint`を同じ内部型へ正規化するため、
`v0.2.1`クライアントも引き続き動作する。配備前検証ではGateway 14件、lint、TypeScript、production
buildと、通常requestから`selection`だけが増えるmacOS request比較が成功した。

同日のC6実機テストで、選択していない画面にも選択用promptが常に付く不具合を確認した（R10.5）。
`selection` wireは積極的に取得できた選択テキストからのみ作り、`visual_only`／
`accessibility_element`／`visual_selection_hint`はGatewayが**受理した上で無視**する（400にはしない
— validationは正規化より先に走るため、拒否すると現行クライアントのVisionセッションごと失敗する）。

`selection`が無いrequestは「ユーザーが選択していない」を意味しない。AXが返さなかっただけであり、
画像上の選択を観測できるのはモデルだけである。したがって**通常Visionのintent promptが常に
「画像上に明確なテキスト選択が見えるならそれを主対象として読む。見えなければ通常の画面説明を行い、
いずれの場合も選択の有無・不在・不確実性をユーザーへ述べない」と指示する**。`selection`が届いた
場合はそちらが確定した回答scopeとなり、画像判定の指示は出さない（mode命令は常に1つ）。詳細は
[vision-selection-evidence-fix.md](vision-selection-evidence-fix.md)を正とする。

## 共通

- Base URL: `https://api.universal-io.com/api`
- 認証: `Authorization: Bearer <Supabase access token>`
- Content-Type: `application/json`（transcribeのみmultipart）
- macOSクライアントにローカルGateway、BYOK、別endpointへのfallbackはない。
- Gateway内のモデル順序は `web/lib/server/ai-routing.ts` が唯一の正本。全AI機能が一次・二次を
  1つずつ持ち、一次失敗時だけ二次を1回実行する。
- `request_id` は全AIリクエストで必須。
- `review`、`transcribe`、`vision`、`suggest`の各routeは
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
課金は加えて `BILLING_UNAVAILABLE`、`PLAN_NOT_PURCHASABLE`、`SUBSCRIPTION_EXISTS`、
`NO_BILLING_ACCOUNT` を返す。

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
- `mode`: `compose`
- `input.draft`: 必須
- `input.context`: 任意
- 実装: `web/app/api/ai/review/route.ts`
- クライアント: `GatewayReviewClient`

**この`delta`はまだ逐次ではない。** `runReviewStream`はモデルの生成完了を待ってから全文を
1つの`delta`として送る（プロバイダへ`stream: true`を送っていない）。SSEの封筒は本物だが、
体感遅延は非ストリーミングと同じである。逐次化はvisionと同じ機構
（`runStreamWithModelFallback`＋`JSONStringFieldStream`）で行える。

## POST /ai/transcribe

音声を文字起こしする。一次はGroq `whisper-large-v3-turbo`、二次はOpenAI `whisper-1`。
16 kHz mono WAVを推奨する。

- multipart fields: `file`, `request_id`, `platform`, `app_version`（任意）、`language`（`ja` / `en`、任意）
- 実装: `web/app/api/ai/transcribe/route.ts`
- クライアント: `GatewayTranscriber`

POST成功応答の`meta.timing_ms`と`Server-Timing`は
`auth` / `quota` / `provider` / `usage` / `total`のミリ秒内訳を返す。

## POST /ai/vision

固定したスクリーンショットを読み、初期説明、質問回答、次の操作、Copilot進捗を
同一契約で返す。1回の試行につきVLM呼び出しは1回とし、一次失敗時だけ共通ルーターが
二次モデルを1回試す。旧Navigator endpointへは切り替えない。

- `operation`: `vision`
- `input.capture_id`: 必須
- `input.image_base64`: 必須、PNG/JPEG
- `input.question`: 任意
- `input.turns`: 最大20件
- `input.candidates`: 同一captureから取得した画面構造候補、最大500件。schemaは`ax` / `dom`を
  表現できるが、現行macOSクライアントが実際に収集しているのはAX候補だけであり、ブラウザDOMを
  取得する統合は存在しない
- `input.guidance`: Copilot進捗時の目的と直前案内。`question`とは排他
- `input.selection`: 任意。現行R10 macOSクライアントが通常Visionへ加えるSelection Extension。
  詳細schemaと不変条件は次節を正とする。
- `input.focus_target`: 公開済み`v0.2.1`向けの後方互換入力。Focused Visionのセッション内対象。
  `kind`は`selected_text` / `accessibility_element` / `region`、`source`はそれぞれ
  `ax_selected_text` / `ax_element` / `user_region`。`text`は最大12,000文字、`role`は128文字、
  `label`は512文字で、禁止制御文字を含めない。`frame`はAXグローバル座標ではなくcapture左上を
  原点とするピクセル座標で、capture外は切り詰める。`truncated`でtext切り詰めを明示する。
  R10.5以降、Gatewayがselectionへ正規化するのは`selected_text`だけで、`accessibility_element` /
  `region`は**200で受理した上で無視**し、通常Visionとして扱う（`AXSelected`は「現在表示中の項目」で
  あり選択意図の証拠にならないため。判定記録はvision-selection-evidence-fix.md §7-1）。
- `input.visual_selection_hint`: 公開済み`v0.2.1`向けの後方互換入力。boolean受理は恒久維持するが、
  R10.5以降Gatewayは**受理した上で無視**し、通常Visionとして扱う（画像上のハイライト有無を
  クライアントは観測できず、この値は常に推測だったため）。`focus_target`とは排他。
- `input.context`: 任意（`app_name` / `bundle_id` / `window_title` / `host`、各1,024文字まで）。
  Skill判定と画面の出所提示のためだけの参照データで保存しない。判定規則はsuggestと同じで、
  `host`が一次シグナル、ネイティブアプリは`bundle_id`。`candidate_diagnostics`には
  アプリ名・ウインドウタイトルを入れない（あちらはusageへ渡る運用情報）
- `stream`: 任意boolean。`true`のときSSEで返す（下記）。省略・falseは従来のJSON応答で、
  公開済みクライアントの契約は変わらない
- 実装: `web/app/api/ai/vision/route.ts`
- クライアント: `GatewayVisionClient`

### `stream: true`のSSE契約

| event | data | 意味 |
|---|---|---|
| `delta` | `{"text": "..."}` | `result.message`の増分。**読ませるためだけに使う** |
| `reset` | `{}` | ここまでの`delta`を破棄する。一次モデルが回答途中で落ち、二次モデルが別の回答を最初から書き直す |
| `result` | 非ストリーミング成功応答と同一のJSON | 検証済みの結果。**これが唯一の判断材料** |
| `error` | エラー契約と同一のJSON | 一次・二次とも失敗 |

`mode`、`target_candidate_id`、`uncertainties`は必ず`result`から読む。`delta`から推測しない
（ストリーミングが検証を緩めてはならない）。`result`が来ないまま終わったストリームは失敗である。

成功応答（ストリーミング／非ストリーミング共通）の`meta.timing_ms`は`body` / `auth` / `quota` /
`provider` / `usage` / `total`と、preflightの内訳`verify_jwt` / `tenant_entitlement` / `plan` /
`count`をミリ秒で返す。配布済み0.2.2候補との互換用に`get_user`へ同じJWT検証時間、
`tenant`へ同じ結合取得時間、`entitlement`へ0も返す。AI routeの`verify_jwt`はES256署名と期限の
`getClaims()`検証であり、Auth serverから現在のuser rowを読む`getUser()`ではない。`usage`は
応答後実行のため0、preflight各値の0は
「プロセス内キャッシュが答えたので往復していない」を意味する。
**クライアントの往復時間と`total`の差が回線（アップロード・TLS・応答転送）である。**
実測でモデル時間2.4〜3.5秒に対しクライアントは3.4〜7.7秒待っていたため、この内訳を追加した
（latency-plan.md 1-k）。

`message`はschemaの2番目で`reasoning_effort`は`none`なので、最初の増分は総時間のごく一部で届く。
Copilot進捗ターン（`input.guidance`）は**現状ストリーミングしない**。結果受領後に
`mode == observation`をクライアントが棄却するため、流した本文を取り消す挙動になるからである。

`selection`と後方互換fieldはVision promptだけで使い、usage metadata、運用ログ、応答へ保存しない。
通常Vision、Focused Vision、継続質問は同じmodel routeと応答契約を使う。Copilotの新captureへ古い
selectionのtext／frame／structureを引き継がない。

### R10 Selection Extension契約（Gateway・macOS本番入口実装済み）

正式公開済み`v0.2.1`クライアントの契約は上記の`focus_target` / `visual_selection_hint`である。
R10ブランチのGatewayは同じ`POST /ai/vision`へ任意の`input.selection`を追加し、旧fieldと新fieldを
同じ内部Selection Extensionへ正規化する。C4でmacOS本番入口は`input.selection`送信へ切り替わり、
旧fieldを生成しない。Gatewayの本番deploy有無はリポジトリ内の実装完了とは分けて扱う。

```json
{
  "selection": {
    "kind": "text",
    "text": "選択全文の先頭…[省略: 4800 UTF-16 units]…選択全文の末尾",
    "acquisition_completeness": "complete",
    "acquisition": "ax_document_selection",
    "capture_visibility": "partial",
    "frames": [
      { "x": 120, "y": 240, "width": 360, "height": 42 }
    ],
    "structures": [
      {
        "source": "ax",
        "role": "AXHeading",
        "label": "件名",
        "relationship": "intersects_selection",
        "states": [],
        "actions": [],
        "coverage": "partial"
      }
    ],
    "wire_truncated": true,
    "original_utf16_units": 16800
  }
}
```

不変条件は`Focused Vision = Vision Core + Selection Extension`である。`selection`をrequestから
除いた時、image、現行の通常candidate policy、identity、Skill、turns、model route、responseは
通常Visionと同一になる。初回の通常AX candidatesは通常／Focusedとも現行どおり空で、
Selection Extension取得済み情報のために追加walkしない。

`text`は選択全文またはそのbounded representationであり、先頭segmentから代用しない。wire上限は
12,000 UTF-16 unitsで、上限超過時は省略量markerを中央へ置き、marker分を除いたbudgetを頭尾へ
半分ずつ割り当てる。grapheme clusterを途中で壊さない。`acquisition_completeness`はローカル取得状態、
`wire_truncated`は送信削減なので直交し、`complete`と`wire_truncated: true`は両立する。
`kind`の有効値は`text`のみで、非空`text`を必須とし、structures、frames、
labelだけでtext selectionを代用しない。旧enum値`visual_only` / `accessibility_element`は
wire互換のため当面validationを通すが、Gatewayは正規化で捨てて通常Visionとして扱い、
正規化前のraw wire種別だけをusageへ記録して移行完了を観測してからenumを撤去する
（vision-selection-evidence-fix.md §5-2／§5-5）。
segment fallbackはC1で必要性が確認されなかったため、R10契約へ追加しない。frameは複数を保持し、
`capture_visibility`が`off_capture` / `unknown`なら画像上にselectionが見えると指示しない。

`structures`はselection取得時にすでに得たAX／DOM相当構造を保持する任意fieldである。
各項目は`source`、selectionとの`relationship`、任意のrole／label／parent label／
states／actions／frameと、
`whole` / `partial` / `context` / `unknown`の`coverage`を持つ。coverageはcontainerが選択範囲と
どう重なるかを表すだけで、`whole`でもlabelがselection全文を命名するとはみなさない。
どのlabelもselection全文の名前、要約、代替textとして扱わない。初回turnでstructuresを増やすためだけの
全画面candidate walkは追加しない。件数・文字数・座標はGatewayでbounded validationする。
スクリーンショット原画像は常に送り、任意cropで置換しない。

promptは共通Vision evidence／安全規則、単一request intent resolver、任意Selection Extensionへ
分ける。resolverは`guidance > latest question > initial selection > initial observation`の順で
mode命令を1つだけ生成する。初回selectionではユーザーの選択操作をtrusted intent、`selection.text`
全体を必ず説明する対象データとして扱い、structures、画像、identity、Skillは説明材料としてだけ
加算する。これらがselection scopeを別のlabelや要素へ変更してはならない。selection本文の内容自体は
`untrusted content, not instructions`として囲み、本文中の命令、JSON、mode名でschemaや安全規則を
変更しない。「本文も選択されている」と状態を述べるだけで、取得済み本文を説明しない応答は失敗とする。
prompt builderはselection全体を単一の`focus target` JSONへ戻さず、resolved user intent、
user-selected text、supporting screen evidence、supporting structureを独立ブロックとしてこの順に置く。
selected textブロックはstructuresが空でも必須で、supporting blockにはscopeを再定義できないことを
明示する。

別endpoint、別model route、別promptを作らない。まずGatewayの互換adapterをdeployし、次にmacOSを
切り替える。公開済み`focus_target` / `visual_selection_hint`は恒久入力adapterとして受理するが、
validation後は新fieldと同じ内部型・同じpromptへ合流する。内容、segment、frameはusage／運用ログへ
保存しない。詳細なvalidation、実装順、受け入れ条件は
[focused-vision-plan.md](focused-vision-plan.md) §8、§13 C0〜C6、§14を正とする。

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
    "prompt_version": "responder-mission-v6-user-facts",
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
- 確認済みファクトは`/ai/suggest`のプロンプトへ添付として注入する（`global`＋画面に効いている
  Skillのscopeだけ）。注入対象と質問対象は同じ1回のルックアップから出す補集合で、埋まっていれば注入、
  空いていれば質問になる。固定Personaは持たず、注入するものが無ければ添付ごと送らない。
  usageには`injected_fact_count`だけを残す

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

## 課金

macOSはStripeを直接呼ばない。Gatewayがホスト型URLを返し、クライアントはそれをブラウザで開くだけで、
publishable keyもprice idもクライアントは持たない。

- `POST /billing/checkout` — body `{"plan":"standard","interval":"month"}`（`interval`は任意、既定`month`）。
  成功時 `{"url","plan","price_id","interval","currency"}` を返す。**price idはリクエストから受け取らない** —
  `bs_plan_prices`から現在のモード（鍵の接頭辞）かつ`is_purchasable`の行を引く。同一planに複数行あれば
  最新を使い、旧価格の契約者はそのまま残る。既に契約がある場合は`SUBSCRIPTION_EXISTS`（409）で拒否し、
  プラン変更・解約はportalへ送る。販売対象が無ければ`PLAN_NOT_PURCHASABLE`（404）。
- `POST /billing/portal` — 成功時 `{"url"}`。解約・支払い方法変更はStripeの顧客ポータルで行い、
  アプリ側に再実装しない。customer未作成なら`NO_BILLING_ACCOUNT`（404）。
  呼び出し元はmacOSの「料金プラン」（`GatewayBillingClient`）と`/billing/start`の契約済み表示で、
  どちらも返ったURLをブラウザで開くだけ。**購入経路を持つ以上、解約経路も必ず露出させる。**
- どちらも失効・past_dueのアカウントから呼べる（買う人・カードを直す人こそ呼ぶため、
  entitlement statusでゲートしない）。鍵が無い場合は`BILLING_UNAVAILABLE`（503）。

購入導線の入口は`/billing/start?plan=standard`（ページ、APIではない）。製品サイトの料金ページから
リンクする。未ログインなら`/auth?next=/billing/start?plan=…`へ送り、ログイン後に同じ場所へ戻して
Checkoutを開始する。ログイン済みならそのままCheckoutへ進む。契約済みの場合は`SUBSCRIPTION_EXISTS`を
受けて、その場から`/billing/portal`を開くボタンを出す。Checkoutセッション作成は1回だけ実行する
（認証リスナーの再レンダリングで二重にPOSTしない）。

このページから`/admin`へ送らない。`/admin`は`bs_profiles.role`でゲートされており、一般の購入者には
鍵のかかった扉になる。案内先はStripeのポータルと製品サイト（`lib/site.ts`）だけにする。

`POST /stripe/webhook` はStripe専用で、Bearer認証を持たない（**署名が資格情報**）。
`STRIPE_WEBHOOK_SECRET`未設定なら503、署名不正なら400（再送させない）。処理するのは
`checkout.session.completed`、`customer.subscription.created` / `updated` / `deleted`、
`invoice.paid`、`invoice.payment_failed`の6種で、それ以外は200で受けて無視する。

- 6種すべてが同じ処理へ収束する。**イベントのpayloadを信用せず、subscriptionをStripeから
  読み直す**。イベントはendpointのAPI versionで配送され順序も保証されないため、古い`updated`が
  新しい状態を上書きし得る。読み直せば常に現在の真実を書くので、再送も自然に冪等になる。
- 冪等性は`bs_stripe_events`（event id PK）が持つ。`applied_at`が入っていれば重複として無視し、
  受信済みだが未適用なら再適用する。失敗時は500を返してStripeに再送させる。
- price id → plan は`bs_plan_prices`で解決する。対応行が無ければ適用せず500を返す（行を足せば
  再送で成功する。推測でplanを与えない）。
- entitlementへの反映は状態の**翻訳**で、コピーではない。`trialing` / `active` / `past_due`は
  売れたplanを維持し、それ以外（`canceled`、`unpaid`、`incomplete`、`incomplete_expired`、`paused`）は
  `free` / `active`へ落として`stripe_subscription_id`を消す。`canceled`をそのまま書かない理由は、
  それがentitlement判定を落として**無料枠まで使えなくなる**ため。契約IDを残さない理由は、
  残ると退会が永久にできなくなるため。
- `past_due`は猶予として利用を継続させる（Smart Retriesは数週間走る）。アクセスを失うのは
  Stripeが最終的に解約した時点で、リトライの初回失敗ではない。
- `account_class`と`monthly_review_limit`はwebhookで触らない。誰が支払うかと個別override は
  Stripeイベントが変える理由にならない。
- `stripe_customer_id`が空のtenantには、subscriptionのcustomerをこの時点で紐付ける（列がまだ
  NULLの時だけ。既存のcustomerを別のものへ移し替えない）。Checkout経由なら購入前に保存済みだが、
  Dashboard・CLI・importで作られたsubscriptionでは空のままになり、**顧客ポータルはcustomer idだけで
  引くため、有料プランなのに解約できないアカウントが生まれる**。
- **解約は期間終了時に効く**（顧客ポータルの設定）。支払った月は使えるという扱いで、即時解約はしない。
  この間Stripeの`status`は`active`のままなので、entitlementも有料プランを維持する。終了日は
  `cancel_at`へ書く（Stripeの`cancel_at`、古いAPI versionでは`cancel_at_period_end`から期間終了を採る）。
  **毎回再計算して更新する** — ポータルは解約の取り消しもできるため、古い日付を残すと
  「まだ終了する」と言い続ける。`cancel_at`は表示専用で、利用可否の判定には使わない
  （判定は`plan`と`status`。アクセスが終わるのはStripeが実際に解約して`deleted`が届いた時）。

## アカウント・管理

- `GET /account` — `{"account":{email, tenant_id, plan, status, monthly_review_limit,
  has_billing_account, cancel_at, features}, "quota":{…}}`。`plan`は`bs_plans`のid（`free`／`standard`等）を
  そのまま返し、クライアントは**受け取ったidを表示するだけでプランの一覧を持たない**。表示名を
  知らないidは生のまま表示する（既定値へ丸めると、`bs_plans`に行を足した瞬間に有料契約者へ
  「フリー」と表示する事故が起きる。実際に`standard`で起きた）。`has_billing_account`は
  `stripe_customer_id`の有無で、クライアントは真のときだけ「お支払い管理」を出す。
  `cancel_at`はnullなら継続、値があれば「その日に終了予定、それまでは利用可」を意味する。
  `plan`と`status`だけでは解約済みと通常更新が区別できないため、**解約が効いたことを
  ユーザーに示せる唯一の情報**である。この2つは`bs_entitlements`から1回のreadで取り、
  `authenticate`には足さない（全AI routeが通る経路に課金の詳細を載せない）。usageは記録しない。
- `DELETE /account` — body `{"confirmation":"DELETE"}`。直近10分以内の認証を要求し、
  有効なsubscriptionがある場合は`ACTIVE_SUBSCRIPTION`で拒否する。
- `GET /admin/overview` — `config.billing`に実効モード（鍵の接頭辞由来）、webhook署名シークレットの
  有無、販売可能な価格一覧を含む。

v3で文体・関係性メモリを廃止したため、`/ai/memory/distill` と `/memory/cards` は存在しない。
`input.memory`を送るクライアントも無い。ユーザーに関する事実の記憶はv3で別機構として設計する
（正本 [v3-tool-fit-plan.md](v3-tool-fit-plan.md)）。

各routeの入力検証と認可は `web/app/api` の現行実装を正とする。
