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
# Usage: fwf reconcile [--branch NAME ...] [--against BRANCH]
#   --branch NAME    reconcile this branch (repeatable). Default: both
#                    $STAGING_BRANCH and $INTEGRATION_BRANCH.
#   --against BRANCH classify against this branch. Default: $DEFAULT_BRANCH.
#
# Prints one report line per branch (see fwf_reconcile_branch's header for the
# exact line shapes) and exits 0 iff EVERY branch is safe to build on
# (reconciled / normal-ahead / clean no-op / lock-busy); exits 1 if ANY branch
# is halted-diverged, suspect, or cas-lost -- the caller (captain tick) MUST
# treat a non-zero exit as "do not assign new work onto that base".
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

main() {
  local -a branches=() against="$DEFAULT_BRANCH"
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branches+=("${2:?--branch needs a value}"); shift 2 ;;
      --against) against="${2:?--against needs a value}"; shift 2 ;;
      *) echo "fwf-reconcile.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
  [ "${#branches[@]}" -gt 0 ] || branches=("$STAGING_BRANCH" "$INTEGRATION_BRANCH")

  local rc=0 line
  for b in "${branches[@]}"; do
    line="$(fwf_reconcile_branch "$b" "$against")" || rc=1
    printf '%s\n' "$line"
  done
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
