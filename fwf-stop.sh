#!/usr/bin/env bash
# Graceful stop: signal every agent in the swarm to commit & push its WIP, cancel
# its recurring loop, and go idle. Also drops a STOP sentinel that looping agents
# self-check (prompts/*.tmpl), so a loop that fires before it sees the broadcast
# still halts. Use before pausing or shutting the swarm down.
#
# Usage: [FWF_PROFILE=example] fwf-stop.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

tmux has-session -t "$SESSION" 2>/dev/null || { echo "no tmux session '$SESSION'" >&2; exit 1; }

mkdir -p "$FWF_RUN"
: > "$STOP_FILE"   # sentinel: looping agents that check __STOPFILE__ will self-halt

MSG="$(tr '\n' ' ' < "$DIR/prompts/stop.txt" | tr -s ' ')"
for p in $(tmux list-panes -t "$SESSION" -F '#{pane_id}'); do
  tmux send-keys -t "$p" C-a C-k; sleep 0.3      # clear whatever is in the composer
  tmux send-keys -t "$p" -l "$MSG"; sleep 0.5
  tmux send-keys -t "$p" Enter;    sleep 0.5
  tmux send-keys -t "$p" Enter
done

echo "STOP broadcast to all panes of '$SESSION'; sentinel created at $STOP_FILE"
echo "Resume later with: fwf-resume.sh   (clears the sentinel; re-arm loops via fwf-respawn.sh <role>)"
