# Universal I/O マスタープラン

最終更新: 2026-07-18 ／ ステータス: リリース前安定化

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
- 旧方式へのfallback、feature flag、shadow実行、ローカルGateway自動選択を持たない。
- Visionは画像、同一captureの候補、会話を1回のVLM呼び出しへ渡す。
- モデル結果が選んだcandidate IDだけを、コードが保持する矩形へ変換する。
- 実験は短命ブランチで完結し、本番ツリーへ残さない。

## データ境界

- 認証、entitlement、usage、同期メモリはSupabaseを正とする。
- 下書きと入力履歴はMacローカル。履歴上限は100件。
- スクリーンショット、音声、周辺コンテクストは処理用で、Gatewayへ恒久保存しない。
- APIキーはGateway環境だけに置く。macOSのKeychainへAI APIキーを保存しない。

## リリースまでのマイルストーン

### R1 — 経路一本化（完了、2026-07-18）

- 現行Visionを正式な `VisionSession` と `/api/ai/vision` に昇格。
- 旧Vision、Navigator v3/v4、Run、shadow、harness、fixture、local Gateway、BYOKを削除。
- Compose、Transform、Transcribe、Memoryを本番Gateway専用に統一。
- 実験資料とアーカイブをGit履歴へ戻し、作業ツリーから削除。

### R2 — 機械検証（進行中）

- XcodeGen生成が成功する。
- macOS Debugを署名なしでビルドできる。
- Web lint、TypeScript、production buildが成功する。
- 本番route一覧とクライアントendpointが一対一で一致する。
- リポジトリ内に旧経路の参照が残っていない。

### R3 — 本番E2E

- ログイン、レビュー、音声入力、受信変換、Vision、Copilot、履歴、メモリを実機確認。
- 本番Gatewayで全routeがJSON/SSE契約を返し、404 HTMLを返さない。
- Visionのcapture ID、model、fallbackなしをクライアントとusageで確認。
- 権限再起動、ネットワーク障害、期限切れsessionで明示的エラーになる。

### R4 — リリース品質

- [manual-golden-paths.md](manual-golden-paths.md) を全項目実施。
- UI文言、フォーカス、キーボード操作、VoiceOverラベルを確認。
- クラッシュ、秘密情報、ログへの入力本文・画像パス漏洩を点検。
- 署名、Hardened Runtime、notarization、DMG、更新導線を確認。

### R5 — 公開

- mainへ統合し、本番Gatewayを先にdeployする。
- 本番routeの疎通確認後にmacOSビルドを配布する。
- version/build番号、release note、rollback tagを確定する。
- 初期usage、エラー率、レイテンシを監視する。

## リリース判定

以下をすべて満たした時だけ公開する。

- R2〜R4が完了している。
- 主要5 AI endpointに旧・代替endpointが存在しない。
- 重大度Highの既知不具合が0件。
- Composeのレビュー後フォーカス、履歴復元、音声入力、Vision初回応答が実機で再現可能。
- rollback先と本番Gatewayの互換性が確認されている。

## 変更ルール

新しい方式を試す時は、この本番構造を変更する前に短命ブランチを作る。採用時は現行方式を
同じ変更で置換し、不採用時はブランチを閉じる。二方式の常設並走は禁止する。
