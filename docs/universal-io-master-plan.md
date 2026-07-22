# Universal I/O マスタープラン

最終更新: 2026-07-22 ／ ステータス: `v0.1.0` 公開済み・次期開発準備

## 製品

Universal I/O は、人が情報を送る・受け取る・画面上で行動する間に入り、意図と表現を
整える中間レイヤーである。自律操作ではなく、最終判断と操作はユーザーが行う。

製品surfaceは4つだけとする。

1. Compose: 自分の文章を作り、必要ならレビューして送信する。
2. Transform: 受信文章を理解し、返信や次の行動を準備する。
3. Vision: 現在の画面を読み、質問へ答える。
4. Copilot: 画面上の次の一手を示し、ユーザー操作後に再評価する。

## 現行アーキテクチャ

```text
macOS UI
  └─ SessionCoordinator
       ├─ ComposeSession  ── /api/ai/review
       ├─ TransformSession ─ /api/ai/transform
       ├─ VisionSession ──── /api/ai/vision
       └─ GatewayTranscriber /api/ai/transcribe
                              │
                       Production Gateway
                              │
                       AI providers + Supabase
```

設計原則:

- 状態遷移は `SessionCoordinator` に集約する。
- 各surfaceはSessionとViewを1組だけ持つ。
- AIは本番Gateway経由だけ。macOSからプロバイダーを直接呼ばない。
- ローカルGateway、BYOK、旧endpoint、shadow実行、macOS側のfallbackを持たない。
- 全AI機能はGatewayの単一モデルルーターで一次・二次モデルを指定する。一次失敗時だけ二次を
  1回実行し、切替時はユーザーへ共通noticeを表示する。両方失敗時は共通エラーを返す。
- Visionは画像、同一captureの候補、会話を1回のVLM呼び出しへ渡す。
- モデル結果が選んだcandidate IDだけを、コードが保持する矩形へ変換する。
- 実験は短命ブランチで完結し、本番ツリーへ残さない。

モデルルーティングの正本は `web/lib/server/ai-routing.ts` だけとする。個別engine、route、
macOS、環境変数にモデル名やfallback順序を重複させない。Admin Consoleはこの正本を読み、
各機能の一次・二次、vendor、model ID、API方式をそのまま表示する。

## データ境界

- 認証、entitlement、usage、同期メモリはSupabaseを正とする。
- 下書きとCompose送信履歴はMacローカル。履歴上限は100件。Transformは一切履歴化しない。
- スクリーンショット、音声、周辺コンテクストは処理用で、Gatewayへ恒久保存しない。一時画像は
  セッション終了時、異常終了で残った画像は次回起動時に削除する。
- 同期メモリを削除した時は、同期用tombstoneからも本文と相手名を消去する。
- usageと運用ログには入力本文、画像・音声、画像パス、アプリ名、ウインドウタイトルを保存しない。
- APIキーはGateway環境だけに置く。macOSのKeychainへAI APIキーを保存しない。

## リリースまでのマイルストーン

### R1 — 経路一本化（完了、2026-07-18）

- 現行Visionを正式な `VisionSession` と `/api/ai/vision` に昇格。
- 旧Vision、Navigator v3/v4、Run、shadow、harness、fixture、local Gateway、BYOKを削除。
- Compose、Transform、Transcribe、Memoryを本番Gateway専用に統一。
- 実験資料とアーカイブをGit履歴へ戻し、作業ツリーから削除。

### R2 — 機械検証（完了、2026-07-22）

- XcodeGen生成が成功する。
- macOS Debugを署名なしでビルドできる。
- Web lint、TypeScript、production buildが成功する。
- 本番route一覧とクライアントendpointが一対一で一致する。
- リポジトリ内に旧経路の参照が残っていない。

### R3 — 本番E2E（進行中）

- ログイン、レビュー、音声入力、受信変換、Vision、Copilot、履歴、メモリを実機確認。
- 本番Gatewayで全routeがJSON/SSE契約を返し、404 HTMLを返さない。
- 全AI機能で実モデルと `fallback_used` をクライアントとusageで確認する。
- 一次失敗時は二次で成功して共通noticeが表示され、両方失敗時は共通エラーになる。
- 権限再起動、ネットワーク障害、期限切れsessionで明示的エラーになる。

### R4 — リリース品質

- [manual-golden-paths.md](manual-golden-paths.md) を全項目実施。
- UI文言、フォーカス、キーボード操作、VoiceOverラベルを確認。
- クラッシュ、秘密情報、ログへの入力本文・画像パス漏洩を点検。
- 署名、Hardened Runtime、notarization、DMG、更新導線を確認。

### R5 — 公開（`v0.1.0` 完了、2026-07-22）

- 正式版は `0.1.0`（build `2`）、Gitタグは `v0.1.0`、ソースは `700f607`。
- main、本番Gateway、Webサイトをdeploy済み。
- Developer ID署名、notarization、staple、Gatekeeper評価済みDMGを配布。
- 公開DMGはversion／build別の不変URLへ保存し、Webサイトは不変URLを直接参照する。
  version aliasとlatest aliasも互換用に更新する。
- 公式DMGのSHA-256は
  `e0b08385d11cb591019490a93a5bfc2aa3b0f510ef577f116ab768c3f90f2f90`。
- 初期usage、エラー率、レイテンシを監視する。

## リリース判定

以下をすべて満たした時だけ公開する。

- R2〜R4が完了している。
- 主要5 AI endpointに旧・代替endpointが存在せず、各routeのモデル指定が共通SSOTだけにある。
- 重大度Highの既知不具合が0件。
- Composeのレビュー後フォーカス、履歴復元、音声入力、Vision初回応答が実機で再現可能。
- rollback先と本番Gatewayの互換性が確認されている。

## 次期改善候補（2026-07-22 実機テスト所見）

以下は現行リリースの阻害要因ではなく、別セッションで設計・実装する改善候補とする。

### Copilot完了時の終了・フィードバック導線

- 完了時の「目的の情報を確認しました」は、状態説明なのか案内終了なのか意図が曖昧。
- 「目的を達成したので閉じる」「案内を終了」など、ユーザーが完了を確認して閉じる明示的な
  操作に置き換える。この操作は目的達成のフィードバック信号としても扱えるようにする。
- 完了操作の横にGood / Badとコメント用の吹き出しを置き、任意で評価や具体的な意見を
  運営へ送れる導線を検討する。
- 収集項目、送信前の説明、本文・画像・画面情報を含めるかどうか、保存期間を実装前に定め、
  ユーザーの意図しない情報を送信しない。

### Transformのパネル内スペース配分

- 画面内テキストを選択してTransformを開いた時、選択元テキストの入力欄が縦に広すぎて
  解説・変換結果の表示領域を圧縮している。
- 選択元テキストは確認に必要な高さへ抑え、解説・変換結果へ優先的に縦方向のスペースを割く。
- 長文時のスクロール、最小・最大高、ウインドウサイズ変更時の配分を含めてUIを調整する。

### メモリ学習の品質評価

- 現行は送信差分から高確度の文体・関係性メモを抽出し、重複排除した直近20件をレビューへ
  注入する。経路は機能するが、推論されたメモの正確性は実利用で評価する必要がある。
- 誤学習率、レビュー品質への寄与、相手名の重複、ユーザーが修正・削除した割合を測定し、
  自動反映を続けるか、保存前確認方式へ変更するかを決める。
- usageの保持期間、アカウント削除、provider ZDRをプライバシー運用として確定する。

## 変更ルール

新しい方式を試す時は、この本番構造を変更する前に短命ブランチを作る。採用時は現行方式を
同じ変更で置換し、不採用時はブランチを閉じる。二方式の常設並走は禁止する。
