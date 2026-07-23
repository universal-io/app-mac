#!/usr/bin/env bash
#
# ls-cleanup.sh — forget stray Launch Services registrations of this app.
#
# WHY THIS EXISTS
# Every build (Xcode Run, `xcodebuild`, CLI verification) copies an app bundle
# to its own path and macOS auto-registers it with Launch Services
# (the RegisterWithLaunchServices build step runs `lsregister -f`). Over a long
# development history these registrations pile up — dozens of copies in
# DerivedData, /private/tmp, mounted DMGs, etc. When they share the PRODUCTION
# bundle id they can win name resolution and hide the real /Applications app
# from Launchpad. See docs/dev-prod-app-identity.md for the full story.
#
# WHAT THIS DOES
# Unregisters every Launch Services entry for a "Universal IO" bundle EXCEPT the
# installed production app at /Applications, then re-registers that one. Dev
# builds are safe to forget: the next build re-registers them automatically.
#
# Non-destructive: only touches the LS database, never deletes any files.
#
# Usage:
#   bash tools/ls-cleanup.sh          # clean up, keep /Applications
#   bash tools/ls-cleanup.sh --dry-run

set -euo pipefail

LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
KEEP="/Applications/Universal IO.app"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

echo "Scanning Launch Services for Universal IO registrations..."

# All registered bundle paths named "Universal IO*.app", deduplicated.
# Written to a temp file so the loop body stays in the main shell (bash 3.2 on
# stock macOS has no `mapfile`, and a piped `while` runs in a subshell).
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
"$LSREG" -dump 2>/dev/null \
  | grep -oE "path: +.*Universal IO[^/]*\.app" \
  | sed 's/path: *//' \
  | sort -u > "$LIST"

if [ ! -s "$LIST" ]; then
  echo "Nothing registered. Clean already."
  exit 0
fi

removed=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$p" = "$KEEP" ]; then
    echo "keep    : $p"
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would-rm: $p"
  else
    "$LSREG" -u "$p" 2>/dev/null && echo "forget  : $p"
  fi
  removed=$((removed + 1))
done < "$LIST"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: $removed registration(s) would be forgotten."
  exit 0
fi

# Re-assert the production app and refresh Launchpad's index.
if [ -d "$KEEP" ]; then
  "$LSREG" -f "$KEEP" 2>/dev/null || true
  echo "re-register: $KEEP"
else
  echo "note: $KEEP not installed — nothing to re-register."
fi
killall Dock 2>/dev/null || true

echo "Done. Forgot $removed registration(s). Dev builds re-register on next build."
