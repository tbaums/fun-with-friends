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

# issue #515: resolve the claim/release SEQUENCE, not `.[0]`.
#
# This used to select the FIRST comment matching ^CLAIM <role>$ and treat it as
# authoritative forever. Combined with the two exits from LIVE below -- pane
# death, or the 900s no-signal fallback -- both of which are keyed to the
# claimer being UNHEALTHY, a live and well-behaved seat could never give a
# ticket back. Observed: a claim posted at 12:21:42Z and withdrawn in prose 32
# seconds later still read LIVE twelve hours on, and #504 (AUTHORIZED, and the
# cause of every red on the board that day) was unclaimable the whole time.
#
# The rule, stated rather than implied by the code:
#   * a CLAIM takes effect only when nothing is currently held
#     (first-claim-wins among LIVE claims is preserved -- this adds an exit,
#      it does not weaken the control)
#   * a RELEASE takes effect only from the role that currently holds it
#     (ergonomic, not a security control -- see fwf-claim.sh:66 and #207)
#   * claim -> release -> re-claim resolves to the re-claim
#
# The output contract is unchanged ("<createdAt>\tCLAIM <role>", or empty), so
# the age arithmetic and LIVE/RECLAIMABLE reporting below are untouched.
_FWF515_RESOLVE='(.comments // [])
| map(select(.body | test("^(CLAIM|RELEASE) [A-Za-z0-9_-]+$")))
| reduce .[] as $c ({holder:null, created:null};
    ($c.body | split(" ")) as $p
    | if $p[0] == "CLAIM"
      then (if .holder == null then {holder:$p[1], created:$c.createdAt} else . end)
      else (if .holder == $p[1] then {holder:null, created:null} else . end)
      end)
| if .holder == null then empty else "\(.created)\tCLAIM \(.holder)" end'

# Same dual-backend shape as fwf-claim.sh's _issue_read.
_first_claim_line() { # -> "<createdAt>\tCLAIM <role>" of the EFFECTIVE claim, or empty
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$num" --json comments --jq "$_FWF515_RESOLVE"
  else
    gh issue view "$num" --json comments --jq "$_FWF515_RESOLVE"
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
