# ドキュメント索引

最終更新: 2026-09-03 ／ ステータス: 現行

このファイルがドキュメントの唯一の入口です。実装の正は現行コード、製品計画の正は
`universal-io-master-plan.md` です。

**APIとサーバー側の正本はこのリポジトリにありません。** 2026-08-16にGatewayを
`universal-io/api-gateway` へ切り出しました（下記「他リポジトリにある正本」）。

## 正本（このリポジトリ）

| ドキュメント | 役割 |
|---|---|
| [../HANDOFF.md](../HANDOFF.md) | **次のセッションが最初に読む。いま何をすべきか。** 1本だけを保ち、役目を終えた記述は消す |
| [../README.md](../README.md) | 現行機能、実行経路、開発手順 |
| [universal-io-master-plan.md](universal-io-master-plan.md) | 製品ビジョンとリリース・マイルストーン |
| [manual-golden-paths.md](manual-golden-paths.md) | リリース前の手動検証 |
| [macos-ux-polish-checklist.md](macos-ux-polish-checklist.md) | リリース前 UX 磨き込みチェックリスト（TCC/ウィンドウ/署名） |
| [v3-tool-fit-plan.md](v3-tool-fit-plan.md) | v3 ツール適合（Skills とユーザーファクト）の設計根拠 |
| [focused-vision-plan.md](focused-vision-plan.md) | 完了したR9、Selection Extension改修（R10）、将来のAX直接入力研究の正本 |
| [ga4-complete-skill-plan.md](ga4-complete-skill-plan.md) | R8 M6: GA4を1本目の「完全サポート」Skillにする実証実験。用事一覧・器の論点・実測記録 |

## 他リポジトリにある正本

**`universal-io/api-gateway`**（本番Gateway。`api.universal-io.com`）

| ドキュメント | 役割 |
|---|---|
| `docs/api-contract.md` | **APIの正本。** macOS/iOS/Webクライアントと本番Gatewayの契約 |
| `docs/design-philosophy.md` | **設計思想の正本。** 北極星＝ユーザー起点の世界モデル、作る順序 |
| `docs/supabase-setup.md` | 認証・データ基盤の設定 |
| `docs/admin-dashboard-plan.md` | 本番Admin Console |
| `docs/reliability-hardening-plan.md` | 起動確実性と公開品質（R11） |
| `docs/guidance-accuracy-plan.md` | 案内の正確さ（R12） |
| `docs/latency-plan.md` | 応答時間の内訳と改善 |
| `docs/vision-selection-evidence-fix.md` | R10.5 selection判定の記録 |
| `docs/dev-prod-app-identity.md` | 開発版と本番版のアプリ正体分離 |

**`universal-io/app-web`**（Webクライアント企画）

| ドキュメント | 役割 |
|---|---|
| `docs/requirements.md` | リポジトリ構成の決定とGateway切り出しの経緯 |

## 参照資料

- [vision-bubble-placement-review.md](vision-bubble-placement-review.md) — R14のバブル配置が4回再発した経緯、実測、2026-09-02のレビュー・実装・実機確認記録
- [pitch/](pitch/) — ピッチとGTM資料
- [promo/](promo/) — 紹介動画シナリオ

## 運用ルール

1. 同じ役割の正本を複数作らない。
2. 新しい `.md` はこの索引への登録と同じコミットで作る。
3. 実験は短命ブランチだけで行い、終了時に実装・fixture・flag・専用設定・説明文を削除する。
4. 失敗した方式を作業ツリーにアーカイブしない。必要ならGit履歴から参照する。
5. 方針変更はREADME、該当正本、コードを同じコミットで更新する。
6. `test`、`mock`、`dummy`、`fixture`、`experiment`、`challenge`、`shadow`という本番代替経路を
   常設しない。必要な検証は隔離した短命ブランチで実施する。
7. **Gateway・API・課金・Supabaseに関する変更は `api-gateway` リポジトリで行う。**
   このリポジトリはmacOSクライアントだけを持つ。
