#!/usr/bin/env bash
# Tear down both factory tmux sessions and release the e2e lock. With --purge,
# also remove the worktrees and impl dev-data dirs (destructive — retiring it).
#
# Usage: [FWF_PROFILE=example] fwf-down.sh [--purge]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux kill-session -t "$s" 2>/dev/null; then echo "killed tmux session '$s'"; else echo "no tmux session '$s'"; fi
done
rmdir "$E2E_LOCK" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  echo "purging worktrees and impl dev-data…"
  for id in "${PAIRS[@]}"; do
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "impl$id")" 2>/dev/null || true
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "qa$id")"   2>/dev/null || true
    rm -rf "$(data_dir "impl$id")"
  done
  for tag in pm gv captain conductor; do
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "$tag")" 2>/dev/null || true
  done
  git -C "$FWF_REPO" worktree prune
  echo "purge complete. (Branches and remote PRs are left intact.)"
fi
