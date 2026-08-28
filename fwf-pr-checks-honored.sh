#!/usr/bin/env bash
# fwf-pr-checks-honored.sh — issue #220 AC (i)/(o)/(p): the QA-side
# ERGONOMIC pre-merge checkpoint (#207's two-chokepoint language). NOT the
# security control -- branch protection (AC a-h) is; every seat holds owner
# credentials and can `gh pr merge` past this regardless. What this buys is
# the ergonomic half: fail fast, cheaply, with a clear reason, while the
# reviewer can still do something about it.
#
# THE ACTUAL FIX THIS CLOSES (instance 2, live incident): qa2 posted
# `QA-APPROVED: #241` and merged 6 seconds later while `shellcheck + syntax`
# reported FAILURE -- reasoning "gate green modulo suite flakiness unrelated
# to this diff", which was RIGHT about one flaky check and WRONG to let that
# belief generalise to a DETERMINISTIC one. Shellcheck does not race.
#
# THE RULE (AC o): a FAILURE conclusion refuses UNLESS EXPLICITLY NAMED. A
# blanket "the suite is flaky" does not satisfy this -- the actor must name
# WHICH check it is discounting. Naming one flaky check never licenses
# advancing past a DIFFERENT, deterministic red one.
#
# THE NAMING MECHANISM (AC p, mirroring #82's QA-*/fwf-Reviewer: convention
# rather than inventing a parallel one): a PLAIN PR comment whose FIRST LINE
# is exactly `fwf-CI-discount: <check-name>`, followed by the reason on
# subsequent lines. Column-0-per-comment, like every other marker this
# floor uses -- so a discount can never be quoted/discussed without also
# discounting for real (the #218 defect family: a sentinel matched by
# substring instead of anchored).
#
# Usage: fwf pr-checks-honored <pr-number>
# Exit codes:
#   0   every FAILURE conclusion (if any) is explicitly discounted by name --
#       CI is honored, this checkpoint has nothing to add.
#   1   at least one FAILURE is NOT discounted -- refuses. Prints exactly
#       which check(s), so the reviewer can act on it, not just re-check.
#   2   the checks (or the discount comments) could not be read at all --
#       fails CLOSED, never silently "nothing red" (issue #211's lesson:
#       unreadable != empty).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# --- gh access (overridable by tests) ---------------------------------------
gh_pr_checks() { # $1=pr -> [{name,bucket}] JSON array
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr checks "$1" --json name,bucket )
  else gh pr checks "$1" --json name,bucket; fi
}
gh_pr_comments() { # $1=pr -> [{body}] JSON array
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr view "$1" --json comments --jq '.comments')
  else gh pr view "$1" --json comments --jq '.comments'; fi
}

# $1=comments-json -> same shape, every body fence-stripped first
# (issue #194's own QA-caught lesson, applied here from the start: a
# `fwf-CI-discount:` marker quoted inside a ``` fence purely for
# discussion is column-0 on its own line, and the naive discount_name
# regex below would read it as a real discount otherwise). Shares
# fwf_strip_fences (lib.sh) with fwf-authz.sh's sentinel and #194's
# fwf-Reviewer: marker -- one stripper, not a third hand-rolled copy.
_strip_fences_in_comments_json() {
  printf '%s' "$1" | jq -c '.[]' | while IFS= read -r c; do
    local b_stripped
    b_stripped="$(printf '%s' "$c" | jq -r '.body' | fwf_strip_fences)"
    printf '%s' "$c" | jq -c --arg b "$b_stripped" '.body = $b'
  done | jq -sc '.'
}

# --- pure logic ---------------------------------------------------------
# $1=checks-json  $2=comments-json -> one "REFUSED: <check-name>" line per
# un-discounted FAILURE (empty output = fully honored / nothing to refuse).
_pr_checks_honored_diff() {
  jq -nr --argjson checks "$1" --argjson comments "$2" '
    def discount_name($body):
      ($body | capture("(?m)^fwf-CI-discount:[ \t]*(?<v>.+?)[ \t]*$"; "").v) // null;
    ([$comments[] | discount_name(.body // "")] | map(select(. != null))) as $discounted
    | [$checks[] | select(.bucket == "fail") | . as $c | select(($discounted | index($c.name)) == null)
        | "REFUSED: " + $c.name] | .[]
  '
}

main() {
  local pr="${1:?usage: fwf pr-checks-honored <pr-number>}" checks comments out
  if ! checks="$(gh_pr_checks "$pr" 2>/dev/null)"; then
    fwf_log_unknown_read fwf-pr-checks-honored.sh "pr=$pr checks could not be read (gh failure) -- refusing, never silently honored" || true
    echo "UNKNOWN: could not read checks for #$pr" >&2
    return 2
  fi
  if ! comments="$(gh_pr_comments "$pr" 2>/dev/null)"; then
    fwf_log_unknown_read fwf-pr-checks-honored.sh "pr=$pr comments could not be read (gh failure) -- refusing, never silently honored" || true
    echo "UNKNOWN: could not read comments for #$pr" >&2
    return 2
  fi
  comments="$(_strip_fences_in_comments_json "$comments")"
  out="$(_pr_checks_honored_diff "$checks" "$comments")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
