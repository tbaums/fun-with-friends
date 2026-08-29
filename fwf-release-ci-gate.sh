#!/usr/bin/env bash
# fwf-release-ci-gate.sh -- issue #303: the release gate consults ci.yml's
# verdict for the tagged SHA, rather than re-implementing a SUBSET of CI's
# own checks (release.yml historically ran only shellcheck + a single
# ubuntu functional pass -- anything red only on another CI job, e.g.
# `dash crate (rust)` or a since-removed macOS lane, was invisible to it,
# and three consecutive releases (v0.33.0/v0.34.0/v0.35.0) published over a
# red `dash crate (rust)` as a result).
#
# SOURCE OF TRUTH: .github/branch-policy.json's required_contexts (the same
# file fwf-branch-policy.sh diffs live branch protection against) -- this
# script does not name a single check by hand, so the two can never drift
# from each other the way release.yml's old hand-rolled subset drifted from
# ci.yml.
#
# THE DANGEROUS CASE IS ABSENT, NOT FAILING (AC b): a required context that
# has never reported for this SHA must refuse the release, exactly like a
# failing one -- "none of the required contexts are failing" is TRUE for a
# context that simply never ran, and answering the wrong question here is
# how a silently-renamed CI job (the exact case #220/branch-policy.json's
# own comment warns about) turns into a silent, permanent bypass instead of
# a loud one.
#
# THE RACE WITH ci.yml (AC c): release.yml (tags) and ci.yml (push to main)
# fire from the same push, as two independent workflow runs -- at the
# moment this gate first looks, a required context may be genuinely
# pending, not failing. So this polls, bounded by a stated timeout; on
# timeout it FAILS CLOSED (does not publish) rather than proceeding on
# whatever partial picture it has. See FWF_RELEASE_CI_TIMEOUT_SECS below
# for the timeout and the measurement it's based on.
#
# Usage: fwf-release-ci-gate.sh <sha>
# Exit: 0 = every required context reported SUCCESS for <sha> (latest run
#           per context). 1 = at least one required context is missing,
#           pending past the timeout, or completed non-success. 2 = a real
#           read failure (policy file unreadable/malformed, gh api
#           unreachable) -- UNKNOWN, never silently treated as green
#           (issue #211's own lesson).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

POLICY_FILE="${FWF_BRANCH_POLICY_FILE:-$FWF_REPO/.github/branch-policy.json}"

# issue #303 (c1): the ONLY required context left with real runtime variance
# is "functional suite (ubuntu-latest)" -- observed 13-16 minutes wall-clock
# across this session's own CI runs (2026-08-29, e.g. run 33230009451:
# 02:52:27Z-03:07:38Z, ~15m11s). "dash crate (rust)" and "shellcheck +
# syntax" both complete in under a minute. The macOS lane this timeout
# used to have to accommodate was removed from ci.yml entirely by 15801ee
# (docs/macos-ci.md) -- it no longer contributes to the race at all.
# 1200s (20m) is the ubuntu suite's observed worst case plus ~5 minutes of
# margin for queueing/scheduling jitter, not a guess.
FWF_RELEASE_CI_TIMEOUT_SECS="${FWF_RELEASE_CI_TIMEOUT_SECS:-1200}"
FWF_RELEASE_CI_POLL_SECS="${FWF_RELEASE_CI_POLL_SECS:-20}"

usage() { echo "usage: fwf-release-ci-gate.sh <sha>" >&2; }

policy_json() {
  [ -f "$POLICY_FILE" ] || { echo "fwf-release-ci-gate.sh: policy file not found: $POLICY_FILE" >&2; return 2; }
  jq -c '.' "$POLICY_FILE" 2>/dev/null || { echo "fwf-release-ci-gate.sh: policy file is not valid JSON: $POLICY_FILE" >&2; return 2; }
}

# Overridable for tests (same shape as fwf-branch-policy.sh's
# gh_branch_protection): emits the raw check-runs JSON for $1=sha.
gh_check_runs() { # $1=sha
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh api "repos/{owner}/{repo}/commits/$1/check-runs" --paginate )
  else gh api "repos/{owner}/{repo}/commits/$1/check-runs" --paginate; fi
}

# $1=sha -> prints one TSV line per REQUIRED context: "<name>\t<verdict>"
# where verdict is one of: ok | absent | pending | failed. Never partial --
# every required context gets exactly one line, so a caller counting lines
# can never mistake "silently dropped" for "clean".
#
# LATEST RUN PER CONTEXT (edge case: "say which run it consults"): GitHub's
# check-runs endpoint can return more than one run for the same context
# name (a re-run). Sorted by started_at descending so [0] is the most
# recent -- two readers of the same SHA at different times get the same
# answer as long as no NEW run has started since.
_release_ci_gate_verdicts() { # $1=sha $2=required-contexts-json-array
  local sha="$1" required="$2" runs name verdict latest
  if ! runs="$(gh_check_runs "$sha")"; then
    echo "fwf-release-ci-gate.sh: could not read check-runs for $sha (gh api failed)" >&2
    return 2
  fi
  printf '%s' "$runs" | jq -e '.check_runs' >/dev/null 2>&1 || {
    echo "fwf-release-ci-gate.sh: check-runs response for $sha is not the expected shape" >&2
    return 2
  }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    latest="$(printf '%s' "$runs" | jq -c --arg n "$name" \
      '[.check_runs[] | select(.name == $n)] | sort_by(.started_at) | last // empty')"
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
      verdict=absent
    else
      local status conclusion
      status="$(printf '%s' "$latest" | jq -r '.status')"
      conclusion="$(printf '%s' "$latest" | jq -r '.conclusion // empty')"
      if [ "$status" != "completed" ]; then
        verdict=pending
      # issue #286's own lesson, cited by this ticket's edge cases:
      # "skipped" is reachable when a prior step in the SAME job fails and
      # later steps skip -- it is not evidence of health, so it is treated
      # as failed here, never folded into "not failing therefore fine".
      elif [ "$conclusion" = "success" ]; then
        verdict=ok
      else
        verdict=failed
      fi
    fi
    printf '%s\t%s\n' "$name" "$verdict"
  done < <(printf '%s' "$required" | jq -r '.[]')
}

main() {
  local sha="${1:-}"
  [ -n "$sha" ] || { usage; return 2; }

  local required_contexts
  required_contexts="$(policy_json | jq -c '.required_contexts')" || return 2

  local deadline waited=0 verdicts failed_lines not_ok now
  deadline=$(( $(date -u +%s) + FWF_RELEASE_CI_TIMEOUT_SECS ))
  while :; do
    if ! verdicts="$(_release_ci_gate_verdicts "$sha" "$required_contexts")"; then
      return 2
    fi
    failed_lines="$(printf '%s\n' "$verdicts" | awk -F'\t' '$2=="failed"{print}')"
    if [ -n "$failed_lines" ]; then
      # A definitively completed, non-success context is a REFUSAL right
      # now -- no amount of further waiting resolves an already-completed
      # run, so this does not wait out the rest of the timeout on a
      # verdict that is never going to change.
      echo "fwf-release-ci-gate.sh: REFUSING $sha -- required context(s) failed:" >&2
      printf '%s\n' "$failed_lines" | awk -F'\t' '{print "  " $1}' >&2
      printf '%s\n' "$verdicts" | awk -F'\t' '$2!="ok"{print "  " $1 ": " $2}' >&2
      return 1
    fi
    not_ok="$(printf '%s\n' "$verdicts" | awk -F'\t' '$2!="ok"{print}')"
    if [ -z "$not_ok" ]; then
      echo "fwf-release-ci-gate.sh: $sha is green -- every required context reported success:" >&2
      printf '%s\n' "$verdicts" | awk -F'\t' '{print "  " $1}' >&2
      return 0
    fi
    now="$(date -u +%s)"
    if [ "$now" -ge "$deadline" ]; then
      echo "fwf-release-ci-gate.sh: REFUSING $sha -- timed out after ${FWF_RELEASE_CI_TIMEOUT_SECS}s waiting for required context(s) still absent/pending:" >&2
      printf '%s\n' "$not_ok" | awk -F'\t' '{print "  " $1 ": " $2}' >&2
      return 1
    fi
    echo "fwf-release-ci-gate.sh: waiting on $(printf '%s\n' "$not_ok" | wc -l | tr -d ' ') required context(s) (${waited}s elapsed, timeout ${FWF_RELEASE_CI_TIMEOUT_SECS}s):" >&2
    printf '%s\n' "$not_ok" | awk -F'\t' '{print "  " $1 ": " $2}' >&2
    sleep "$FWF_RELEASE_CI_POLL_SECS"
    waited=$(( waited + FWF_RELEASE_CI_POLL_SECS ))
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; exit $?; fi
