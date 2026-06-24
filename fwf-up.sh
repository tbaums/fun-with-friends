#!/usr/bin/env bash
# Bring up the fun-with-friends factory as TWO tmux sessions:
#   COORDINATION  ($COORD_SESSION): PM · GV · CAPTAIN  (3 columns; you talk to the captain)
#   IMPLEMENTATION ($BUILD_SESSION): IMPL1/QA1 … IMPLn/QAn · CONDUCTOR
#                                    (n = FWF_PAIRS / --pairs, default 3)
# Per-role model overrides (FWF_MODEL / FWF_MODEL_<ROLE>, --model/--impl-model…)
# are applied to each pane's claude launch via fwf_claude_cmd.
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
# Role prompts resolve via fwf_tmpl_path (selected template, falling back to
# its FWF_TEMPLATE_BASE for files the template doesn't override).

FLOOR_ONLY=0
case "${1:-}" in
  "") ;;
  --floor-only) FLOOR_ONLY=1;;
  *) echo "usage: fwf-up.sh [--floor-only]" >&2; exit 1;;
esac

# user-testing (issue #42): refuse a prod-looking target BEFORE any pane boots —
# whacky source-blind personas must only ever hit an isolated scratch/UAT app.
# No-op for every other template.
fwf_ut_guard_target || exit 1
# ...and warn at launch if the personas' browser MCP is not wired (the wall trial
# one hit). Fail-open — a warning, never a block. No-op for every other template.
fwf_ut_browser_preflight

# Disk-pressure guard (#638): on a shared host a full disk fails not just builds
# but PROD writes (data repo, TTS cache) — it's what wedged the v0.22.0 release.
# Refuse to bring up / cycle the floor below a free-space floor. The swarm's
# shared CARGO_TARGET_DIR keeps steady state bounded; this is the backstop.
# Tunable via FWF_MIN_FREE_GB (set 0 to disable).
fwf_min_free_gb="${FWF_MIN_FREE_GB:-50}"
# POSIX df (-Pk): 1024-byte blocks, one line per fs — portable across macOS/Linux
# (unlike BSD-only `df -g`). $4 is available KiB; fold to whole GiB.
fwf_free_gb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')"
if [ "$fwf_min_free_gb" -gt 0 ] && [ "${fwf_free_gb:-0}" -lt "$fwf_min_free_gb" ]; then
  echo "fwf: REFUSING to start — only ${fwf_free_gb}G free on \$HOME (floor ${fwf_min_free_gb}G)." >&2
  echo "fwf: free disk first — stale Rust target/ dirs are the usual culprit — then retry." >&2
  exit 1
fi

# Arming (issue #38): full role prompt once + lean /loop tick — fwf_arm_pane.

# Per-pane label (@l) and color (@c); text/color come from the shared
# fwf_role_label/fwf_role_color helpers (lib.sh) so respawn-recovery (#36)
# produces identical panes.
label_role() { tmux set -p -t "$1" @c "$(fwf_role_color "$2")"; tmux set -p -t "$1" @l "$(fwf_role_label "$2")"; }

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
  # Persistent factory-design tag (issue #31): always visible in the status bar.
  tmux set -t "$s" status-left-length 24
  tmux set -t "$s" status-left "#[bold][$FWF_TEMPLATE]#[default] "
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
printf '%s\n' "$FWF_TEMPLATE" > "$FWF_RUN/template"   # persist the running template so read-only tools (the dash) resolve it, not the dev default (#51)
# (Re)write the gh shim the panes' PATH points at: the REST+ETag read cache in
# every mode, plus the fail-closed write guard in local mode (#34/#57). Idempotent,
# and `fwf up` must never depend on provision having been recent.
fwf_install_ghguard

# Say what is about to launch BEFORE ten panes boot (issue #30): a profile/env
# mismatch should be visible here, not discovered by briefing the captain.
echo "fwf: template=$FWF_TEMPLATE · issues=$FWF_ISSUES · pairs=$FWF_PAIRS · profile=$PROFILE"
echo "fwf: sessions: $COORD_SESSION (coordination) + $BUILD_SESSION (floor)"

# Track what THIS run creates; only those panes get launched + armed.
BUILD_CREATED=0; PM_CREATED=0; GV_CREATED=0; CAPTAIN_CREATED=0

# --- IMPLEMENTATION session: N impl/qa columns + a full-height conductor ------
declare -a TP BP   # TP[id]=impl pane ; BP[id]=qa pane (id = 1..FWF_PAIRS)
if tmux has-session -t "$BUILD_SESSION" 2>/dev/null; then
  echo "build session '$BUILD_SESSION' already up — leaving it untouched."
else
  BUILD_CREATED=1
  # fwf_role_cwd gives each pane its worktree, or a throwaway scratch dir for a
  # worktree-less (source-blind) role such as a user-testing persona (issue #42).
  tmux new-session -d -s "$BUILD_SESSION" -c "$(fwf_role_cwd impl1)"
  TP[1]=$(tmux display -p -t "$BUILD_SESSION" '#{pane_id}')
  prev="${TP[1]}"
  for id in "${PAIRS[@]}"; do
    [ "$id" = 1 ] && continue
    TP[$id]=$(tmux split-window -h -P -F '#{pane_id}' -t "$prev" -c "$(fwf_role_cwd "impl$id")")
    prev="${TP[$id]}"
  done
  # A template may suppress the conductor (e.g. user-testing has no gate pipeline).
  CONDUCTOR_PANE=""
  if ! fwf_role_suppressed conductor; then
    CONDUCTOR_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$prev" -c "$(fwf_role_cwd conductor)")
  fi
  tmux select-layout -t "$BUILD_SESSION" even-horizontal
  for id in "${PAIRS[@]}"; do
    fwf_role_suppressed "qa$id" && continue   # suppressed pairs run impl-only (no QA column)
    BP[$id]=$(tmux split-window -v -P -F '#{pane_id}' -t "${TP[$id]}" -c "$(fwf_role_cwd "qa$id")")
  done
  for id in "${PAIRS[@]}"; do
    label_role "${TP[$id]}" "impl$id"
    [ -n "${BP[$id]:-}" ] && label_role "${BP[$id]}" "qa$id"
  done
  [ -n "$CONDUCTOR_PANE" ] && label_role "$CONDUCTOR_PANE" conductor
  style_session "$BUILD_SESSION"
fi

# --- COORDINATION session: PM · GV · CAPTAIN (you talk to the captain) --------
if [ "$FLOOR_ONLY" = 1 ]; then
  # Recreate only the PM/GV panes that are missing, splitting LEFT of the
  # captain (-b) so the familiar PM · GV · CAPTAIN order is preserved.
  GV_PANE=""
  if ! fwf_role_suppressed gv; then
    GV_PANE="$(fwf_find_pane "$COORD_SESSION" "GRAND VIZIER" || true)"
    if [ -z "$GV_PANE" ]; then
      GV_CREATED=1
      GV_PANE=$(tmux split-window -h -b -P -F '#{pane_id}' -t "$CAPTAIN_PANE" -c "$(fwf_role_cwd gv)")
    fi
  fi
  PM_PANE="$(fwf_find_pane "$COORD_SESSION" "PM ·" || true)"
  if [ -z "$PM_PANE" ]; then
    PM_CREATED=1
    # split left of the GV if there is one, else left of the captain.
    PM_PANE=$(tmux split-window -h -b -P -F '#{pane_id}' -t "${GV_PANE:-$CAPTAIN_PANE}" -c "$(fwf_role_cwd pm)")
  fi
  tmux select-layout -t "$COORD_SESSION" even-horizontal
else
  CAPTAIN_CREATED=1; PM_CREATED=1; GV_CREATED=0
  tmux new-session -d -s "$COORD_SESSION" -c "$(fwf_role_cwd pm)"
  PM_PANE=$(tmux display -p -t "$COORD_SESSION" '#{pane_id}')
  # A template may suppress the Grand Vizier (e.g. user-testing: PM=researcher,
  # captain — no GV). When it does, the captain splits off the PM directly.
  cap_anchor="$PM_PANE"
  if ! fwf_role_suppressed gv; then
    GV_CREATED=1
    GV_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$PM_PANE" -c "$(fwf_role_cwd gv)")
    cap_anchor="$GV_PANE"
  fi
  CAPTAIN_PANE=$(tmux split-window -h -P -F '#{pane_id}' -t "$cap_anchor" -c "$(fwf_role_cwd captain)")
  tmux select-layout -t "$COORD_SESSION" even-horizontal
  style_session "$COORD_SESSION"
fi
[ "$PM_CREATED" = 1 ] && label_role "$PM_PANE" pm
[ "$GV_CREATED" = 1 ] && label_role "$GV_PANE" gv
[ "$CAPTAIN_CREATED" = 1 ] && label_role "$CAPTAIN_PANE" captain

# --- extra roles declared by the template (e.g. dev-sre's SRE pane) -----------
# Idempotent like everything else: create only the panes that are missing;
# only those get launched + armed below.
EXTRA_PANES=(); EXTRA_NAMES=()
for er in $(fwf_extra_names); do
  case "$(fwf_extra_session "$er")" in
    coord) er_sess="$COORD_SESSION";;
    build) er_sess="$BUILD_SESSION";;
    *) echo "fwf-up: extra role '$er' declares unknown session '$(fwf_extra_session "$er")' (use coord|build)" >&2; exit 1;;
  esac
  er_tok="$(printf '%s' "$er" | tr '[:lower:]' '[:upper:]')"
  er_pane="$(fwf_find_pane "$er_sess" "$er_tok ·" || true)"
  if [ -z "$er_pane" ]; then
    er_anchor="$(tmux list-panes -t "$er_sess" -F '#{pane_id}' | tail -1)"
    er_pane=$(tmux split-window -h -P -F '#{pane_id}' -t "$er_anchor" -c "$(wt_dir "$er")")
    tmux select-layout -t "$er_sess" even-horizontal
    label_role "$er_pane" "$er"
    EXTRA_PANES+=( "$er_pane" ); EXTRA_NAMES+=( "$er" )
  fi
done

# --- launch claude (perms bypassed) in the panes THIS run created -------------
# NEW_PANES/NEW_ROLES are parallel arrays so each pane launches with its role's
# model override (fwf_claude_cmd).
NEW_PANES=(); NEW_ROLES=()
if [ "$BUILD_CREATED" = 1 ]; then
  for id in "${PAIRS[@]}"; do
    NEW_PANES+=( "${TP[$id]}" ); NEW_ROLES+=( "impl$id" )
    [ -n "${BP[$id]:-}" ] && { NEW_PANES+=( "${BP[$id]}" ); NEW_ROLES+=( "qa$id" ); }
  done
  [ -n "$CONDUCTOR_PANE" ] && { NEW_PANES+=( "$CONDUCTOR_PANE" ); NEW_ROLES+=( conductor ); }
fi
[ "$PM_CREATED" = 1 ]      && { NEW_PANES+=( "$PM_PANE" );      NEW_ROLES+=( pm ); }
[ "$GV_CREATED" = 1 ]      && { NEW_PANES+=( "$GV_PANE" );      NEW_ROLES+=( gv ); }
[ "$CAPTAIN_CREATED" = 1 ] && { NEW_PANES+=( "$CAPTAIN_PANE" ); NEW_ROLES+=( captain ); }
if [ "${#EXTRA_PANES[@]}" -gt 0 ]; then
  NEW_PANES+=( "${EXTRA_PANES[@]}" ); NEW_ROLES+=( "${EXTRA_NAMES[@]}" )
fi
if [ "${#NEW_PANES[@]}" = 0 ]; then
  echo "fwf is already fully up — nothing to do."
  exit 0
fi

i=0
while [ "$i" -lt "${#NEW_PANES[@]}" ]; do
  tmux send-keys -t "${NEW_PANES[$i]}" -l "$(fwf_claude_cmd "${NEW_ROLES[$i]}")"; tmux send-keys -t "${NEW_PANES[$i]}" Enter
  i=$((i+1))
done
echo "launched claude in ${#NEW_PANES[@]} pane(s); verifying each actually booted (re-sending to laggards)…"
i=0
while [ "$i" -lt "${#NEW_PANES[@]}" ]; do
  fwf_ensure_claude "${NEW_PANES[$i]}" "$(fwf_claude_cmd "${NEW_ROLES[$i]}")" || echo "warning: claude did not come up in pane ${NEW_PANES[$i]}"
  i=$((i+1))
done
sleep 2
for p in "${NEW_PANES[@]}"; do tmux send-keys -t "$p" Enter; done   # clear one-time bypass-accept screen
sleep 2

# --- deliver prompts to the panes THIS run created -----------------------------
if [ "$BUILD_CREATED" = 1 ]; then
  for id in "${PAIRS[@]}"; do
    fwf_arm_pane "${TP[$id]}" "impl$id" implementer "$id" "$IMPL_INTERVAL"
    [ -n "${BP[$id]:-}" ] && fwf_arm_pane "${BP[$id]}" "qa$id" qa "$id" "$QA_LOOP_INTERVAL"
  done
  [ -n "$CONDUCTOR_PANE" ] && fwf_arm_pane "$CONDUCTOR_PANE" conductor conductor "" "$CONDUCTOR_INTERVAL"
fi
[ "$PM_CREATED" = 1 ]      && fwf_arm_pane "$PM_PANE"      pm pm "" "$PM_INTERVAL"
[ "$GV_CREATED" = 1 ]      && fwf_arm_pane "$GV_PANE"      gv gv "" "$GV_INTERVAL"
[ "$CAPTAIN_CREATED" = 1 ] && fwf_arm_pane "$CAPTAIN_PANE" captain captain "" "$CAPTAIN_INTERVAL"
i=0
while [ "$i" -lt "${#EXTRA_PANES[@]}" ]; do
  fwf_arm_pane "${EXTRA_PANES[$i]}" "${EXTRA_NAMES[$i]}" "${EXTRA_NAMES[$i]}" "" "$(fwf_extra_interval "${EXTRA_NAMES[$i]}")"
  i=$((i+1))
done

echo
if [ "$FLOOR_ONLY" = 1 ]; then
  echo "floor is up (captain untouched):"
else
  echo "fwf is up (two sessions):"
fi
echo "  coordination: tmux attach -t $COORD_SESSION   ($FWF_DISPLAY_PM · GV · CAPTAIN — talk to the captain)"
echo "  floor [$FWF_TEMPLATE]: tmux attach -t $BUILD_SESSION   ($FWF_PAIRS $FWF_DISPLAY_IMPL/$FWF_DISPLAY_QA pair(s) + $FWF_DISPLAY_CONDUCTOR)"
echo "  QA loops every $QA_LOOP_INTERVAL; conductor e2e+promotes every $CONDUCTOR_INTERVAL; GV reviews every $GV_INTERVAL"
