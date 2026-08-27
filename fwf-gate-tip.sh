#!/usr/bin/env bash
# fwf-gate-tip.sh — issue #254 AC (d)+(e): print the tip value `fwf gate
# --tip-cmd` last COMPLETED-recorded for a role, so a caller that just got a
# promotable (green, or ancestor-relaxed) verdict can promote that EXACT SHA
# by its literal hash — never by re-resolving the watched ref a second time,
# which could have moved again since the gate itself resolved it.
#
# Usage: fwf gate-tip <role>
#   Prints the recorded tip value on stdout and exits 0, or prints nothing
#   and exits 1 if no marker exists yet for this role (never fabricates a
#   value — the caller must not promote on a guess).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf gate-tip <role>   # print the last COMPLETED gate's recorded tip value for <role>" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }

f="$(fwf_gate_tip_marker_path "$role")"
[ -f "$f" ] || { echo "fwf gate-tip: no recorded tip marker for role '$role' yet" >&2; exit 1; }

tip="$(_fwf_gate_owner_field tip "$f")"
[ -n "$tip" ] || { echo "fwf gate-tip: marker for role '$role' is unreadable or has no tip field" >&2; exit 1; }
printf '%s\n' "$tip"
