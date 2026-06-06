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

any=0
for s in "$COORD_SESSION" "$BUILD_SESSION"; do tmux has-session -t "$s" 2>/dev/null && any=1; done
[ "$any" = 1 ] || { echo "no fwf tmux sessions ('$COORD_SESSION' / '$BUILD_SESSION')" >&2; exit 1; }

mkdir -p "$FWF_RUN"
: > "$STOP_FILE"   # sentinel: looping agents that check __STOPFILE__ will self-halt

MSG="$(tr '\n' ' ' < "$DIR/prompts/stop.txt" | tr -s ' ')"
for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  tmux has-session -t "$s" 2>/dev/null || continue
  for p in $(tmux list-panes -t "$s" -F '#{pane_id}'); do
    fwf_clear_composer "$p"                        # clear whatever is in the composer (Ctrl+U)
    tmux send-keys -t "$p" -l "$MSG"; sleep 0.5
    tmux send-keys -t "$p" Enter;    sleep 0.5
    tmux send-keys -t "$p" Enter
  done
done

echo "STOP broadcast to all panes of '$COORD_SESSION' + '$BUILD_SESSION'; sentinel created at $STOP_FILE"
echo "Resume later with: fwf-resume.sh   (clears the sentinel; re-arm loops via fwf-respawn.sh <role>)"
