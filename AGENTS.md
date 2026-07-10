# Worktree Guard

This worktree is the current source of truth for the active foundation redesign recovery work.

Path:
- `/Users/kaya.matsumoto/projects/universal-io/app-mac-stabilize-foundation`

Rules:
- Do all code changes for the current thread in this worktree.
- Do not switch to `/Users/kaya.matsumoto/projects/universal-io/app-mac` for this thread.
- If the active development target changes in the future, update this file first before editing code elsewhere.

Current branch:
- `stabilize/foundation-redesign-from-580a211`

Current operational note:
- This worktree is the one the user runs in Xcode.
- Any similar changes found only in `app-mac` are not authoritative unless they are intentionally re-applied here.
