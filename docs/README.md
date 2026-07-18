# ドキュメント索引

最終更新: 2026-07-18 ／ ステータス: 現行

このファイルがドキュメントの唯一の入口です。実装の正は現行コード、製品計画の正は
`universal-io-master-plan.md`、APIの正は `api-contract.md` です。

## 正本

| ドキュメント | 役割 |
|---|---|
| [../README.md](../README.md) | 現行機能、実行経路、開発手順 |
| [universal-io-master-plan.md](universal-io-master-plan.md) | 製品ビジョンとリリース・マイルストーン |
| [api-contract.md](api-contract.md) | macOSクライアントと本番Gatewayの契約 |
| [manual-golden-paths.md](manual-golden-paths.md) | リリース前の手動検証 |
| [supabase-setup.md](supabase-setup.md) | 認証・データ基盤の設定 |
| [admin-dashboard-plan.md](admin-dashboard-plan.md) | 本番Admin Console |

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
