# Compose Vision Suggest（先回り文案）開発計画

最終更新: 2026-07-24 ／ ステータス: ドラフト（実験ブランチ `feature/compose-vision-suggest`）

## 0. 位置づけ・運用

- 本ドキュメントはこの新機能専用の独立計画である。ボツになった場合は本ブランチを削除する
  だけで、ドキュメント・コード・設定を丸ごとパージできる（§8）。
- 正本の役割分担は変えない。製品計画の正は `universal-io-master-plan.md`、APIの正は
  `api-contract.md`、実装の正は現行コード。本機能が採用に至った時点で、確定した仕様を
  それらへ反映してから本計画は消す。
- 本番アーキテクチャの原則（macOSは認証済みGatewayだけを呼ぶ／ローカル代替経路を持たない）は
  維持する。実験用のshadowやflagを常設しない。

## 1. 目的と体験

現在のコンポーズパネルは「自分が書いた文章をレビューする」機能である。本機能はその**逆方向**、
「いま入力すべき内容を先回りで提案する」体験を足す。

- パネルを開くと、全画面スクショで前後関係を理解し、**いまフォーカスがあたっている入力フォームに
  何を書くべきかの文案**を、レビュー結果と同じ「パネル下部」に自動表示する。
- ユーザーは自分の意志で道具を呼び出しているので、パネル起動＝画面コンテクスト取得の合図とみなす。
  ユーザーはその内容を使わなくてもよい（使わなければ消える）。
- コストがかかるため、簡単にオン/オフできる。

## 2. 確定した動作モデル

### 2.1 キャプチャの前倒し（共有画像）

- Shift×2 でパネルが開いた**瞬間**に全画面スクショを取得する。取得はローカルで軽量、
  この時点では送信しない。
- この1枚を **自動文案 / Vision / Copilot で共有**する。コンポーズから Vision へ進んだ時は
  撮影済みなので待ち時間ゼロでVisionモードに入れる。
- 再取得はしない。パネル起動時の画面をそのまま使う（画面は静的前提）。Copilot は従来どおり
  操作後に自前で再取得する。

### 2.2 下部エリア = 「第2フィールド」1スロット

- 中身は **自動文案** か **レビュー結果** のどちらか一方（排他）。両方同時には出さない。
- どちらも**編集可能**（レビュー結果と同じ扱い）。
- 自動文案は **使わなければ消える**（ephemeral）。
- 自分の下書きがアクティブな状態で**レビューボタン**を押すと、このスロットが
  自動文案 → レビュー結果へ**置き換わる**。

### 2.3 フォーカス切替（Shift×1）

- 「自分の下書き」⇄「第2フィールド（自動文案 or レビュー結果）」を切り替える。

### 2.4 採用

- 自動文案を採用すると**自分の下書き入力欄に入り**、以降は通常の送信フローに乗る。
- 外部フォームへ直接は書き込まない。

### 2.5 オン/オフ

- オフ＝**自動文案のLLM解析だけを止める**。スクショの前倒し取得は続けるので、Visionへ進んだ
  時の速さは保たれる。
- 簡単に切り替えられること。トグルの置き場所は要検討（§7）。

## 3. Shift入力の周回と Copilot 分岐

```
[閉] ─Shift×2→ [コンポーズ] ─Shift×2→ [Vision] ─Shift×2→ [閉]
                                          │
                                          └─（案内開始ボタン）→ [Copilot]
```

- Shift×2 は常に「次へ進む」。Vision の次に押すと**閉に戻る**（＝やっぱりやめた、を戻しやすく）。
- **Copilot は Vision からの分岐**で、Shift×2 の周回上ではなく、明示的な「案内開始」ボタンで開始する。
- Shift×1（フォーカス切替）と Shift 長押し（音声入力）は現行どおり。

## 4. コスト・プライバシー方針

- 自動文案のLLM呼び出しは、既存の本番Gateway経由でのみ行う（新規または既存の Vision 系
  ルートを利用）。macOS からプロバイダーを直接呼ばない。
- スクショと画像は既存ルールを踏襲する: 処理用の一時ファイルのみ、通常終了時に削除、異常終了で
  残った画像は次回起動時に削除。Vision/自動文案の会話は永続化しない。
- usage には運用情報（機能・モデル・token/秒・成否・処理時間）だけを記録し、画像・入力本文・
  回答本文・アプリ名・ウインドウタイトルは保存しない（現行方針を維持）。
- 「途中経由だけで無駄が出る」件の切り分け: **スクショ取得は常に実行**（軽い・未送信）だが、
  **自動文案のLLM解析は「実際に入力可能な外部フォームにフォーカスがある時」に限定**して発火する
  ことを検討する。これでVision前倒しの利点を残しつつ、コストを実入力の場面に絞る。

## 5. 既存コードとの接続点（コード確認済み）

実コードを読んで確定した差し込み点。

- **状態機械 / Shift検出**
  - `BombSquad/Core/SessionCoordinator.swift`: 全イベントの唯一の解釈点。`handleDoubleTap(in:)`
    が現状 `compose` で「空下書き→キャプチャ→Vision」「非空→レビュー」に分岐。`presentComposeSession()`
    がコンポーズ起動時に `SituationalContextService.captureTask()` を既に走らせている。ここに
    **無音の全画面プリキャプチャ**を足し、Vision移行時に**再利用**する。
  - `BombSquad/Core/AppMode.swift`: 厳密な遷移表。`compose→capturing→vision→navigator→copilot`。
    プリキャプチャ再利用は既存の `compose→capturing→vision` をオーバーレイ無しで通す。
  - `BombSquad/Services/ModifierGestureMonitor.swift`: 右Shift の single/double/long 検出。変更不要。
- **キャプチャ**
  - `BombSquad/Services/ScreenshotCaptureService.swift`: `captureFullScreen(displayID:)` が
    **自アプリのウィンドウを除外**して撮る。無音プリキャプチャにそのまま使える（オーバーレイ不要）。
    一時ファイルは `UniversalIO-Captures` に置かれ、起動時/終了時に掃除される既存ルールに乗る。
  - `BombSquad/Models/ScreenshotAttachment.swift`: 共有する画像の型。`id`/`url`/`captureRect`。
- **コンポーズ（下部スロット）**
  - `BombSquad/Core/ComposeSession.swift`: `draft` / `revisedDraft` / `result` / `focusedField`
    （`.draft`/`.revision`）/ `situationalContext`。`adoptSuggestedDraft(_:)` が既にあり
    「文案→下書き欄へ」に流用できる。`toggleFocusedField()` が Shift×1 の対象切替。ここに
    **自動文案 state**（`suggestion`）と、`.revision` と排他の第2スロット制御を足す。
  - `BombSquad/Core/ComposeSessionView.swift`: `hasResultSurface` で下部 `resultPane` を出し分け。
    ここを「空 / 自動文案 / レビュー結果」の3状態に一般化する。レビューボタンは既に存在
    （`session.requestReview`）。
  - `BombSquad/Models/FocusField.swift`: `.draft`/`.revision`/`.navigator`。自動文案の焦点は
    `.revision` を第2スロットとして共用する（別 case は増やさない）。
- **Vision**
  - `BombSquad/Core/VisionSession.swift` / `BombSquad/Services/GatewayVisionClient.swift`
    （`POST /api/ai/vision`, route `snapshot_vlm`）: プリキャプチャした `ScreenshotAttachment`
    をそのまま渡して即Vision。画像ファイルの所有権は Vision 側へ移り、`tearDown()` で削除される。
- **設定**
  - `BombSquad/Models/AIProvider.swift` の `enum AppSettings`: `isMemoryEnabled` 等と同じ形で
    `isProactiveSuggestEnabled`（既定 true）を足す。オフでもプリキャプチャは続ける。

## 6. サーバー / API（確定方針）

- 既存 `/api/ai/vision` は route/mode/candidates を厳格検証しており（`GatewayVisionClient.decode`）、
  文案生成は意味が違うため**専用ルート `POST /api/ai/suggest` を新設**する。
  - 入力: 画像（base64）＋フォーカス中フォームの文脈（`SituationalContext`: アプリ名・
    ウインドウ・周辺テキスト・要素種別）＋ language。
  - 出力: 文案テキスト＋ `fallback_used` を含む meta（現行 notice ルール準拠）。
  - 実ファイル: `web/app/api/ai/suggest/route.ts`（既存 `web/app/api/ai/vision/route.ts` を範にする）。
- `web/lib/server/ai-routing.ts` の `AIFeature` に `"suggest"` を足し、`AI_MODEL_ROUTES` に画像対応の
  一次/二次（vision と同じ `gpt-5.6-luna` responses 系）を定義。モデル名を散らさない正本ルールに従う。
- クライアントは `BombSquad/Services/GatewaySuggestClient.swift`（新規、`GatewayVisionClient` を範に）。
- 採用/不採用シグナルのメモリ還元は将来検討（本計画のスコープ外）。

## 6-b. 実装フェーズ

1. **Phase 1（クライアントのみ・LLM無し）**: コンポーズ起動時の無音プリキャプチャと、Vision移行時の
   再利用（オーバーレイを飛ばして即Vision）。既存挙動は維持し、`isEmptyDraft` の Vision 入口を高速化。
2. **Phase 2（エンド・ツー・エンド）**: `ComposeSession` に自動文案 state ＋下部スロットUI、
   `AppSettings.isProactiveSuggestEnabled`、`GatewaySuggestClient` ＋ `/api/ai/suggest` ＋
   `ai-routing` の `suggest` エントリ。
3. **Phase 3（周回・ゲート・磨き）**: Shift×2 の周回（閉→コンポーズ→Vision→閉、レビューはボタンのみ）、
   発火ゲート（`SituationalContext` に編集可能フォーカス判定を追加）、ヘルプ文言・設定トグルUI・テスト。

## 7. 現在の状態と次セッションへの引き継ぎ（2026-07-24）

**作業ブランチは `dev` に一本化**（細別ブランチは廃止）。以降の作業も `dev`。
**`dev` は `main` へ fast-forward マージ済みで、`dev` = `main` = `origin` が同期している**（現在 `1ee2a78`）。
`main` へのマージ＝**本番Gatewayデプロイ**なので、web/ を触った時は必ず意識する（クライアントのみの変更は
Gateway に影響しない）。配布中のDMG（v0.1.1）は別物で、`release.sh` を回さない限り変わらない。

検証状況: `xcodebuild build`＋テスト7件グリーン、web `lint`／`npm run build`（本番ビルド）グリーン。

> **✅ 先回り文案は本番で動作確認済み（2026-07-24 実機）**。入力欄にフォーカスしてパネルを開くと候補文が出る。

### 実装済み（dev）

- 先回り文案（Compose Vision Suggest）: 起動時の無音プリキャプチャ→Vision 再利用、`/api/ai/suggest`
  （`suggest-engine` ＋ `ai-routing` の `suggest`）＋ `GatewaySuggestClient`、下部スロット排他表示、
  `AppSettings.isProactiveSuggestEnabled` ＋設定トグル。
- フォーカス判定を**同期化**（`SituationalContextService.focusedFieldIsEditable(pid:)`）——パネル前面化前に
  読むので `editableFocus=false` 誤判定を解消。判定結果 `composeFocusEditable` で文案ゲート。
- ルーティング: idle で Shift×2 →「選択あり=変換／編集欄フォーカスあり=コンポーズ／無し=最初から Vision」。
  `AppMode` に `idle→capturing` を追加。`handleVisionCaptureCompletion` は composeSession を optional 化。
- 下部スロットは文案・レビュー結果・表示すべきエラーが届いた時だけ開く。preparing中はコンパクトな
  Compose操作列に「画面分析中」または「レビュー中」とスピナーを表示し、空の結果領域を予約しない。
  `[Suggest]` の DEBUG ログを各判定点に追加（Console で発火理由が見える）。
- Google ログイン: `prompt=select_account` でアカウント選択毎回、キャンセルは `infoMessage` で穏当化。
- エラー文言: `UserFacingError` ＋ `UserPresentableError` マーカー（自前エラーのみ日本語温存、SDK 英語は非露出）。
- 画面収録許可: 「許可」で毎回 設定の該当ペインを直接オープン＋押下フィードバック＋正しい名称の案内。
- Keychain: データ保護キーチェーン化は**revert 済み**（下記）。

### ✅ 解消済み: `/api/ai/suggest` の本番未デプロイ（2026-07-24）

**これが「何度やっても文案が出ない」の唯一の根本原因だった。** クライアントは正しく動いていたが、
呼び先が本番に存在しなかった。

- 症状の確定: 本番 `POST /api/ai/suggest` が **HTTP 404（HTML の 404 ページ＝ルート自体が無い）**。
  同時に `POST /api/ai/vision` は 400 を返す＝ Gateway 自体は正常。ルートファイルは `dev` にのみ存在し
  `main` に無かった。本番は `main` からデプロイされるため、届いていなかった。
- 対処: `dev` → `main` を fast-forward マージして push（Gateway への差分は
  `api/ai/suggest/route.ts`・`suggest-engine.ts`・`ai-routing` の `suggest` 追加のみ＝**純粋な追加**、
  既存ルート不変）。事前に `npm run build` を通し、ルート表に `ƒ /api/ai/suggest` が出ることを確認済み。
- 結果: 本番が **404 → 400 `{"error":{"code":"BAD_REQUEST"}}`** に変化＝**ルート稼働**。
- **デプロイルール**: `main` にコミット＝本番デプロイ。ブランチ push＝Vercel プレビュー（別ドメインなので
  アプリからは使えない＝実検証には main/本番が要る）。`vercel` CLI 不在・CI workflow 無し＝ git 連携。

### ✅ 完了: エラーを隠さない（2026-07-24）

ユーザー原則:「**問題を隠さない／安易なフォールバックをしない／何が起きているかエラーで見せる**」。
失敗（例外）と 空（モデルが候補無し）を**区別**し、失敗は実エラーを表示するようにした。

- `ComposeSession`: `suggestionErrorMessage` / `suggestionErrorDetail` ＋ `markSuggestionFailed(_:detail:)`。
  `markSuggestionUnavailable()` は「候補無し」専用として残す。成功・再試行時はエラーを消す。
- `SessionCoordinator`: リクエストの catch と**プリキャプチャ失敗**の両方を `markSuggestionFailed` へ。
  技術詳細は `technicalDetail(for:)`（domain/code + 生メッセージ）。
- `ComposeSessionView`: `.unavailable` 分岐でエラーがあれば警告アイコン＋文言＋技術詳細（小・選択可）。

- 同原則で**残っている見直し候補**: `presentVisionFromIdle` の「画面収録なし→compose に無言フォールバック」、
  各所の `try?`。安易に握りつぶさず、必要な所は理由を見せる。

### ✅ 完了: 候補文は「確定1回」で送信（2026-07-24）

ユーザー指摘:「候補文にフォーカスすると UI がまた変わってメイン入力欄のようになり、そこから確定する
＝**二度手間**。この流れは不要」。

- 旧: 候補文で確定 → `adoptSuggestion()` が**下書き欄へテキストを移すだけ**（候補スロットが畳まれて
  パネルが変形）→ **もう一度確定**して初めて送信。
- 新: `deploySuggestion()` が（その場で編集した内容ごと）**ターゲット欄へ直接送信**し、スロットを閉じる。
  レビュー結果の `deployRevision()` と同じ挙動に揃えた。主ボタンも「採用」→「**送信**」。
- 下部スロットはもともとその場で編集可能なので、下書きへ移す中間ステップに価値が無かった。

### 次セッション: 体験のブラッシュアップ（候補）

- **フォーカス時の見た目の変化**: 二度手間自体は解消したが、Shift×1 で候補スロットへフォーカスした時に
  「形が変わる」印象は残っている（`EditorFocusBackground` の強調＋レイアウト）。落ち着いた見せ方を検討する。
- **残る無言フォールバック**（「問題を隠さない」原則の続き）: `presentVisionFromIdle` の
  「画面収録なし → 無言で compose へ」、各所の `try?`。理由を見せるべき所を洗い出す。
- **発火ゲートの精度**: Web/Electron アプリでの編集可能フォーカス判定（`focusedFieldIsEditable`）。
- **自動テスト**: suggestion の state 遷移（preparing→ready/unavailable/failed、送信後のクリア）。
- **文案の質**: プロンプト（`suggest-engine`）は初版。実利用での手応えを見て調整する。

### 2026-07-24 ブラッシュアップ

- `suggest-engine` の推論を `none` から `low` へ変更した。画面上の根拠だけを機械的に埋めるのではなく、
  表示中の会話、作業状態、入力欄の役割から「このユーザーなら次に何を書くか」を合理的に推論する。
  短さを固定せず、状況に対して簡潔だが十分な1案を返す。
- 共通の判断プロンプトとPersona添付を分離した。現行の既定Personaは、事業開発とソフトウェア開発を
  横断するFounder／Engineer／Designer／Business professional。将来はアカウントプロフィール由来の
  Personaでこの添付だけを置換できる構造とした。
- Visionを明示的に閉じた後、呼び出し元アプリを再アクティブ化する。従来はUniversal I/Oが前面に残り、
  次回Shift×2の編集可能判定が自アプリPIDに対してfalseとなり、直接Visionへ誤ルーティングしていた。
  別アプリのクリックによる`resignActive`終了と、送信時の`PasteDeployer`経路ではフォーカスを奪い返さない。
- Composeは通常`680×420`で開き、文案・レビュー結果・エラーの表示時だけ`680×660`へ下方向に拡張する。
  画面分析／レビューの待機中は操作列のスピナーだけを表示する。Reduce Motion時はサイズ変更をアニメーション
  しない。Compose原文、AI文案、レビュー文案、Vision質問は共通の紙飛行機ボタンへ統一し、AI文案の
  「破棄」は削除した。各アイコンには用途別のVoiceOverラベルとEnterのhelpを付ける。
- パネルは毎回カーソルのある画面の中央へ初期配置するが、表示後は非インタラクティブな背景・余白と
  各結果ヘッダーをドラッグして自由に移動できる。位置はセッションをまたいで保存しない。
- 最新の人間メッセージについて、表示順、話者、宛先、行為主体を文案生成前に確認する共通ルールを
  追加した。相手が請求書等を作成・添付した場面では、ユーザーが作成者であるかのように言い換えず、
  受領・確認する側として返信する。
- macOSが既に取得していたbundle IDをGatewayへ渡し、共通判断、Personaとは別の
  **アプリ文脈添付**を必要時だけ差し込む構造を追加した。初期添付はSlack（名前／avatar＝話者、
  色付きmention＝宛先、下側＝最新、添付の所属、システムnotice除外）とGmail（From／To、
  thread順、引用部、添付の所属）。bundle IDに加えアプリ名・window titleでも判定するため、
  ブラウザ版にも適用できる。未知のアプリは共通ルールだけで動作する。
- アプリ文脈の定義とresolverを`web/lib/server/suggest-context-packages.ts`へ分離した。Slack／Gmailは
  それぞれ独立した既定パッケージで、今後もDocs、Sheets等を製品単位で同じ配列へ追加する。
- 同じ誤認が続いたため、推論を`medium`へ上げ、話者、宛先、ユーザーの立場、添付所有者、依頼、
  返信意図をstrict schemaで先に出力してから文案を作る`speaker-grounding-v2`へ変更した。
  認知結果は検証中の説明欄へ表示し、Gateway応答metaの`prompt_version`と`context_package`で
  本番実行時に新プロンプトとアプリパッケージの適用有無を確認できる。

### そのほかの引き継ぎ事項

- **Keychain 保存プロンプト**: データ保護キーチェーン（access group 無し）は実行時に壊れ、PKCE の
  code_verifier を失って Google ログインが失敗した → **login キーチェーンへ revert 済み**（commit ef84673）。
  プロンプト問題は未解決だが、これは**開発環境固有**（署名が毎ビルド変わるため）で**本番（Developer ID 安定署名）
  では出ない**。本気で消すなら `keychain-access-groups` entitlement＋プロビジョニングプロファイルが必要（署名
  インフラ変更＝ユーザー判断）。同じ access-group 無しデータ保護方式は**再挑戦しないこと**。詳細 memory
  `signing-tcc-identity`。
- **リリース/パッチは不要**（公開版 v0.1.1 は身内のみ利用、まだ実ユーザーなし）。今は技術検証優先。
  main と v0.1.1 タグは auth/permissions 系ファイルが同一＝UX 修正は将来そのまま効く。
- 発火ゲート精度（Web/Electron の編集可能判定）と自動テスト（suggestion state 遷移）は将来課題。

## 8. パージ手順

本機能を含む dev の巻き戻しは Git 履歴から。dev は単一開発ブランチのため、個別機能だけの purge は
`git revert <commit>` で行う（ブランチ削除での一括 purge は前提としない）。
