#!/usr/bin/env bash
# fwf-shipped.sh — issue #420: "the PR shipped" and "the fix shipped" are
# different claims, and #377 closed as "shipped and on main" on the strength
# of the FIRST one alone -- the merged PR's own head commit was an ancestor
# of main, but that head was an empty claim commit; the real fix (214e3ec)
# was pushed to the same branch AFTER the PR had already merged, so it was
# never in any PR at all. `git merge-base --is-ancestor <merge-commit> main`
# answers a true question about the wrong object.
#
# Two questions, both asked fresh against origin/$DEFAULT_BRANCH, and BOTH
# must hold for "shipped":
#   (A) is the PR's MERGED head an ancestor of main?        ("the PR shipped")
#   (B) did the head branch grow commits OUTSIDE that merged head, and if
#       so, is EVERY one of them also on main?               ("the fix shipped")
# (B)'s empty-set case (nothing landed after the merge) is the common,
# expected shape and is NOT itself a failure -- only a non-empty set with a
# member absent from main is NOT SHIPPED. Reported SEPARATELY, always, per
# PR -- collapsing them into one verdict is exactly how #377 slipped through
# (the closer's own check only ever asked (A)).
#
# Issue resolution reuses the shipped resolver, not a bespoke one:
# `_fwf_pr_ctx_pr_linked_issues` (lib/pr_context.sh) greps a PR's OWN BODY
# for GitHub's recognized closing keywords -- a github cross-reference search
# over-matches (comments, discussion mentions, unrelated PRs that merely
# cite the number) and `closingIssuesReferences` is empty for every PR here
# (every fwf PR bases on $STAGING_BRANCH, never $DEFAULT_BRANCH, which is
# the only base GitHub tracks that field for). Candidate PRs are gathered via
# `gh pr list --search "<n> in:body"` (broad, over-matching) and then
# NARROWED through the real resolver (precise) -- the two-step shape #377's
# own reopening evidence demonstrated: nine candidates, two real links.
#
# Usage: fwf shipped <issue> [--sha <merged-head-sha>]
#   <issue>        issue number to check.
#   --sha <sha>    OVERRIDE: skip PR resolution entirely and check (A) alone
#                  for this exact commit (no branch to compare a tip
#                  against, so (B) is not evaluated and the report says so).
#                  For a multi-PR ticket the query cannot resolve. NOT the
#                  default path -- a closer who names the wrong sha by hand
#                  gets exactly the same false green #377's own closer did;
#                  requiring a DIFFERENT hand-picked object leans on the same
#                  judgement that already failed once.
#
# Exit codes (a REPORT tool, never an automatic reopen/close -- issue #420
# AC4; the caller decides what to do with the verdict):
#   0 = SHIPPED      -- at least one linked, merged PR satisfies (A) AND (B).
#   1 = NOT SHIPPED  -- every linked PR fails (A) and/or (B), or the --sha
#                       override's (A) alone failed.
#   2 = NO COMPARISON -- nothing to check: no linked PR found, or (for --sha)
#                       nothing else applicable. Silence must never render as
#                       clean -- this is a distinct, named state, not a 0.
#   3 = NOT APPLICABLE -- the issue is closed with a state_reason other than
#                       "completed" (declined/duplicate/superseded/etc.): a
#                       decision closure, not a delivery closure, and must
#                       not be dragged through a check it can only fail.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf shipped <issue> [--sha <merged-head-sha>]" >&2; }

_shipped_gh() { if [ -d "${FWF_REPO:-}/.git" ]; then ( cd "$FWF_REPO" && gh "$@" ); else gh "$@"; fi; }

# $1=sha -> is it an ancestor of the freshly-fetched origin/$DEFAULT_BRANCH?
# Echoes the main sha checked against on stdout (issue #420 edge case: a
# stale FAIL must be recognisable as one), rc 0 ancestor / 1 not / 2 could
# not determine (fetch/rev-parse failure -- fails toward "not shipped", the
# same closed direction #211/#193 use for every other unreadable state here).
_shipped_check_a() { # $1=sha -> echoes "<main_sha>"; rc 0/1/2
  local sha="$1" main_sha
  git -C "$FWF_REPO" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 \
    || { echo ""; return 2; }
  main_sha="$(git -C "$FWF_REPO" rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null)" \
    || { echo ""; return 2; }
  echo "$main_sha"
  git -C "$FWF_REPO" merge-base --is-ancestor "$sha" "$main_sha" 2>/dev/null
}

# $1=merged-head-sha $2=head-ref-name $3=main_sha (already fetched by (A)) ->
# stdout: one of
#   "EMPTY"                          -- tip == merged head, nothing outside.
#   "NO_BRANCH"                      -- head ref no longer exists (deleted on
#                                        merge, the expected clean shape).
#   "CLEAN <n>"                      -- n commit(s) landed after the merge,
#                                        ALL present on main (surfaced, not a
#                                        failure).
#   "MISSING <sha1> <sha2> ..."      -- commit(s) outside the merged head that
#                                        are NOT on main. NOT SHIPPED.
_shipped_check_b() {
  local head_sha="$1" head_ref="$2" main_sha="$3" tip outside s missing=()
  tip="$(git -C "$FWF_REPO" ls-remote origin "refs/heads/$head_ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$tip" ] || { echo "NO_BRANCH"; return 0; }
  [ "$tip" = "$head_sha" ] && { echo "EMPTY"; return 0; }
  git -C "$FWF_REPO" fetch origin "$head_ref" >/dev/null 2>&1 || true
  outside="$(git -C "$FWF_REPO" rev-list "${head_sha}..${tip}" 2>/dev/null)"
  [ -n "$outside" ] || { echo "EMPTY"; return 0; }
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    git -C "$FWF_REPO" merge-base --is-ancestor "$s" "$main_sha" 2>/dev/null || missing+=("$s")
  done <<< "$outside"
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "CLEAN $(printf '%s\n' "$outside" | wc -l | tr -d ' ')"
  else
    echo "MISSING ${missing[*]}"
  fi
}

# $1=issue -> candidate PR numbers (broad, over-matching text search),
# newline-separated, empty if none / gh unreachable.
_shipped_candidates() {
  _shipped_gh pr list -R "$(fwf_repo_slug)" --search "$1 in:body" --state all --json number \
    --jq '.[].number' 2>/dev/null || true
}

main() {
  local issue="" sha_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha_override="${2:-}"; [ -n "$sha_override" ] || { usage; exit 1; }; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      ''|*[!0-9]*) usage; exit 1 ;;
      *) [ -z "$issue" ] || { usage; exit 1; }; issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || { usage; exit 1; }

  # AC (edge case): a decision closure (declined/duplicate/superseded) is
  # not a delivery closure -- it can only ever fail this check, and running
  # it anyway manufactures noise on a ticket nobody meant to ship. Only a
  # CLOSED issue is affected; an open one always proceeds (a captain may
  # legitimately want to know "has this already shipped via an old PR"
  # before an issue is even closed).
  local st reason
  st="$(_shipped_gh issue view "$issue" --json state --jq '.state' 2>/dev/null || true)"
  if [ "$st" = "CLOSED" ]; then
    reason="$(_shipped_gh issue view "$issue" --json stateReason --jq '.stateReason // "unknown"' 2>/dev/null || echo unknown)"
    if [ "$reason" != "COMPLETED" ]; then
      echo "issue #$issue: NOT APPLICABLE -- closed as ${reason,,} (a decision closure, not a delivery closure); shipped-check does not apply"
      exit 3
    fi
  fi

  if [ -n "$sha_override" ]; then
    echo "issue #$issue: checking --sha override $sha_override (bypasses PR resolution; (B) not evaluated -- no branch to compare a tip against)"
    local main_sha rc
    main_sha="$(_shipped_check_a "$sha_override")"; rc=$?
    case "$rc" in
      2) echo "issue #$issue: NO COMPARISON -- could not fetch/resolve origin/$DEFAULT_BRANCH"; exit 2 ;;
      0) echo "issue #$issue: SHIPPED -- $sha_override is an ancestor of origin/$DEFAULT_BRANCH ($main_sha)"; exit 0 ;;
      1) echo "issue #$issue: NOT SHIPPED -- $sha_override is NOT an ancestor of origin/$DEFAULT_BRANCH ($main_sha)"; exit 1 ;;
    esac
  fi

  # Broad candidates, narrowed to REAL "Closes #N" links only (issue #420
  # AC1) -- a cross-reference search over-matches every PR that merely
  # mentions the number in prose/discussion.
  local candidates linked_prs=() c links
  candidates="$(_shipped_candidates "$issue")"
  if [ -n "$candidates" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      links="$(_fwf_pr_ctx_pr_linked_issues "$c")"
      if printf '%s\n' "$links" | grep -qx "$issue"; then
        linked_prs+=("$c")
      fi
    done <<< "$candidates"
  fi

  if [ "${#linked_prs[@]}" -eq 0 ]; then
    echo "issue #$issue: NO COMPARISON -- no PR found declaring 'Closes #$issue' (or Fixes/Resolves) in its body"
    exit 2
  fi

  # Run (A)+(B) over EVERY linked PR, report each -- never pick one (issue
  # #420 AC1): a multi-PR issue can have one hollow-merged PR and one real
  # open one, and picking either alone yields a confident, opposite answer.
  local pr merged head_sha head_ref state main_sha rc_a b_result any_shipped=0 not_shipped_prs=() landed_sha
  for pr in "${linked_prs[@]}"; do
    local pr_json
    pr_json="$(_shipped_gh api "repos/$(fwf_repo_slug)/pulls/$pr" --jq '{merged, head_sha:.head.sha, head_ref:.head.ref, state, merge_commit_sha:.merge_commit_sha}' 2>/dev/null)"
    if [ -z "$pr_json" ]; then
      echo "PR #$pr: NO COMPARISON -- could not read the PR"
      not_shipped_prs+=("$pr")
      continue
    fi
    merged="$(printf '%s' "$pr_json" | jq -r '.merged')"
    state="$(printf '%s' "$pr_json" | jq -r '.state')"
    if [ "$merged" != "true" ]; then
      echo "PR #$pr: NOT SHIPPED -- not merged (state=$state)"
      not_shipped_prs+=("$pr")
      continue
    fi
    head_sha="$(printf '%s' "$pr_json" | jq -r '.head_sha')"
    head_ref="$(printf '%s' "$pr_json" | jq -r '.head_ref')"
    # issue #470 AC2: (A) asks "did the LANDED commit reach main" -- for a
    # squash or rebase merge, that is merge_commit_sha, never head_sha (a
    # squash's head is never an ancestor of anything; a rebase's head is
    # rewritten onto the base, so it isn't either). Unconditional, not
    # strategy-dependent: merge_commit_sha is populated for all three merge
    # strategies (merge/squash/rebase), so head_sha is only ever a fallback
    # for the data-absent case (merge_commit_sha literally null), never a
    # per-strategy choice -- that distinction is what AC2 requires.
    landed_sha="$(printf '%s' "$pr_json" | jq -r '.merge_commit_sha // empty')"
    [ -n "$landed_sha" ] || landed_sha="$head_sha"

    main_sha="$(_shipped_check_a "$landed_sha")"; rc_a=$?
    if [ "$rc_a" -eq 2 ]; then
      echo "PR #$pr: NO COMPARISON -- could not fetch/resolve origin/$DEFAULT_BRANCH"
      not_shipped_prs+=("$pr")
      continue
    fi
    if [ "$rc_a" -ne 0 ]; then
      echo "PR #$pr: NOT SHIPPED -- (A) FAIL: landed commit $landed_sha is NOT an ancestor of origin/$DEFAULT_BRANCH ($main_sha)"
      not_shipped_prs+=("$pr")
      continue
    fi

    b_result="$(_shipped_check_b "$head_sha" "$head_ref" "$main_sha")"
    case "$b_result" in
      EMPTY)
        echo "PR #$pr: SHIPPED -- (A) OK, (B) OK: landed commit $landed_sha is on origin/$DEFAULT_BRANCH ($main_sha), nothing landed on '$head_ref' after the merge"
        any_shipped=1 ;;
      NO_BRANCH)
        echo "PR #$pr: SHIPPED -- (A) OK (landed commit $landed_sha is on origin/$DEFAULT_BRANCH ($main_sha)), (B) no comparison: head branch '$head_ref' no longer exists (expected shape for a clean delete-on-merge)"
        any_shipped=1 ;;
      CLEAN\ *)
        echo "PR #$pr: SHIPPED -- (A) OK, (B) OK: ${b_result#CLEAN } commit(s) landed on '$head_ref' after the merge, all present on origin/$DEFAULT_BRANCH ($main_sha) via another route"
        any_shipped=1 ;;
      MISSING\ *)
        echo "PR #$pr: NOT SHIPPED -- (A) OK, (B) FAIL: commit(s) outside the merged head ($head_sha) are NOT on origin/$DEFAULT_BRANCH ($main_sha): ${b_result#MISSING }"
        not_shipped_prs+=("$pr") ;;
    esac
  done

  if [ "$any_shipped" -eq 1 ]; then
    if [ "${#not_shipped_prs[@]}" -gt 0 ]; then
      echo "issue #$issue: SHIPPED (via the PR(s) above) -- but also names ${#not_shipped_prs[@]} linked PR(s) that did NOT ship on their own: ${not_shipped_prs[*]}"
    else
      echo "issue #$issue: SHIPPED"
    fi
    exit 0
  fi
  echo "issue #$issue: NOT SHIPPED -- no linked PR satisfies both (A) and (B)"
  exit 1
}

main "$@"
