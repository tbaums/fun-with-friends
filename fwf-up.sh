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
# Per-UNIT recreation (issue #105, generalizing issue #6's single
# --floor-only): (re)create just the BUILD session, just the PM pane, or both
# — around a LIVE captain pane, which (and GV, which never idles) is left
# completely untouched so the captain can cycle either unit without losing
# its own context.
#   --build-only   (re)create only the BUILD session (impl/qa/conductor).
#                  Requires an existing coordination session (with a live
#                  captain) — it builds the floor AROUND that captain.
#   --pm-only      (re)create only the PM pane (ensuring GV exists too, as a
#                  defensive invariant check — GV should already be there
#                  since it's never torn down, but this is the natural place
#                  to self-heal if it somehow isn't). Also requires an
#                  existing coordination session.
#   --floor-only   KEPT for back-compat: equivalent to --build-only +
#                  --pm-only together (today's exact prior behavior).
#   --coord-only   (issue #155) the non-destructive MIRROR of --build-only:
#                  brings up the coordination session (PM/GV/CAPTAIN) from a
#                  cold/fully-down state, leaving any existing build floor
#                  completely untouched (up, down, or absent — never checked).
#                  A clean no-op if the coordination session is already up
#                  (use --pm-only to recreate just the PM pane within it).
# Idempotent: pieces that already exist are left alone; only panes created by
# THIS run get claude launched + a prompt delivered. Every up-path here logs
# a floor-up event (issue #85, now plane-tagged) for the plane(s) it targets,
# clearing any logged IDLE for them, even when nothing new was created.
#
# Usage: [FWF_PROFILE=example] fwf-up.sh [--build-only|--pm-only|--floor-only|--coord-only]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
# Role prompts resolve via fwf_tmpl_path (selected template, falling back to
# its FWF_TEMPLATE_BASE for files the template doesn't override).

build_only=0; pm_only=0; coord_only=0
case "${1:-}" in
  "") ;;
  --floor-only) build_only=1; pm_only=1;;
  --build-only) build_only=1;;
  --pm-only) pm_only=1;;
  --coord-only) coord_only=1;;
  *) echo "usage: fwf-up.sh [--build-only|--pm-only|--floor-only|--coord-only]" >&2; exit 1;;
esac
FULL=1
{ [ "$build_only" = 1 ] || [ "$pm_only" = 1 ] || [ "$coord_only" = 1 ]; } && FULL=0
# FLOOR_ONLY: true whenever this run is a partial recreation that must anchor
# around an ALREADY-LIVE captain (build_only/pm_only) — used below to pick
# the anchor-around-a-live-captain precondition and the final echo.
# --coord-only is NOT floor-only: it brings up coord fresh (no captain to
# anchor around) and gets its own precondition/echo branch.
FLOOR_ONLY=0
{ [ "$build_only" = 1 ] || [ "$pm_only" = 1 ]; } && FLOOR_ONLY=1

# user-testing (issue #42): refuse a prod-looking target BEFORE any pane boots —
# whacky source-blind personas must only ever hit an isolated scratch/UAT app.
# No-op for every other template.
fwf_ut_guard_target || exit 1
# ...and warn at launch if the personas' browser MCP is not wired (the wall trial
# one hit). Fail-open — a warning, never a block. No-op for every other template.
fwf_ut_browser_preflight
# Cross-machine guard: warn (never block) if this box's fwf is behind the latest
# release — flows like the discovery ticket path live in the templates and only
# reach a box via `fwf upgrade`, so a stale box would silently run the old flow.
fwf_version_skew_warn || true

# Token-budget WRITER (issue #96): armed ONLY when FWF_TOKEN_BUDGET is set —
# zero cost otherwise. Idempotent (a floor-only recycle or re-`up` doesn't
# spawn a second writer). Every role's step-0 BUDGET CHECK reads what this
# writes; nothing here itself pauses anything.
fwf_budget_writer_start

# Disk-pressure guard: on a shared host a full disk fails not just builds
# but PROD writes too — it once wedged a release.
# Refuse to bring up / cycle the floor below a free-space floor. Each worktree
# builds into its OWN private target (issue #151 — a shared target dir is a
# false-GREEN mechanism, not a disk optimization), so N worktrees cost N targets;
# this floor + a prune policy are the disk backstop, not a shared cache.
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

if [ "$coord_only" = 1 ]; then
  # Bringing up coord fresh (issue #155): the build floor is never checked or
  # touched here, whether it's up, down, or absent. Only refuse if coord is
  # already up — a clean no-op, not an error (use --pm-only to recreate just
  # the PM pane within an existing coord).
  if tmux has-session -t "$COORD_SESSION" 2>/dev/null; then
    # issue #85/#105 (via #225 adversarial review): an up-path was still
    # invoked for the pm plane and confirms it up, even on this no-op — clear
    # any logged IDLE for it, matching --build-only/--pm-only's no-op path.
    fwf_floor_event floor-up "" "" pm
    echo "fwf-up: '$COORD_SESSION' is already up — nothing to do (use 'fwf up --pm-only' to recreate just the PM pane)."
    exit 0
  fi
elif [ "$FLOOR_ONLY" = 1 ]; then
  # Rebuilding a UNIT around a live captain: the coord session + captain
  # pane must already exist (otherwise a full launch is what you want).
  tmux has-session -t "$COORD_SESSION" 2>/dev/null \
    || { echo "fwf-up: no '$COORD_SESSION' session — run a full 'fwf up' instead." >&2; exit 1; }
  CAPTAIN_PANE="$(fwf_find_pane "$COORD_SESSION" CAPTAIN || true)"
  [ -n "$CAPTAIN_PANE" ] \
    || { echo "fwf-up: no CAPTAIN pane in '$COORD_SESSION' — run a full 'fwf up' instead." >&2; exit 1; }
else
  for s in "$COORD_SESSION" "$BUILD_SESSION"; do
    if tmux has-session -t "$s" 2>/dev/null; then
      echo "tmux session '$s' already exists — run fwf-down.sh first (or 'fwf up --build-only'/'--pm-only'/'--floor-only'/'--coord-only' to rebuild part of it around a live captain)." >&2; exit 1
    fi
  done
fi

# Preflight (issue #142): fwf-up.sh assumes fwf-provision.sh already ran —
# on a never-provisioned profile this used to launch every pane into $HOME
# (tmux -c on a missing worktree dir silently falls back there) with no
# error, looking healthy while unable to actually pipeline. Fail loud
# instead, scoped to only the roles THIS run will actually launch.
preflight_roles=()
if [ "$FULL" = 1 ] || [ "$build_only" = 1 ]; then
  for id in "${PAIRS[@]}"; do
    preflight_roles+=("impl$id")
    fwf_role_suppressed "qa$id" || preflight_roles+=("qa$id")
  done
  fwf_role_suppressed conductor || preflight_roles+=(conductor)
fi
if [ "$FULL" = 1 ] || [ "$pm_only" = 1 ] || [ "$coord_only" = 1 ]; then
  preflight_roles+=(pm captain)
  fwf_role_suppressed gv || preflight_roles+=(gv)
fi
if [ "${#preflight_roles[@]}" -gt 0 ]; then
  missing_wt="$(fwf_missing_worktrees "${preflight_roles[@]}")"
  [ -z "$missing_wt" ] \
    || { echo "fwf-up: no worktrees for profile '$PROFILE' (missing:$missing_wt) — run 'fwf provision' or 'fwf start' first." >&2; exit 1; }
fi

# Boot-time worktree refresh for the read-only roles (issue #146 AC4): a role
# provisioned a while ago should start current with $DEFAULT_BRANCH, not
# carry forward whatever it was at provision-time. Necessary but NOT
# sufficient on its own — the per-tick refresh (each role's own template)
# and fwf supervise's independent fail-loud check cover the drift that
# accumulates DURING a run, which this boot-time pass cannot. Warn-only:
# a refresh failure here must not block the launch, since the per-tick
# retry + supervise alarm are what actually own reporting it.
if [ "$FULL" = 1 ] || [ "$pm_only" = 1 ] || [ "$coord_only" = 1 ]; then
  coord_refresh_roles=(pm captain)
  fwf_role_suppressed gv || coord_refresh_roles+=(gv)
  for r in "${coord_refresh_roles[@]}"; do
    wt_result="$(fwf_worktree_refresh_role "$r" 2>/dev/null || echo "FETCH_FAILED unknown")"
    case "${wt_result%% *}" in
      REFRESHED|NO_WORKTREE) : ;;
      *) echo "fwf-up: WARNING — $r worktree refresh: $wt_result (will retry every tick, issue #146)" >&2 ;;
    esac
  done
fi

mkdir -p "$FWF_RUN"
rm -f "$STOP_FILE"   # a fresh launch IS a resume — clear any stale STOP sentinel so agents don't idle immediately
printf '%s\n' "$FWF_TEMPLATE" > "$FWF_RUN/template"   # persist the running template so read-only tools (the dash) resolve it, not the dev default (#51)
fwf_persist_tmux_socket "$(fwf_tmux_socket_value)"    # learn the launch socket (#62) so the dash queries the right tmux server, not just "default"
# (Re)write the gh shim the panes' PATH points at: the REST+ETag read cache in
# every mode, plus the fail-closed write guard in local mode (#34/#57). Idempotent,
# and `fwf up` must never depend on provision having been recent.
fwf_install_ghguard
# (Re)write the pane-env file every pane's claude launch sources (issue #143):
# regenerated fresh on every `up` so panes reliably get FWF_PANE_ENV-listed
# vars regardless of whether the tmux server predates this launch.
fwf_write_pane_env

# (Re)resolve + persist claude auth (issue #217): panes get their token by
# process inheritance from THIS shell today; a later respawn/supervise from a
# different shell inherits nothing. Refreshing on every `up` means a rotated
# token (or a first-time `claude /login` since the last up) is picked up, not
# just carried over stale. Fail loud here, before ten panes boot unauthenticated
# and LOOK up on the dash while doing zero work — the exact failure this
# ticket exists to prevent.
_fwf217_auth_src="$(fwf_resolve_claude_auth)" || {
  echo "fwf: no claude credentials found (checked \$CLAUDE_CODE_OAUTH_TOKEN, ~/.claude/.credentials.json, and the macOS Keychain) — run 'claude /login' first, or export CLAUDE_CODE_OAUTH_TOKEN, then re-run 'fwf up'" >&2
  exit 1
}
echo "fwf: claude auth resolved from: $_fwf217_auth_src"

# Say what is about to launch BEFORE ten panes boot (issue #30): a profile/env
# mismatch should be visible here, not discovered by briefing the captain.
echo "fwf: template=$FWF_TEMPLATE · issues=$FWF_ISSUES · pairs=$FWF_PAIRS · profile=$PROFILE"
echo "fwf: sessions: $COORD_SESSION (coordination) + $BUILD_SESSION (floor)"

# Track what THIS run creates; only those panes get launched + armed.
BUILD_CREATED=0; PM_CREATED=0; GV_CREATED=0; CAPTAIN_CREATED=0

# --- IMPLEMENTATION session: N impl/qa columns + a full-height conductor ------
# issue #105: this unit is touched whenever build_only is set, OR this is a
# full (unflagged) launch — a --pm-only run skips it entirely.
declare -a TP BP   # TP[id]=impl pane ; BP[id]=qa pane (id = 1..FWF_PAIRS)
CONDUCTOR_PANE=""
if [ "$FULL" = 1 ] || [ "$build_only" = 1 ]; then
if tmux has-session -t "$BUILD_SESSION" 2>/dev/null; then
  # issue #190: a silently-discarded --pairs on a live floor is a WORSE
  # failure than not being able to scale at all -- the operator sees a
  # clean exit and believes the floor scaled. Only checked when --pairs was
  # EXPLICITLY passed this invocation (FWF_PAIRS_REQUESTED, set by the `fwf`
  # dispatcher, never by FWF_PAIRS's own default/profile value) -- a bare
  # `fwf up` on a live floor keeps today's unchanged, silent no-op (AC d).
  if [ "${FWF_PAIRS_REQUESTED:-0}" = 1 ]; then
    RUNNING_PAIRS="$(fwf_running_pair_count "$BUILD_SESSION")"
    if [ "$RUNNING_PAIRS" = unknown ]; then
      echo "fwf: build session '$BUILD_SESSION' has an inconsistent pair state (some index has only one of implN/qaN) — could not determine the running pair count, refusing to guess. Resolve the floor's state before requesting a pair count." >&2
      exit 1
    elif [ "$RUNNING_PAIRS" != "$FWF_PAIRS" ]; then
      echo "fwf: build session '$BUILD_SESSION' is already up running $RUNNING_PAIRS pair(s) — requested $FWF_PAIRS was NOT applied." >&2
      echo "fwf: 'fwf up --pairs' cannot resize a live floor. 'fwf scale --pairs $FWF_PAIRS' (issue #210) reconciles a live floor WITHOUT disturbing in-flight work — try that first." >&2
      echo "fwf: the only path here that applies a new count is 'fwf up --build-only', which RECREATES the build session and KILLS every in-flight implementer/QA pane." >&2
      echo "fwf: if that's acceptable, re-run with 'fwf up --build-only'. Otherwise leave the floor at $RUNNING_PAIRS pair(s) or use 'fwf scale'." >&2
      exit 1
    fi
    echo "build session '$BUILD_SESSION' already up running the requested $FWF_PAIRS pair(s) — leaving it untouched."
  else
    echo "build session '$BUILD_SESSION' already up — leaving it untouched."
  fi
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
    # Rebalance after each split so a wide floor (e.g. a #47 deep sweep of 9
    # personas) never runs the active pane out of width mid-loop ("no space for
    # new pane"). A no-op for small floors — the final layout is unchanged.
    tmux select-layout -t "$BUILD_SESSION" even-horizontal >/dev/null 2>&1
  done
  # A template may suppress the conductor (e.g. user-testing has no gate pipeline).
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
fi   # end build-session block (issue #105: FULL or build_only)

# --- COORDINATION session: PM · GV · CAPTAIN (you talk to the captain) --------
# issue #105: only touched when this is a full launch (both PM and GV get
# created) or --pm-only (PM recreated; GV existence is defensively verified —
# it should already be there, since no down-path ever tears it down, but this
# is the natural self-heal point if it somehow isn't). A pure --build-only
# run skips this block entirely — GV_PANE/PM_PANE/CAPTAIN_PANE stay unset and
# the [ "$X_CREATED" = 1 ] guards below short-circuit before ever expanding
# them.
GV_PANE=""
if [ "$FULL" = 1 ] || [ "$coord_only" = 1 ]; then
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
elif [ "$pm_only" = 1 ]; then
  # Recreate the PM pane (and defensively ensure GV exists), splitting LEFT
  # of the captain (-b) so the familiar PM · GV · CAPTAIN order is preserved.
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
fi
[ "$PM_CREATED" = 1 ] && label_role "$PM_PANE" pm
[ "$GV_CREATED" = 1 ] && label_role "$GV_PANE" gv
[ "$CAPTAIN_CREATED" = 1 ] && label_role "$CAPTAIN_PANE" captain

# --- extra roles declared by the template (e.g. dev-sre's SRE pane) -----------
# Idempotent like everything else: create only the panes that are missing;
# only those get launched + armed below. issue #105: an extra role in the
# coord session is part of the PM plane (touched on FULL or --pm-only); one
# in the build session is part of the build plane (FULL or --build-only) —
# a --build-only run must not reach into the coord session at all, and
# vice versa.
EXTRA_PANES=(); EXTRA_NAMES=()
for er in $(fwf_extra_names); do
  case "$(fwf_extra_session "$er")" in
    coord) er_sess="$COORD_SESSION"; { [ "$FULL" = 1 ] || [ "$pm_only" = 1 ] || [ "$coord_only" = 1 ]; } || continue;;
    build) er_sess="$BUILD_SESSION"; { [ "$FULL" = 1 ] || [ "$build_only" = 1 ]; } || continue;;
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
# issue #105: log floor-up for exactly the plane(s) THIS invocation targets
# (FULL touches both; --build-only/--pm-only touch just their own) — even
# when nothing new gets created below, since an up-path was still invoked
# for that plane and confirms it up, clearing any logged IDLE (issue #85).
_fwf_log_plane_up_events() {
  # issue #190: each line's compound condition can be FALSE on a legitimate
  # invocation (e.g. --build-only alone leaves the `pm` line's condition
  # false) -- under `set -e`, a bare `cond && cmd` whose cond is false
  # returns 1, and being the LAST statement run made THAT this function's
  # own return value, aborting the caller's script on the exact "already up
  # -- nothing to do" path this function exists to log for. `|| true` on
  # each line makes "condition didn't apply" distinct from "the logging
  # call itself failed" -- neither line's failure was ever meant to abort.
  { [ "$FULL" = 1 ] || [ "$build_only" = 1 ]; }                              && fwf_floor_event floor-up "" "" build
  true
  { [ "$FULL" = 1 ] || [ "$pm_only" = 1 ] || [ "$coord_only" = 1 ]; }        && fwf_floor_event floor-up "" "" pm
  true
}

if [ "${#NEW_PANES[@]}" = 0 ]; then
  _fwf_log_plane_up_events
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
# Track every role we arm (role / pane / tmpl / id / interval) so the boot
# health-gate below can re-arm any that fails to fire a first tick (issue #133).
ARM_ROLES=(); ARM_PANES=(); ARM_TMPLS=(); ARM_IDS=(); ARM_INTERVALS=()
arm_and_track() { # $1=pane $2=role $3=tmpl $4=id $5=interval
  fwf_arm_pane "$1" "$2" "$3" "$4" "$5"
  ARM_ROLES+=("$2"); ARM_PANES+=("$1"); ARM_TMPLS+=("$3"); ARM_IDS+=("$4"); ARM_INTERVALS+=("$5")
}
BOOT_EPOCH="$(date +%s)"   # first tick must land at/after here — capture pre-arm
if [ "$BUILD_CREATED" = 1 ]; then
  for id in "${PAIRS[@]}"; do
    arm_and_track "${TP[$id]}" "impl$id" implementer "$id" "$IMPL_INTERVAL"
    [ -n "${BP[$id]:-}" ] && arm_and_track "${BP[$id]}" "qa$id" qa "$id" "$QA_LOOP_INTERVAL"
  done
  [ -n "$CONDUCTOR_PANE" ] && arm_and_track "$CONDUCTOR_PANE" conductor conductor "" "$CONDUCTOR_INTERVAL"
fi
[ "$PM_CREATED" = 1 ]      && arm_and_track "$PM_PANE"      pm pm "" "$PM_INTERVAL"
[ "$GV_CREATED" = 1 ]      && arm_and_track "$GV_PANE"      gv gv "" "$GV_INTERVAL"
[ "$CAPTAIN_CREATED" = 1 ] && arm_and_track "$CAPTAIN_PANE" captain captain "" "$CAPTAIN_INTERVAL"
i=0
while [ "$i" -lt "${#EXTRA_PANES[@]}" ]; do
  arm_and_track "${EXTRA_PANES[$i]}" "${EXTRA_NAMES[$i]}" "${EXTRA_NAMES[$i]}" "" "$(fwf_extra_interval "${EXTRA_NAMES[$i]}")"
  i=$((i+1))
done

# --- boot health-gate (issue #133) ---------------------------------------------
# PROCESS-ALIVE IS NOT LOOP-ALIVE: confirm every armed role actually fired a
# real first tick before we call the floor up. Re-arm any laggard once; hard-
# respawn any that STILL won't loop — so a wedged role is recovered automatically
# at boot, never left for a human to notice and `fwf respawn` by hand. Set
# FWF_SKIP_BOOT_GATE=1 to bypass (e.g. a deliberately parked bring-up).
if [ "${FWF_SKIP_BOOT_GATE:-0}" != 1 ] && [ "${#ARM_ROLES[@]}" -gt 0 ]; then
  BOOT_VERIFY_MARGIN="${FWF_BOOT_VERIFY_MARGIN:-45}"
  # Re-arm callback: re-deliver the role prompt + lean /loop to the named role's
  # own pane (looked up from the tracking arrays).
  _fwf_boot_renudge() { # $1=role
    local r="$1" j=0
    while [ "$j" -lt "${#ARM_ROLES[@]}" ]; do
      if [ "${ARM_ROLES[$j]}" = "$r" ]; then
        fwf_arm_pane "${ARM_PANES[$j]}" "${ARM_ROLES[$j]}" "${ARM_TMPLS[$j]}" "${ARM_IDS[$j]}" "${ARM_INTERVALS[$j]}"
        return 0
      fi
      j=$((j+1))
    done
  }
  BOOT_SPECS=(); j=0
  while [ "$j" -lt "${#ARM_ROLES[@]}" ]; do
    isecs="$(fwf_interval_seconds "${ARM_INTERVALS[$j]}" 2>/dev/null || echo 180)"
    BOOT_SPECS+=("${ARM_ROLES[$j]}:$((isecs + BOOT_VERIFY_MARGIN))")
    j=$((j+1))
  done
  echo "verifying every role fired a first loop tick (re-arming laggards)…"
  if fwf_verify_boot_ticks "$BOOT_EPOCH" _fwf_boot_renudge "${BOOT_SPECS[@]}"; then
    echo "boot health-gate: all ${#ARM_ROLES[@]} role(s) ticking."
  else
    # Automated recovery: hard-respawn (kill pane → relaunch → re-arm → verify)
    # each role that never looped even after a re-arm. No manual respawn needed.
    for dr in "${FWF_BOOT_DEAD_ROLES[@]}"; do
      echo "boot health-gate: hard-respawning wedged role '$dr'…" >&2
      "$DIR/fwf-respawn.sh" "$dr" || echo "warning: automated respawn of '$dr' did not verify — run 'fwf respawn $dr' and check its pane" >&2
    done
  fi
fi

_fwf_log_plane_up_events   # issue #85/#105: this run just (re)built its plane(s) — clear any logged IDLE for them

echo
if [ "$FULL" = 1 ]; then
  echo "fwf is up (two sessions):"
elif [ "$coord_only" = 1 ]; then
  echo "coordination is up (build floor untouched):"
elif [ "$build_only" = 1 ] && [ "$pm_only" = 1 ]; then
  echo "floor is up (captain and GV untouched):"
elif [ "$build_only" = 1 ]; then
  echo "build floor is up (coordination untouched):"
else
  echo "PM is up (captain, GV, and the build floor untouched):"
fi
echo "  coordination: tmux attach -t $COORD_SESSION   ($FWF_DISPLAY_PM · GV · CAPTAIN — talk to the captain)"
echo "  floor [$FWF_TEMPLATE]: tmux attach -t $BUILD_SESSION   ($FWF_PAIRS $FWF_DISPLAY_IMPL/$FWF_DISPLAY_QA pair(s) + $FWF_DISPLAY_CONDUCTOR)"
echo "  QA loops every $QA_LOOP_INTERVAL; conductor e2e+promotes every $CONDUCTOR_INTERVAL; GV reviews every $GV_INTERVAL"
