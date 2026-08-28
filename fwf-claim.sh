#!/usr/bin/env bash
# fwf-claim.sh — issue #243: a fail-FAST authorization checkpoint at
# INTENT-FORMATION time, split out of #207 (which keeps the enforcement
# checkpoint — merge/promote/release, refused repository-side). This is the
# ergonomic half: today an implementer discovers a HELD issue is not
# authorized only at merge, after the work is already done — the most
# expensive possible moment to learn it, and exactly the pressure that
# produced the forged CAPTAIN-NOTICE incident this ticket exists to relieve.
#
# THIS IS NOT A SECURITY CONTROL. An agent can simply not run `fwf claim`.
# Its value is making the authorized path the EASY path and surfacing a
# hold before the effort is spent — #207's repository-side refusal is what
# makes the hold BINDING. Stated here AND on the success path (AC h): the
# terminal is where a reader draws the "was this authorized?" conclusion,
# not the docs.
#
# Usage: fwf claim <issue-number>
#   On success: prints the prerequisite scan (if any), the ergonomic-not-
#   control statement, and creates the claim artifact -- an empty commit
#   `claim #<n>: <title>` (the definition pinned by this ticket, AC i0/i2:
#   NO branch management here, matching #177's own live worktree-branch
#   contention concern -- the caller is assumed to already be on the
#   right branch).
#
# Exit codes: 0 = claimed (AUTHORIZED or NOT-GATED, INDETERMINATE warns but
#   still proceeds). 1 = REFUSED (HELD or INVALID) or a usage error.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# Same dual-backend shape as fwf-dash-data.sh's di_read: FWF_ISSUES=local
# routes to the local store (fwf-issues.sh), else real gh -- a claim run
# against the local test/dev issue store must never shell out to gh.
_issue_read() { # $1=issue-number ; rest = --json <field> --jq <expr>
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$@"
  else
    gh issue view "$@"
  fi
}

usage() { echo "usage: fwf claim <issue-number>   # fail-fast authorization checkpoint at intent-formation time (issue #243) -- NOT a security control, see 'fwf claim --help'" >&2; }

# issue #243 AC (h): the ergonomic-not-control statement, verbatim, on
# BOTH --help and the success path -- the terminal is where a reader
# concludes an authorization check was passed, not the docs.
ERGONOMIC_NOTICE="fwf claim is an ERGONOMIC checkpoint, not a security control: it can simply be skipped. #207's repository-side refusal at merge/promote/release is what actually binds authorization -- this only surfaces a hold before effort is spent on it."

case "${1:-}" in
  -h|--help|help)
    usage
    echo "$ERGONOMIC_NOTICE" >&2
    exit 0
    ;;
esac

num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 1;; esac

# --- refusal event log, durable across ticks (issue #243 AC f) --------------
# EVENT-SOURCED, never recomputed per render: fwf-dash-data.sh reading this
# costs a file read, not a fresh `fwf authz` (and hence a fresh comment-
# thread read) per candidate issue per refresh -- issue #239 already
# measured that exact per-render cost as the dash's dominant term, and a
# second one here would double it before #239 even finished measuring the
# first. Durable (a real file under $FWF_STATE_DIR, not in-process state
# that resets every tick -- the #238 N=3-counter trap) so a refusal
# recorded on tick N is still visible on tick N+1.
CLAIM_REFUSAL_LOG="$FWF_STATE_DIR/claim-refusals.log"
_record_refusal() { # $1=issue-number $2=verdict
  mkdir -p "$(dirname "$CLAIM_REFUSAL_LOG")" 2>/dev/null
  printf 'ts=%s issue=%s verdict=%s\n' "$(date +%s)" "$1" "$2" >> "$CLAIM_REFUSAL_LOG" 2>/dev/null
  # Bounded, same rolling-window shape as #227/#239's own logs -- a count
  # of recent refusals, never an unbounded file nobody prunes.
  if [ -f "$CLAIM_REFUSAL_LOG" ]; then
    tail -n "${FWF_CLAIM_REFUSAL_LOG_MAX:-500}" "$CLAIM_REFUSAL_LOG" > "$CLAIM_REFUSAL_LOG.tmp.$$" 2>/dev/null \
      && mv "$CLAIM_REFUSAL_LOG.tmp.$$" "$CLAIM_REFUSAL_LOG" || rm -f "$CLAIM_REFUSAL_LOG.tmp.$$"
  fi
}

refuse() { # $1=verdict-line $2=cause-class(policy|infrastructure)
  echo "fwf claim #$num: REFUSED — $2 cause" >&2
  echo "  $1" >&2
  echo "  next: fwf authz $num" >&2
  # AC (h): the ergonomic-not-control statement belongs on EVERY path a
  # reader might stop at, including refusal -- silence here would read as
  # "this is where the real control lives", the exact misreading (h) exists
  # to prevent.
  echo "$ERGONOMIC_NOTICE" >&2
  _record_refusal "$num" "$2"
  exit 1
}

# --- (j)/(j2): declared-prerequisite scan, warn-only, PARTIAL BY CONSTRUCTION
# The convention (a "## HARD PREREQUISITE(S)" heading, #135's own example)
# is deliberately NOT minted here -- this consumes whatever's already
# established, never derives it from free prose. Two independent
# mechanisation attempts (a prose-dependency-language sweep in each
# direction) failed identically per this ticket's own body, which is WHY
# this only ever WARNS, never refuses, on what it finds -- and why an
# absent heading must say so explicitly (AC j2: silence is not "no
# prerequisites", it is "the scan found nothing", a narrower claim).
_scan_prerequisites() { # $1=issue-number
  local body heading_line nums n verdict rc read_rc
  # #211's convention, here too: a genuinely EMPTY body (rc 0, a real and
  # common state for a terse ticket) is not the same fact as "the read
  # itself failed" (nonzero rc) -- collapsing them would misreport a real
  # empty body as UNKNOWN, and a real read failure as "no heading, proceed
  # calmly" (the WORSE direction, since it hides a read failure behind the
  # routine, unworried message).
  body="$(_issue_read "$1" --json body --jq '.body' 2>/dev/null)"; read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    echo "  prerequisites: UNKNOWN — could not read the issue body to scan for a declared-prerequisite heading" >&2
    return 0
  fi
  # The heading line itself (case-insensitive) plus the two lines after it --
  # #135's own example puts the referenced numbers directly on the heading
  # line ("## HARD PREREQUISITES -- #234 AND #189 land first"), and this
  # stays deliberately narrow (a heading match, never free prose) per the
  # ticket's own "cannot be derived from prose" finding.
  heading_line="$(printf '%s\n' "$body" | grep -inA2 '^##.*HARD PREREQUISITE' | head -3)"
  if [ -z "$heading_line" ]; then
    echo "  prerequisites: no '## HARD PREREQUISITE' heading found (a PARTIAL scan -- this is not the same claim as 'no prerequisites exist', see issue #243 AC j2)" >&2
    return 0
  fi
  nums="$(printf '%s\n' "$heading_line" | grep -oE '#[0-9]+' | tr -d '#' | sort -un)"
  if [ -z "$nums" ]; then
    echo "  prerequisites: a HARD PREREQUISITE heading was found but named no #<n> references" >&2
    return 0
  fi
  echo "  prerequisites (declared, from a HARD PREREQUISITE heading -- a partial scan, not a schema):" >&2
  for n in $nums; do
    [ "$n" = "$1" ] && continue   # never report an issue as its own prerequisite
    verdict="$("$DIR/fwf-authz.sh" "$n" 2>&1)"; rc=$?
    case "$rc" in
      0)  echo "    #$n: AUTHORIZED" >&2 ;;
      12) echo "    #$n: NOT-GATED (no gate ever applied)" >&2 ;;
      *)  echo "    #$n: NOT YET CLEAR ($(printf '%s' "$verdict" | head -1))" >&2 ;;
    esac
  done
}

verdict_out="$("$DIR/fwf-authz.sh" "$num" 2>&1)"; rc=$?
case "$rc" in
  0)
    # AUTHORIZED — proceed.
    ;;
  12)
    # NOT-GATED (#215) — proceed (AC c): a fix-forward on an issue no gate
    # ever held must not be caught by this.
    echo "fwf claim #$num: NOT-GATED — $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
  2)
    # INDETERMINATE — warn (infrastructure cause) and ALLOW (AC b). This is
    # the anti-stall half: claiming is cheap and reversible, and refusing
    # here on a mere READ failure is exactly the policy that would
    # manufacture the stall this ticket exists to relieve.
    echo "fwf claim #$num: WARNING — infrastructure cause, proceeding anyway (claiming is cheap/reversible; #207's merge-time check is what actually binds)" >&2
    echo "  $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
  10|11)
    # HELD or INVALID — refuse (AC a). Both are a POLICY cause (a real
    # verdict was read; it says no), distinct from INDETERMINATE's
    # infrastructure cause above.
    refuse "$(printf '%s' "$verdict_out" | head -1)" "policy"
    ;;
  *)
    # Any other/unexpected exit from fwf-authz.sh: fail closed the same
    # direction as INDETERMINATE (a read that cannot complete must not
    # collapse into a confident value either way), but distinguishably
    # worded so it is never mistaken for the well-known INDETERMINATE case.
    echo "fwf claim #$num: WARNING — unrecognized fwf-authz.sh exit ($rc), infrastructure cause, proceeding anyway" >&2
    echo "  $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
esac

_scan_prerequisites "$num"

echo "$ERGONOMIC_NOTICE" >&2

# --- (i0)/(i2): the claim artifact -- pinned here, no branch management ----
# Verified against the templates: only dev/refactor ever GAVE the command
# (git commit --allow-empty -m "claim #<n>: <title>"), and they agreed
# exactly; defect-report/ideation/validate referenced the artifact without
# ever defining it. This is now the one place the definition lives.
# Deliberately does NOT switch/create a branch (#177: one worktree per
# branch, so a claim verb that switches branches inherits that deadlock;
# one that only commits does not) -- the caller is assumed to already be
# on the branch it wants this commit on.
title="$(_issue_read "$num" --json title --jq '.title' 2>/dev/null)"
if [ -z "$title" ]; then
  echo "fwf claim #$num: could not read the issue title (gh failed) -- committing without one" >&2
  title="(title unavailable)"
fi
if ! git commit --allow-empty -m "claim #$num: $title" -m "Co-Authored-By: Claude <noreply@anthropic.com>" >&2; then
  echo "fwf claim #$num: git commit failed -- see above" >&2
  exit 1
fi
echo "fwf claim #$num: claimed."
exit 0
