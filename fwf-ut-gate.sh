#!/usr/bin/env bash
# Conductor-triggered pre-promotion UX gate (issue #46). Spins up a quick
# user-testing trial (#42/#47) against the staged build, under an isolated
# tmux socket, and reports whether any BLOCKER-severity findings should hold
# promotion. Invoked by the conductor between a green e2e and the ff-merge
# into integration (templates/dev/conductor.tmpl, __UT_GATE_CMD__) — never
# called directly by a human.
#
# Usage: FWF_PROFILE=<profile> fwf-ut-gate.sh
# (run from the conductor's own worktree, already on the staged, e2e-green commit)
#
# Exit codes:
#   0 = SKIPPED  — not configured / disabled / no UI-touching diff / daily cap
#                  hit. Promotion proceeds exactly as if this script didn't exist.
#   2 = RAN, clean — no blocker findings. Promotion proceeds; attach the
#                    printed report path to the promotion note for review.
#   3 = RAN, BLOCKER(s) found — do NOT promote; surface the printed report
#                                path for a human call.
#   4 = RAN, but the trial infra failed (app never came up, or provisioning/
#       launch failed) — fail OPEN: promotion proceeds, but log loudly so a
#       human can look at the gate itself.
# On exit 2/3/4 the findings-report.md path is the LAST line on stdout.
set -uo pipefail   # deliberately not -e: every stage must still reach cleanup
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
log() { printf '[fwf-ut-gate %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

if ! fwf_ut_gate_configured; then
  log "skip: $(fwf_ut_gate_skip_reason)"
  exit 0
fi

DIFF_PATHS="$(git diff --name-only "origin/$INTEGRATION_BRANCH..origin/$STAGING_BRANCH" 2>/dev/null || true)"
if ! printf '%s\n' "$DIFF_PATHS" | fwf_ut_gate_diff_triggered; then
  log "skip: staged batch does not touch UI (UT_GATE_UI_GLOB='$UT_GATE_UI_GLOB')"
  exit 0
fi

if ! fwf_ut_gate_budget_ok; then
  log "skip: daily UX-gate budget exhausted (cap=${FWF_UT_GATE_DAILY_CAP} trial(s)/day — see $UT_GATE_BUDGET_FILE)"
  exit 0
fi
fwf_ut_gate_budget_bump
log "UI-touching batch + budget available — running the UX gate (profile=$UT_GATE_PROFILE)"

# Boot a throwaway instance of the STAGED build. Contract (documented in
# profiles/example.sh): UT_GATE_APP_CMD prints ONLY its URL as the first
# stdout line once ready, then keeps running in the foreground until killed.
APP_OUT="$(mktemp "${TMPDIR:-/tmp}/fwf-ut-gate-app-out.XXXXXX")"
APP_ERR="$(mktemp "${TMPDIR:-/tmp}/fwf-ut-gate-app-err.XXXXXX")"
APP_PID=""
cleanup_app() {
  [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }
  rm -f "$APP_OUT" "$APP_ERR"
}
# shellcheck disable=SC2086,SC2261  # UT_GATE_APP_CMD is an operator-authored command line, intentionally word-split via eval
eval "$UT_GATE_APP_CMD" >"$APP_OUT" 2>"$APP_ERR" &
APP_PID=$!
APP_URL=""
i=0
while [ "$i" -lt 60 ]; do
  APP_URL="$(head -n1 "$APP_OUT" 2>/dev/null || true)"
  [ -n "$APP_URL" ] && break
  sleep 1
  i=$((i + 1))
done
if [ -z "$APP_URL" ]; then
  log "FAIL-OPEN: UT_GATE_APP_CMD produced no URL within 60s (stderr: $(tail -n3 "$APP_ERR" 2>/dev/null | tr '\n' ' ')) — skipping the gate, promotion proceeds unblocked."
  cleanup_app
  exit 4
fi
log "staged build serving at $APP_URL"

mkdir -p "$FWF_RUN"
GATE_RUN_DIR="$(mktemp -d "$FWF_RUN/ut-gate.XXXXXX")"
# FULLY isolated run state for the nested trial — NOT just the tmux socket.
# fwf-stop.sh drops its STOP sentinel at the single, profile-agnostic
# $FWF_RUN/STOP path (config.sh) that EVERY role in the OUTER factory
# (including this conductor) checks each cycle — calling it here would
# broadcast a shutdown to the whole live factory, not just this trial. So the
# nested trial gets its own FWF_RUN_DIR (STOP file, e2e.lock, ut/ findings
# root, everything) and is torn down with a bare kill, never fwf-stop.sh.
GATE_FWF_RUN="$GATE_RUN_DIR/run"
mkdir -p "$GATE_FWF_RUN"
# Isolated tmux socket (the docs/user-testing.md trial-isolation pattern) so
# this nested factory can never disturb the conductor's own tmux server.
export TMUX_TMPDIR="$GATE_RUN_DIR/tmux"
mkdir -p "$TMUX_TMPDIR"

cleanup_trial() {
  FWF_PROFILE="$UT_GATE_PROFILE" FWF_RUN_DIR="$GATE_FWF_RUN" "$DIR/fwf-down.sh" --purge >/dev/null 2>&1 || true
  tmux -S "$TMUX_TMPDIR/default" kill-server >/dev/null 2>&1 || true
  cleanup_app
  rm -rf "$GATE_RUN_DIR"
}
trap cleanup_trial EXIT

# Force the quick gate (~25min, archetypes 1-3): UT_GATE_TIMEOUT below is
# sized for it, and a deep sweep would blow the budget this gate is meant to
# bound. FWF_UT_MODE is deliberately NOT inherited from the caller's env.
if ! FWF_PROFILE="$UT_GATE_PROFILE" FWF_RUN_DIR="$GATE_FWF_RUN" FWF_UT_APP_URL="$APP_URL" FWF_UT_MODE=quick "$DIR/fwf-provision.sh" >&2; then
  log "FAIL-OPEN: nested trial provisioning failed — skipping the gate, promotion proceeds unblocked."
  exit 4
fi
if ! FWF_PROFILE="$UT_GATE_PROFILE" FWF_RUN_DIR="$GATE_FWF_RUN" FWF_UT_APP_URL="$APP_URL" FWF_UT_MODE=quick "$DIR/fwf-up.sh" >&2; then
  log "FAIL-OPEN: nested trial launch failed — skipping the gate, promotion proceeds unblocked."
  exit 4
fi

log "trial live — letting it run up to ${UT_GATE_TIMEOUT}s (the personas/researcher loop on their own cron ticks; this script just waits)"
sleep "$UT_GATE_TIMEOUT"
# No graceful fwf-stop.sh here (see the STOP-sentinel note above) — the
# researcher rewrites findings-report.md from diaries every loop tick
# regardless, so the report on disk is already current; teardown is a
# straight kill via fwf-down.sh in cleanup_trial (trap, runs after we read it).

REPORT="$GATE_FWF_RUN/ut/$UT_GATE_PROFILE/findings-report.md"
read -r BLOCKERS TOTAL <<EOF
$(fwf_ut_gate_parse_findings "$REPORT")
EOF
log "trial complete: $BLOCKERS blocker(s), $TOTAL total finding(s) — report at $REPORT"
printf '%s\n' "$REPORT"
[ "$BLOCKERS" -gt 0 ] && exit 3
exit 2
