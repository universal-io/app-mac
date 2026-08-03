# ドキュメント索引

最終更新: 2026-08-03 ／ ステータス: 現行

このファイルがドキュメントの唯一の入口です。実装の正は現行コード、製品計画の正は
`universal-io-master-plan.md`、APIの正は `api-contract.md` です。

## 正本

| ドキュメント | 役割 |
|---|---|
| [../README.md](../README.md) | 現行機能、実行経路、開発手順 |
| [universal-io-master-plan.md](universal-io-master-plan.md) | 製品ビジョンとリリース・マイルストーン |
| [design-philosophy.md](design-philosophy.md) | 設計思想（北極星＝ユーザー起点の世界モデル、作る順序） |
| [api-contract.md](api-contract.md) | macOSクライアントと本番Gatewayの契約 |
| [manual-golden-paths.md](manual-golden-paths.md) | リリース前の手動検証 |
| [dev-prod-app-identity.md](dev-prod-app-identity.md) | 開発版と本番版のアプリ正体分離（Launchpad/Launch Services 対策） |
| [macos-ux-polish-checklist.md](macos-ux-polish-checklist.md) | リリース前 UX 磨き込みチェックリスト（TCC/ウィンドウ/署名） |
| [supabase-setup.md](supabase-setup.md) | 認証・データ基盤の設定 |
| [admin-dashboard-plan.md](admin-dashboard-plan.md) | 本番Admin Console |
| [v3-tool-fit-plan.md](v3-tool-fit-plan.md) | v3 ツール適合（Skills とユーザーファクト）の設計根拠 |
| [focused-vision-plan.md](focused-vision-plan.md) | 完了したR9、Selection Extension改修（R10）、将来のAX直接入力研究の正本 |
| [reliability-hardening-plan.md](reliability-hardening-plan.md) | 起動確実性と公開品質（R11）。長時間稼働での無音停止の原因分析と技術的負債の棚卸し |

## 参照資料

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
