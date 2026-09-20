# app-mac

macOSクライアント専用。Gateway・認証基盤・課金・Supabaseの変更先は `../api-gateway`。
各ディレクトリは独立したGitリポジトリ。gitは `git -C <絶対パス>`、npmは
`npm --prefix <絶対パス>` を使い、コミット前に対象リポジトリの `status --short` を確認する。
`api-gateway` のmainへのpushは本番API、`web-product` は製品サイトの本番デプロイになる。

## 作業別の入口

依頼に該当する節だけ参照する。リンク先の通読・全検証は開始条件ではない。

| 作業 | 参照先 |
|---|---|
| ビルド・実機確認 | [開発](README.md#開発) |
| Keychain不具合 | [診断](README.md#キーチェーンの診断) |
| リリース | [リリース運用](README.md#リリース運用)、[Golden Paths](docs/manual-golden-paths.md)、[UXチェック](docs/macos-ux-polish-checklist.md) |
| 前回の続き・未完了事項 | [HANDOFF](HANDOFF.md) の該当項目 |
| 製品仕様・開発方針 | [マスタープラン](docs/universal-io-master-plan.md) の該当項目 |
| 文書の追加・整理、正本の所在確認 | [文書索引](docs/README.md) |
| API契約・サーバー設計 | [API契約](../api-gateway/docs/api-contract.md)、[設計思想](../api-gateway/docs/design-philosophy.md) |
| 外部アカウント・OAuth・DB | [Supabase設定](../api-gateway/docs/supabase-setup.md) |

## 維持する制約

- mainlineの変更は `/Users/kaya.matsumoto/projects/universal-io/app-mac` で行う。
  `app-mac-stabilize-foundation` は復旧参照専用。作業場所を意図的に移すなら先にこの指定を更新する。
- 本番経路は一つ。旧Navigator、local Gateway、BYOK fallback、常設の本番代替経路・test/eval harnessを復活させない。
  実験は隔離した短命ブランチで行い、終了時に実装・fixture・flag・設定・説明文を撤去する。
- CLIの署名なし検証ビルドは起動しない。実機確認はXcodeから署名付きで行う。
  公開前には候補DMGでGolden Pathsを確認し、同一byte列を公開する。署名ビルドごとにbuild番号を上げる。
- 新規 `.md` は無断作成せず、追加時は索引にも同じコミットで登録する。
  仕様・方針・進捗が変わる時だけ該当正本を同じコミットで更新する。
- Supabaseは `supabase_bomb_squad` のみ。schema/data read・SQL作業前にproject URLが
  `https://skcsbcyivjcvevxntvqa.supabase.co` と完全一致することを確認する。
  不一致や期待するテーブルの欠落時は停止し、正しいMCPの再接続・セッション再開を依頼する。代替DBを作らない。
  書き込みごとにURLを再確認し、SQL/migrationレビューとユーザーの明示承認を得る。
