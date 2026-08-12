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

# Anti-thrash cooldown on the FULL teardown too (issue #133). The #88 cooldown
# used to guard ONLY the per-plane (--build-only/--pm-only) paths; a full
# `fwf down` bypassed it entirely. That let an automated actor (e.g. a usage
# dead-man's switch firing every few minutes) tear down a floor that had come
# up seconds earlier — `up` → sessions killed ~cooldown-window later → "0/2, no
# work done", repeatably. A full down is refused while EITHER plane is still in
# its up-cooldown, unless --force. A human retiring the floor passes --force;
# a genuine emergency-stop actor (real usage breach) should also pass --force,
# but a MISFIRING one that doesn't is now stopped from insta-killing a fresh
# floor. --purge is exempt (deliberate retire), as is --force.
if [ "$purge" != 1 ] && [ "$force" != 1 ]; then
  build_remaining="$(fwf_plane_cooldown_remaining build)"
  pm_remaining="$(fwf_plane_cooldown_remaining pm)"
  if [ "$build_remaining" -gt 0 ] || [ "$pm_remaining" -gt 0 ]; then
    echo "fwf-down: refusing full down — a floor came up too recently (build cooldown ${build_remaining}s, pm cooldown ${pm_remaining}s remaining; pass --force to override)" >&2
    exit 1
  fi
fi

# Snapshot which planes were actually up BEFORE we kill them, so the floor-down
# audit rows below reflect reality rather than logging a down for a plane that
# was never up.
_build_was_up=0; _pm_was_up=0
tmux has-session -t "$BUILD_SESSION" 2>/dev/null && _build_was_up=1
tmux has-session -t "$COORD_SESSION" 2>/dev/null && _pm_was_up=1

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux kill-session -t "$s" 2>/dev/null; then echo "killed tmux session '$s'"; else echo "no tmux session '$s'"; fi
done
rm -rf "$E2E_LOCK"
fwf_budget_writer_stop
fwf_budget_baseline_clear   # issue #108: full teardown ends this run — the next full 'fwf up' snapshots a fresh baseline
rm -f "$FWF_RUN/template"   # clear the persisted running-template marker (#51) so it can't go stale once the factory is down
rm -f "$FWF_TMUX_SOCKET_FILE"   # clear the persisted launch-socket marker (#62) alongside it

# Record floor-down for the planes we just tore down (issue #133). The full
# teardown previously logged NOTHING — only the per-plane paths called
# fwf_floor_event — so a full `fwf down` (incl. an automated one) left the
# floor-events log with a trailing floor-up, i.e. the audit trail + dash read
# the floor as still UP after its sessions were killed. That is the "silent
# teardown / unreliable liveness signal" in #133: you could not tell from the
# log that the floor was gone, or who took it down and why. Now every full down
# is auditable with its --actor/--reason, exactly like the per-plane paths.
[ "$_build_was_up" = 1 ] && fwf_floor_event floor-down "$actor" "$reason" build
[ "$_pm_was_up" = 1 ]    && fwf_floor_event floor-down "$actor" "$reason" pm

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
