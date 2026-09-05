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
#   2 = MALFORMED, or a read/usage failure -- the FIRST claim-shaped comment
#       (its first line starts with "CLAIM"/"RELEASE") does not parse as
#       "CLAIM <role>"/"RELEASE <role>", or the thread could not be read at
#       all. Fail-closed (do not reclaim) in BOTH directions, same as #500's
#       own incident: a malformed signal is exactly the case that must not
#       be silently treated as absent (issue #502; mirrors fwf-authz.sh's
#       INVALID, which does the same for a malformed sentinel).
#   3 = no claim-shaped comment found at all -- nothing holds this issue,
#       proceed. Split out of the old, overloaded rc 2 (issue #502): "there
#       is nothing here" and "there is something here I can't parse" need
#       opposite handling, and folding them together made the second one
#       strictly worse than having no claim at all.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf claim-liveness <issue-number>" >&2; }

num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 2;; esac

# issue #515: resolve the claim/release SEQUENCE, not just the first matching comment.
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
# issue #502: matches on the comment's FIRST LINE only, not the whole body --
# a comment whose first line is "CLAIM <role>" followed by an explanation
# (#500's exact incident shape) is exactly as much a claim as a bare one-line
# comment, and every human/agent reading the thread already reads it that
# way. Distinguishes THREE states, not two: no claim-shaped comment at all
# (nothing to resolve -- rc 3 below); the FIRST claim-shaped comment does not
# parse as "<CLAIM|RELEASE> <role>" (MALFORMED -- rc 2, loud, mirrors
# fwf-authz.sh's INVALID); or a resolvable claim/release sequence (unchanged
# from #515, just fed from first-lines instead of whole bodies). A malformed
# comment that is NOT the first claim-shaped one in the thread is silently
# ignored, same as any other non-matching text -- only the very first
# claim-shaped sighting can trigger MALFORMED, so a bare or garbled RELEASE
# posted after a real, well-formed CLAIM still loses to it (AC5: first-claim-
# wins must not become first-*parseable*-claim-wins for the wrong reason).
#
# Output contract, extended (previously "<createdAt>\tCLAIM <role>" or
# empty): a MALFORMED first line now produces "malformed\t<the line>" --
# a shape no valid claim/release output or the empty ("nothing found")
# output can ever collide with, since neither starts with the literal word
# "malformed" followed by a tab.
_FWF502_RESOLVE='def firstline: split("\n")[0] | sub("[\t\r ]+$"; "");
( (.comments // [])
  | map({created: .createdAt, line: (.body | firstline)})
  | map(. + {
      shaped: (.line | test("^(CLAIM|RELEASE)([ \t]|$)")),
      wellformed: (.line | test("^(CLAIM|RELEASE) [A-Za-z0-9_-]+$"))
    })
  | map(select(.shaped))
) as $shaped
| if ($shaped | length) == 0 then
    empty
  else
    ($shaped | nth(0; .[])) as $head
    | if ($head.wellformed | not) then
        "malformed\t\($head.line)"
      else
        ($shaped
         | map(select(.wellformed))
         | reduce .[] as $c ({holder:null, created:null, released:null};
             ($c.line | split(" ")) as $p
             | if $p[0] == "CLAIM"
               then (if .holder == null then {holder:$p[1], created:$c.created, released:null} else . end)
               else (if .holder == $p[1] then {holder:null, created:null, released:$p[1]} else . end)
               end)
         | if .holder != null then "\(.created)\tCLAIM \(.holder)"
           elif .released != null then "\treleased \(.released)"
           else empty end)
      end
  end'

# Same dual-backend shape as fwf-claim.sh's _issue_read. Issue #502: the SAME
# jq filter serves both backends here (unlike the two hand-duplicated regexes
# this replaced pre-#515), so fixing the match here fixes both at once.
_first_claim_line() { # -> "<createdAt>\tCLAIM <role>" of the effective claim, "malformed\t<line>", or empty
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$num" --json comments --jq "$_FWF502_RESOLVE"
  else
    gh issue view "$num" --json comments --jq "$_FWF502_RESOLVE"
  fi
}

line="$(_first_claim_line 2>/dev/null)"; read_rc=$?
if [ "$read_rc" -ne 0 ]; then
  echo "fwf claim-liveness #$num: UNKNOWN -- could not read the issue's comments" >&2
  exit 2
fi
if [ -z "$line" ]; then
  echo "fwf claim-liveness #$num: no CLAIM comment found on this issue -- nothing holds it, proceed"
  exit 3
fi

# issue #502: a claim-shaped comment (first line starts with CLAIM/RELEASE)
# that does not parse as "<verb> <role>" -- e.g. bare "CLAIM" with no role,
# or a role tag with disallowed characters. Distinct from "nothing found"
# (rc 3, above): there plainly IS something here, it just does not parse,
# and folding that into "no claim" would silently treat a botched or
# forged-looking claim attempt as an open ticket. Fail closed and say so
# loudly, exactly as fwf-authz.sh's INVALID does for a malformed sentinel.
case "$line" in
  malformed$'\t'*)
    echo "fwf claim-liveness #$num: MALFORMED -- the first claim-shaped comment does not parse as 'CLAIM <role>' or 'RELEASE <role>': ${line#malformed$'\t'}" >&2
    exit 2 ;;
esac

# issue #515, second defect (found by the PM on the first cut of this fix):
# a RELEASED claim must not land in the rc 2 bucket. rc 2 means "I could not
# DETERMINE the claim state" -- no comment, or an unreadable thread -- which
# is why templates/dev/implementer.tmpl step 3d tells every seat to treat it
# as live and fail closed. A completed release is the opposite: the state is
# known, and it is FREE. Folding a determinate answer into the indeterminate
# bucket would mean a correctly released ticket still reads "do not attempt"
# to the one seat the release exists for -- the feature would look right in
# its own test table and do nothing on the floor.
#
# So this is rc 0 (RECLAIMABLE), the SAME code an abandoned claim gets, since
# both mean exactly "no live claim blocks you, proceed". The unreadable and
# malformed cases above stay fail-closed at rc 2, and never-claimed is its
# own rc 3 (issue #502): this widens nothing except the one state that was
# previously unrepresentable.
case "$line" in
  $'\treleased '*)
    echo "fwf claim-liveness #$num: RECLAIMABLE -- ${line#*released } released their claim; no live claim blocks you"
    exit 0 ;;
esac

claim_created="${line%%$'\t'*}"
claim_body="${line#*$'\t'}"
role_tag="${claim_body#CLAIM }"

now="$(date -u +%s)"
claim_epoch="$(fwf_iso_to_epoch "$claim_created" 2>/dev/null || true)"
case "$claim_epoch" in ''|*[!0-9]*) claim_epoch="$now";; esac
claim_age=$(( now - claim_epoch ))
[ "$claim_age" -ge 0 ] || claim_age=0

# issue #503, AC6: fwf_claim_liveness_blocks now prints a one-line reason on
# every path -- "blocks because live" and "blocks because undiagnosable" are
# no longer the same bare LIVE, distinguishable here on the actual output.
if liveness_reason="$(fwf_claim_liveness_blocks "$role_tag" "$claim_age")"; then
  echo "fwf claim-liveness #$num: LIVE -- $role_tag's claim (age ${claim_age}s) blocks a reclaim ($liveness_reason)"
  exit 1
fi
echo "fwf claim-liveness #$num: RECLAIMABLE -- $role_tag's claim (age ${claim_age}s) is abandoned ($liveness_reason)"
exit 0
