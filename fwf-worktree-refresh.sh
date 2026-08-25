#!/usr/bin/env bash
# fwf-worktree-refresh.sh — issue #146: per-tick fetch-then-detach refresh
# for a READ-ONLY role's worktree (PM/GV/Captain), so it always reasons
# about current __DEFAULT__ instead of drifting arbitrarily stale during a
# long session. impl/qa are explicitly OUT OF SCOPE — see fwf_worktree_refresh_role
# (lib.sh) for the full mechanism and safety rule.
#
# Usage: fwf worktree-refresh <role>
#
# Exit codes:
#   0   REFRESHED, SKIPPED_BRANCH, or SKIPPED_DIRTY — nothing wrong. A
#       SKIPPED_* case still prints a loud line for a read-only role (see
#       below) but is not itself a hard failure — the caller decides whether
#       to escalate a dirty/branched read-only worktree as an anomaly.
#   1   STALE, FETCH_FAILED, or NO_WORKTREE — the refresh did not achieve a
#       confirmed-current worktree. Callers MUST treat this as the loud
#       failure case the ticket requires, not silently retry-and-forget.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf worktree-refresh <role>" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }

result="$(fwf_worktree_refresh_role "$role")"
state="${result%% *}"

case "$state" in
  REFRESHED)
    echo "fwf worktree-refresh: $role refreshed — ${result#* }"
    exit 0
    ;;
  SKIPPED_BRANCH)
    echo "fwf worktree-refresh: $role left untouched — on branch '${result#* }', not detached (anomaly for a read-only role — a reader shouldn't be on a branch)" >&2
    exit 0
    ;;
  SKIPPED_DIRTY)
    echo "fwf worktree-refresh: $role left untouched — uncommitted changes present (anomaly for a read-only role — a reader shouldn't have local changes; if this role is producing a #169-style deliverable, that carve-out is not yet implemented — see issue #146)" >&2
    exit 0
    ;;
  NO_WORKTREE)
    echo "fwf worktree-refresh: $role has no worktree to refresh (worktree-less role — nothing to do)"
    exit 0
    ;;
  FETCH_FAILED)
    echo "fwf worktree-refresh: $role STALE — fetch/checkout failed; worktree may be reasoning about an old tree" >&2
    exit 1
    ;;
  STALE)
    echo "fwf worktree-refresh: $role STALE — still ${result#STALE } behind origin/$DEFAULT_BRANCH after a refresh attempt; worktree is reasoning about an old tree" >&2
    exit 1
    ;;
  *)
    echo "fwf worktree-refresh: $role unrecognized result '$result'" >&2
    exit 1
    ;;
esac
