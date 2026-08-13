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
# Per role it snapshots (tick, tokens, epoch) into $FWF_STATE_DIR/tick-watch/<role>,
# diffs against the prior snapshot, and classifies the window via the PURE
# lib.sh predicate fwf_wedge_verdict:
#   HEALTHY  tick advanced.
#   WORKING  tick static but tokens still flowing (a healthy long cycle) — or
#            both static but still within the flat-for grace. Never reaped.
#   WEDGED   tick static AND tokens flat past FWF_WEDGE_MIN_SECS — the only
#            verdict that may trigger a respawn.
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
# Sourcing the usage-data provider pulls in lib.sh AND _fwf_usage_role for token
# sampling; its own all-roles main body is guarded off when sourced (#165).
# shellcheck source=fwf-usage-data.sh
source "$DIR/fwf-usage-data.sh"
command -v jq >/dev/null 2>&1 || { echo "supervise: jq is required for token sampling" >&2; exit 1; }

WATCH_DIR="$FWF_STATE_DIR/tick-watch"
mkdir -p "$WATCH_DIR" 2>/dev/null || true

# Total tokens booked to a role this run (all kinds summed) — the scalar whose
# movement between two samples means "the agent is doing real work". 0 on any
# read hiccup (never errors), so a bad sample reads as flat, not as a crash.
_supervise_role_tokens() { # $1=role
  _fwf_usage_role "$1" 2>/dev/null \
    | jq -r '.tokens | ((.input//0)+(.cache_creation//0)+(.cache_read//0)+(.output//0))' 2>/dev/null \
    || true
}

# Which roles to watch: explicit args, else the whole factory.
if [ "$#" -gt 0 ]; then roles="$*"; else roles="$(fwf_all_roles)"; fi

now="$(date -u +%s)"
autorespawn="${FWF_SUPERVISE_AUTORESPAWN:-0}"

for role in $roles; do
  [ -n "$role" ] || continue
  cur_tick="$(fwf_tick_read "$role")"
  cur_tok="$(_supervise_role_tokens "$role")"
  case "$cur_tok" in ''|*[!0-9]*) cur_tok=0;; esac
  snap="$WATCH_DIR/$role"

  prev_tick="" prev_tok="" prev_epoch=""
  [ -f "$snap" ] && read -r prev_tick prev_tok prev_epoch < "$snap"

  # Always refresh the snapshot for the next window, before any action.
  printf '%s %s %s\n' "$cur_tick" "$cur_tok" "$now" > "$snap.tmp.$$" \
    && mv -f "$snap.tmp.$$" "$snap"

  # First sample for this role: nothing to diff against yet — record a baseline.
  case "$prev_tick$prev_tok$prev_epoch" in
    '') printf 'supervise: %-10s BASELINE tick=%s tokens=%s (first sample)\n' "$role" "$cur_tick" "$cur_tok"
        continue;;
  esac
  case "$prev_tick"  in ''|*[!0-9]*) prev_tick=0;;  esac
  case "$prev_tok"   in ''|*[!0-9]*) prev_tok=0;;   esac
  case "$prev_epoch" in ''|*[!0-9]*) prev_epoch="$now";; esac

  d_tick=$(( cur_tick - prev_tick )); [ "$d_tick" -lt 0 ] && d_tick=0
  d_tok=$(( cur_tok - prev_tok ));    [ "$d_tok"  -lt 0 ] && d_tok=0
  elapsed=$(( now - prev_epoch ));    [ "$elapsed" -lt 0 ] && elapsed=0

  verdict="$(fwf_wedge_verdict "$d_tick" "$d_tok" "$elapsed")"
  printf 'supervise: %-10s %-7s dtick=%s dtokens=%s elapsed=%ss\n' \
    "$role" "$verdict" "$d_tick" "$d_tok" "$elapsed"

  [ "$verdict" = "WEDGED" ] || continue
  if [ "$autorespawn" = "1" ]; then
    printf 'supervise: %-10s WEDGED -> respawning (FWF_SUPERVISE_AUTORESPAWN=1)\n' "$role"
    "$DIR/fwf-respawn.sh" "$role" || printf 'supervise: %-10s respawn FAILED\n' "$role" >&2
  else
    printf 'supervise: %-10s WEDGED -> log-only (dark); set FWF_SUPERVISE_AUTORESPAWN=1 to reap\n' "$role"
  fi
done
