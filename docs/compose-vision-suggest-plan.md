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

## 7. 進捗 / 残タスク

Phase 1〜3 実装済み（`feature/compose-vision-suggest`）:

- [x] コンポーズ起動時の無音プリキャプチャと Vision 再利用（Phase 1）。
- [x] `/api/ai/suggest` ＋ `suggest-engine` ＋ `ai-routing` の `suggest` ＋ `GatewaySuggestClient`（Phase 2）。
- [x] `ComposeSession` の自動文案 state（preparing/ready/unavailable）と下部スロットの排他表示・採用・編集（Phase 2）。
- [x] `AppSettings.isProactiveSuggestEnabled` ＋ `GeneralSettingsView` のトグル（Phase 3）。
- [x] `SituationalContext.focusedFieldEditable` による発火ゲート（Phase 3）。
- [x] Shift×2 周回（コンポーズ→Vision常時、レビューはボタン）＋ヘルプ文言・`needsReReview` ヒント・README 操作（Phase 3）。

残タスク（要検討）:

- [ ] 実機での体感確認（発火タイミング、文案品質、`suggest` の遅延）。まだ手動 golden path 未追加。
- [ ] 発火ゲートの精度（Web/Electron の編集可能判定、`isContextCaptureEnabled` オフ時は文案も出ない依存の是非）。
- [ ] 採用/不採用シグナルのメモリ還元（将来）。
- [ ] 自動テスト追加（suggestion state 遷移、排他表示）。

## 8. パージ手順

ボツ時は以下でクリーンに戻す。

```bash
git checkout main
git branch -D feature/compose-vision-suggest
```

本計画の内容・コード・設定はすべて本ブランチ内に閉じるため、上記だけで作業ツリーから消える。
