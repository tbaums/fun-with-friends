#!/usr/bin/env bash
# fwf-reconcile.sh — issue #114: auto-reconcile staging/integration to main
# after a release, so the swarm never keeps building on a stale base.
#
# WHY: the release runbook's "re-sync staging/integration back to main after a
# direct-to-main change" step was a MANUAL prose instruction and got skipped
# (the 2026-07-14 incident: main was 5 commits ahead of staging/integration,
# two implementers were assigned tickets that extended code that didn't exist
# on their build base yet). This is the one shared classifier + FF-or-halt
# helper (see fwf_reconcile_branch in lib.sh) called from BOTH hook points:
#   1. the release/direct-to-main write path (RELEASING.md's runbook step +
#      .github/workflows/release.yml, right after main advances)
#   2. the captain's per-tick stale-base guard, run before assigning any
#      ticket (see templates/*/captain.tmpl)
# Backend-agnostic (pure git refs) -- identical behavior whether FWF_ISSUES is
# "gh" or "local".
#
# Every branch is classified against $DEFAULT_BRANCH by ancestry into one of
# five states -- see lib.sh's fwf_reconcile_classify header comment for the
# full BEHIND/AHEAD/EQUAL/DIVERGED/SUSPECT contract.
#
# Usage: fwf reconcile [--check] [--branch NAME ...] [--against BRANCH]
#   --branch NAME    reconcile this branch (repeatable). Default: both
#                    $STAGING_BRANCH and $INTEGRATION_BRANCH.
#   --against BRANCH classify against this branch. Default: $DEFAULT_BRANCH.
#   --check          CLASSIFY ONLY -- report and set the exit code, but never
#                    lock, fast-forward or push (issue #179). This is the
#                    PRE-PUBLISH gate: run it BEFORE a release publishes, when
#                    failing is free because no artifact exists yet. Plain
#                    (non---check) reconcile stays the POST-publish call, where
#                    it only ever acts on BEHIND and cannot fail dangerously.
#                    --check exits non-zero ONLY on DIVERGED/SUSPECT; BEHIND is
#                    staleness, not divergence, and must not block a release.
#
# Prints one report line per branch (see fwf_reconcile_branch's header for the
# exact line shapes and the full three-way rc contract, issue #238 AC6).
# Exit 0 = EVERY branch confirmed SAFE (reconciled / normal-ahead / clean
#          no-op) -- safe to build on, and safe to close a stale artifact
#          about it.
# Exit 1 = ANY branch is halted-diverged or suspect (ESCALATE) -- the caller
#          MUST treat this as "do not assign new work onto that base" and,
#          for reconcile-guard specifically, file/update a durable artifact.
# Exit 2 = no branch escalated, but ANY branch is lock-busy or cas-lost
#          (INDETERMINATE) -- not confirmed safe, not an escalation either;
#          re-classify next tick. --check never returns 2 (see below).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

main() {
  local -a branches=() against="$DEFAULT_BRANCH" check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branches+=("${2:?--branch needs a value}"); shift 2 ;;
      --against) against="${2:?--against needs a value}"; shift 2 ;;
      --check) check=1; shift ;;
      *) echo "fwf-reconcile.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
  [ "${#branches[@]}" -gt 0 ] || branches=("$STAGING_BRANCH" "$INTEGRATION_BRANCH")

  # Aggregate rc across all branches (issue #238 AC6): ESCALATE(1) always
  # wins over INDETERMINATE(2), which always wins over SAFE(0) -- so a caller
  # gets the single WORST class present, never masked by a later safe branch.
  # --check never returns 2 (fwf_reconcile_check_branch has no lock-busy/
  # cas-lost concept -- it never mutates, so nothing to race), so this stays
  # the existing binary 0/1 contract for the pre-publish gate.
  local rc=0 line branch_rc
  for b in "${branches[@]}"; do
    branch_rc=0
    if [ "$check" -eq 1 ]; then
      line="$(fwf_reconcile_check_branch "$b" "$against")" || branch_rc=$?
    else
      line="$(fwf_reconcile_branch "$b" "$against")" || branch_rc=$?
    fi
    printf '%s\n' "$line"
    case "$branch_rc" in
      1) rc=1 ;;
      2) [ "$rc" -eq 0 ] && rc=2 ;;
    esac
  done
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
