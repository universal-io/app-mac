# Agent Rules (app-mac)

## 隣にもう1つリポジトリがある（毎セッション必読）

`/Users/kaya.matsumoto/projects/universal-io/` の下に**独立した2つのgitリポジトリ**がある。

| パス | 中身 | `main` へのpushが意味すること |
|---|---|---|
| `app-mac` | macOSアプリ ＋ Gateway（`web/`） | `api.universal-io.com` の本番デプロイ |
| `web-product` | 製品サイト（別リポジトリ） | `universal-io.com` の本番デプロイ |

**エージェントのシェルは作業ごとに `app-mac` へ戻る。** `cd` した直後でも、次の
コマンドでは `app-mac` にいる。したがって裸の `git add -A && git commit` は、
どこで作業していたつもりでも `app-mac` にコミットされる。

実際に2026-08-02〜03のセッションで、`web-product` 向けのコミットが2回
`app-mac` に入り、そのたびに `README.md` の無関係な変更が別物のコミットメッセージで
記録された（どちらも `git reset --soft` で取り消し済み）。

規則:

- **gitは必ず `git -C <絶対パス>` を使う。** `cd` してから裸の `git` を打たない。
- npmも同様に `npm --prefix <絶対パス>`、またはそのコマンド内で `cd` を完結させる。
- コミット前に `git -C <パス> status --short` で、想定したファイルだけが載っているか確認する。
- 取り違えに気づいたら `git -C <誤ったパス> reset --soft HEAD~1` で戻し、
  巻き込んだファイルを `restore --staged` してから正しいリポジトリへ入れ直す。

## Session Start Protocol（必読・毎セッション）

1. コードやドキュメントに触る前に **[docs/README.md](docs/README.md)（ドキュメント索引）を読む**。
   どのファイルが正本で、どれがアーカイブかはそこが唯一の答え。
2. 現行の製品・開発正本は [README.md](README.md) と
   [docs/universal-io-master-plan.md](docs/universal-io-master-plan.md)。
   作業の開始・完了・方針変更は**同じコミットで**該当する正本に反映する。
3. ドキュメント管理ルール（増やすなら畳む・索引登録必須・old/ 運用）は
   docs/README.md の「ドキュメント管理ルール」に従う。**新規 .md の無断作成は禁止**。

# Worktree Guard

This worktree is the active source of truth for the mainline and the upcoming
Copilot accuracy work.

Path:
- `/Users/kaya.matsumoto/projects/universal-io/app-mac`

Rules:
- Do code changes for the resumed mainline thread in this worktree.
- The stabilization worktree remains a recovery reference only:
  `/Users/kaya.matsumoto/projects/universal-io/app-mac-stabilize-foundation`
- If work intentionally moves away again in the future, update this file first.

Current branch:
- `feat/vision-selection-extension`（復帰点は
  `pre-vision-selection-extension-20260731` / `dcac535`。Focused Visionを
  通常Visionへの純粋なselection extensionへ改修する短命ブランチ）

Current operational note:
- 2026-07-18: Vision/Copilotを単一の本番経路へ統合。旧Navigator、実験名、
  runtime flag、local Gateway、BYOK fallback、常設test/eval harnessは削除済み。
- 実験は短命ブランチで行い、終了時に本番ツリーへ残さない。

# Supabase Production Writes

- Bomb Squadの正しいMCPは `supabase_bomb_squad`、project refは
  `skcsbcyivjcvevxntvqa`。汎用名 `supabase` や他プロジェクトのMCPを使わない。
- schema/data readおよびSQL作業の前にproject URLを確認し、
  `https://skcsbcyivjcvevxntvqa.supabase.co` と完全一致しなければ停止する。
- 書き込み前にはURLを再確認し、migrationまたはSQLをレビューして、ユーザーの
  明示承認を得る。MCPがwrite-capableであること自体は実行承認ではない。
