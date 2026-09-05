#!/usr/bin/env bash
# Respawn a single role's pane: kill its claude, relaunch it (perms bypassed),
# and re-deliver its prompt — using a readiness wait so the prompt is never typed
# into the shell by mistake. Use this to hot-swap one agent (e.g. after editing a
# prompt template) without relaunching the whole grid.
#
# Usage: [FWF_PROFILE=<profile>] fwf-respawn.sh <role>
#   (<profile> is a placeholder -- do NOT pass the literal word `example`; a
#    respawn adopts the running factory's profile automatically.)
#   role = impl1 | impl2 | impl3 | qa1 | qa2 | qa3 | conductor   (implementation session)
#        | pm | gv | captain                                     (coordination session)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# issue #530: lib.sh defaults PROFILE to `example` when FWF_PROFILE is unset,
# and example.sh leaves FWF_PAIRS commented out, so it falls through to the
# built-in default of 3. A respawn launched from a seat's own shell inherits no
# FWF_PROFILE, so it would resolve `example`, believe the floor is 3 pairs, and
# manufacture seats the running factory never had. Prefer the profile `fwf up`
# persisted for the RUNNING factory before falling back to lib.sh's default.
_fwf_run_dir="${FWF_RUN_DIR:-$HOME/.fun-with-friends}"
if [ -r "$_fwf_run_dir/profile" ]; then
  _fwf_running_profile="$(cat "$_fwf_run_dir/profile" 2>/dev/null)"
  if [ -n "$_fwf_running_profile" ] && [ "${FWF_PROFILE:-}" != "$_fwf_running_profile" ]; then
    # A respawn acts on the RUNNING factory, so the running factory's profile is
    # the only correct answer. Filling in a blank was not enough: callers were
    # observed passing FWF_PROFILE=example explicitly -- the literal placeholder
    # from this file's own usage line -- which sailed past a blank-only check,
    # resolved a 3-pair floor shape, and manufactured seats this factory never
    # had. Override, loudly, rather than silently building someone else's floor.
    if [ -n "${FWF_PROFILE:-}" ]; then
      printf 'fwf-respawn: FWF_PROFILE=%s disagrees with the running factory (%s) -- using the running factory. Set FWF_PROFILE_FORCE=1 to override.\n' \
        "$FWF_PROFILE" "$_fwf_running_profile" >&2
    fi
    if [ -z "${FWF_PROFILE_FORCE:-}" ]; then
      FWF_PROFILE="$_fwf_running_profile"; export FWF_PROFILE
    fi
  fi
  unset _fwf_running_profile
fi
unset _fwf_run_dir
source "$DIR/lib.sh"
# Role prompts resolve via fwf_tmpl_path (template, falling back to its base).

# Re-capture the launch socket (#62) if respawn runs inside tmux — harmless
# when it's unchanged. If respawn runs OUTSIDE tmux (e.g. a script/cron with no
# $TMUX), leave whatever `fwf up` already persisted in place rather than
# blanking it to the "default" marker — the factory itself hasn't moved.
[ -n "${TMUX:-}" ] && fwf_persist_tmux_socket "$(fwf_tmux_socket_value)"
# Keep the pane-env file (issue #143) fresh even for a standalone respawn
# that ran with no preceding `fwf up` in this run dir.
fwf_write_pane_env

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
# Suppression checked FIRST so a suppressed seat always gets ITS OWN,
# more specific refusal below rather than the generic floor-boundary one
# just below it -- fwf_roster_names (lib.sh) already excludes suppressed
# roles from the roster, so checking floor-membership first would shadow
# this message for exactly the seats it exists to name.
if fwf_role_suppressed "$role"; then
  echo "fwf-respawn: '$role' is suppressed in template '$FWF_TEMPLATE' — it is not part of this factory." >&2; exit 1
fi
# issue #452: ask the floor what it IS, not the profile what it SHOULD BE.
# FWF_PAIRS here is the profile default -- not necessarily what `fwf up`/
# `fwf scale` actually launched with (a launch-time override is never
# persisted, and `fwf scale` deliberately never rewrites the profile
# either), so a fresh shell can see "2" while the floor genuinely runs 4.
# A seat is respawnable if it's in the UNION of the configured roster and
# the running floor's own recorded state (fwf_roster_names, lib.sh) --
# state/<profile>/heartbeat/<role> is the durable evidence a seat belongs
# to the floor, an artifact that outlives the process that stopped
# updating it (#450: a seat wedged 16.5h still has one). AC (5): a
# genuinely scaled-down seat's entries are removed by `fwf scale`
# (fwf-scale.sh), so this widens what counts as present -- it does not
# resurrect a seat the operator deliberately removed.
#
# Scoped to id > FWF_PAIRS only (issue #460): a seat already within the
# profile default passes on the cheap integer comparison alone, same as
# pre-#452 -- zero subprocess cost. The first version of this fix ran
# fwf_roster_names (a fork-heavy pipeline: brace-group, `while read`,
# `sort -u`, plus a `basename` fork per heartbeat entry) unconditionally,
# for EVERY respawn, including this common in-floor case that never
# needed it. Under host contention that added synchronous latency was
# enough to blow through #217/#312's own respawn tests' deliberately
# tight verify windows (FWF_RESPAWN_VERIFY_MARGIN=1,
# FWF_HEARTBEAT_POLL_SECS=1), producing "pid not found" / "env not
# observed in time" failures with nothing actually wrong in auth or env
# forwarding -- a real regression traced to added cost on the hot path,
# not a flake and not a forwarding bug. Restricting the roster lookup to
# only the case it exists for (a seat beyond the profile default) removes
# that cost from the common path entirely.
if [ -n "$id" ] && [ "$id" -gt "$FWF_PAIRS" ]; then
  if [ ! -d "$FWF_STATE_DIR/heartbeat" ]; then
    echo "fwf-respawn: $FWF_STATE_DIR/heartbeat is missing/unreadable -- falling back to the configured floor only (FWF_PAIRS=$FWF_PAIRS)" >&2
  fi
  if ! fwf_roster_names | grep -qxF -- "$role"; then
    echo "fwf-respawn: $role is beyond both the configured floor (FWF_PAIRS=$FWF_PAIRS) and the running floor's own recorded state ($FWF_STATE_DIR/heartbeat) -- observed roster: $(fwf_roster_names | tr '\n' ' ' | sed 's/ $//')" >&2
    exit 1
  fi
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
  # issue #504: respawn-pane -k returns before the old claude has exited, and
  # the pane keeps reporting `claude` during that window. Wait for the pane to
  # actually reach a shell first, or fwf_ensure_claude below reads the dying
  # process as "already running", never relaunches, and fwf_arm_pane types the
  # role prompt straight into bash.
  fwf_pane_wait_for_shell "$CP" 10 || echo "warning: $role pane $CP did not settle to a shell after kill" >&2
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

# issue #99, Fix 2: verify the loop actually TICKS after arming, off the
# durable heartbeat file — never the pane's animation glyph, which keeps
# looking "alive" even on a role that never advances a cycle (the exact
# ambiguity that caused operators to fire repeated respawns chasing a
# healthy-but-slow agent). Verifies SCHEDULED/START, not completion: the
# heartbeat fires at cycle step-0, before any work, so a healthy first cycle
# whose WORK takes minutes still verifies within the window.
FWF_RESPAWN_VERIFY_MARGIN="${FWF_RESPAWN_VERIFY_MARGIN:-30}"
_fwf_respawn_renudge() {
  fwf_send_prompt "$CP" "/loop $interval $role tick: if you have compacted or lost ANY context since the last tick, FIRST re-read your role prompt at $(fwf_write_role_prompt "$role" "$tmpl" "$id"). Then run exactly ONE cycle of that role's loop and report in its format. Act the role; do not re-state it."
}
arm_epoch="$(date +%s)"
fwf_arm_pane "$CP" "$role" "$tmpl" "$id" "$interval"
# issue #85/#105: respawning a role means its PLANE is no longer idle — clear
# any logged IDLE for that plane. captain and gv aren't a plane (GV never
# idles; the captain is the always-up driver) so neither logs an event. An
# extra template-declared role's plane follows its own declared session
# (coord -> pm; build -> build), matching fwf-up.sh's own classification.
case "$role" in
  pm) fwf_floor_event floor-up "" "" pm;;
  gv|captain) ;;
  impl*|qa*|conductor) fwf_floor_event floor-up "" "" build;;
  *)
    if fwf_extra_entry "$role" >/dev/null 2>&1; then
      case "$(fwf_extra_session "$role")" in
        build) fwf_floor_event floor-up "" "" build;;
        *)     fwf_floor_event floor-up "" "" pm;;
      esac
    fi
    ;;
esac

interval_secs="$(fwf_interval_seconds "$interval")" || exit 1
window=$((interval_secs + FWF_RESPAWN_VERIFY_MARGIN))

# issue #133 (failure mode 2 — the "reported-success respawn that still doesn't
# loop"): the soft re-nudge inside fwf_verify_respawn_tick only RE-SENDS the
# /loop line into the same pane. If that pane's claude never armed the loop (or
# is wedged at its prompt), re-typing the same line cannot revive it — so on a
# soft-verify failure we escalate ONCE to a HARD recycle: kill the pane's
# claude, relaunch it fresh, re-arm from scratch, and re-verify. We NEVER print
# a success line without a real heartbeat tick, and we don't give up until the
# pane itself has actually been recycled.
_fwf_respawn_hard_rearm() {
  echo "fwf-respawn: soft re-nudge did not tick — escalating to a hard kill+relaunch of $role's pane $CP" >&2
  tmux respawn-pane -k -t "$CP" -c "$(fwf_role_cwd "$role")" 2>/dev/null || true
  fwf_pane_wait_for_shell "$CP" 10 || echo "warning: $role pane $CP did not settle to a shell after hard kill" >&2   # issue #504
  fwf_ensure_claude "$CP" "$(fwf_claude_cmd "$role")" || echo "warning: claude did not come up in $role pane $CP on escalation" >&2
  sleep 2; tmux send-keys -t "$CP" Enter; sleep 2
  arm_epoch="$(date +%s)"
  fwf_arm_pane "$CP" "$role" "$tmpl" "$id" "$interval"
}

if fwf_verify_respawn_tick "$role" "$arm_epoch" "$window" _fwf_respawn_renudge; then
  echo "$role respawned and armed in $CP (role prompt once + lean $interval tick)"
else
  _fwf_respawn_hard_rearm
  if fwf_verify_respawn_tick "$role" "$arm_epoch" "$window" _fwf_respawn_renudge; then
    echo "$role respawned and armed in $CP after a hard pane relaunch (escalated recovery)"
  else
    # issue #217 AC(7)/(10): name the unauthenticated case explicitly when
    # that's what happened, instead of the generic "wedged at a deeper
    # level" -- and name WHICH source the auth sink was last resolved from
    # (read-only here — respawn must NEVER re-resolve/rewrite the sink from
    # its own possibly-wrong environment, e.g. supervise's, which could
    # silently clobber a good sink with "none"), so the operator can tell
    # "no credential at all" from "a stale env var in whatever shell last
    # ran `fwf up` outranking a fresher credentials file" (the precedence
    # trap this ticket's own edge cases call out).
    _fwf217_src="$(sed -n 's/^export FWF_AUTH_SOURCE=//p' "$FWF_AUTH_ENV_FILE" 2>/dev/null)"
    [ -n "$_fwf217_src" ] || _fwf217_src="none (no sink written yet — run 'fwf up' or 'fwf auth resolve')"
    echo "fwf-respawn: $role STILL not ticking after a hard relaunch — the pane is wedged at a deeper level; inspect it manually (tmux attach; pane $CP). Auth sink last resolved from: $_fwf217_src — if this doesn't match what you expect, 'fwf auth resolve' re-checks and 'unset CLAUDE_CODE_OAUTH_TOKEN' clears a stale shell var before the next 'fwf up'." >&2
    exit 1
  fi
fi
