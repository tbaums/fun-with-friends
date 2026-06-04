#!/usr/bin/env bash
# Bring up the fun-with-friends swarm: an 8-pane tmux grid (4 columns x 2 rows).
#   col1: IMPL1 / QA1     col2: IMPL2 / QA2     col3: IMPL3 / QA3     col4: PM / CONDUCTOR
# Each implementer/QA pair shares one color; the active pane is highlighted hard.
# Assumes fwf-provision.sh has created the worktrees.
#
# Usage: [FWF_PROFILE=transom] fwf-up.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
PROMPTS="$DIR/prompts"

# Type a prompt into a pane's claude composer and submit. The first Enter after
# a long literal paste is frequently absorbed by the TUI, so we send two.
send() { tmux send-keys -t "$1" -l "$2"; sleep 1; tmux send-keys -t "$1" Enter; sleep 1; tmux send-keys -t "$1" Enter; }

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' already exists — run fwf-down.sh first." >&2; exit 1
fi
mkdir -p "$FWF_RUN"
rm -f "$STOP_FILE"   # a fresh launch IS a resume — clear any stale STOP sentinel so agents don't idle immediately

# --- 4-column x 2-row grid, addressed by stable pane ids ---------------------
declare -a TP BP   # TP[1..3]=impl, TP[4]=pm ; BP[1..3]=qa, BP[4]=conductor
tmux new-session -d -s "$SESSION" -c "$(wt_dir impl1)"
TP[1]=$(tmux display -p -t "$SESSION" '#{pane_id}')
TP[2]=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[1]}" -c "$(wt_dir impl2)")
TP[3]=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[2]}" -c "$(wt_dir impl3)")
TP[4]=$(tmux split-window -h -P -F '#{pane_id}' -t "${TP[3]}" -c "$(wt_dir pm)")
tmux select-layout -t "$SESSION" even-horizontal
BP[1]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[1]}" -c "$(wt_dir qa1)")
BP[2]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[2]}" -c "$(wt_dir qa2)")
BP[3]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[3]}" -c "$(wt_dir qa3)")
BP[4]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[4]}" -c "$(wt_dir conductor)")

# --- styling -----------------------------------------------------------------
# Per-pane label (@l) and color (@c). Border title is dim+colored when inactive,
# and the ACTIVE pane gets a bright reverse-video "▶ ACTIVE ◀" bar so it's obvious.
tmux set -t "$SESSION" pane-border-status top
tmux set -t "$SESSION" pane-border-lines heavy
tmux set -t "$SESSION" pane-border-style       'fg=colour238'             # inactive borders: dim grey
tmux set -t "$SESSION" pane-active-border-style 'fg=colour231,bold'        # active border: bright white, bold
tmux set -t "$SESSION" pane-border-format \
  '#{?pane_active,#[reverse][ ▶ ACTIVE ◀ ]#[noreverse] ,}#[bold]#[fg=#{@c}]#{@l}#[default]'
# Dim the content of inactive panes so the focused one pops (active stays normal).
tmux set -t "$SESSION" window-style        'fg=colour245'
tmux set -t "$SESSION" window-active-style 'fg=terminal'

label() { tmux set -p -t "$1" @c "$2"; tmux set -p -t "$1" @l "$3"; }
for id in "${PAIRS[@]}"; do
  c="$(pair_color "$id")"
  label "${TP[$id]}" "$c" "IMPL$id · any issue → instant draft PR · impl$id/*"
  label "${BP[$id]}" "$c" "QA$id · reviews+merges impl$id/* · loop $QA_LOOP_INTERVAL"
done
label "${TP[4]}" "$PM_COLOR"        "PM · ideas → $WIP_LABEL draft issues · refine loop $PM_INTERVAL"
label "${BP[4]}" "$CONDUCTOR_COLOR" "CONDUCTOR · e2e on $STAGING_BRANCH → $INTEGRATION_BRANCH (never $DEFAULT_BRANCH)"

# --- launch claude (perms bypassed) in all 8 panes ---------------------------
for p in "${TP[@]}" "${BP[@]}"; do
  tmux send-keys -t "$p" -l "$CLAUDE_CMD"; tmux send-keys -t "$p" Enter
done
echo "launched claude in 8 panes; verifying each actually booted (re-sending to laggards)…"
for p in "${TP[@]}" "${BP[@]}"; do
  fwf_ensure_claude "$p" || echo "warning: claude did not come up in pane $p"
done
sleep 2
for p in "${TP[@]}" "${BP[@]}"; do tmux send-keys -t "$p" Enter; done   # clear one-time bypass-accept screen
sleep 2

# --- deliver prompts ---------------------------------------------------------
for id in "${PAIRS[@]}"; do
  send "${TP[$id]}" "/loop $IMPL_INTERVAL $(fwf_render "$PROMPTS/implementer.tmpl" "$id")"
  send "${BP[$id]}" "/loop $QA_LOOP_INTERVAL $(fwf_render "$PROMPTS/qa.tmpl" "$id")"
done
send "${TP[4]}" "/loop $PM_INTERVAL $(fwf_render "$PROMPTS/pm.tmpl" "")"
send "${BP[4]}" "/loop $CONDUCTOR_INTERVAL $(fwf_render "$PROMPTS/conductor.tmpl" "")"

echo
echo "fwf '$SESSION' is up:  tmux attach -t $SESSION"
echo "  columns: IMPL1/QA1 · IMPL2/QA2 · IMPL3/QA3 · PM/CONDUCTOR"
echo "  QA loops every $QA_LOOP_INTERVAL; conductor e2e+promote every $CONDUCTOR_INTERVAL"
