#!/usr/bin/env bash
# fwf-merge.sh — issue #136 (prevention layer): squash-merges a PR with the
# crafted history card ALWAYS included, replacing the multi-line printf
# construction templates/dev/qa.tmpl and templates/refactor/qa.tmpl used to
# spell out inline. A helper nobody's workflow invokes fixes nothing (#136's
# own framing) -- this is that helper, wired into both qa.tmpls in the same
# change, so the shared-account direct/manual merge path this floor actually
# uses is the ONE code path that produces the crafted body, not prose an
# agent has to transcribe correctly (the exact class of bug #189 shipped 16
# times: <n> vs <num> on one line, easy to misread, easy to get away with
# once).
#
# Usage: fwf merge <num> [--target <branch>]
#   <num>          the PR number to squash-merge.
#   --target       branch to merge into (default: the profile's STAGING_BRANCH).
#
# Composes the body itself (issue #189's --pr resolution + issue #135's
# fail-open fold + credit + fwf-Provenance), then calls
#   gh pr merge <num> --squash --delete-branch --subject <pr-title> --body <that>
# Fails loudly and merges NOTHING if the context fold itself refuses (issue
# #106's guard) -- never falls back to a thinner or default body just to get
# the merge to happen; a caller that hits this should investigate the
# refusal, not bypass this helper.
#
# issue #207 (enforcement layer): also refuses the merge unless EVERY issue
# the PR closes is AUTHORIZED or NOT-GATED per `fwf authz` -- the real,
# mechanical oracle, never a belief about one. #207 was written before this
# script existed and assumed "the merge path is not an fwf path" (it cited
# QA hand-composing `gh pr merge` inline); that citation is now STALE -- this
# script, wired into qa.tmpl by #136, IS the path QA actually walks, and is
# the natural, already-real chokepoint #207's own AC(l) asks for. See
# docs/authz-point-of-action.md for what's built here vs. deferred.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf merge <num> [--target <branch>]" >&2; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 1 ;; esac
shift
target="${STAGING_BRANCH:-staging}"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:-}"; [ -n "$target" ] || { usage; exit 1; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

title="$(gh pr view "$num" --json title --jq '.title' 2>/dev/null)"
[ -n "$title" ] || { echo "fwf merge: could not read PR #$num's title (bad number, or gh unreachable)" >&2; exit 1; }

linked="$(_fwf_pr_ctx_pr_linked_issues "$num")"
[ -n "$linked" ] || {
  # issue #207 AC(k): a branch name referencing an issue number, with no
  # "Closes #N" in the body, is a signal worth naming -- not a gate (this
  # refusal already happens regardless, for the pre-existing #136 reason
  # above); purely informational so the common accidental case is visible.
  branch_name="$(gh pr view "$num" --json headRefName --jq '.headRefName' 2>/dev/null)"
  # this repo's own convention is <role>/issue-<N>-<slug> -- match THAT
  # number specifically first, since a bare digit scan would instead hit an
  # implN/qaN role prefix's own trailing digit (e.g. "impl1/issue-909-x"
  # naively scanned left-to-right finds "1", not the intended 909).
  branch_num="$(printf '%s' "$branch_name" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1)"
  [ -n "$branch_num" ] || branch_num="$(printf '%s' "$branch_name" | grep -oE '[0-9]+' | head -1)"
  hint=""
  [ -n "$branch_num" ] && hint=" (its branch name references #$branch_num -- if that was meant to be closed, add 'Closes #$branch_num' to the PR body)"
  echo "fwf merge: PR #$num has no resolvable linked issue ('Closes #n' in its body) -- refusing to merge with no issue to close$hint" >&2
  exit 1
}
issue_num="$(printf '%s\n' "$linked" | head -1)"
if [ "$(printf '%s\n' "$linked" | wc -l)" -gt 1 ]; then
  echo "fwf merge: PR #$num closes multiple issues ($(printf '%s' "$linked" | tr '\n' ' ' | sed 's/ $//')) -- picked the lowest, #$issue_num" >&2
fi

# issue #207: enforce authorization AT THE POINT OF ACTION, not at the point
# of belief -- calls the real oracle (fwf authz) for EVERY linked issue, not
# just the one context() picks for the body. A forged out-of-band artifact
# (a fabricated CAPTAIN-NOTICE, a believed-but-wrong authorization) changes
# nothing here: this never reads pane/ghost text or a role's belief, only
# fwf-authz.sh's own verdict. Refuses unless EVERY closed issue is AUTHORIZED
# or NOT-GATED (#215) -- checking only the first is a plausible bug and a
# real hole. The refusal names its cause as INFRASTRUCTURE (INDETERMINATE --
# the oracle itself could not be read) or POLICY (HELD/INVALID -- read fine,
# not authorized), per this ticket's own "a refusal must be ROUTED, not a
# wall" requirement -- an agent that cannot tell the two apart is an agent
# that will reclassify a policy hold as a malfunction. Also raises a
# needs-captain flag on the blocking issue (existing #113 mechanism, already
# swept every captain tick) so a refusal is loud and human-addressed, not a
# silently-retried loop -- see docs/authz-point-of-action.md for the AC(f)/
# (g) dash-surfacing follow-up this defers.
# Overridable for tests only (a controllable fake standing in for
# fwf-authz.sh's own, separately-tested internal correctness, so THIS
# script's classification logic can be driven to every exit code without
# needing to fabricate the full GitHub state each real verdict requires) --
# unset in normal operation, where it's the real script right next to us.
authz_script="${FWF_MERGE_AUTHZ_SCRIPT:-$DIR/fwf-authz.sh}"
while IFS= read -r li; do
  [ -n "$li" ] || continue
  az_out="$("$authz_script" "$li" 2>&1)"; az_rc=$?
  case "$az_rc" in
    0|12) : ;; # AUTHORIZED or NOT-GATED -- proceed
    2)
      echo "fwf merge: REFUSED -- #$li's authorization could not be determined (INFRASTRUCTURE failure, not a policy hold). PR #$num stays open. Retry: fwf authz $li" >&2
      "$DIR/fwf-flag-captain.sh" "$li" --role qa --reason "fwf merge #$num REFUSED: authz INDETERMINATE (infrastructure) -- retry 'fwf authz $li'" >/dev/null 2>&1 || true
      exit 1 ;;
    10|11)
      echo "fwf merge: REFUSED -- #$li is not authorized (POLICY hold, not an infrastructure failure). PR #$num stays open. Verify with: fwf authz $li" >&2
      "$DIR/fwf-flag-captain.sh" "$li" --role qa --reason "fwf merge #$num REFUSED: authz $([ "$az_rc" = 10 ] && echo HELD || echo INVALID) (policy) -- verify with 'fwf authz $li'" >/dev/null 2>&1 || true
      exit 1 ;;
    *)
      echo "fwf merge: REFUSED -- #$li's authz check exited unexpectedly ($az_rc); treating as INDETERMINATE (fail-closed): $az_out" >&2
      "$DIR/fwf-flag-captain.sh" "$li" --role qa --reason "fwf merge #$num REFUSED: authz check exited $az_rc (unexpected, fail-closed)" >/dev/null 2>&1 || true
      exit 1 ;;
  esac
done <<<"$linked"

ctx="$(fwf_context_block "$issue_num" | fwf_pr_body_guard)" || {
  echo "fwf merge: context fold refused (issue #106 guard, see above) -- not merging with a hollow or leaky body" >&2
  exit 1
}

credit="$(fwf_credit_block)"
provenance="$(fwf_provenance_block)"

body="$(printf 'Closes #%s.\n\n%s\n\n%s\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n%s' \
  "$issue_num" "$ctx" "$credit" "$provenance")"

exec gh pr merge "$num" --squash --delete-branch --subject "$title" --body "$body"
