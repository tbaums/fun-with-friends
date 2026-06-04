#!/usr/bin/env bash
# Respawn a single role's pane: kill its claude, relaunch it (perms bypassed),
# and re-deliver its prompt — using a readiness wait so the prompt is never typed
# into the shell by mistake. Use this to hot-swap one agent (e.g. after editing a
# prompt template) without relaunching the whole grid.
#
# Usage: [FWF_PROFILE=transom] fwf-respawn.sh <role>
#   role = impl1 | impl2 | impl3 | qa1 | qa2 | qa3 | pm | conductor
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
PROMPTS="$DIR/prompts"

role="${1:-}"
case "$role" in
  impl[123]) tmpl=implementer.tmpl; id="${role#impl}"; loop="";;
  qa[123])   tmpl=qa.tmpl;          id="${role#qa}";   loop="/loop $QA_LOOP_INTERVAL ";;
  pm)        tmpl=pm.tmpl;          id="";             loop="/loop $PM_INTERVAL ";;
  conductor) tmpl=conductor.tmpl;   id="";             loop="/loop $CONDUCTOR_INTERVAL ";;
  *) echo "usage: fwf-respawn.sh <impl1|impl2|impl3|qa1|qa2|qa3|pm|conductor>" >&2; exit 1;;
esac

tmux has-session -t "$SESSION" 2>/dev/null || { echo "no tmux session '$SESSION'" >&2; exit 1; }

# Find the pane by its label token (IMPL1 / QA1 / PM / CONDUCTOR).
token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
CP=""
for p in $(tmux list-panes -t "$SESSION" -F '#{pane_id}'); do
  case "$(tmux show -p -t "$p" @l 2>/dev/null)" in *"$token"*) CP="$p"; break;; esac
done
[ -n "$CP" ] || { echo "could not find a pane labeled '$token' in session '$SESSION'" >&2; exit 1; }
echo "respawning $role in pane $CP"

tmux respawn-pane -k -t "$CP" -c "$(wt_dir "$role")"
tmux send-keys -t "$CP" -l "$CLAUDE_CMD"; tmux send-keys -t "$CP" Enter
fwf_wait_ready "$CP" || echo "warning: $role pane not ready after ${FWF_BOOT_TIMEOUT}s; continuing"
sleep 2
tmux send-keys -t "$CP" Enter   # clear one-time bypass-accept screen
sleep 2

text="$loop$(fwf_render "$PROMPTS/$tmpl" "$id")"
tmux send-keys -t "$CP" -l "$text"; sleep 1
tmux send-keys -t "$CP" Enter; sleep 1
tmux send-keys -t "$CP" Enter
echo "$role respawned and prompt delivered in $CP"
