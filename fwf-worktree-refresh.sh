#!/usr/bin/env bash
# fwf-worktree-refresh.sh — issue #146: per-tick fetch-then-detach refresh
# for a READ-ONLY role's worktree (PM/GV/Captain), so it always reasons
# about current __DEFAULT__ instead of drifting arbitrarily stale during a
# long session. impl/qa are explicitly OUT OF SCOPE — see fwf_worktree_refresh_role
# (lib.sh) for the full mechanism and safety rule.
#
# Usage: fwf worktree-refresh <role>
#
# Exit codes (three-tier, so "non-zero = not confirmed current" is a
# structural guarantee a caller can key on, never a wording convention a
# future template edit could drift from — issue #146 QA/GV review):
#   0   REFRESHED — fetched and confirmed at 0-behind origin/__DEFAULT__.
#       The only code that means "this worktree is current."
#   1   STALE, FETCH_FAILED, or NO_WORKTREE — a hard failure: the refresh
#       was attempted (or couldn't even find a worktree to attempt on) and
#       did NOT achieve a confirmed-current worktree. For a role whose whole
#       job is reading code, having no worktree at all is the worst case,
#       not a benign no-op — grouped here on purpose.
#   2   SKIPPED_BRANCH or SKIPPED_DIRTY — the safety rule deliberately left
#       the worktree untouched (protects impl/qa's mid-ticket shape), so
#       it was NOT refreshed and may still be arbitrarily stale. This is an
#       anomaly for a read-only role, not a benign skip — it is intentionally
#       NOT exit 0, so "non-zero means alarm" (every template's own wording)
#       catches this case too instead of reading it as success.
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
    echo "fwf worktree-refresh: $role left untouched — on branch '${result#* }', not detached (anomaly for a read-only role — a reader shouldn't be on a branch; NOT refreshed, may still be stale)" >&2
    exit 2
    ;;
  SKIPPED_DIRTY)
    echo "fwf worktree-refresh: $role left untouched — uncommitted changes present (anomaly for a read-only role — a reader shouldn't have local changes; if this role is producing a #169-style deliverable, that carve-out is not yet implemented — see issue #146; NOT refreshed, may still be stale)" >&2
    exit 2
    ;;
  NO_WORKTREE)
    echo "fwf worktree-refresh: $role has no worktree to refresh — this role has nothing to read code from" >&2
    exit 1
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
