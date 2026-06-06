#!/usr/bin/env bash
# Bring up the fun-with-friends factory as TWO tmux sessions:
#   COORDINATION  ($COORD_SESSION): PM · GV · CAPTAIN  (3 columns; you talk to the captain)
#   IMPLEMENTATION ($BUILD_SESSION): IMPL1/QA1 · IMPL2/QA2 · IMPL3/QA3 · CONDUCTOR
# The two halves coordinate through the issue tracker + git, never across panes.
# Each implementer/QA pair shares one color; the active pane is highlighted hard.
# Assumes fwf-provision.sh has created the worktrees.
#
# Usage: [FWF_PROFILE=example] fwf-up.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
PROMPTS="$DIR/prompts"

# Type a prompt into a pane's claude composer and submit. Clear any stale buffer
# first, then type. The first Enter after a long literal paste is frequently
# absorbed by the TUI, so we send two.
send() { fwf_clear_composer "$1"; tmux send-keys -t "$1" -l "$2"; sleep 1; tmux send-keys -t "$1" Enter; sleep 1; tmux send-keys -t "$1" Enter; }

# Per-pane label (@l) and color (@c).
label() { tmux set -p -t "$1" @c "$2"; tmux set -p -t "$1" @l "$3"; }

# Shared pane styling for a session: dim+colored inactive border titles, a bright
# reverse-video "▶ ACTIVE ◀" bar on the focused pane, and dimmed inactive content.
style_session() { # $1=session
  local s="$1"
  tmux set -t "$s" pane-border-status top
  tmux set -t "$s" pane-border-lines heavy
  tmux set -t "$s" pane-border-style        'fg=colour238'
  tmux set -t "$s" pane-active-border-style 'fg=colour231,bold'
  tmux set -t "$s" pane-border-format \
    '#{?pane_active,#[reverse][ ▶ ACTIVE ◀ ]#[noreverse] ,}#[bold]#[fg=#{@c}]#{@l}#[default]'
  tmux set -t "$s" window-style        'fg=colour245'
  tmux set -t "$s" window-active-style 'fg=terminal'
}

for s in "$COORD_SESSION" "$BUILD_SESSION"; do
  if tmux has-session -t "$s" 2>/dev/null; then
    echo "tmux session '$s' already exists — run fwf-down.sh first." >&2; exit 1
  fi
done
mkdir -p "$FWF_RUN"
rm -f "$STOP_FILE"   # a fresh launch IS a resume — clear any stale STOP sentinel so agents don't idle immediately

# --- IMPLEMENTATION session: 3 impl/qa columns + a full-height conductor ------
declare -a TP BP   # TP[1..3]=impl ; BP[1..3]=qa
tmux new-session -d -s "$BUILD_SESSION" -c "$(wt_dir impl1)"
TP[1]=$(tmux display -p -t "$BUILD_SESSION" '#{pane_id}')
TP[2]=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[1]}" -c "$(wt_dir impl2)")
TP[3]=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[2]}" -c "$(wt_dir impl3)")
CONDUCTOR_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[3]}" -c "$(wt_dir conductor)")
tmux select-layout -t "$BUILD_SESSION" even-horizontal
BP[1]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[1]}" -c "$(wt_dir qa1)")
BP[2]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[2]}" -c "$(wt_dir qa2)")
BP[3]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[3]}" -c "$(wt_dir qa3)")
for id in "${PAIRS[@]}"; do
  c="$(pair_color "$id")"
  label "${TP[$id]}" "$c" "IMPL$id · any issue → instant draft PR · impl$id/*"
  label "${BP[$id]}" "$c" "QA$id · reviews+merges impl$id/* · loop $QA_LOOP_INTERVAL"
done
label "$CONDUCTOR_PANE" "$CONDUCTOR_COLOR" "CONDUCTOR · e2e on $STAGING_BRANCH → $INTEGRATION_BRANCH (never $DEFAULT_BRANCH)"

# --- COORDINATION session: PM · GV · CAPTAIN (you talk to the captain) --------
tmux new-session -d -s "$COORD_SESSION" -c "$(wt_dir pm)"
PM_PANE=$(tmux display -p -t "$COORD_SESSION" '#{pane_id}')
GV_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$PM_PANE" -c "$(wt_dir gv)")
CAPTAIN_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$GV_PANE" -c "$(wt_dir captain)")
tmux select-layout -t "$COORD_SESSION" even-horizontal
label "$PM_PANE"      "$PM_COLOR"      "PM · ideas → $WIP_LABEL draft issues · refine loop $PM_INTERVAL"
label "$GV_PANE"      "$GV_COLOR"      "GRAND VIZIER (GV) · hardens PM specs · advises captain · loop $GV_INTERVAL"
label "$CAPTAIN_PANE" "$CAPTAIN_COLOR" "CAPTAIN · you talk here · scopes+ships, hones via GV · loop $CAPTAIN_INTERVAL"

style_session "$BUILD_SESSION"
style_session "$COORD_SESSION"

# --- launch claude (perms bypassed) in all 10 panes --------------------------
ALL_PANES=( "${TP[1]}" "${TP[2]}" "${TP[3]}" "${BP[1]}" "${BP[2]}" "${BP[3]}" "$CONDUCTOR_PANE" "$PM_PANE" "$GV_PANE" "$CAPTAIN_PANE" )
for p in "${ALL_PANES[@]}"; do
  tmux send-keys -t "$p" -l "$CLAUDE_CMD"; tmux send-keys -t "$p" Enter
done
echo "launched claude in 10 panes; verifying each actually booted (re-sending to laggards)…"
for p in "${ALL_PANES[@]}"; do
  fwf_ensure_claude "$p" || echo "warning: claude did not come up in pane $p"
done
sleep 2
for p in "${ALL_PANES[@]}"; do tmux send-keys -t "$p" Enter; done   # clear one-time bypass-accept screen
sleep 2

# --- deliver prompts ---------------------------------------------------------
for id in "${PAIRS[@]}"; do
  send "${TP[$id]}" "/loop $IMPL_INTERVAL $(fwf_render "$PROMPTS/implementer.tmpl" "$id")"
  send "${BP[$id]}" "/loop $QA_LOOP_INTERVAL $(fwf_render "$PROMPTS/qa.tmpl" "$id")"
done
send "$CONDUCTOR_PANE" "/loop $CONDUCTOR_INTERVAL $(fwf_render "$PROMPTS/conductor.tmpl" "")"
send "$PM_PANE"        "/loop $PM_INTERVAL $(fwf_render "$PROMPTS/pm.tmpl" "")"
send "$GV_PANE"        "/loop $GV_INTERVAL $(fwf_render "$PROMPTS/gv.tmpl" "")"
send "$CAPTAIN_PANE"   "/loop $CAPTAIN_INTERVAL $(fwf_render "$PROMPTS/captain.tmpl" "")"

echo
echo "fwf is up (two sessions):"
echo "  coordination  : tmux attach -t $COORD_SESSION   (PM · GV · CAPTAIN — talk to the captain)"
echo "  implementation: tmux attach -t $BUILD_SESSION   (IMPL1/QA1 · IMPL2/QA2 · IMPL3/QA3 · CONDUCTOR)"
echo "  QA loops every $QA_LOOP_INTERVAL; conductor e2e+promotes every $CONDUCTOR_INTERVAL; GV reviews every $GV_INTERVAL"
