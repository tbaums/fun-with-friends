#!/usr/bin/env bash
# fwf-pr-assign-reviewer.sh — issue #194: decide WHO a new PR's reviewer
# should be, from the CONFIGURED seat roster, deterministically.
#
# Rule (stated in the ticket, reproduced here so the code and the spec never
# drift apart):
#   1. Head branch is implN/* -> qaN. Preserves today's pairing exactly.
#   2. Otherwise (captain/*, gv/*, pm/*, conductor/*, anything else) -> the
#      LEAST-LOADED configured QA seat by open-assigned-PR count, ties
#      broken by lowest seat index (roster order) so the result is
#      reproducible.
#   3. No QA seat configured at all -> "none" (fwf dash surfaces this).
#
# LIVENESS IS DELIBERATELY ABSENT. Routing to the least-loaded LIVE seat
# would mean a captain PR created during a qa2 respawn routes permanently to
# qa1 (or none) on a condition that resolved in seconds -- and there is no
# live-seat query in this codebase to build that on anyway (fwf_all_roles
# is the CONFIGURED roster; fwf-supervise.sh's verdict lives inside its own
# loop, not a queryable view). Liveness is an OBSERVATION about a stable
# assignment, surfaced on the dash, never an input to making it.
#
# UNREADABLE != EMPTY (issue #211's own lesson, in a second subsystem): the
# roster itself (fwf_qa_roster, lib.sh) is pure/infallible -- PAIRS and
# suppression are both config-derived, no file/network read -- so "zero
# seats configured" is always a real, confident answer, never a collapsed
# read. The genuinely fallible read here is the OPEN-PR-COUNT query (a live
# `gh pr list` call): if THAT fails, this refuses to fabricate "everyone is
# at 0 load" and instead falls back to the same deterministic tie-break
# (lowest-index configured seat) a real all-tied count would produce --
# logged for observability, never silently mistaken for a confident count.
#
# Usage: fwf pr-assign-reviewer <head-branch>
# Emits exactly one line: <seat> | none
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# --- gh access (overridable by tests) ---------------------------------------
gh_pr_list() {
  local q='[.[] | {number, headRefName, body: (.body // ""), comments: [.comments[] | {body: (.body // ""), createdAt}]}]'
  if [ -d "$FWF_REPO/.git" ]; then
    ( cd "$FWF_REPO" && gh pr list --state open --json number,headRefName,body,comments --jq "$q" )
  else
    gh pr list --state open --json number,headRefName,body,comments --jq "$q"
  fi 2>/dev/null
}

# --- pure logic ---------------------------------------------------------
# $1=roster-json(array of seat names, index order)  $2=open-prs-json
# -> the least-loaded seat, tie-broken by roster index.
_assign_least_loaded() {
  jq -nr --argjson roster "$1" --argjson prs "$2" '
    def marker_of($body):
      ($body | capture("(?m)^fwf-Reviewer:[ \t]*(?<v>[A-Za-z0-9_-]+)"; "").v) // null;
    def resolved($pr):
      ([$pr.comments[] | select((.body // "") | test("(?m)^fwf-Reviewer:"))] | sort_by(.createdAt) | last) as $c
      | if $c != null then (marker_of($c.body) // null) else (marker_of($pr.body) // null) end;
    def fallback($pr):
      ($pr.headRefName | capture("^impl(?<n>[0-9]+)/"; "").n) as $n
      | if $n then "qa" + $n else null end;
    ([$prs[] | (resolved(.) // fallback(.))]
      | map(select(. != null and . != "none"))) as $assigned
    | ($roster | to_entries
       | map(. as $e | {seat: $e.value, idx: $e.key,
                        count: ([$assigned[] | select(. == $e.value)] | length)}))
    | sort_by([.count, .idx]) | .[0].seat
  '
}

main() {
  local branch="${1:?usage: fwf pr-assign-reviewer <head-branch>}" n roster roster_json
  # Rule 1: implN/* -> qaN, deterministic, no read of any kind needed.
  case "$branch" in
    impl[0-9]*/*)
      n="${branch#impl}"; n="${n%%/*}"
      echo "qa$n"
      return 0
      ;;
  esac

  roster="$(fwf_qa_roster)"
  # Rule 3: genuinely zero configured seats -- a real, confident answer.
  [ -n "$roster" ] || { echo "none"; return 0; }
  roster_json="$(printf '%s\n' "$roster" | jq -R -s -c 'split("\n") | map(select(length>0))')"

  local prs_json
  if ! prs_json="$(gh_pr_list)"; then
    fwf_log_unknown_read fwf-pr-assign-reviewer.sh "could not list open PRs -- falling back to the lowest-index configured seat, same as an all-tied count would produce" || true
    printf '%s\n' "$roster" | head -1
    return 0
  fi
  _assign_least_loaded "$roster_json" "$prs_json"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
