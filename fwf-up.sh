#!/usr/bin/env bash
# Bring up the fun-with-friends factory as TWO tmux sessions:
#   COORDINATION  ($COORD_SESSION): PM · GV · CAPTAIN  (3 columns; you talk to the captain)
#   IMPLEMENTATION ($BUILD_SESSION): IMPL1/QA1 · IMPL2/QA2 · IMPL3/QA3 · CONDUCTOR
# The two halves coordinate through the issue tracker + git, never across panes.
# Each implementer/QA pair shares one color; the active pane is highlighted hard.
# Assumes fwf-provision.sh has created the worktrees.
#
# --floor-only (issue #6): (re)create ONLY the floor — the BUILD session plus
# the PM/GV panes — around a LIVE captain pane, which is left completely
# untouched so the captain can cycle the floor without losing its own context.
# Idempotent: pieces that already exist are left alone; only panes created by
# THIS run get claude launched + a prompt delivered.
#
# Usage: [FWF_PROFILE=example] fwf-up.sh [--floor-only]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
PROMPTS="$DIR/prompts"

FLOOR_ONLY=0
case "${1:-}" in
  "") ;;
  --floor-only) FLOOR_ONLY=1;;
  *) echo "usage: fwf-up.sh [--floor-only]" >&2; exit 1;;
esac

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

if [ "$FLOOR_ONLY" = 1 ]; then
  # Rebuilding the floor around a live captain: the coord session + captain
  # pane must already exist (otherwise a full launch is what you want).
  tmux has-session -t "$COORD_SESSION" 2>/dev/null \
    || { echo "fwf-up --floor-only: no '$COORD_SESSION' session — run a full 'fwf up' instead." >&2; exit 1; }
  CAPTAIN_PANE="$(fwf_find_pane "$COORD_SESSION" CAPTAIN || true)"
  [ -n "$CAPTAIN_PANE" ] \
    || { echo "fwf-up --floor-only: no CAPTAIN pane in '$COORD_SESSION' — run a full 'fwf up' instead." >&2; exit 1; }
else
  for s in "$COORD_SESSION" "$BUILD_SESSION"; do
    if tmux has-session -t "$s" 2>/dev/null; then
      echo "tmux session '$s' already exists — run fwf-down.sh first (or 'fwf up --floor-only' to rebuild just the floor around a live captain)." >&2; exit 1
    fi
  done
fi

mkdir -p "$FWF_RUN"
rm -f "$STOP_FILE"   # a fresh launch IS a resume — clear any stale STOP sentinel so agents don't idle immediately

# Track what THIS run creates; only those panes get launched + armed.
BUILD_CREATED=0; PM_CREATED=0; GV_CREATED=0; CAPTAIN_CREATED=0

# --- IMPLEMENTATION session: 3 impl/qa columns + a full-height conductor ------
declare -a TP BP   # TP[1..3]=impl ; BP[1..3]=qa
if tmux has-session -t "$BUILD_SESSION" 2>/dev/null; then
  echo "build session '$BUILD_SESSION' already up — leaving it untouched."
else
  BUILD_CREATED=1
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
  style_session "$BUILD_SESSION"
fi

# --- COORDINATION session: PM · GV · CAPTAIN (you talk to the captain) --------
if [ "$FLOOR_ONLY" = 1 ]; then
  # Recreate only the PM/GV panes that are missing, splitting LEFT of the
  # captain (-b) so the familiar PM · GV · CAPTAIN order is preserved.
  GV_PANE="$(fwf_find_pane "$COORD_SESSION" "GRAND VIZIER" || true)"
  if [ -z "$GV_PANE" ]; then
    GV_CREATED=1
    GV_PANE=$(tmux split-window -h -b -P -F '#{pane_id}' -t "$CAPTAIN_PANE" -c "$(wt_dir gv)")
  fi
  PM_PANE="$(fwf_find_pane "$COORD_SESSION" "PM ·" || true)"
  if [ -z "$PM_PANE" ]; then
    PM_CREATED=1
    PM_PANE=$(tmux split-window -h -b -P -F '#{pane_id}' -t "$GV_PANE" -c "$(wt_dir pm)")
  fi
  tmux select-layout -t "$COORD_SESSION" even-horizontal
else
  CAPTAIN_CREATED=1; PM_CREATED=1; GV_CREATED=1
  tmux new-session -d -s "$COORD_SESSION" -c "$(wt_dir pm)"
  PM_PANE=$(tmux display -p -t "$COORD_SESSION" '#{pane_id}')
  GV_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$PM_PANE" -c "$(wt_dir gv)")
  CAPTAIN_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$GV_PANE" -c "$(wt_dir captain)")
  tmux select-layout -t "$COORD_SESSION" even-horizontal
  style_session "$COORD_SESSION"
fi
[ "$PM_CREATED" = 1 ] && label "$PM_PANE" "$PM_COLOR" "PM · ideas → $WIP_LABEL draft issues · refine loop $PM_INTERVAL"
[ "$GV_CREATED" = 1 ] && label "$GV_PANE" "$GV_COLOR" "GRAND VIZIER (GV) · hardens PM specs · advises captain · loop $GV_INTERVAL"
[ "$CAPTAIN_CREATED" = 1 ] && label "$CAPTAIN_PANE" "$CAPTAIN_COLOR" "CAPTAIN · you talk here · scopes+ships, hones via GV · loop $CAPTAIN_INTERVAL"

# --- launch claude (perms bypassed) in the panes THIS run created -------------
NEW_PANES=()
[ "$BUILD_CREATED" = 1 ]   && NEW_PANES+=( "${TP[1]}" "${TP[2]}" "${TP[3]}" "${BP[1]}" "${BP[2]}" "${BP[3]}" "$CONDUCTOR_PANE" )
[ "$PM_CREATED" = 1 ]      && NEW_PANES+=( "$PM_PANE" )
[ "$GV_CREATED" = 1 ]      && NEW_PANES+=( "$GV_PANE" )
[ "$CAPTAIN_CREATED" = 1 ] && NEW_PANES+=( "$CAPTAIN_PANE" )
if [ "${#NEW_PANES[@]}" = 0 ]; then
  echo "fwf is already fully up — nothing to do."
  exit 0
fi

for p in "${NEW_PANES[@]}"; do
  tmux send-keys -t "$p" -l "$CLAUDE_CMD"; tmux send-keys -t "$p" Enter
done
echo "launched claude in ${#NEW_PANES[@]} pane(s); verifying each actually booted (re-sending to laggards)…"
for p in "${NEW_PANES[@]}"; do
  fwf_ensure_claude "$p" || echo "warning: claude did not come up in pane $p"
done
sleep 2
for p in "${NEW_PANES[@]}"; do tmux send-keys -t "$p" Enter; done   # clear one-time bypass-accept screen
sleep 2

# --- deliver prompts to the panes THIS run created -----------------------------
if [ "$BUILD_CREATED" = 1 ]; then
  for id in "${PAIRS[@]}"; do
    send "${TP[$id]}" "/loop $IMPL_INTERVAL $(fwf_render "$PROMPTS/implementer.tmpl" "$id")"
    send "${BP[$id]}" "/loop $QA_LOOP_INTERVAL $(fwf_render "$PROMPTS/qa.tmpl" "$id")"
  done
  send "$CONDUCTOR_PANE" "/loop $CONDUCTOR_INTERVAL $(fwf_render "$PROMPTS/conductor.tmpl" "")"
fi
[ "$PM_CREATED" = 1 ]      && send "$PM_PANE"      "/loop $PM_INTERVAL $(fwf_render "$PROMPTS/pm.tmpl" "")"
[ "$GV_CREATED" = 1 ]      && send "$GV_PANE"      "/loop $GV_INTERVAL $(fwf_render "$PROMPTS/gv.tmpl" "")"
[ "$CAPTAIN_CREATED" = 1 ] && send "$CAPTAIN_PANE" "/loop $CAPTAIN_INTERVAL $(fwf_render "$PROMPTS/captain.tmpl" "")"

echo
if [ "$FLOOR_ONLY" = 1 ]; then
  echo "floor is up (captain untouched):"
else
  echo "fwf is up (two sessions):"
fi
echo "  coordination  : tmux attach -t $COORD_SESSION   (PM · GV · CAPTAIN — talk to the captain)"
echo "  implementation: tmux attach -t $BUILD_SESSION   (IMPL1/QA1 · IMPL2/QA2 · IMPL3/QA3 · CONDUCTOR)"
echo "  QA loops every $QA_LOOP_INTERVAL; conductor e2e+promotes every $CONDUCTOR_INTERVAL; GV reviews every $GV_INTERVAL"
