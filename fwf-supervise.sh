#!/usr/bin/env bash
# fwf supervise — steady-state wedge supervisor (issue #165).
#
# The boot health-gate (#133) catches a role that never STARTS ticking; nothing
# yet catches a role that goes tick-stale DURING steady state. But tick-staleness
# alone is ambiguous: a genuinely wedged agent, a healthy-but-mid-long-task agent,
# and a parked one all look equally stale. This supervisor disambiguates by
# pairing the two per-role signals that already exist but nothing consumed in
# steady state — the monotonic loop tick (#133) and per-role token flow (#95).
#
# Per role, classification is delegated to fwf-pane-liveness.sh (issue #147),
# which snapshots (tick, tokens, epoch) into $FWF_STATE_DIR/tick-watch/<role>
# and diffs against the prior snapshot via the PURE lib.sh predicate
# fwf_wedge_verdict:
#   HEALTHY  tick advanced.
#   WORKING  tick static but tokens still flowing (a healthy long cycle) — or
#            both static but still within the flat-for grace. Never reaped.
#   WEDGED   tick static AND tokens flat past FWF_WEDGE_MIN_SECS — the only
#            verdict that may trigger a respawn.
#   UNKNOWN  no baseline old enough to diff against yet (a fresh baseline is
#            stamped for a later call). Never reaped.
# This is deliberately the SAME script #147's build-plane idle guard queries
# (fwf_build_plane_blocked, lib.sh) — one shared liveness source, so this
# loop and that guard can never disagree about the same role's aliveness.
#
# SHIPS DARK. On WEDGED it only LOGS the verdict unless FWF_SUPERVISE_AUTORESPAWN=1,
# in which case it calls fwf-respawn.sh <role> to hot-swap the wedged pane.
# Snapshotting + classification ALWAYS run; only the respawn action is gated, so
# the classifier can be observed in production before it is ever allowed to reap.
#
# Usage: fwf supervise [role ...]        (default: every role; --profile via the
#                                          dispatcher's engine() — see #69)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fwf-usage-data.sh
source "$DIR/fwf-usage-data.sh"

# Which roles to watch: explicit args, else the whole factory.
if [ "$#" -gt 0 ]; then roles="$*"; else roles="$(fwf_all_roles)"; fi

autorespawn="${FWF_SUPERVISE_AUTORESPAWN:-0}"

for role in $roles; do
  [ -n "$role" ] || continue
  verdict="$("$DIR/fwf-pane-liveness.sh" "$role")"

  if [ "$verdict" = "UNKNOWN" ]; then
    printf 'supervise: %-10s UNKNOWN (no old-enough baseline yet — will classify on a later call)\n' "$role"
    continue
  fi
  printf 'supervise: %-10s %s\n' "$role" "$verdict"

  [ "$verdict" = "WEDGED" ] || continue
  if [ "$autorespawn" = "1" ]; then
    printf 'supervise: %-10s WEDGED -> respawning (FWF_SUPERVISE_AUTORESPAWN=1)\n' "$role"
    "$DIR/fwf-respawn.sh" "$role" || printf 'supervise: %-10s respawn FAILED\n' "$role" >&2
  else
    printf 'supervise: %-10s WEDGED -> log-only (dark); set FWF_SUPERVISE_AUTORESPAWN=1 to reap\n' "$role"
  fi
done
