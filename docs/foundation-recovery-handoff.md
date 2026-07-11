# Foundation Recovery Handoff

Updated: 2026-07-11

## Summary

The validated recovery implementation from the stabilization worktree was
adopted as the canonical `feature/foundation-redesign` line.

## Decision

- Keep the tested recovery state as the new mainline for foundation redesign.
- Preserve the pre-adoption `app-mac` transplant state on a backup branch for
  reference only.
- Retain `stabilize/foundation-redesign-from-580a211` as a recovery/archive
  branch, not the day-to-day development target.

## Branches

- Canonical development branch: `feature/foundation-redesign`
- Recovery/archive branch: `stabilize/foundation-redesign-from-580a211`
- Backup snapshot before branch adoption:
  `backup/foundation-redesign-pre-stable-adoption-20260711`

## Operational Rule

Continue feature work from `feature/foundation-redesign`. Do not port changes
back out of habit from the stabilization worktree; if that worktree is used
again, treat it as a deliberate recovery branch and document the switch first.
