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

for role in $roles; do
  [ -n "$role" ] || continue
  verdict="$("$DIR/fwf-pane-liveness.sh" "$role")"

  if [ "$verdict" = "UNKNOWN" ]; then
    printf 'supervise: %-10s UNKNOWN (no old-enough baseline yet — will classify on a later call)\n' "$role"
    continue
  fi
  printf 'supervise: %-10s %s\n' "$role" "$verdict"

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

  [ "$verdict" = "WEDGED" ] || continue
  if [ "$autorespawn" = "1" ]; then
    printf 'supervise: %-10s WEDGED -> respawning (FWF_SUPERVISE_AUTORESPAWN=1)\n' "$role"
    "$DIR/fwf-respawn.sh" "$role" || printf 'supervise: %-10s respawn FAILED\n' "$role" >&2
  else
    printf 'supervise: %-10s WEDGED -> log-only (dark); set FWF_SUPERVISE_AUTORESPAWN=1 to reap\n' "$role"
  fi
done
