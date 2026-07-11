# Agent Rules (app-mac)

## Session Start Protocol（必読・毎セッション）

1. コードやドキュメントに触る前に **[docs/README.md](docs/README.md)（ドキュメント索引）を読む**。
   どのファイルが正本で、どれがアーカイブかはそこが唯一の答え。
2. 現行の開発正本は [docs/foundation-rebuild-plan.md](docs/foundation-rebuild-plan.md)。
   作業の開始・完了・方針変更は**同じコミットで**この正本に反映する。
3. ドキュメント管理ルール（増やすなら畳む・索引登録必須・old/ 運用）は
   docs/README.md の「ドキュメント管理ルール」に従う。**新規 .md の無断作成は禁止**。

# Worktree Guard

This worktree is the active source of truth for the current foundation redesign
thread.

Path:
- `/Users/kaya.matsumoto/projects/universal-io/app-mac`

Rules:
- Do code changes for the resumed mainline thread in this worktree.
- The stabilization worktree remains a recovery reference only:
  `/Users/kaya.matsumoto/projects/universal-io/app-mac-stabilize-foundation`
- If work intentionally moves away again in the future, update this file first.

Current branch:
- `feature/foundation-redesign`

Current operational note:
- The validated stabilization state was adopted into this branch on 2026-07-11.
- Continue implementation here unless a new recovery handoff is explicitly documented.
