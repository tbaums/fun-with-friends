#!/usr/bin/env bash
# Tear down both factory tmux sessions and release the e2e lock. With --purge,
# also remove the worktrees and impl dev-data dirs (destructive — retiring it).
#
# --floor-only (alias --keep-captain, issue #6): tear down ONLY the floor — the
# BUILD session plus the PM/GV panes of the coordination session — leaving the
# captain pane and its session/context completely untouched, so the captain can
# idle the expensive floor and later bring it back with 'fwf up --floor-only'.
#
# Usage: [FWF_PROFILE=example] fwf-down.sh [--purge | --floor-only]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

floor_only=0; purge=0
for a in "$@"; do
  case "$a" in
    --floor-only|--keep-captain) floor_only=1;;
    --purge) purge=1;;
    *) echo "usage: fwf-down.sh [--purge | --floor-only]" >&2; exit 1;;
  esac
done
if [ "$floor_only" = 1 ] && [ "$purge" = 1 ]; then
  echo "fwf-down: --floor-only and --purge don't combine (purge retires the whole factory, captain included)." >&2
  exit 1
fi

if [ "$floor_only" = 1 ]; then
  if tmux kill-session -t "$BUILD_SESSION" 2>/dev/null; then echo "killed tmux session '$BUILD_SESSION'"; else echo "no tmux session '$BUILD_SESSION'"; fi
  for token in "PM ·" "GRAND VIZIER"; do
    p="$(fwf_find_pane "$COORD_SESSION" "$token" || true)"
    if [ -n "$p" ]; then tmux kill-pane -t "$p"; echo "killed pane '$token' in '$COORD_SESSION'"; else echo "no pane '$token' in '$COORD_SESSION'"; fi
  done
  rmdir "$E2E_LOCK" 2>/dev/null || true
  echo "floor is down; the captain pane (if any) is untouched in '$COORD_SESSION'. Bring the floor back with: fwf up --floor-only"
  exit 0
fi

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux kill-session -t "$s" 2>/dev/null; then echo "killed tmux session '$s'"; else echo "no tmux session '$s'"; fi
done
rmdir "$E2E_LOCK" 2>/dev/null || true

if [ "$purge" = 1 ]; then
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
