#!/usr/bin/env bash
# Tear down the swarm tmux session and release the e2e lock. With --purge, also
# remove the worktrees and impl dev-data dirs (destructive — retiring the swarm).
#
# Usage: [FWF_PROFILE=example] fwf-down.sh [--purge]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

if tmux kill-session -t "$SESSION" 2>/dev/null; then echo "killed tmux session '$SESSION'"; else echo "no tmux session '$SESSION'"; fi
rmdir "$E2E_LOCK" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  echo "purging worktrees and impl dev-data…"
  for id in "${PAIRS[@]}"; do
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "impl$id")" 2>/dev/null || true
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "qa$id")"   2>/dev/null || true
    rm -rf "$(data_dir "impl$id")"
  done
  git -C "$FWF_REPO" worktree remove --force "$(wt_dir pm)"        2>/dev/null || true
  git -C "$FWF_REPO" worktree remove --force "$(wt_dir conductor)" 2>/dev/null || true
  git -C "$FWF_REPO" worktree prune
  echo "purge complete. (Branches and remote PRs are left intact.)"
fi
