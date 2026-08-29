#!/usr/bin/env bash
# fwf-claim-liveness.sh -- issue #377: the implementer's own claim-survey
# decision ("is this other role's claim actually abandoned?") used a bare
# age-only proxy -- "no PR after 15 minutes = abandoned" -- the same wrong
# proxy #147/#210 already replaced with a real liveness check at the other
# two consumers of a claim's age: the conductor's build-plane teardown guard
# (fwf_build_plane_blocked, lib.sh) and fwf-scale.sh's idle-impl check. Both
# reuse fwf_claim_liveness_blocks, which asks "is the claimant's pane
# actually alive" instead of just "how old is the claim" -- a claimant mid
# validation-gate (tick and tokens both static while a blocking `bash
# test/run.sh` runs) is otherwise indistinguishable from one that walked
# away, and the age threshold is shorter than a routine full-suite gate
# (parallel-worktree contention routinely pushes it past 15 minutes).
#
# This is the third call site, wired to the SAME signal so all three can
# never disagree about the same claimant.
#
# Usage: fwf claim-liveness <issue-number>
#   Finds the FIRST live "CLAIM <role>" comment on the issue and reports
#   whether it's still LIVE (blocks a reclaim) or RECLAIMABLE (abandoned).
#
# Exit codes:
#   0 = RECLAIMABLE -- safe to post a fresh CLAIM and proceed.
#   1 = LIVE -- do not reclaim.
#   2 = no CLAIM comment found on this issue, or a read/usage failure
#       (fail-closed in the "do not reclaim" direction: silence is never
#       treated as permission).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf claim-liveness <issue-number>" >&2; }

num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 2;; esac

# Same dual-backend shape as fwf-claim.sh's _issue_read.
_first_claim_line() { # -> "<createdAt>\t<CLAIM role>" of the FIRST claim, or empty
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$num" --json comments --jq \
      '(.comments // []) | map(select(.body | test("^CLAIM [A-Za-z0-9_-]+$"))) | (.[0] // empty) | if . == null then empty else "\(.createdAt)\t\(.body)" end'
  else
    gh issue view "$num" --json comments --jq \
      '(.comments // []) | map(select(.body | test("^CLAIM [A-Za-z0-9_-]+$"))) | (.[0] // empty) | if . == null then empty else "\(.createdAt)\t\(.body)" end'
  fi
}

line="$(_first_claim_line 2>/dev/null)"; read_rc=$?
if [ "$read_rc" -ne 0 ]; then
  echo "fwf claim-liveness #$num: UNKNOWN -- could not read the issue's comments" >&2
  exit 2
fi
if [ -z "$line" ]; then
  echo "fwf claim-liveness #$num: no CLAIM comment found on this issue"
  exit 2
fi

claim_created="${line%%$'\t'*}"
claim_body="${line#*$'\t'}"
role_tag="${claim_body#CLAIM }"

now="$(date -u +%s)"
claim_epoch="$(fwf_iso_to_epoch "$claim_created" 2>/dev/null || true)"
case "$claim_epoch" in ''|*[!0-9]*) claim_epoch="$now";; esac
claim_age=$(( now - claim_epoch ))
[ "$claim_age" -ge 0 ] || claim_age=0

if fwf_claim_liveness_blocks "$role_tag" "$claim_age"; then
  echo "fwf claim-liveness #$num: LIVE -- $role_tag's claim (age ${claim_age}s) blocks a reclaim (pane alive, or liveness unconfirmed/too fresh)"
  exit 1
fi
echo "fwf claim-liveness #$num: RECLAIMABLE -- $role_tag's claim (age ${claim_age}s) is abandoned (pane confirmed dead, or past the ${FWF_CLAIM_LIVENESS_FALLBACK_SECS:-900}s no-signal fallback)"
exit 0
