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
  # Everything in coordination EXCEPT the captain is floor — PM, GV, and any
  # template-declared extra role (e.g. dev-sre's SRE). Matching on "not the
  # captain" (rather than a token list) means a floor-down works even when
  # invoked without the template that declared the extras.
  for p in $(tmux list-panes -t "$COORD_SESSION" -F '#{pane_id}' 2>/dev/null); do
    l="$(tmux show -p -t "$p" @l 2>/dev/null)"
    case "$l" in
      *CAPTAIN*) ;;   # the one survivor
      *) tmux kill-pane -t "$p" 2>/dev/null && echo "killed pane '${l:-unlabeled}' in '$COORD_SESSION'";;
    esac
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
  for tag in pm gv captain conductor $(fwf_extra_names); do
    git -C "$FWF_REPO" worktree remove --force "$(wt_dir "$tag")" 2>/dev/null || true
  done
  git -C "$FWF_REPO" worktree prune
  # Worktree-less roles (e.g. user-testing personas) keep a scratch dir + evidence
  # under the per-profile UT root instead of a worktree — clear it on purge too.
  [ -d "$(fwf_ut_root)" ] && { rm -rf "$(fwf_ut_root)"; echo "removed user-testing scratch root $(fwf_ut_root)"; }
  echo "purge complete. (Branches and remote PRs are left intact.)"
fi
