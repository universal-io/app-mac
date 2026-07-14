# Navigator / Copilot Accuracy Plan

最終更新: 2026-07-14 ／ ステータス: **進行中**（`feature/copilot-accuracy`、v4 eval契約とGA4 smoke fixture作成済み）

基盤リファクタ完了後の**現行開発の正本**。現在の Copilot は機能導線は動くが、
案内精度と画面遷移待ちが実用水準に達していない。場当たり的なプロンプト修正ではなく、
モデル・ワークフロー・画面状態検出を分離して計測する。

## 0. 開始条件と作業ブランチ

- [x] `feature/foundation-redesign` を `main` へ統合し、`feature/copilot-accuracy` を作成。
- [x] `feature/copilot-accuracy` に `main` の `Merge configurable keyboard bindings` を取り込み、現行 `main` を土台に継続。
- モデル変更・プロンプト変更・キャプチャ判定変更を同時に行わない。
- 1 実験 = 1 変数 = 1 コミット。同一ゴールデンセットで比較する。

## 0.5 ゼロベース技術レビューの決定（2026-07-14、オーナー承認済み）

製品戦略は維持する。すなわち、未対応アプリでも使える汎用 Vision を土台に、一般的な
オフィスツール、導入企業、個人特性ごとの精度パッケージを Gateway 側で自動適用する。
macOS クライアントは引き続きセンサー／アクチュエーターに徹し、ユーザーにツールモードを
選ばせず、最終操作はユーザーが行う。

ただし、現在の自由文マーカー中心の実行制御を完成形とはしない。既存経路は比較可能な
baseline として維持し、GA4 の1ユースケースだけを新しい実行契約で縦に通す。その結果を
確認してから Slack / Notion など一般的なオフィスツールへ広げる。一般公開前のため、速度・
コストより正確性、再現性、監査可能性を優先する。ビッグバン置換は禁止し、feature flag 下の
並走経路、1変数1コミット、各段階での手動検証を守る。

### パッケージの4層と用語

この文脈の `vendor` は OpenAI 等のモデル提供者ではなく、Slack / Notion / freee のような
**業務アプリ提供元（app vendor）**を指す。AI provider と混同しないよう、コードとDBでは
可能な限り `app_vendor` / `model_provider` と明記する。

この4層はNavigator専用の分類ではなく、Compose / Transform / Visionを横断する共通Contextの
適用範囲である。既存のL1 Situational / L2 Relationship / L3 Personaは「内容と寿命」の別軸。
全体契約・合成規則・surface projectionは
[universal-io-master-plan.md](universal-io-master-plan.md) §3.1を正とする。本計画ではVisionの
projectionだけを先に実装し、`vision tenant` や `navigator user pack` という別の正本を作らない。

| 層 | 識別単位 | 目的 | 例 | 現在 | 今後 |
|---|---|---|---|---|---|
| generic | 全利用者 | 未知の画面でも最低限理解・案内する | 任意のWeb/デスクトップ画面 | 汎用 system prompt | 型付き既定契約として常時適用 |
| app vendor / product | 提供元＋製品／ツール | 標準UI、用語、代表タスクを共有する | Google/GA4、Slack/Slack、Notion/Notion | `scope=global` の pack に暗黙混在 | 版付きproduct packとして明示 |
| tenant | 導入組織 | 個社固有UI、ERP、権限、承認フローを上書きする | A社Salesforce、社内ERP | DB列のみ。実行時未使用 | 認証tenantに限定した overlay |
| user | 個人 | 言語、認知特性、説明粒度、支援設定を適用する | やさしい日本語、詳細度 | Navigator pack として未実装 | 許可された presentation overlay |

合成順は `generic → app vendor → tenant → user`。後段ほど具体的だが、tenant/user は
上位層の安全制約、確認必須操作、データ取扱い規則を緩められない。ユーザー層には個社知識や
秘密を保存せず、回答表現と支援方法を中心にする。tenant 層は必ず認証済み tenant ID で選び、
他tenantへ漏れないことをAPI境界とテストで保証する。

### v4 の責務境界

1. **Observation Snapshot**: capture ID、時刻、撮影範囲、app/bundle/window/URL、遷移状態、
   画像、OCR/AX候補（安定ID・role・label・rect・親子文脈）を1時点の不変データとして扱う。
2. **Capability Pack**: match rules、用語、UI意味マップ、レシピ、事前条件／完了条件、代替経路、
   操作ポリシー、参照知識、golden case、互換バージョンを型付き・版付きデータとして管理する。
3. **Run / Task**: Gateway が `run_id`、pack/version、plan/version、現在stepを発行する。
   クライアントは表示用キャッシュを持てるが、自由文を正本にしない。画像自体は永続保存しない。
4. **Planner**: 意図・レシピ・Taskを構造化出力する。確信不足なら開始せず確認質問へ戻す。
5. **Grounder**: 自由な座標生成を主契約にせず、端末が列挙した候補IDから対象を選ぶ。
6. **Verifier**: before/after Observation とstepの完了条件を比較し、`verified / not_changed /
   ambiguous / blocked / complete` を構造化出力する。本文中の `[[step:done]]` は廃止対象。
7. **Renderer**: 確定したTask/Verifier結果だけを短い自然文へ変換する。帯の指示はTaskデータを表示する。
8. **Trace / Eval**: role、model、pack/version、入力fixture、構造化出力、遅延、token、失敗理由を
   分離して再生・比較できるようにする。実画面・会話本文は既定で永続保存しない。

### 個別最適化と fine-tuning の境界

- UI構造、社内用語、操作手順、権限差、更新頻度の高い知識は Pack + RAG + recipe で扱う。
- UI座標や揮発する画面文言、tenantの機密データをモデル重みに焼き込まない。
- fine-tuning は十分な評価済みtraceが集まった後、安定した意図分類、recipe選択、Verifier判断など
  「知識更新ではなく反復するモデル挙動」の改善候補に限定する。
- screenshot-only を汎用fallbackとして守りつつ、企業向け高保証パッケージでは DOM / AX /
  vendor API connector を追加センサーとして許可する。専用連携が無いと使えない設計にはしない。

### 並走移行の順序

1. [x] 固定fixtureを検証できる eval runner と trace schema を作る（挙動変更なし）。
2. Observation / candidate ID / structured Verifier の契約を追加する。
3. pack v1（version、app vendor、tenant overlay、継承、適用証跡）を追加する。
4. GA4 の代表経路を feature flag 下で v4 に通し、現行v3と同じfixtureで比較する。
5. OpenAI Responses API + GPT-5.6 品質上限を役割別に測る。
6. GA4 合格後、Slack、Notionの一般利用タスクへ広げる。その後にfreeeや個社ERPを扱う。

#### v4 Observation実装（2026-07-14開始）

- [x] Gateway/API: `message.observation` v1のstrict schema、最新1件制約、後方互換受理、
  非本文usage metadataを追加。provider promptはまだv3のまま（shadow mode）。
- [x] Eval: fixture独自schemaを廃止し、本番 `lib/context/observation.ts` を正本として共有。
- [x] macOS: attachment + capture時点environment + OCR候補からObservationを生成し、最新turnだけ送る。
  capture ID／撮影時刻／範囲／pixel・screen座標をattachmentから引き継ぎ、OCR候補には
  同一capture内で安定する `ocr:<index>` IDを付ける。app/windowは再キャプチャごとに取得し、
  context除外時はenvironmentだけを送らない。URL、AX候補、実遷移状態は後続実装。
- [ ] AX候補: OCRとは別sourceでrole/state/親文脈を収集し、同一capture内の安定IDを付ける。
- [ ] Grounder/Verifier: candidate ID選択とbefore/after構造化判定をprovider roleとして接続する。

#### eval基盤の開始点（2026-07-14）

- `web/evals/navigator` に strict schema、採点器、CLI、Vitest を追加。
- 最初の `ga4-smoke-v1` は planner 2件（国・地域／デバイス）、重複する「概要」の
  candidate ID grounding 1件、before/after Observation の verifier 1件。計9 assertion。
- 人手確認referenceは `npm run eval:navigator:check` で 9/9。既知の「国・地域を
  テクノロジー→概要へ誤誘導」を混ぜたunit testが失敗を検出する。
- 現時点のObservationは合成データで、実画像とモデルAPIは未接続。これは採点契約だけを先に
  固定し、モデル・prompt・入力品質を同時変更しないため。次に実画面captureをfixtureへ追加し、
  現行v3の出力をbaseline resultとして保存する。
- `eval:navigator:capture-v3` はローカルの既存設定を読み、現行 `runNavigateStream` をそのまま
  通してplanner結果・モデルID・未版管理pack ID・遅延・tokenをresult JSONへ保存する。
  評価用に別promptを複製しないため、将来の比較baselineも実運用経路とのドリフトを避けられる。
- 初回v3 captureでfixture自体の過剰制約を検出した。画面上で既に展開済みの「レポート」を
  再度開く期待手順は誤りなので、candidateに `expanded/selected/...` 状態を追加して除外。
  goalも表層文字列の完全一致ではなく、正解として明示した同義語グループのいずれかで採点する。
  評価器の誤判定をモデルの失敗として数えないことを、モデル比較より優先する。

#### 現行v3 baseline（2026-07-14）

ローカルの実効 `openai:gpt-5.4-mini` と `ga4@unversioned-v3` を現行
`runNavigateStream` 経由で実行し、`ga4-current-v3-gpt-5.4-mini-2026-07-14.json` に保存した。

| role | score | 結果 |
|---|---:|---|
| planner | 7/7 | 国・地域→ユーザー属性、device→テクノロジーを正しく分離 |
| grounding | 0/1 | v3にcandidate ID出力が存在しないため未回答 |
| verifier | 0/1 | v3に独立した構造化Verifierが存在しないため未回答 |
| total | 7/9 (77.8%) | 未実装roleを黙って合格扱いしない |

planner 2件の全体所要時間は約4.5秒 / 1.7秒。ただしv3のusageはplanner callのtokenを
集計していないため、result内のtoken値はmain/locator側だけで完全な原価ではない。また、これは
合成OCR/AX候補によるsmokeであり、実画面画像を含む品質合格ではない。

## 1. 現行実装の事実（検証開始点）

### モデル配線

`web/lib/server/env.ts` の既定値は次の2段構成。本番は環境変数で上書きできるため、
最初に admin/runtime で実際の値を確認する。

- 自動初手（画面認識1文）: Groq `meta-llama/llama-4-scout-17b-16e-instruct`
- 通常質問・プランナー・ロケーター補追: OpenAI `gpt-5.4-mini`

したがって「Copilot が全て Groq」ではない。速度優先は自動初手に限定され、
タスク計画と進捗判定は既定でメインモデルが担当する。

### Copilot 再キャプチャ

`VisionSession` の現行処理は、固定待ち3枚比較から状態機械ベースへ切り替えた。

1. クリック完了から 1.2 秒待つ。
2. 直前の `attachment` を baseline として保持する。
3. フルスクリーンを 0.35 秒ごとに最大 8 回サンプリングする。
4. baseline との差分が閾値を超えるまで `waitingForChange`。
5. 変化開始後は `settling` に入り、連続する2枚が安定閾値内になった時点で採用する。
6. 変化が始まらない、または安定前に試行回数を使い切った場合は `timedOut` とし、自動で古い画面を送らない。

差分判定はフル解像度の完全一致ではなく、縮小グレースケール画像の平均差分で行う。
これにより「遷移開始前の2枚が偶然一致」「変化中の3枚目を無条件採用」の両方を避ける。

### 2026-07-14 現行経路監査

モデル差し替えの前に、macOS の状態遷移から Gateway の本文・プランナー・
ロケーター補追までを終端間で監査した。結論は、**モデルだけを高性能化しても品質上限を
正しく測れない**。比較開始前に次の評価ブロッカーを分離する。

#### P0（品質上限の測定を壊す）

1. **Task が決定論データになっていない**
   - Gateway の `taskBlock` は `steps[].verbal` しかモデルに渡さず、Task に保存した
     `target` / `fill` を落としている。
   - クライアントも未完了ターンでは Task の `target` ではなく、毎回モデルが返す
     `[[target]]` を信頼してハイライトする。帯の指示文も Task 本体ではなくモデル回答。
   - そのため「プランはデータ、LLM は現在ステップの確認だけ」という設計契約が
     実行時に崩れている。
2. **GPT-5.6 の品質上限は現行 API 実装では出ない**
   - 現行は OpenAI-compatible Chat Completions のみ。OpenAI の現行ガイドは推論・
     マルチターンに Responses API を推奨し、最高品質の `reasoning.mode: "pro"` も
     Responses API 限定。
   - 現行上限は本文 1,200 / planner 1,500 / locator 400 `max_completion_tokens`。
     推論トークンもこの上限を消費するため、高い reasoning effort では表示文より前に
     上限到達する可能性がある。公式の初期検証目安は reasoning + output に 25,000 以上。
3. **古いタスク提案が次の質問に残る**
   - `sendNavigatorQuestion` は `navigatorProposedTask` を消さない。次の planner が
     `null` または失敗した場合、前の質問の「ナビゲーション開始」が残る。
4. **遷移検出の baseline と candidate が同じ撮影範囲とは限らない**
   - 初回が範囲選択でも、Copilot 再キャプチャは常にディスプレイ全体。画面が
     変わっていなくても「変化開始」と判定しうる。
   - 撮影ディスプレイも直前 attachment の中心に固定。クリック後に別ディスプレイへ
     ウィンドウが開いた場合は古い側を撮り続ける。
   - 撮影自体の失敗はログのみで、`waitingForChange` が残る可能性がある。

#### P1（比較の帰属と再現性を壊す）

- 本文、planner、locator supplement が同じ model ID に束ねられ、役割別の成否を
  分離できない。step verifier も独立せず本文回答と `[[step:done]]` を兼用。
- planner と locator の失敗は best-effort で握りつぶされ、planner の token / 成否 / 失敗理由は
  usage に記録されない。比較時のコストと失敗箇所を誤帰属する。
- クライアントは URL hint を送らず、セッション開始時の app / window title を
  再キャプチャ後も使い続ける。タブ・ウィンドウ・アプリが変わると harness が stale になる。
- 通常 Navigator Q&A は全履歴を残すが Gateway は 24 messages 上限。クライアント側に
  上限前の切り詰めがなく、長い通常 Q&A は 400 で終了する。
- モデルに届く画像は長辺 1,600px / JPEG 0.7 へ事前縮小済み。API で
  `detail: original` にしても失われた細かい UI 文字は戻らない。「モデルの公平比較」と
  「入力を含むシステム品質上限」は別実験にする。
- 固定入力の eval runner と fixture がない。プロンプト、画像、モデル、キャプチャ判定を
  同時に変えると改善要因を証明できない。

## 2. 検証順序

### A. ゴールデンセットと計測を先に固定

- 実画面 × 目的 × 正解経路を20〜30件用意する。GA4 の既知失敗（国・地域、重複する「概要」）を必ず含める。
- タスクプラン正解率、次ステップ正解率、完了判定、ロケータ正解率、古い画面の採用率を分けて記録する。
- TTFT、ターン総時間、キャプチャ安定待ち時間、入出力トークン、推定コストも並記する。

### B. モデル選定

- 自動初手、通常QA、プランナー、ステップ検証を別タスクとして評価する。
- 速度基準だけではなく、まず高性能モデルで品質上限を測る。実用精度が上がるなら数秒の追加待ちは許容候補。
- 同一入力でモデルだけを差し替え、プロンプト・レシピ・画像は固定する。

#### 2026-07-13 公式仕様調査

現行の高速初手 `meta-llama/llama-4-scout-17b-16e-instruct` は、Groq の
[廃止予定](https://console.groq.com/docs/deprecations)で **2026-07-17 に停止予定**。
品質改善とは別に置換が必須であり、以降は比較時の期限付き baseline としてのみ扱う。

- Groq 内で同じ「画像を直接受ける高速初手」の比較候補は
  [`qwen/qwen3.6-27b`](https://console.groq.com/docs/model/qwen/qwen3.6-27b)。画像入力、
  reasoning / non-reasoning の両モードに対応するが Preview のため、採用時は model ID と
  廃止予定を運用監視する。
- Groq が移行候補に挙げる
  [`openai/gpt-oss-120b`](https://console.groq.com/docs/model/openai/gpt-oss-120b) は text-only。
  スクリーンショット入力を担う初手の直接置換には使えない。視覚認識と計画を分離した場合の
  text planner 候補に限る。
- 現行後続ターンの
  [`gpt-5.4-mini`](https://developers.openai.com/api/docs/models/gpt-5.4-mini) は画像入力と
  computer use を対象にした現行モデルであり、比較 baseline として維持する。
- 品質上限の測定には OpenAI の
  [現行モデル選択ガイド](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.6)に従い、
  GPT-5.6 系の品質優先モデルとバランス型を候補にする。ただし API 方式・reasoning effort・
  image detail の差も結果に影響するため、単なる model ID 差し替えと混ぜない。
- 視覚 grounding / locator は、公式に 0–1000 正規化 bounding box を返せる
  [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding)を別候補にする。
  プランナー全体の置換と locator 単体の置換を分けて評価する。

| 役割 | 現行 baseline | 最初の比較候補 | 判定したいこと |
|---|---|---|---|
| 自動初手（画像→1文） | Llama 4 Scout（7/17停止） | Qwen 3.6 27B / `gpt-5.4-mini` | 初手精度を落とさず停止モデルを置換できるか |
| 通常QA・計画・進捗判定 | `gpt-5.4-mini` | GPT-5.6 品質優先 / バランス型 | 数秒の追加待ちで実用精度が改善するか |
| text-only planner（分離案） | なし | GPT-OSS 120B | 視覚結果を構造化した後なら有効か |
| locator / grounding | `gpt-5.4-mini` 補追 | Gemini Flash / Pro 系 | 重複ラベルや座標特定が改善するか |

#### 2026-07-14 選定結果（品質上限の最初の候補）

**最初は OpenAI [`gpt-5.6-sol`](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
（alias: `gpt-5.6`）を品質上限 baseline にする。**
これは「全社比較で必ず一位」と先に決める意味ではない。現行 Gateway が OpenAI を
持ち、画像入力・推論・computer-use 系能力を持つ公式の最上位モデルを最小の
移行幅で検証できるため、最初のフィジビリティ測定に最適と判断した。

品質上限構成:

- API: OpenAI Responses API（Chat Completions の model ID 差し替えで終わらせない）
- model: `gpt-5.6-sol`
- image: `detail: original`。モデル公平比較では現行 1,600px 入力を固定し、
  別の「システム上限」実験で未縮小入力を比較する。
- planner / step verifier: `reasoning.mode: "pro"`, `reasoning.effort: "max"`, 構造化出力。
- 本文: まず standard + `reasoning.effort: "max"` でストリーミングを保つ。
  同一 eval で pro + max（単一最終回答）も比較し、品質差があれば上限値に採用。
- output budget: 少なくとも初期検証は reasoning + visible output に 25,000 tokens を予約。

次の challenger は、空間理解を比較する Google
[`gemini-3.1-pro-preview`](https://ai.google.dev/gemini-api/docs/gemini-3)、その後に Anthropic の最上位
[`claude-fable-5`](https://platform.claude.com/docs/en/about-claude/models/overview)。
後者は現行 `VENDOR_ENDPOINTS` では呼べず専用 adapter が
必要なため、GPT baseline の後にする。「最も正確」の最終判定は公式の序列ではなく、
本プロダクトの同一 golden set の task / step / completion / locator 合格率で決める。

モデル変更前に admin の「実効モデル設定」で本番環境変数による上書きを確認する。
2026-07-13 時点で `web/.env.local` にモデル上書きはなく、ローカルはコード既定値どおり。
**本番の実効値は未確認**なので、ローカル既定値だけを本番値として扱わない。なお現リポジトリには
固定入力を反復評価する test / eval runner がないため、まずゴールデンセットを再実行可能な形にする。

### C. 画面遷移検出（モデルと独立に検証）

- クリック直前のキャプチャを baseline とし、まず「変化が始まった」ことを検出する。
- 変化開始後、連続する2枚以上が閾値内で安定した時点で採用する。「古い画面が同じ」と「新しい画面が安定」を区別する。
- 候補信号: 縮小輝度画像の差分、OCRテキストのhash/集合差、AXウィンドウタイトル、ブラウザURL、
  ローディング要素。画像差分はローカルの小さなビットマップで計算し、モデル往復を増やさない。
- 第一段階として縮小輝度画像差分ベースの `waitingForChange` / `settling` / `timedOut` は実装済み。
- タイムアウト時は古い画面を無言で解説せず、`timedOut` として再読み取りを促す。

### D. ワークフロー評価

- モデルに渡す前に `captureState` として `waitingForChange` / `settling` / `stable` / `timedOut` を持つ価値を検討。
- Task.goal / currentStep / 最新キャプチャの整合性をサーバー呼び出し前に検証する。
- キャプチャ品質とモデル品質の失敗を別ログ・別指標にする。

## Foundation first

- `copilot` の終了状態が弱い。
  完了、停滞、再確認待ちを明示する終端状態が必要。
  いまは明示的な `終了` ボタンを優先しており、自動完了判定は未実装。

- `copilot` の再スキャン判定は暫定。
  現在は §1 の縮小輝度画像差分による `waitingForChange` / `settling` / `timedOut` まで。
  OCR差分、AX変化、URL変化などを使った複合シグナル化は未実装。

- `panel highlight` と `live highlight` は分離済みだが、ライフサイクルはまだ粗い。
  スクロール、画面遷移、別ウィンドウ移動時の追従は未解決。

## Tuning later

- ナビゲーション文言が抽象的で「どこを見るか」が弱い。
  プランナー/プロンプト側の改善対象。

- ステップ数の妥当性が安定しない。
  毎回ゼロベースに近い案内へ寄るケースがある。

- live overlay の表示位置/重なり順が環境依存で不安定。
  パネルの上に出る、スクロールでずれる、再現率が低い等。

- `NavigatorLocator` と OCR 解決の精度不足。
  正しい対象に近いが広すぎる/狭すぎる枠になることがある。

## UX assists to add

- `もう一度確認` / `再スキャン` をより明示的に出す。
  現在も手動確認ボタンはあるが、停滞時の誘導が弱い。

- 案内完了時の UI が必要。
  自動クローズか、完了表示 + 閉じる導線かを決める。

- `変化なし` をユーザーに伝える UI が必要。
  「反映待ち」「再確認中」「再読み取りしてください」を区別したい。
