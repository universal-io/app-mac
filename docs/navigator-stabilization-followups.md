# Navigator / Copilot Accuracy Plan

最終更新: 2026-07-14 ／ ステータス: **進行中**（`feature/copilot-accuracy`、現行経路監査と品質上限モデル選定済み）

基盤リファクタ完了後の**現行開発の正本**。現在の Copilot は機能導線は動くが、
案内精度と画面遷移待ちが実用水準に達していない。場当たり的なプロンプト修正ではなく、
モデル・ワークフロー・画面状態検出を分離して計測する。

## 0. 開始条件と作業ブランチ

- [x] `feature/foundation-redesign` を `main` へ統合し、`feature/copilot-accuracy` を作成。
- [x] `feature/copilot-accuracy` に `main` の `Merge configurable keyboard bindings` を取り込み、現行 `main` を土台に継続。
- モデル変更・プロンプト変更・キャプチャ判定変更を同時に行わない。
- 1 実験 = 1 変数 = 1 コミット。同一ゴールデンセットで比較する。

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
