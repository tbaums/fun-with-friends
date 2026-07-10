#!/usr/bin/env bash
# fwf-pr-review-state.sh — single source of truth for whether a PR has an
# active qa change-request, on a shared GH account where the formal
# review-decision API is unusable: every role authenticates as the same
# GitHub user, so `gh pr review --request-changes` / `--approve` on your own
# PR is rejected, and reviewDecision/mergeStateStatus stay structurally empty
# (issue #82). qa and impl therefore signal state via sentinel PR comments;
# this helper is the ONE place that parses the thread, so both role prompts
# can shrink to "run this, obey its output" instead of hand-parsing prose.
#
# Sentinel protocol (see docs/tutorial.md "PR review state on a shared
# account"): a marker counts ONLY at column 0 (the first line of the comment
# body) — this is what disambiguates roles on an account where the GH
# comment-author field is identical for everyone, not an author check.
#   qa posts:   QA-CHANGES-REQUESTED: #<pr>   (may name a qaN/repro-<pr> branch)
#               QA-APPROVED: #<pr>
#   impl posts: IMPL-ADDRESSED: #<pr> <sha>
# impl must NEVER emit a line matching the QA-* pattern at column 0.
#
# Usage: fwf pr-review-state <pr-number>
# Output (exactly one line, one of):
#   CHANGES_REQUESTED <repro-branch|none>   active qa request impl hasn't answered
#   AWAITING_REVIEW                        impl has answered (or no request yet)
#   APPROVED                                latest QA-* sentinel is QA-APPROVED, or PR merged
#   NONE                                    no such PR, or PR closed unmerged
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib.sh path is resolved at runtime
source "$DIR/lib.sh"

pr="${1:-}"
case "$pr" in
  ''|*[!0-9]*) echo "usage: fwf pr-review-state <pr-number>" >&2; exit 1;;
esac

json="$(gh pr view "$pr" --json state,mergedAt,comments,commits 2>/dev/null)" || { echo NONE; exit 0; }
[ -n "$json" ] || { echo NONE; exit 0; }

printf '%s' "$json" | jq -r '
  if .state == "MERGED" or (.mergedAt != null) then "APPROVED"
  elif .state == "CLOSED" then "NONE"
  else
    (.comments // [] | sort_by(.createdAt)) as $c |
    ($c | map(select(.body | test("^QA-CHANGES-REQUESTED:"))))  as $cr |
    ($c | map(select(.body | test("^QA-APPROVED:"))))           as $ap |
    ($c | map(select(.body | test("^IMPL-ADDRESSED:"))))        as $ia |
    (($cr + $ap) | sort_by(.createdAt)) as $qa |
    if ($qa|length) == 0 then "AWAITING_REVIEW"
    else
      ($qa[-1]) as $latest |
      if ($latest.body | test("^QA-APPROVED:")) then "APPROVED"
      else
        ( if ($ia|length) > 0 then ($ia | sort_by(.createdAt) | .[-1].createdAt) else null end ) as $lastImpl |
        ( .commits // [] | sort_by(.committedDate) | if length > 0 then .[-1].committedDate else null end ) as $lastPush |
        ( if $lastImpl != null then ($lastImpl > $latest.createdAt)
          elif $lastPush != null then ($lastPush > $latest.createdAt)
          else false end ) as $addressed |
        if $addressed then "AWAITING_REVIEW"
        else
          ( ($latest.body | [scan("qa[0-9]+/repro-[0-9]+")] | .[0]) // "none" ) as $branch |
          "CHANGES_REQUESTED " + $branch
        end
      end
    end
  end
'
