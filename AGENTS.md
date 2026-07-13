# Agent Rules (app-mac)

## Session Start Protocol（必読・毎セッション）

1. コードやドキュメントに触る前に **[docs/README.md](docs/README.md)（ドキュメント索引）を読む**。
   どのファイルが正本で、どれがアーカイブかはそこが唯一の答え。
2. 現行の開発正本は [docs/navigator-stabilization-followups.md](docs/navigator-stabilization-followups.md)。
   作業の開始・完了・方針変更は**同じコミットで**この正本に反映する。
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
- `main`

Planned transition:
- foundation rebuild merged into `main` as `8977f57`
- branch `feature/copilot-accuracy` from this integrated main

Current operational note:
- The foundation rebuild passed GP-01〜27 and was integrated into main on 2026-07-13.
- After integration, continue Copilot model/workflow evaluation in this worktree.
