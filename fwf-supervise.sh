#!/usr/bin/env bash
# fwf supervise — steady-state wedge supervisor (issue #165).
#
# The boot health-gate (#133) catches a role that never STARTS ticking; nothing
# yet catches a role that goes tick-stale DURING steady state. But tick-staleness
# alone is ambiguous: a genuinely wedged agent, a healthy-but-mid-long-task agent,
# and a parked one all look equally stale. This supervisor disambiguates by
# pairing the two per-role signals that already exist but nothing consumed in
# steady state — the monotonic loop tick (#133) and per-role token flow (#95).
#
# Per role, classification is delegated to fwf-pane-liveness.sh (issue #147),
# which snapshots (tick, tokens, epoch) into $FWF_STATE_DIR/tick-watch/<role>
# and diffs against the prior snapshot via the PURE lib.sh predicate
# fwf_wedge_verdict:
#   HEALTHY  tick advanced.
#   WORKING  tick static but tokens still flowing (a healthy long cycle) — or
#            both static but still within the flat-for grace. Never reaped.
#   WEDGED   tick static AND tokens flat past FWF_WEDGE_MIN_SECS — the only
#            verdict that may trigger a respawn.
#   UNKNOWN  no baseline old enough to diff against yet (a fresh baseline is
#            stamped for a later call). Never reaped.
# This is deliberately the SAME script #147's build-plane idle guard queries
# (fwf_build_plane_blocked, lib.sh) — one shared liveness source, so this
# loop and that guard can never disagree about the same role's aliveness.
#
# SHIPS DARK. On WEDGED it only LOGS the verdict unless FWF_SUPERVISE_AUTORESPAWN=1,
# in which case it calls fwf-respawn.sh <role> to hot-swap the wedged pane.
# Snapshotting + classification ALWAYS run; only the respawn action is gated, so
# the classifier can be observed in production before it is ever allowed to reap.
#
# Also classifies a SEPARATE failure shape (issue #140): a QA role can be
# HEALTHY/WORKING by the above (the pane is genuinely alive) and still be the
# "stranded review" incident the ticket is about — its own lane has an
# AWAITING_REVIEW PR sitting untouched. See fwf_lane_stale_verdict (lib.sh);
# this is the routed observability channel #140 requires instead of a bare
# `resume` stdout line. Also log-only, never auto-respawns.
#
# Also watches worktree freshness for the read-only roles (issue #146):
# pm/gv/captain each auto-refresh their OWN worktree at the start of every
# tick (fwf worktree-refresh, lib.sh's fwf_worktree_refresh_role), but that
# is self-reported -- a role that stops ticking or whose refresh silently
# fails goes stale again with nothing catching it. This loop independently
# re-runs the SAME refresh and alarms WORKTREE_STALE / WORKTREE_ANOMALY
# through this routed channel (never a bare stdout line from the role's own
# script) when a worktree is still not at 0-behind afterward. impl/qa are
# explicitly out of scope for #146 and are untouched by this check.
#
# Usage: fwf supervise [role ...]        (default: every role; --profile via the
#                                          dispatcher's engine() — see #69)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fwf-usage-data.sh
source "$DIR/fwf-usage-data.sh"

# Which roles to watch: explicit args, else the whole factory.
if [ "$#" -gt 0 ]; then roles="$*"; else roles="$(fwf_all_roles)"; fi

autorespawn="${FWF_SUPERVISE_AUTORESPAWN:-0}"
now="$(date -u +%s)"   # issue #140's lane-stale check ages a PR's updatedAt against this

# issue #174 — "who watches the watcher": this script itself is bash,
# re-read fresh from disk on every invocation, so it can never be stale in
# the way a long-running compiled process can (#153's dash). The one real
# way an operator ends up watching with stale logic is not having upgraded
# the fwf INSTALL itself — already-tracked machinery (fwf doctor / fwf up's
# warning), reused here rather than re-invented, so this run's own output
# names it up front instead of silently assuming the install is current.
_fwf174_skew="$(fwf_version_skew_check 2>/dev/null || true)"
if [ -n "$_fwf174_skew" ]; then
  printf 'supervise: fwf install itself is OUT OF DATE (v%s here, v%s released) — every check below runs OLD logic; run '"'"'fwf upgrade'"'"' first\n' \
    "${_fwf174_skew%%|*}" "${_fwf174_skew##*|}"
fi

for role in $roles; do
  [ -n "$role" ] || continue

  # issue #174 (p1)/(p2)/(p3): prompt drift, checked FIRST and independent of
  # liveness — a role can be perfectly HEALTHY and still be running a
  # superseded prompt. Reported as ONE finding naming BOTH halves of the
  # mixed state (p2), never split into an independent "binary" line and a
  # "prompt" line: for a bash-invoked role loop, every tool call it makes
  # (fwf tick, fwf gate, …) re-reads fwf's CURRENT install fresh — there is
  # no separate "binary" to go stale — so the honest combined finding is
  # "scripts current, prompt stale", not two unrelated facts. Log-only, never
  # respawns (p3) — the remedy is #217's territory, not this script's.
  _fwf174_pd="$(fwf_prompt_drift_verdict "$role")"
  case "$_fwf174_pd" in
    STALE\ *)
      _fwf174_old="$(printf '%s' "$_fwf174_pd" | awk '{print $2}')"
      _fwf174_new="$(printf '%s' "$_fwf174_pd" | awk '{print $3}')"
      _fwf174_behind="$(git -C "$FWF_LIB_DIR" rev-list --count "$_fwf174_old..$_fwf174_new" 2>/dev/null || echo '?')"
      printf 'supervise: %-10s CONFIG_DRIFT scripts/tools this role invokes are current (bash re-reads fresh) but its ALREADY-RENDERED prompt was rendered at %s and fwf is now %s commit(s) ahead at %s — mixed state no commit ever represented; only a respawn (#217) reloads it\n' \
        "$role" "${_fwf174_old:0:12}" "$_fwf174_behind" "${_fwf174_new:0:12}"
      ;;
  esac

  # issue #193 (f)/(g): fwf-pane-liveness.sh's WEDGED verdict is computed
  # purely from on-disk tick/token files (fwf_tick_read), independent of
  # whether this role's tmux SESSION is even visible right now -- a role
  # whose floor was deliberately brought down, or whose session merely
  # isn't visible from THIS host/socket, has a tick file that stops
  # advancing for exactly the same reason a truly wedged role's does.
  # Unchecked, that ambiguity would eventually auto-respawn a role that
  # isn't wedged at all, it's just not running. So session visibility is
  # checked FIRST: an invisible session short-circuits STRAIGHT PAST the
  # tick/token classifier (which cannot tell the two apart) to a distinct,
  # never-reaped verdict -- but, unlike genuine UNKNOWN below, it does NOT
  # skip the worktree-freshness (#146) or lane-stale (#140) checks further
  # down: those are independent, non-tmux signals that stay just as valid
  # whether or not THIS host/socket can currently see the role's pane.
  if fwf_role_session_visible "$role"; then
    verdict="$("$DIR/fwf-pane-liveness.sh" "$role")"
  else
    verdict="SESSION_UNKNOWN"
  fi

  if [ "$verdict" = "UNKNOWN" ]; then
    printf 'supervise: %-10s UNKNOWN (no old-enough baseline yet — will classify on a later call)\n' "$role"
    continue
  elif [ "$verdict" = "SESSION_UNKNOWN" ]; then
    if fwf_factory_visible; then
      printf 'supervise: %-10s SESSION_UNKNOWN role session not visible on the resolved tmux socket though the factory itself is -- cannot distinguish deliberately-down from wrong socket/host; never reaped\n' "$role"
    else
      printf 'supervise: %-10s SESSION_UNKNOWN no fwf session visible on the resolved tmux socket at all (floor genuinely down, or supervise cannot see it from this host/socket) -- never reaped\n' "$role"
    fi
  else
    printf 'supervise: %-10s %s\n' "$role" "$verdict"
  fi

  # Lane-stale check (issue #140): "idle while lane has open work" is a
  # DIFFERENT failure than a wedge — the role is genuinely ticking (verdict
  # above says so), it just isn't engaging its own actionable review queue.
  # QA-only here: the impl-side "claim exists, no PR yet" liveness definition
  # belongs to #147, not duplicated here — #140 only requires the two AGREE
  # on using #165's world-derived aliveness, which this does by sharing
  # fwf_wedge_verdict's own verdict as the gate (skip while WEDGED; that
  # failure is already explained). Observation-only — never auto-respawns —
  # because "you have work but haven't acted" is a judgment-level signal for
  # an operator, not the same kind of clear-cut reap WEDGED is.
  #
  # Cost (ticket's own "keep it cheap/conditional" note): exactly ONE
  # `gh pr list` per QA role per supervise pass, always — cheap and
  # unconditional by design (there's no way to know if a lane has open work
  # without asking). The per-PR `fwf-pr-review-state.sh` call (its own small
  # handful of `gh` calls) is the part that's CONDITIONAL: it only runs for
  # PRs that already exist in this QA's own lane, which is normally 0-1 —
  # nowhere near GH rate-limit territory even at a 1-minute supervise
  # cadence across a handful of QA roles.
  case "$role" in
    qa*)
      if [ "$verdict" != "WEDGED" ]; then
        qa_id="${role#qa}"
        lane_count=0
        lane_oldest_age=0
        lane_prs="$(gh pr list --state open --json number,headRefName,isDraft,updatedAt \
          --jq ".[] | select(.headRefName | startswith(\"impl${qa_id}/\")) | select(.isDraft==false) | \"\(.number) \(.updatedAt)\"" 2>/dev/null || true)"
        if [ -n "$lane_prs" ]; then
          while read -r pr_num pr_updated; do
            [ -n "$pr_num" ] || continue
            pr_state="$("$DIR/fwf-pr-review-state.sh" "$pr_num" 2>/dev/null | awk '{print $1}')"
            [ "$pr_state" = "AWAITING_REVIEW" ] || continue
            pr_epoch="$(fwf_iso_to_epoch "$pr_updated" 2>/dev/null || echo "$now")"
            pr_age=$(( now - pr_epoch )); [ "$pr_age" -lt 0 ] && pr_age=0
            lane_count=$(( lane_count + 1 ))
            [ "$pr_age" -gt "$lane_oldest_age" ] && lane_oldest_age="$pr_age"
          done <<< "$lane_prs"
        fi
        qa_interval_secs="$(fwf_interval_seconds "${QA_LOOP_INTERVAL:-1m}" 2>/dev/null || echo 60)"
        lane_verdict="$(fwf_lane_stale_verdict "$lane_count" "$lane_oldest_age" "$qa_interval_secs")"
        if [ "$lane_verdict" = "LANE_STALE" ]; then
          printf 'supervise: %-10s LANE_STALE %s AWAITING_REVIEW PR(s) in lane, oldest untouched %ss (role is otherwise %s) — a role ticking normally but not engaging open review work\n' \
            "$role" "$lane_count" "$lane_oldest_age" "$verdict"
        fi
      fi
      ;;
  esac

  # Worktree freshness watchdog (issue #146): the per-tick auto-refresh lives
  # in the role's OWN template (`fwf worktree-refresh __ROLETAG__`) and is
  # self-reported -- a role that stops ticking, or whose refresh silently
  # fails (network blip, left on a branch), goes stale again with nothing
  # catching it: the identical "silent" the ticket is about. This is the
  # INDEPENDENT check the ticket requires -- the supervisor re-runs the SAME
  # refresh (fwf_worktree_refresh_role, lib.sh) and alarms through this
  # routed channel, not a bare stdout line from the role's own script, when
  # the worktree is still not at 0-behind afterward. impl/qa are explicitly
  # OUT of scope (#146) and fall through this case untouched.
  case "$role" in
    pm|gv|captain)
      wt_result="$(fwf_worktree_refresh_role "$role" 2>/dev/null || echo "FETCH_FAILED unknown")"
      wt_state="${wt_result%% *}"
      case "$wt_state" in
        REFRESHED|NO_WORKTREE) : ;;
        SKIPPED_BRANCH|SKIPPED_DIRTY)
          printf 'supervise: %-10s WORKTREE_ANOMALY %s -- a read-only role should never have local branch/uncommitted state\n' \
            "$role" "$wt_result"
          ;;
        *)
          printf 'supervise: %-10s WORKTREE_STALE %s -- refresh attempted and role is still not at 0-behind origin/%s\n' \
            "$role" "$wt_result" "$DEFAULT_BRANCH"
          ;;
      esac
      ;;
  esac

  [ "$verdict" = "WEDGED" ] || continue
  if [ "$autorespawn" = "1" ]; then
    printf 'supervise: %-10s WEDGED -> respawning (FWF_SUPERVISE_AUTORESPAWN=1)\n' "$role"
    "$DIR/fwf-respawn.sh" "$role" || printf 'supervise: %-10s respawn FAILED\n' "$role" >&2
  else
    printf 'supervise: %-10s WEDGED -> log-only (dark); set FWF_SUPERVISE_AUTORESPAWN=1 to reap\n' "$role"
  fi
done
