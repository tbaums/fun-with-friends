#!/usr/bin/env bash
# fwf-pr-reviewer.sh — issue #194: resolve a PR's CURRENTLY ASSIGNED reviewer
# from the recorded `fwf-Reviewer:` marker, never re-derived from a branch
# prefix. Reviewer routing used to be inferred from headRefName (qaN reviews
# "implN/*"), which strands any PR authored by captain/gv/pm/conductor with
# no reviewer at all -- invisible to every QA, unmergeable except by a
# captain self-merge (the unreviewed-merge failure this ticket exists to
# close). Explicit assignment: recorded once at PR-creation time, re-
# assignable via a comment, never re-guessed.
#
# Precedence (stated explicitly, per the ticket, because "newest wins" alone
# has no defined answer across two different surfaces with no comparable
# timestamp):
#   1. Any COMMENT marker beats the body marker.
#   2. Among comment markers, the newest wins.
#   3. The body marker is the creation-time default -- applies only when no
#      comment marker exists.
# A marker matches only at column 0 of its line (never mid-line/quoted),
# mirroring #82's QA-*/GV-* sentinel convention this reuses.
#
# Usage: fwf pr-reviewer <pr-number>
# Emits exactly one line to stdout:
#   <seat>       e.g. "qa2" -- the resolved, currently-assigned reviewer.
#   none         an explicit `fwf-Reviewer: none` was recorded (the
#                degenerate zero-configured-QA-seats case, issue #194 AC h).
#   NO_MARKER    the PR was read successfully but carries no marker at all
#                (pre-migration or a human-opened PR) -- the CALLER applies
#                the permanent branch-prefix fallback, this script never
#                guesses one itself.
#   UNKNOWN      the PR could not be read at all (gh/network failure) --
#                issue #211's own lesson, applied here: "no marker" and
#                "could not check for a marker" must never collapse into the
#                same answer, or a transient read glitch would strip a PR's
#                explicit assignment and misroute it into the caller's
#                fallback path by accident.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# --- gh access (overridable by tests, same shape as fwf-pr-review-state.sh) --
gh_pr() {
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr "$@" ); else gh pr "$@"; fi
}
# $1=pr -> {"body":..., "comments":[{body,createdAt}]} or nothing on failure
# (never a fabricated empty-but-successful shape -- the caller distinguishes
# "gh printed nothing" from "gh printed {}" by checking $? via the `if`
# wrapper in main(), not by inspecting this output alone).
pr_raw() {
  gh_pr view "$1" --json body,comments --jq '{body: (.body // ""), comments: [.comments[] | {body: (.body // ""), createdAt}]}' 2>/dev/null
}

# $1=raw-json (pr_raw's shape) -> same shape, with body/every comment-body
# fence-stripped first (QA-caught, repro qa1/repro-281): a `fwf-Reviewer:`
# marker quoted inside a ``` fence purely for discussion is column-0 on its
# own line and must NOT resolve as a real re-assignment -- the same bypass
# fwf-authz.sh's sentinel matcher already closes (#218), reused here via the
# shared fwf_strip_fences (lib.sh) rather than a second hand-rolled copy.
_strip_fences_json() {
  local raw="$1" body_stripped comments_stripped
  body_stripped="$(printf '%s' "$raw" | jq -r '.body' | fwf_strip_fences)"
  comments_stripped="$(
    printf '%s' "$raw" | jq -c '.comments[]' | while IFS= read -r c; do
      local cb_stripped
      cb_stripped="$(printf '%s' "$c" | jq -r '.body' | fwf_strip_fences)"
      printf '%s' "$c" | jq -c --arg b "$cb_stripped" '.body = $b'
    done | jq -sc '.'
  )"
  jq -nc --arg body "$body_stripped" --argjson comments "$comments_stripped" '{body: $body, comments: $comments}'
}

# --- pure logic (given the raw JSON above) -----------------------------------
resolve_reviewer() { # $1=raw-json -> <seat>|none|NO_MARKER
  local stripped
  stripped="$(_strip_fences_json "$1")"
  jq -nr --argjson raw "$stripped" '
    def marker_of($body):
      ($body | capture("(?m)^fwf-Reviewer:[ \t]*(?<v>[A-Za-z0-9_-]+)"; "").v) // null;

    ([$raw.comments[] | select((.body // "") | test("(?m)^fwf-Reviewer:"))]
     | sort_by(.createdAt) | last) as $c
    | if ($c != null) then
        marker_of($c.body) // "NO_MARKER"
      else
        (marker_of($raw.body) // "NO_MARKER")
      end'
}

main() {
  local pr="${1:?usage: fwf pr-reviewer <pr-number>}" raw
  case "$pr" in ''|*[!0-9]*) echo "UNKNOWN"; return 0;; esac
  if ! raw="$(pr_raw "$pr")"; then
    fwf_log_unknown_read fwf-pr-reviewer.sh "pr=$pr could not be read (gh failure)" || true
    echo "UNKNOWN"
    return 0
  fi
  resolve_reviewer "$raw"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
