#!/usr/bin/env bash
# fwf-pr-review-state.sh — issue #82: the single source of truth for the
# qa<->impl review handshake on the shared-account fwf-self swarm.
#
# WHY: every role authenticates as the SAME GitHub user (tbaums), so the
# formal review-decision API can never carry qa's change-request signal (you
# cannot `gh pr review --request-changes` your own PR) — it stays permanently
# empty on this account. An impl loop that reads that field concludes "no
# changes requested" even after qa posted one as a plain comment, and both
# sides idle forever (#81). qa instead posts a structured PLAIN comment,
# mirroring the PM<->GV `GV-SIGNOFF`/`GV-CHANGES` convention this reuses:
#
#   QA-CHANGES-REQUESTED: #<pr>   first line; may name a qaN/repro-<pr> branch
#   QA-APPROVED: #<pr>            first line
#   IMPL-ADDRESSED: #<pr> <sha>   impl's ack of a fix — impl must NEVER emit a
#                                 QA-* line; that asymmetry (not the comment
#                                 author, identical for every role here) is
#                                 what makes self-trigger impossible.
#
# Usage: fwf pr-review-state <pr-number>
# Emits exactly one line to stdout:
#   CHANGES_REQUESTED <repro-branch|none>   active request impl hasn't answered
#   AWAITING_REVIEW                         impl has responded (or no request exists)
#   APPROVED                                QA-APPROVED, or the PR is merged/closed
#   NONE                                    not a PR / no usable state
#
# Rules: the LATEST QA-* sentinel wins; a sentinel counts only at column 0 of
# a comment (never mid-line/quoted — this alone is the self-trigger guard,
# since the author field can't distinguish roles here). A winning
# QA-CHANGES-REQUESTED is "active" only if it is newer than impl's response:
# impl's latest IMPL-ADDRESSED comment timestamp is the PRIMARY signal (a
# clean comment-vs-comment compare); the PR's newest commit committedDate is
# only a FALLBACK when no IMPL-ADDRESSED exists yet, because committedDate can
# predate the actual push after an amend/rebase/cherry-pick and would
# otherwise misread a genuinely-newer fix as an unanswered request.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# --- gh access (overridable by tests) ---------------------------------------
gh_pr() {
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr "$@" ); else gh pr "$@"; fi
}
prs_comments() { # $1=pr -> [{body,createdAt}], gh's own thread order
  gh_pr view "$1" --json comments --jq '[.comments[] | {body, createdAt}]' 2>/dev/null || echo '[]'
}
prs_meta() { # $1=pr -> {state, lastCommitAt}
  gh_pr view "$1" --json state,commits --jq \
    '{state, lastCommitAt: ([.commits[].committedDate] | max // "")}' 2>/dev/null \
    || echo '{"state":"","lastCommitAt":""}'
}

# --- pure logic (given the two JSON blobs above) ----------------------------
# Column-0-only sentinel match + last-wins + newer-than-addressed all live in
# ONE jq program so the rules are tested once, not re-derived per caller.
resolve_state() { # $1=comments-json  $2=meta-json
  jq -nr --argjson comments "$1" --argjson meta "$2" '
    def repro_branch($body):
      ($body | capture("(?<b>qa[0-9]+/repro-[0-9]+)").b) // "none";

    if ($meta.state == "") then
      "NONE"
    elif ($meta.state == "MERGED" or $meta.state == "CLOSED") then
      "APPROVED"
    else
      ([$comments[] | select((.body // "") | test("^QA-(CHANGES-REQUESTED|APPROVED):"))]
       | sort_by(.createdAt) | last) as $qa
      | if ($qa == null) then
          "AWAITING_REVIEW"
        elif ($qa.body | test("^QA-APPROVED:")) then
          "APPROVED"
        else
          (([$comments[] | select((.body // "") | test("^IMPL-ADDRESSED:"))]
            | sort_by(.createdAt) | last | .createdAt) // $meta.lastCommitAt) as $addressed_at
          | if ($addressed_at != "" and $addressed_at != null and $addressed_at > $qa.createdAt) then
              "AWAITING_REVIEW"
            else
              "CHANGES_REQUESTED " + repro_branch($qa.body)
            end
        end
    end'
}

main() {
  local pr="${1:-}"
  case "$pr" in ''|*[!0-9]*) echo NONE; return 0;; esac
  resolve_state "$(prs_comments "$pr")" "$(prs_meta "$pr")"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
