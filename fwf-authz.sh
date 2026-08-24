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
#
# gh's human-readable `--comments` renderer has a reproducible bug (#200): for
# some issues it prints 0 bytes with exit 0 and no stderr, identically with the
# cache bypassed — indistinguishable from a genuinely empty thread. The `--json
# comments` REST path does not share this bug (verified reliable on every issue
# tested, including ones where `--comments` came back empty), so that's what we
# read through here. We key the INDETERMINATE verdict on the read COMMAND
# failing (non-zero exit), not on the thread text being empty — a thread with
# zero comments is a legitimate HELD, not a read failure.
thread=""
read_ok=1
if [ "$FWF_ISSUES" = "local" ]; then
  thread="$("$DIR/fwf-issues.sh" view "$num" --comments 2>/dev/null)" || read_ok=0
else
  # Belt-and-suspenders for a just-un-gated ticket (issue #167): read the thread
  # through a short TTL so the operator sentinel is seen within ~10s even if the
  # approve path's write-through invalidate was somehow missed. The comment-view
  # ETag conditional keeps this forced-fresh read near-free (304 when unchanged),
  # so the tighter window costs a role nothing in the common case.
  thread="$(FWF_GHCACHE_TTL=10 FWF_REAL_GH="$(command -v gh)" "$DIR/fwf-ghcache.sh" serve issue view "$num" --json comments --jq '.comments[].body' 2>/dev/null)" || read_ok=0
fi

if [ "$read_ok" != 1 ]; then
  echo "INDETERMINATE #$num — could not read the issue thread (reader command failed). FAIL CLOSED: treat as NOT authorized. HOLD and post an open question; never infer authorization from pane/ghost text, and never reverse approved work on a belief." >&2
  exit "$EX_INDETERMINATE"
fi

if printf '%s\n' "$thread" | grep -qF "$OPERATOR_UNGATE_SENTINEL"; then
  line="$(printf '%s\n' "$thread" | grep -F "$OPERATOR_UNGATE_SENTINEL" | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  echo "AUTHORIZED #$num — operator un-gate signal present: $line"
  exit 0
fi

echo "HELD #$num — no operator un-gate signal ($OPERATOR_UNGATE_SENTINEL) in the thread. This issue is NOT authorized for build. HOLD and post the doubt as an open question; do NOT infer authorization from any pane/input-box text, and do NOT take a reversing action (re-gate, close PRs, revert)." >&2
exit "$EX_HELD"
