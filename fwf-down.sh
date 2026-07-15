#!/usr/bin/env bash
# Tear down both factory tmux sessions and release the e2e lock. With --purge,
# also remove the worktrees and impl dev-data dirs (destructive — retiring it).
#
# --floor-only (alias --keep-captain, issue #6): tear down ONLY the floor — the
# BUILD session plus the PM/GV panes of the coordination session — leaving the
# captain pane and its session/context completely untouched, so the captain can
# idle the expensive floor and later bring it back with 'fwf up --floor-only'.
# Logs a floor-down event (issue #85) so the dash can show a deliberate idle
# as distinct from a crash, and so there's an audit trail once the panes are
# gone: --actor NAME (default "captain"), --reason "TEXT" (default below).
# --floor-only also enforces a deterministic anti-thrash cooldown (issue #88):
# it refuses within FWF_FLOOR_COOLDOWN seconds of the last recorded floor-up
# unless --force is passed.
#
# Usage: [FWF_PROFILE=example] fwf-down.sh [--purge | --floor-only [--actor NAME] [--reason TEXT] [--force]]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

floor_only=0; purge=0; force=0; actor="captain"; reason="queue empty; nothing in flight"
while [ $# -gt 0 ]; do
  case "$1" in
    --floor-only|--keep-captain) floor_only=1; shift;;
    --purge) purge=1; shift;;
    --actor) actor="$2"; shift 2;;
    --reason) reason="$2"; shift 2;;
    --force) force=1; shift;;
    *) echo "usage: fwf-down.sh [--purge | --floor-only [--actor NAME] [--reason TEXT] [--force]]" >&2; exit 1;;
  esac
done
if [ "$floor_only" = 1 ] && [ "$purge" = 1 ]; then
  echo "fwf-down: --floor-only and --purge don't combine (purge retires the whole factory, captain included)." >&2
  exit 1
fi

if [ "$floor_only" = 1 ]; then
  if [ "$force" != 1 ]; then
    remaining="$(fwf_floor_cooldown_remaining)"
    if [ "$remaining" -gt 0 ]; then
      echo "fwf-down: refusing --floor-only — floor-up cooldown active, ${remaining}s remaining (last floor-up was too recent; pass --force to override)" >&2
      exit 1
    fi
  fi
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
  rm -rf "$E2E_LOCK"
  fwf_budget_writer_stop   # issue #96: a downed floor spends nothing — nothing left to enforce against
  fwf_floor_event floor-down "$actor" "$reason"
  echo "floor is down; the captain pane (if any) is untouched in '$COORD_SESSION'. Bring the floor back with: fwf up --floor-only"
  exit 0
fi

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux kill-session -t "$s" 2>/dev/null; then echo "killed tmux session '$s'"; else echo "no tmux session '$s'"; fi
done
rm -rf "$E2E_LOCK"
fwf_budget_writer_stop
fwf_budget_baseline_clear   # issue #108: full teardown ends this run — the next full 'fwf up' snapshots a fresh baseline
rm -f "$FWF_RUN/template"   # clear the persisted running-template marker (#51) so it can't go stale once the factory is down
rm -f "$FWF_TMUX_SOCKET_FILE"   # clear the persisted launch-socket marker (#62) alongside it

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
