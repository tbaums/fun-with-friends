#!/usr/bin/env bash
# fwf-dash-remote.sh — issue #206: the local-side data provider `fwf dash
# --remote <host>` points FWF_DASH_DATA at instead of fwf-dash-data.sh.
#
# THIS SCRIPT NEVER SPAWNS SSH. Per-render-tick cost stays a local disk
# read (the #153 rule: NOT a subprocess-per-tick with a network hop
# attached) -- fwf-dash.sh's background fetcher (started once, on its own
# interval, decoupled from the render tick) is the only thing that ever
# talks to the network, writing the fetched snapshot atomically to
# FWF_DASH_REMOTE_CACHE_FILE. This script just reads that file.
#
# DASH_SNAPSHOT_SCHEMA_VERSION is duplicated from fwf-dash-data.sh rather
# than sourced from it -- sourcing the whole emitter here would also run
# its lib.sh/tmux-socket/FWF_STATE_DIR resolution for no reason, and its
# own `set -euo pipefail` jq/tool checks can call a bare `exit` that (being
# sourced, not subshelled) would kill THIS process too. test/run.sh
# asserts the two literals stay equal, so a bump to one without the other
# is a RED, the same discipline AC (i2) already requires of the emitted
# field set.
#
# Emits the SAME full board schema fwf-dash-data.sh's main() does, so the
# Rust renderer needs no changes: roles/issues come from the remote
# snapshot when it's fresh and version-matched; every other field the
# local board carries (decisions/pipeline/prod/activity/needs_you/
# unrouted_prs/etc.) is a neutral placeholder, since #206's snapshot
# deliberately narrows to roles+issues+heartbeat ages, not full parity.
#
# Failure states consume #211's vocabulary via #193's fields, never a
# vocabulary invented here (per the ticket's own "shared failure
# representation" section): visibility.factory_visible=false and a
# reason, the same shape a local unreadable read already uses.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
command -v jq >/dev/null 2>&1 || { echo '{"error":"jq is required for fwf dash"}'; exit 1; }

# Kept equal to fwf-dash-data.sh's DASH_SNAPSHOT_SCHEMA_VERSION by a
# test/run.sh assertion, not by sourcing (see the file header for why).
DASH_SNAPSHOT_SCHEMA_VERSION=1

REMOTE_HOST="${FWF_DASH_REMOTE_HOST:?fwf-dash-remote.sh requires FWF_DASH_REMOTE_HOST}"
REMOTE_PROFILE="${FWF_DASH_REMOTE_PROFILE:-$REMOTE_HOST}"
CACHE_FILE="${FWF_DASH_REMOTE_CACHE_FILE:?fwf-dash-remote.sh requires FWF_DASH_REMOTE_CACHE_FILE}"
STALE_SECS="${FWF_DASH_REMOTE_STALE_SECS:-45}"   # 3x the default fetch interval (15s)

# All-roles-unknown fallback board, used whenever the snapshot cannot be
# trusted at all (missing, unreadable, malformed). Never an empty roles
# array -- the roster stays visible, just every role reads "unknown"
# rather than the pane silently vanishing.
_empty_board() { # $1=reason
  local reason="$1" roles
  roles="$(for role in $(fwf_all_roles); do
    jq -n --arg role "$role" '{role:$role, state:"unknown", detail:"", heartbeat_age:null}'
  done | jq -s '.')"
  jq -n \
    --arg profile "$REMOTE_PROFILE" --arg stamp "remote: $reason" \
    --arg host "$REMOTE_HOST" --arg reason "$reason" \
    --argjson roles "$roles" \
    '{profile:$profile, template:"", parked:false, prod:"—", pipeline:"—",
      stamp:$stamp, generated_at:"", roles:$roles, decisions:[], issues:[],
      activity:[], needs_you:{active:false, summary:""},
      floor_idle:{active:false, since:"", reason:"", actor:""},
      upgrade:{available:false}, installed:{version:"unknown"},
      unrouted_prs:[], visibility:{factory_visible:false, newest_heartbeat_age:null,
        state_dir:"", profile:$profile, host:$host},
      api_budget:{state:"unknown"}, claim_refusals:{count:0},
      profile_resolution:{path:"", mode:"", dropped:[]},
      stranded_assignments:{unknown:true, reason:$reason, count:0, issues:[]},
      remote:{active:true, host:$host, profile:$profile, snapshot_age_seconds:null, stale:true, reason:$reason}}'
}

[ -f "$CACHE_FILE" ] || { _empty_board "no snapshot fetched yet from $REMOTE_HOST"; exit 0; }

SNAP="$(cat "$CACHE_FILE" 2>/dev/null)"
[ -n "$SNAP" ] || { _empty_board "snapshot file empty (fetch never succeeded)"; exit 0; }
printf '%s' "$SNAP" | jq -e '.schema_version and .roles and .issues' >/dev/null 2>&1 \
  || { _empty_board "snapshot unreadable/malformed"; exit 0; }

SNAP_VERSION="$(printf '%s' "$SNAP" | jq -r '.schema_version')"
if [ "$SNAP_VERSION" != "$DASH_SNAPSHOT_SCHEMA_VERSION" ]; then
  _empty_board "schema version mismatch: remote emits $SNAP_VERSION, this dash expects $DASH_SNAPSHOT_SCHEMA_VERSION — upgrade one side"
  exit 0
fi

GENERATED_AT="$(printf '%s' "$SNAP" | jq -r '.generated_at')"
NOW_EPOCH="$(date -u +%s)"
GEN_EPOCH="$(date -u -d "$GENERATED_AT" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$GENERATED_AT" +%s 2>/dev/null || echo "")"
AGE=""
if [ -n "$GEN_EPOCH" ]; then AGE=$(( NOW_EPOCH - GEN_EPOCH )); [ "$AGE" -ge 0 ] || AGE=0; fi
STALE=false
if [ -z "$AGE" ] || [ "$AGE" -gt "$STALE_SECS" ]; then STALE=true; fi

STAMP_TEXT="remote: ${AGE:-unknown}s old"
[ "$STALE" = true ] && STAMP_TEXT="remote: STALE (${AGE:-unknown}s old, last fetch from $REMOTE_HOST)"

STALE_REASON=""
[ "$STALE" = true ] && STALE_REASON="snapshot older than ${STALE_SECS}s"

jq -n \
  --arg profile "$REMOTE_PROFILE" --arg stamp "$STAMP_TEXT" --arg gen "$GENERATED_AT" \
  --arg host "$REMOTE_HOST" --argjson stale "$STALE" --arg reason "$STALE_REASON" \
  --arg age "${AGE:-null}" \
  --argjson roles "$(printf '%s' "$SNAP" | jq '[.roles[] | {role, state, detail, heartbeat_age}]')" \
  --argjson issues "$(printf '%s' "$SNAP" | jq '[.issues[] | {number, title, gated, body:""}]')" \
  '{profile:$profile, template:"", parked:false, prod:"—", pipeline:"—",
    stamp:$stamp, generated_at:$gen, roles:$roles, decisions:[], issues:$issues,
    activity:[], needs_you:{active:false, summary:""},
    floor_idle:{active:false, since:"", reason:"", actor:""},
    upgrade:{available:false}, installed:{version:"unknown"},
    unrouted_prs:[], visibility:{factory_visible:(($stale|not)), newest_heartbeat_age:(if $age=="null" then null else ($age|tonumber) end),
      state_dir:"", profile:$profile, host:$host},
    api_budget:{state:"unknown"}, claim_refusals:{count:0},
    profile_resolution:{path:"", mode:"", dropped:[]},
    stranded_assignments:{unknown:true, reason:"remote dash does not track this", count:0, issues:[]},
    remote:{active:true, host:$host, profile:$profile, snapshot_age_seconds:(if $age=="null" then null else ($age|tonumber) end), stale:$stale, reason:$reason}}'
