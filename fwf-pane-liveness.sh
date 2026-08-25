#!/usr/bin/env bash
# fwf-pane-liveness.sh -- point-in-time aliveness QUERY for a single role
# (issue #147), built on #165's classifier (fwf_wedge_verdict, lib.sh) and
# the SAME persisted snapshot fwf-supervise.sh's periodic loop uses
# ($FWF_STATE_DIR/tick-watch/<role>) -- ONE shared liveness source, so this
# script and fwf-supervise.sh's own loop can never disagree about the same
# role (issue #147's own acceptance criterion: "the idle-guard and #165's
# supervisor use a SINGLE shared liveness source"). fwf-supervise.sh itself
# is refactored to call THIS for its per-role classification, rather than
# duplicating the snapshot logic -- one implementation, two callers.
#
# WHY A ONE-SHOT QUERY NEEDS DIFFERENT TIMING THAN A TIGHT LOOP: a periodic
# supervisor that diffs against whatever the immediately PRIOR call sampled
# (however recent that was) can under-count elapsed time if it's ever polled
# faster than FWF_WEDGE_MIN_SECS -- a genuinely wedged role would then never
# accumulate enough elapsed time in any single window to classify as WEDGED,
# no matter how many times it's queried. So THIS script only diffs (and
# refreshes the baseline) once the stored sample is already at least
# FWF_WEDGE_MIN_SECS old; a too-fresh or missing baseline returns UNKNOWN
# and, if none existed at all, stamps a first one for a later query to diff
# against -- callers MUST treat UNKNOWN as "cannot confirm either way," the
# same fail-safe obligation as #147's own claim-window guard.
#
# Usage: fwf-pane-liveness.sh <role>   -> prints exactly one word on stdout:
#   HEALTHY  the tick advanced since the last (old-enough) sample.
#   WORKING  tick static but tokens still flowing, or still within grace.
#   WEDGED   tick static AND tokens flat, sustained past FWF_WEDGE_MIN_SECS.
#   UNKNOWN  no baseline old enough to compare against yet -- ambiguous. ALSO
#            returned, unconditionally and before touching the snapshot, when
#            the current tick read itself could not be trusted (issue #211)
#            -- a wedged agent and an unreadable tick file must never look
#            the same, and the untrustworthy value must never be stamped as
#            a future baseline.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fwf-usage-data.sh
source "$DIR/fwf-usage-data.sh"

role="${1:?usage: fwf-pane-liveness.sh <role>}"
min="${FWF_WEDGE_MIN_SECS:-600}"
now="$(date -u +%s)"
snap="$FWF_STATE_DIR/tick-watch/$role"
mkdir -p "$(dirname "$snap")" 2>/dev/null || true

# `if cur_tick=$(...); then` deliberately, not `cur_tick=$(...); rc=$?` --
# this script is `set -euo pipefail`, and a bare failing assignment
# statement aborts the whole script before `rc=$?` would ever run. A
# command's status inside an `if` condition is exempt from `set -e` by
# design; used here on purpose (issue #211's own `set -e` warning).
if cur_tick="$(fwf_tick_read "$role")"; then
  cur_tick_rc=0
else
  cur_tick_rc=$?
fi
cur_tok=""
if command -v jq >/dev/null 2>&1; then
  cur_tok="$(_fwf_usage_role "$role" 2>/dev/null | jq -r '.tokens | ((.input//0)+(.cache_creation//0)+(.cache_read//0)+(.output//0))' 2>/dev/null || true)"
fi
case "$cur_tok" in ''|*[!0-9]*) cur_tok=0;; esac

prev_tick="" prev_tok="" prev_epoch=""
[ -f "$snap" ] && read -r prev_tick prev_tok prev_epoch < "$snap"

_stamp() { printf '%s %s %s\n' "$cur_tick" "$cur_tok" "$now" > "$snap.tmp.$$" && mv -f "$snap.tmp.$$" "$snap"; }

# issue #211: a tick read that could not be trusted (fwf_tick_read's exit
# status) must never collapse into a confident verdict, and its untrustworthy
# 0-fallback value must never be STAMPED as the next window's baseline --
# that would corrupt every future delta comparison against a value nobody
# ever actually observed. Bail to UNKNOWN before touching the snapshot at
# all, exactly like the "too fresh" case below leaves it untouched, so a
# later, healthy read still gets a full window to diff against.
if [ "$cur_tick_rc" -ne 0 ]; then
  echo UNKNOWN
  exit 0
fi

if [ -z "$prev_epoch" ]; then
  _stamp
  echo UNKNOWN
  exit 0
fi
case "$prev_epoch" in ''|*[!0-9]*) prev_epoch=0;; esac
age=$(( now - prev_epoch )); [ "$age" -lt 0 ] && age=0

if [ "$age" -lt "$min" ]; then
  # Too fresh to say anything meaningful -- leave the existing baseline
  # untouched (do NOT reset its clock) so a later query still gets a full
  # window to diff against.
  echo UNKNOWN
  exit 0
fi

case "$prev_tick" in ''|*[!0-9]*) prev_tick=0;; esac
case "$prev_tok"  in ''|*[!0-9]*) prev_tok=0;;  esac
d_tick=$(( cur_tick - prev_tick )); [ "$d_tick" -lt 0 ] && d_tick=0
d_tok=$(( cur_tok - prev_tok ));    [ "$d_tok"  -lt 0 ] && d_tok=0

verdict="$(fwf_wedge_verdict "$d_tick" "$d_tok" "$age")"
# The window has been consumed -- refresh the baseline so the NEXT query
# starts a fresh window from now.
_stamp
echo "$verdict"
