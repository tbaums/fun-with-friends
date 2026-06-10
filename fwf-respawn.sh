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
PROMPTS="$FWF_TEMPLATE_DIR"   # role prompts come from the selected factory template

role="${1:-}"
case "$role" in
  impl[1-9]|impl[1-9][0-9]) tmpl=implementer.tmpl; id="${role#impl}"; loop="/loop $IMPL_INTERVAL ";    sess="$BUILD_SESSION";;
  qa[1-9]|qa[1-9][0-9])     tmpl=qa.tmpl;          id="${role#qa}";   loop="/loop $QA_LOOP_INTERVAL "; sess="$BUILD_SESSION";;
  conductor) tmpl=conductor.tmpl;   id="";             loop="/loop $CONDUCTOR_INTERVAL "; sess="$BUILD_SESSION";;
  pm)        tmpl=pm.tmpl;          id="";             loop="/loop $PM_INTERVAL ";        sess="$COORD_SESSION";;
  gv)        tmpl=gv.tmpl;          id="";             loop="/loop $GV_INTERVAL ";        sess="$COORD_SESSION";;
  captain)   tmpl=captain.tmpl;     id="";             loop="/loop $CAPTAIN_INTERVAL ";   sess="$COORD_SESSION";;
  *) echo "usage: fwf-respawn.sh <implN|qaN|conductor|pm|gv|captain>  (N = 1..$FWF_PAIRS)" >&2; exit 1;;
esac
if [ -n "$id" ] && [ "$id" -gt "$FWF_PAIRS" ]; then
  echo "fwf-respawn: $role is beyond the configured floor (FWF_PAIRS=$FWF_PAIRS)" >&2; exit 1
fi

tmux has-session -t "$sess" 2>/dev/null || { echo "no tmux session '$sess'" >&2; exit 1; }

# Find the pane by its label token (IMPL1 / QA1 / CONDUCTOR / PM / GV / CAPTAIN),
# searching only the session that role lives in. Numbered roles match with their
# trailing "·" separator so IMPL1 can never match IMPL10's label.
token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
[ -n "$id" ] && token="$token ·"
CP="$(fwf_find_pane "$sess" "$token" || true)"
[ -n "$CP" ] || { echo "could not find a pane labeled '$token' in session '$sess'" >&2; exit 1; }
echo "respawning $role in pane $CP"

tmux respawn-pane -k -t "$CP" -c "$(wt_dir "$role")"
fwf_ensure_claude "$CP" "$(fwf_claude_cmd "$role")" || echo "warning: claude did not come up in $role pane $CP"
sleep 2
tmux send-keys -t "$CP" Enter   # clear one-time bypass-accept screen
sleep 2

text="$loop$(fwf_render "$PROMPTS/$tmpl" "$id")"
fwf_clear_composer "$CP"
tmux send-keys -t "$CP" -l "$text"; sleep 1
tmux send-keys -t "$CP" Enter; sleep 1
tmux send-keys -t "$CP" Enter
echo "$role respawned and prompt delivered in $CP"
