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

fwf_arm_pane "$CP" "$role" "$tmpl" "$id" "$interval"
echo "$role respawned and armed in $CP (role prompt once + lean $interval tick)"
