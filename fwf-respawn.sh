#!/usr/bin/env bash
# Respawn a single role's pane: kill its claude, relaunch it (perms bypassed),
# and re-deliver its prompt — using a readiness wait so the prompt is never typed
# into the shell by mistake. Use this to hot-swap one agent (e.g. after editing a
# prompt template) without relaunching the whole grid.
#
# Usage: [FWF_PROFILE=example] fwf-respawn.sh <role>
#   role = impl1 | impl2 | impl3 | qa1 | qa2 | qa3 | conductor   (implementation session)
#        | pm | gv | captain                                     (coordination session)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
# Role prompts resolve via fwf_tmpl_path (template, falling back to its base).

# Re-capture the launch socket (#62) if respawn runs inside tmux — harmless
# when it's unchanged. If respawn runs OUTSIDE tmux (e.g. a script/cron with no
# $TMUX), leave whatever `fwf up` already persisted in place rather than
# blanking it to the "default" marker — the factory itself hasn't moved.
[ -n "${TMUX:-}" ] && fwf_persist_tmux_socket "$(fwf_tmux_socket_value)"
# Keep the pane-env file (issue #143) fresh even for a standalone respawn
# that ran with no preceding `fwf up` in this run dir.
fwf_write_pane_env

role="${1:-}"
case "$role" in
  impl[1-9]|impl[1-9][0-9]) tmpl=implementer; id="${role#impl}"; interval="$IMPL_INTERVAL";    sess="$BUILD_SESSION";;
  qa[1-9]|qa[1-9][0-9])     tmpl=qa;          id="${role#qa}";   interval="$QA_LOOP_INTERVAL"; sess="$BUILD_SESSION";;
  conductor) tmpl=conductor;   id="";             interval="$CONDUCTOR_INTERVAL"; sess="$BUILD_SESSION";;
  pm)        tmpl=pm;          id="";             interval="$PM_INTERVAL";        sess="$COORD_SESSION";;
  gv)        tmpl=gv;          id="";             interval="$GV_INTERVAL";        sess="$COORD_SESSION";;
  captain)   tmpl=captain;     id="";             interval="$CAPTAIN_INTERVAL";   sess="$COORD_SESSION";;
  *)
    if fwf_extra_entry "$role" >/dev/null 2>&1; then   # template-declared extra role (e.g. sre)
      tmpl="$role"; id=""; interval="$(fwf_extra_interval "$role")"
      case "$(fwf_extra_session "$role")" in
        build) sess="$BUILD_SESSION";; *) sess="$COORD_SESSION";;
      esac
    else
      echo "usage: fwf-respawn.sh <implN|qaN|conductor|pm|gv|captain|extra-role>  (N = 1..$FWF_PAIRS)" >&2; exit 1
    fi;;
esac
if [ -n "$id" ] && [ "$id" -gt "$FWF_PAIRS" ]; then
  echo "fwf-respawn: $role is beyond the configured floor (FWF_PAIRS=$FWF_PAIRS)" >&2; exit 1
fi
if fwf_role_suppressed "$role"; then
  echo "fwf-respawn: '$role' is suppressed in template '$FWF_TEMPLATE' — it is not part of this factory." >&2; exit 1
fi

tmux has-session -t "$sess" 2>/dev/null || { echo "no tmux session '$sess'" >&2; exit 1; }

# Find the pane by its label token (IMPL1 / QA1 / CONDUCTOR / PM / GV / CAPTAIN),
# searching only the session that role lives in. Numbered roles match with their
# trailing "·" separator so IMPL1 can never match IMPL10's label.
token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
case "$role" in impl*|qa*) token="$token ·";; esac   # numbered roles: IMPL1 must not match IMPL10
fwf_extra_entry "$role" >/dev/null 2>&1 && token="$token ·"   # extra roles are labeled "NAME · …"
CP="$(fwf_find_pane "$sess" "$token" || true)"
if [ -n "$CP" ]; then
  echo "respawning $role in pane $CP"
  tmux respawn-pane -k -t "$CP" -c "$(fwf_role_cwd "$role")"
else
  # Recovery (issue #36): the pane is GONE entirely (claude-update crash, OOM
  # kill, accidental close) — create + label a fresh one and arm it, making
  # respawn the universal answer to "role died" however it died.
  echo "no pane labeled '$token' in '$sess' — creating a fresh $role pane (recovery)"
  CP="$(fwf_create_role_pane "$role")" || exit 1
  echo "created pane $CP for $role"
fi
fwf_ensure_claude "$CP" "$(fwf_claude_cmd "$role")" || echo "warning: claude did not come up in $role pane $CP"
sleep 2
tmux send-keys -t "$CP" Enter   # clear one-time bypass-accept screen
sleep 2

# issue #99, Fix 2: verify the loop actually TICKS after arming, off the
# durable heartbeat file — never the pane's animation glyph, which keeps
# looking "alive" even on a role that never advances a cycle (the exact
# ambiguity that caused operators to fire repeated respawns chasing a
# healthy-but-slow agent). Verifies SCHEDULED/START, not completion: the
# heartbeat fires at cycle step-0, before any work, so a healthy first cycle
# whose WORK takes minutes still verifies within the window.
FWF_RESPAWN_VERIFY_MARGIN="${FWF_RESPAWN_VERIFY_MARGIN:-30}"
_fwf_respawn_renudge() {
  fwf_send_prompt "$CP" "/loop $interval $role tick: if you have compacted or lost ANY context since the last tick, FIRST re-read your role prompt at $(fwf_write_role_prompt "$role" "$tmpl" "$id"). Then run exactly ONE cycle of that role's loop and report in its format. Act the role; do not re-state it."
}
arm_epoch="$(date +%s)"
fwf_arm_pane "$CP" "$role" "$tmpl" "$id" "$interval"
# issue #85/#105: respawning a role means its PLANE is no longer idle — clear
# any logged IDLE for that plane. captain and gv aren't a plane (GV never
# idles; the captain is the always-up driver) so neither logs an event. An
# extra template-declared role's plane follows its own declared session
# (coord -> pm; build -> build), matching fwf-up.sh's own classification.
case "$role" in
  pm) fwf_floor_event floor-up "" "" pm;;
  gv|captain) ;;
  impl*|qa*|conductor) fwf_floor_event floor-up "" "" build;;
  *)
    if fwf_extra_entry "$role" >/dev/null 2>&1; then
      case "$(fwf_extra_session "$role")" in
        build) fwf_floor_event floor-up "" "" build;;
        *)     fwf_floor_event floor-up "" "" pm;;
      esac
    fi
    ;;
esac

interval_secs="$(fwf_interval_seconds "$interval")" || exit 1
window=$((interval_secs + FWF_RESPAWN_VERIFY_MARGIN))

# issue #133 (failure mode 2 — the "reported-success respawn that still doesn't
# loop"): the soft re-nudge inside fwf_verify_respawn_tick only RE-SENDS the
# /loop line into the same pane. If that pane's claude never armed the loop (or
# is wedged at its prompt), re-typing the same line cannot revive it — so on a
# soft-verify failure we escalate ONCE to a HARD recycle: kill the pane's
# claude, relaunch it fresh, re-arm from scratch, and re-verify. We NEVER print
# a success line without a real heartbeat tick, and we don't give up until the
# pane itself has actually been recycled.
_fwf_respawn_hard_rearm() {
  echo "fwf-respawn: soft re-nudge did not tick — escalating to a hard kill+relaunch of $role's pane $CP" >&2
  tmux respawn-pane -k -t "$CP" -c "$(fwf_role_cwd "$role")" 2>/dev/null || true
  fwf_ensure_claude "$CP" "$(fwf_claude_cmd "$role")" || echo "warning: claude did not come up in $role pane $CP on escalation" >&2
  sleep 2; tmux send-keys -t "$CP" Enter; sleep 2
  arm_epoch="$(date +%s)"
  fwf_arm_pane "$CP" "$role" "$tmpl" "$id" "$interval"
}

if fwf_verify_respawn_tick "$role" "$arm_epoch" "$window" _fwf_respawn_renudge; then
  echo "$role respawned and armed in $CP (role prompt once + lean $interval tick)"
else
  _fwf_respawn_hard_rearm
  if fwf_verify_respawn_tick "$role" "$arm_epoch" "$window" _fwf_respawn_renudge; then
    echo "$role respawned and armed in $CP after a hard pane relaunch (escalated recovery)"
  else
    # issue #217 AC(7)/(10): name the unauthenticated case explicitly when
    # that's what happened, instead of the generic "wedged at a deeper
    # level" -- and name WHICH source the auth sink was last resolved from
    # (read-only here — respawn must NEVER re-resolve/rewrite the sink from
    # its own possibly-wrong environment, e.g. supervise's, which could
    # silently clobber a good sink with "none"), so the operator can tell
    # "no credential at all" from "a stale env var in whatever shell last
    # ran `fwf up` outranking a fresher credentials file" (the precedence
    # trap this ticket's own edge cases call out).
    _fwf217_src="$(sed -n 's/^export FWF_AUTH_SOURCE=//p' "$FWF_AUTH_ENV_FILE" 2>/dev/null)"
    [ -n "$_fwf217_src" ] || _fwf217_src="none (no sink written yet — run 'fwf up' or 'fwf auth resolve')"
    echo "fwf-respawn: $role STILL not ticking after a hard relaunch — the pane is wedged at a deeper level; inspect it manually (tmux attach; pane $CP). Auth sink last resolved from: $_fwf217_src — if this doesn't match what you expect, 'fwf auth resolve' re-checks and 'unset CLAUDE_CODE_OAUTH_TOKEN' clears a stale shell var before the next 'fwf up'." >&2
    exit 1
  fi
fi
