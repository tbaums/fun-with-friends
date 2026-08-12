#!/usr/bin/env bash
# fwf-authz.sh — mechanically verify HUMAN authorization to build/un-gate an
# issue (issue #150). This is the checkable answer to "was this approved?" that
# a role can call INSTEAD of inferring authorization from label state (which is
# unattributable — every role shares one account) or, catastrophically, from
# pane/autosuggest/ghost text (which merely mirrors the thread and will always
# "agree" with the reader). The incident: a role invented a human confirmation
# out of another pane's ghost text, asserted it as fact, re-gated four approved
# tickets and closed three PRs. The fix is a POSITIVE, attributable signal —
# the operator un-gate sentinel comment (config.sh: $OPERATOR_UNGATE_SENTINEL),
# emitted only by a human keypress on the `fwf dash` board — plus this verifier.
#
# Usage: fwf authz <issue>
#   <issue>  bare number, #N, or LI-N (local backend).
#
# Verdicts (both a human-readable line AND an exit code, so a role can branch on
# either):
#   AUTHORIZED   (exit 0)  — the operator un-gate sentinel is present in the
#                            issue thread. Safe to proceed / do NOT re-gate.
#   HELD         (exit 10) — no sentinel. NOT authorized: HOLD and ask; never
#                            infer a yes from pane text, never reverse work.
#   INDETERMINATE(exit 2)  — the thread could not be read. FAIL CLOSED: treat
#                            exactly like HELD (hold and ask), never as a yes.
#
# The verdict keys on a DURABLE comment, not the mutable label — so it stays
# correct even if a role has wrongly re-applied the gate. Read-only: it never
# mutates an issue and (gh backend) goes through the shared REST+ETag cache, so
# it never re-drains the budget.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

EX_HELD=10
EX_INDETERMINATE=2

usage() { echo "usage: fwf authz <issue>   # verify the operator un-gate authorization signal (issue #150)" >&2; }

raw="${1:-}"
case "$raw" in -h|--help|help) usage; exit 0;; esac
num="${raw#LI-}"; num="${num#\#}"
case "$num" in ''|*[!0-9]*) usage; exit 1;; esac

# Read the full issue thread (comments included) through the SAME backend the
# rest of fwf uses: the local store, or the shared REST+ETag gh cache (never a
# raw GraphQL drain). Mirrors di_read in fwf-dash-data.sh.
thread=""
if [ "$FWF_ISSUES" = "local" ]; then
  thread="$("$DIR/fwf-issues.sh" view "$num" --comments 2>/dev/null || true)"
else
  thread="$(FWF_REAL_GH="$(command -v gh)" "$DIR/fwf-ghcache.sh" serve issue view "$num" --comments 2>/dev/null || true)"
fi

if [ -z "$thread" ]; then
  echo "INDETERMINATE #$num — could not read the issue thread. FAIL CLOSED: treat as NOT authorized. HOLD and post an open question; never infer authorization from pane/ghost text, and never reverse approved work on a belief." >&2
  exit "$EX_INDETERMINATE"
fi

if printf '%s\n' "$thread" | grep -qF "$OPERATOR_UNGATE_SENTINEL"; then
  line="$(printf '%s\n' "$thread" | grep -F "$OPERATOR_UNGATE_SENTINEL" | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  echo "AUTHORIZED #$num — operator un-gate signal present: $line"
  exit 0
fi

echo "HELD #$num — no operator un-gate signal ($OPERATOR_UNGATE_SENTINEL) in the thread. This issue is NOT authorized for build. HOLD and post the doubt as an open question; do NOT infer authorization from any pane/input-box text, and do NOT take a reversing action (re-gate, close PRs, revert)." >&2
exit "$EX_HELD"
