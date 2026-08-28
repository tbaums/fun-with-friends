#!/usr/bin/env bash
# fwf-gate-promote.sh — issue #237: the OBLIGED call site binding a promote
# to the verdict that authorizes it, replacing raw `git merge && git push`
# prose an agent was trusted to gate correctly by its own reasoning.
#
# "For this promotion, 'gated' and 'ungated' were the same state." A
# promotion that reads the tip's recorded verdict and pushes ONLY on green,
# for the EXACT recorded SHA (never a re-resolved ref), makes that ordering
# a property of the code path rather than of an agent remembering an `if`.
#
# Usage: fwf gate-promote <role> <target-branch>
#   Reads <role>'s last COMPLETED gate-tip record (fwf_gate_tip_marker_path,
#   lib.sh — the SAME record `fwf gate-tip <role>` reads). Refuses unless its
#   verdict is exactly "green". Then merges that record's SHA, as a LITERAL
#   HASH (never a symbolic ref — issue #254's own reasoning: the ref may
#   have moved again since the gate resolved it), into <target-branch> via a
#   detached-then-ff-only sequence, and pushes — the check and the push are
#   ONE invocation, never separable in a caller's prompt (AC l).
#
# Exit codes:
#   0   promoted -- <target-branch> now points at the recorded green SHA.
#   1   refused -- see stderr for exactly which of AC (a)/(e)/(e2)/(f)/(k2)
#       fired. Never promotes and never leaves <target-branch> touched.
#   2   usage error (bad arguments) -- distinct from a refusal, so a caller
#       scripting around this can tell "I asked wrong" from "it said no".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf gate-promote <role> <target-branch>" >&2; }

role="${1:-}"; target="${2:-}"
if [ -z "$role" ] || [ -z "$target" ]; then usage; exit 2; fi

refuse() { # $1=short-reason  $2=actionable-detail
  echo "fwf gate-promote: REFUSED — $1" >&2
  [ -n "${2:-}" ] && echo "  $2" >&2
  exit 1
}

# issue #237 AC d3: the legacy, unmaintained record this obliged path
# supersedes. Nothing has written it since #202 replaced it with the
# gate-tip/<role> store this script itself reads below -- a dead record at
# a well-known path is worse than none (indistinguishable from live by
# inspection), so every promote attempt quietly clears it, not just once.
rm -f "$FWF_RUN/conductor-last-gated-sha" 2>/dev/null || true

tip_marker="$(fwf_gate_tip_marker_path "$role")"
if [ ! -f "$tip_marker" ]; then
  refuse "no recorded gate for role '$role'" \
    "run: fwf gate $role --e2e --tip-cmd '<ref-to-watch>' -- <e2e command>"
fi

tip="$(_fwf_gate_owner_field tip "$tip_marker")"
verdict="$(_fwf_gate_owner_field verdict "$tip_marker")"
# AC (f): present-but-unreadable/malformed is INDETERMINATE, never
# silently read as "not gated" (which would print a wrong, more comforting
# reason) and never as "gated" either.
if [ -z "$tip" ] || [ -z "$verdict" ]; then
  refuse "INDETERMINATE — role '$role''s gate-tip record exists but is unreadable/malformed" \
    "inspect: $tip_marker"
fi

# AC (e2): present, populated, and UNRESOLVABLE is a FOURTH outcome,
# distinct from both "not gated" and "gated" -- the live incident this
# ticket was filed against (a recorded SHA that resolved to no object).
if ! git cat-file -e "$tip" 2>/dev/null; then
  refuse "CORRUPT — recorded SHA '$tip' for role '$role' does not resolve to any object" \
    "this is not \"never gated\" -- the record is unreadable garbage; re-gate to overwrite it: fwf gate $role --e2e --tip-cmd '<ref-to-watch>' -- <e2e command>"
fi

# AC (a)/(b): only a green verdict, for the exact recorded SHA, authorizes
# anything. red/stale/unknown all refuse, distinguishably.
if [ "$verdict" != green ]; then
  refuse "role '$role''s last recorded verdict for $tip is '$verdict', not green" \
    "run: fwf gate $role --e2e --tip-cmd '<ref-to-watch>' -- <e2e command>"
fi

# AC (k2): a green verdict whose gate is now KNOWN to have been broken
# (revoked by fingerprint, after an investigation) must not authorize a
# promote just because nobody has re-gated since. Looked up from the
# SEPARATE sha-keyed store (#220), which is where #237 added the
# fingerprint field -- the role-keyed tip marker above never carries one.
verdict_record="$(fwf_gate_verdict_read "$tip" 2>/dev/null || true)"
fingerprint=""
if [ -n "$verdict_record" ]; then
  fingerprint="$(printf '%s\n' "$verdict_record" | grep -oE 'fingerprint=[^ ]+' | cut -d= -f2-)"
fi
if [ -n "$fingerprint" ] && fwf_gate_fingerprint_revoked "$fingerprint"; then
  refuse "REVOKED — the gate that produced this green verdict (fingerprint $fingerprint) has since been revoked" \
    "re-gate on a fixed gate to produce a fresh, non-revoked record: fwf gate $role --e2e --tip-cmd '<ref-to-watch>' -- <e2e command>"
fi

# AC (l): the check above and the push below are the SAME invocation --
# there is no separate "now promote" step a caller's prompt could run on
# its own belief that the check passed.
#
# issue #91/#254's own established pattern: detach onto the target's
# remote-tracking ref (never the local branch, which another worktree may
# hold), ff-only pull to make sure it is current, then merge the recorded
# SHA AS A LITERAL HASH -- never `origin/<target>` or any other symbolic
# ref, which could have moved since this script started reading. That is
# what makes "promote a SHA the gate never tested" unexpressible rather
# than merely checked.
if ! git fetch origin "$target" >/dev/null 2>&1; then
  refuse "could not fetch origin/$target" "check network/credentials and retry"
fi
if ! git switch --detach "origin/$target" >/dev/null 2>&1; then
  refuse "could not detach onto origin/$target"
fi
if ! git merge --ff-only "$tip" >/dev/null 2>&1; then
  refuse "git merge --ff-only $tip onto origin/$target failed" \
    "origin/$target is not an ancestor-compatible base for the recorded SHA -- this should not happen if $target is only ever advanced by this same path; investigate before forcing anything"
fi
if ! git push origin "HEAD:$target" >/dev/null 2>&1; then
  refuse "git push origin HEAD:$target failed" "check push access/branch protection"
fi

echo "fwf gate-promote: $target now at $tip (role '$role', green, recorded $(_fwf_gate_owner_field recorded "$tip_marker"))"
exit 0
