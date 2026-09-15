#!/usr/bin/env bash
# Tear down factory tmux sessions/panes and release the e2e lock. With
# --purge, also remove the worktrees and impl dev-data dirs (destructive —
# retiring it).
#
# Per-UNIT idling (issue #105, generalizing issue #6's single --floor-only):
# the captain idles the BUILD floor and the PM pane INDEPENDENTLY, driven by
# each unit's own workload — GV never idles (it must stay reachable-on-demand
# whenever the captain is up; no flag here ever tears it down).
#   --build-only   tear down ONLY the build session (impl/qa/conductor).
#   --pm-only      tear down ONLY the PM pane (and any template-declared
#                  extra coordination-session role, e.g. dev-sre's SRE pane —
#                  "not CAPTAIN, not GV" is the PM-plane bucket).
#   --floor-only (alias --keep-captain) — KEPT for back-compat: equivalent to
#                  --build-only + --pm-only together (today's exact prior
#                  behavior), refused as ONE atomic operation if EITHER unit's
#                  guard below would block it (no half-teardown).
# Either flag leaves the captain pane and GV completely untouched.
#
# Each unit logs its own floor-down event (issue #85, now plane-tagged) so the
# dash can show a deliberate idle as distinct from a crash, and so there's an
# audit trail once its panes are gone: --actor NAME (default "captain"),
# --reason "TEXT" (default below).
#
# Each unit also enforces its own deterministic anti-thrash cooldown (issue
# #88, generalized): FWF_BUILD_COOLDOWN / FWF_PM_COOLDOWN seconds since that
# unit's own last recorded up-event, overridable with --force.
#
# Each unit ALSO enforces a deadlock guard (issue #105 acceptance criterion
# 1) that --force does NOT override — idling must never strand work:
# --build-only refuses while any PR is open or a promotion is in flight;
# --pm-only refuses while any product-wip draft is open. See
# fwf_build_plane_blocked / fwf_pm_plane_blocked in lib.sh for exactly what's
# checked and why the PM guard is deliberately coarse (shared-GH-account
# comments can't disambiguate "already addressed" — issue #82's constraint).
#
# Usage: [FWF_PROFILE=example] fwf-down.sh [--purge | --build-only|--pm-only|--floor-only [--actor NAME] [--reason TEXT] [--force]]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

build_only=0; pm_only=0; purge=0; force=0; actor="captain"; reason="queue empty; nothing in flight"
while [ $# -gt 0 ]; do
  case "$1" in
    --floor-only|--keep-captain) build_only=1; pm_only=1; shift;;
    --build-only) build_only=1; shift;;
    --pm-only) pm_only=1; shift;;
    --purge) purge=1; shift;;
    --actor) actor="$2"; shift 2;;
    --reason) reason="$2"; shift 2;;
    --force) force=1; shift;;
    *) echo "usage: fwf-down.sh [--purge | --build-only|--pm-only|--floor-only [--actor NAME] [--reason TEXT] [--force]]" >&2; exit 1;;
  esac
done
if { [ "$build_only" = 1 ] || [ "$pm_only" = 1 ]; } && [ "$purge" = 1 ]; then
  echo "fwf-down: --build-only/--pm-only/--floor-only and --purge don't combine (purge retires the whole factory, captain included)." >&2
  exit 1
fi

if [ "$build_only" = 1 ] || [ "$pm_only" = 1 ]; then
  # Pre-flight EVERY requested unit's cooldown + deadlock guard BEFORE
  # tearing anything down — a --floor-only refusal on either unit must not
  # leave the other half-torn-down (acceptance criterion 1c: on any
  # ambiguity, decline and stay up).
  refuse=0
  if [ "$build_only" = 1 ]; then
    if [ "$force" != 1 ]; then
      remaining="$(fwf_plane_cooldown_remaining build)"
      if [ "$remaining" -gt 0 ]; then
        echo "fwf-down: refusing --build-only — build-up cooldown active, ${remaining}s remaining (last build-up was too recent; pass --force to override)" >&2
        refuse=1
      fi
    fi
    blocked="$(fwf_build_plane_blocked)"
    if [ -n "$blocked" ]; then
      echo "fwf-down: refusing --build-only — $blocked (--force does not override this; it would strand work)" >&2
      refuse=1
    fi
  fi
  if [ "$pm_only" = 1 ]; then
    if [ "$force" != 1 ]; then
      remaining="$(fwf_plane_cooldown_remaining pm)"
      if [ "$remaining" -gt 0 ]; then
        echo "fwf-down: refusing --pm-only — pm-up cooldown active, ${remaining}s remaining (last pm-up was too recent; pass --force to override)" >&2
        refuse=1
      fi
    fi
    blocked="$(fwf_pm_plane_blocked)"
    if [ -n "$blocked" ]; then
      echo "fwf-down: refusing --pm-only — $blocked (--force does not override this; it would strand work)" >&2
      refuse=1
    fi
  fi
  [ "$refuse" = 1 ] && exit 1

  if [ "$build_only" = 1 ]; then
    if tmux kill-session -t "$BUILD_SESSION" 2>/dev/null; then echo "killed tmux session '$BUILD_SESSION'"; else echo "no tmux session '$BUILD_SESSION'"; fi
    rm -rf "$E2E_LOCK"
    fwf_budget_writer_stop   # issue #96: a downed build floor spends nothing — nothing left to enforce against
    fwf_floor_event floor-down "$actor" "$reason" build
    echo "build floor is down. Bring it back with: fwf up --build-only"
  fi
  if [ "$pm_only" = 1 ]; then
    # Everything in coordination EXCEPT the captain AND the GV is the PM
    # plane — PM itself, plus any template-declared extra role (e.g.
    # dev-sre's SRE). GV never idles (issue #105) so it is deliberately
    # excluded here, unlike the pre-#105 "not the captain" sweep.
    for p in $(tmux list-panes -t "$COORD_SESSION" -F '#{pane_id}' 2>/dev/null); do
      l="$(tmux show -p -t "$p" @l 2>/dev/null)"
      case "$l" in
        *CAPTAIN*|*"GRAND VIZIER"*) ;;   # survivors
        *) tmux kill-pane -t "$p" 2>/dev/null && echo "killed pane '${l:-unlabeled}' in '$COORD_SESSION'";;
      esac
    done
    fwf_floor_event floor-down "$actor" "$reason" pm
    echo "PM is down. Bring it back with: fwf up --pm-only"
  fi
  echo "the captain pane and GV (if any) are untouched in '$COORD_SESSION'."
  exit 0
fi

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux kill-session -t "$s" 2>/dev/null; then echo "killed tmux session '$s'"; else echo "no tmux session '$s'"; fi
done
rm -rf "$E2E_LOCK"
# issue #217: a full teardown decommissions the whole floor -- leaving the
# auth sink behind means a live OAuth token sits at a predictable path
# indefinitely with nothing running to use it, the worst version of the
# persistence property the sink exists to provide. Deliberately NOT done on
# the --build-only/--pm-only/--floor-only partial-teardown paths above: those
# leave the OTHER plane running, and it may still need this same shared sink
# for its own later respawn.
fwf_auth_clear
fwf_budget_writer_stop
fwf_budget_baseline_clear   # issue #108: full teardown ends this run — the next full 'fwf up' snapshots a fresh baseline
fwf_subscription_state_clear   # issue #149: same reasoning — don't inherit a stale ratchet/parked-state into the next run
rm -f "$FWF_RUN/template"   # clear the persisted running-template marker (#51) so it can't go stale once the factory is down
rm -f "$FWF_RUN/profile"   # clear the persisted running-profile marker (#530) alongside it
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
