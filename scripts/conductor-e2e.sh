#!/usr/bin/env bash
# conductor-e2e.sh — the conductor's e2e payload.
#
# WHY THIS EXISTS (issue #385, approved by the operator 2026-08-29):
# the conductor used to re-run the ENTIRE bash suite (~2500 tests) on every
# promotion cycle, on a SHA that ci.yml had already run the same suite against.
# Measured cost: 17-53min per cycle (avg ~36) against a designed 2min cadence,
# with 3 of 7 verdicts coming back STALE because staging moved during the run.
# That is not a slow gate, it is a gate that structurally cannot keep up with
# the floor, so `integration` starves for hours at a time.
#
# issue #409: this used to ALSO consult GitHub's ci.yml verdict (via #303's
# release CI-verdict oracle script) as a second step before falling through
# to the local suite. GitHub CI is now permanently disabled (operator
# notice, ci.yml disabled, release.yml packaging-only) -- with no context
# ever reporting, that consult polled the FULL 1200s timeout on every
# cold-cache cycle before falling through anyway, turning a ~20min cold
# cycle into ~42min. Dropped entirely rather than degraded to a zero-wait
# check: a check against a permanently-disabled CI system has no path to
# ever returning green, so keeping it (even non-blocking) is dead weight
# with no offsetting benefit. Per the operator's own direction: never wait
# on, retrigger, or block on a GitHub run. That oracle script itself is
# untouched -- it's still used elsewhere (release.yml branch-protection
# checks) and still has its own tests; only this caller stops consulting it.
#
# FAIL-SAFE BY CONSTRUCTION, UNCHANGED: the local suite is skipped ONLY on a
# definitive green (exit 0) from fwf-local-ci.sh for THIS EXACT SHA. Pending,
# red, absent, script-missing, LAPSED, INDETERMINATE -- anything else at all
# -- falls through to a local run. This can make the gate faster; it cannot
# make it more permissive.
#
# issue #436: "definitive green" is no longer just "the last run was green" --
# fwf-local-ci.sh verdict now exits 0 only when the SHA is skip-eligible under
# its own two-consecutive-greens-after-a-real-red policy (or UNKNOWN, which is
# also non-zero). This call site is unchanged: the policy is wired entirely
# through the exit code, so a SHA that failed twice still falls through here
# to a real re-run until confirmed, with no logic duplicated in this file.
# Composes with #446 below unmodified: once a fresh run genuinely executes
# and passes in the retry loop, that run IS the validation for this cycle --
# the two-consecutive-greens requirement only gates trusting a CACHED prior
# verdict well enough to skip a run, not a run that just happened for real.
#
# issue #446 AC (2): a LAPSED verdict (the suite passed but a required check,
# e.g. shellcheck, never actually ran -- #443's finding escaped to macOS
# exactly this way) is not treated as a real failure either. It gets a
# bounded number of forced re-runs rather than either extreme: trusting it
# (this ticket's own defect) or retrying it forever (#404's shape: no clean
# run => block => re-run => OOM => block, on a box whose load is the very
# reason the check keeps lapsing). Three total attempts (N=2 forced re-runs
# beyond the first) -- enough for a transient spike to clear, small enough
# that a genuinely loaded box does not spend an hour proving it is loaded.
# If every attempt lapses the same check, this settles on INDETERMINATE --
# named and recorded (fwf-local-ci.sh mark-indeterminate), never silently
# treated as green and never a silent infinite block.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHA="$(git rev-parse HEAD 2>/dev/null)"
FWF_CONDUCTOR_E2E_MAX_ATTEMPTS="${FWF_CONDUCTOR_E2E_MAX_ATTEMPTS:-3}"

# issue #468 AC (1)/(2): SELF-LIMITING, the primary mechanism -- a harness
# run whose owner is gone must not spawn a further retry generation. This
# is what closes the incident directly: fwf-gate.sh runs this script as a
# background child of ITSELF (lib.sh's own process-group comments -- "the
# wrapped command now runs in its OWN process group"), so our $PPID at
# start IS the real owning process. If that owner dies (fwf-gate.sh's own
# tree SIGKILLed by the OOM killer, or the session that spawned it torn
# down), we get reparented to init and $PPID no longer reflects it -- but
# the value captured at start still does, which is why it is read ONCE
# here rather than re-read from $PPID at check time.
#
# Deliberately self-contained (no `source lib.sh`): this script has never
# depended on the profile/config machinery lib.sh pulls in, and pulling
# it in just for one portable helper would make every isolated-copy test
# of this file (there are several) also need to carry lib.sh's own
# dependency tree along. `_ce2e_ps_elapsed_secs` below is a copy of
# lib.sh's `_fwf_ps_elapsed_secs` (issue #332: `ps -o etime=`, portable
# across GNU/BSD, unlike the GNU-only `etimes`) -- keep the two in sync if
# either changes.
_ce2e_ps_elapsed_secs() { # $1=pid
  local et d h m sec
  et="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$et" ] || return 0
  case "$et" in *-*) d="${et%%-*}"; et="${et#*-}";; *) d=0;; esac
  case "$et" in
    *:*:*) h="${et%%:*}"; et="${et#*:}"; m="${et%%:*}"; sec="${et##*:}";;
    *:*)   h=0;           m="${et%%:*}"; sec="${et##*:}";;
    *)     return 0;;
  esac
  case "$d$h$m$sec" in *[!0-9]*) return 0;; esac
  printf '%s' "$(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$sec ))"
}
#
# Corroborated against PID reuse (issue #195's own guard, reused here):
# the SAME owner's elapsed time only ever grows across our own run: a
# SMALLER reading than what we captured at start means some UNRELATED
# process has since taken that PID number, not that our real owner is
# still there. An unreadable elapsed time (either time) is INDETERMINATE,
# not proof of reuse -- this check fails OPEN, matching this repo's
# anti-stall posture for a checkpoint that only refuses ourselves (the
# DESTRUCTIVE reaper in fwf-reap-orphans.sh is where fail-closed belongs;
# a false refusal here is nearly free -- the next conductor cycle just
# retries -- while a false kill there is not).
_FWF_CE2E_OWNER_PID="$PPID"
_FWF_CE2E_OWNER_ELAPSED0="$(_ce2e_ps_elapsed_secs "$_FWF_CE2E_OWNER_PID" 2>/dev/null || true)"
_fwf_ce2e_owner_alive() {
  [ -n "$_FWF_CE2E_OWNER_PID" ] && [ "$_FWF_CE2E_OWNER_PID" -gt 1 ] 2>/dev/null || return 1
  kill -0 "$_FWF_CE2E_OWNER_PID" 2>/dev/null || return 1
  if [ -n "$_FWF_CE2E_OWNER_ELAPSED0" ]; then
    local now_elapsed
    now_elapsed="$(_ce2e_ps_elapsed_secs "$_FWF_CE2E_OWNER_PID" 2>/dev/null || true)"
    if [ -n "$now_elapsed" ] && [ "$now_elapsed" -lt "$_FWF_CE2E_OWNER_ELAPSED0" ]; then
      return 1
    fi
  fi
  return 0
}
_fwf_ce2e_refuse_generation() {
  echo "conductor-e2e: owning process (pid $_FWF_CE2E_OWNER_PID) is gone -- refusing to spawn a further retry generation (issue #468). This run's own tick is orphaned; exiting rather than looping unbounded." >&2
  exit 1
}
_fwf_ce2e_owner_alive || _fwf_ce2e_refuse_generation

# LOCAL CI FIRST (operator direction 2026-08-29): the box has 332G free, 17G
# RAM and 12 cores, so a suite we already ran here is the fastest and most
# reliable oracle available -- GitHub evicted 5 jobs today and had not even
# STARTED on the staging tip when this was written. Not a self-hosted Actions
# runner: this repo is PUBLIC, and a registered runner would execute fork-PR
# code on a box holding the factory OAuth token, tailnet and SSH keys.
LOCAL="$DIR/fwf-local-ci.sh"

if [ -z "$SHA" ] || [ ! -x "$LOCAL" ]; then
  exec bash test/run.sh
fi

# issue #457: back off entirely (no suite run at all this cycle) once the
# CROSS-INVOCATION lapse streak (fwf-local-ci.sh lapse-streak, #446 AC 3 --
# consecutive lapses across ALL runs on this box, reset the moment any run
# actually executes the check) shows this is not a transient spike but a
# box that structurally cannot give the check room to run. The bounded
# retry loop below only bounds ONE invocation's own attempts; without this,
# every ~2min conductor tick independently re-ran the SAME 3-attempt cycle
# and rediscovered the same exhaustion -- observed: 78 minutes, 4 full
# suites, zero verdict advance. Once backed off, still PROBES once per
# cooldown window (never a permanent block) so recovery is still detected
# automatically the moment the box actually has room again.
# issue #457 AC (3) ("consider" -- not a hard requirement, and not built
# here): reserving RAM more aggressively for a retried lapse, or running
# the lapsed check alone once the rest of the suite is green, would both
# shrink the cost of the retries this backoff already bounds. Deliberately
# out of scope for this ticket -- AC (3) itself only asks that it be
# considered, and the backoff above already removes the actual harm (a
# box wasting ~70min/cycle) without needing either. Worth a follow-up if
# the backoff's own cooldown proves too coarse in practice.
FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_STREAK="${FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_STREAK:-6}"
FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_COOLDOWN="${FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_COOLDOWN:-900}"
streak="$("$LOCAL" lapse-streak 2>/dev/null || echo 0)"
case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
if [ "$streak" -ge "$FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_STREAK" ]; then
  if cd_out="$("$LOCAL" indeterminate-recent "$SHA" "$FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_COOLDOWN" 2>&1)"; then
    echo "conductor-e2e: lint gate has lapsed $streak consecutive times (>= $FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_STREAK) -- $SHA is $cd_out, backing off rather than spending another full attempt cycle (issue #457)" >&2
    exit 1
  fi
  echo "conductor-e2e: lint gate has lapsed $streak consecutive times (>= $FWF_CONDUCTOR_E2E_LAPSE_BACKOFF_STREAK) -- probing once (cooldown expired, or this SHA not yet marked) before backing off again" >&2
fi

attempt=1
while [ "$attempt" -le "$FWF_CONDUCTOR_E2E_MAX_ATTEMPTS" ]; do
  if out="$("$LOCAL" verdict "$SHA" 2>&1)"; then
    echo "conductor-e2e: local CI already GREEN for $SHA — skipping the re-run (#385)"
    echo "$out"
    exit 0
  fi
  echo "conductor-e2e: no usable green cached for $SHA (attempt $attempt/$FWF_CONDUCTOR_E2E_MAX_ATTEMPTS) — running locally"
  printf '%s\n' "$out"

  # nothing cached (or the cached verdict wasn't a real green) -- run the
  # suite here and RECORD the result, so the next consult (this role's next
  # cycle, or any other role on this box) is a cache hit instead of another
  # full re-run. This is what makes local CI the DEFAULT rather than an
  # opportunistic shortcut.
  run_out="$("$LOCAL" run 2>&1)"; run_rc=$?
  printf '%s\n' "$run_out"
  [ "$run_rc" -eq 0 ] && exit 0   # a genuine, non-lapsed green

  # issue #446 AC (2): only a LAPSE retries. A real red/truncated is a
  # terminal result and must stop the loop here, never be masked by trying
  # again -- retrying a genuine failure is exactly the permissiveness this
  # gate must not gain.
  if ! printf '%s\n' "$run_out" | grep -q "LAPSED"; then
    exit "$run_rc"
  fi
  # issue #468 AC (1): re-check before EVERY further generation, not just
  # once at start -- a single full "$LOCAL" run above is exactly the
  # ~22min unit the incident measured, so the owner can die at any point
  # during it, not only before the loop began.
  _fwf_ce2e_owner_alive || _fwf_ce2e_refuse_generation
  attempt=$((attempt + 1))
done

echo "conductor-e2e: the lint gate lapsed on every one of $FWF_CONDUCTOR_E2E_MAX_ATTEMPTS attempts for $SHA — INDETERMINATE, not green (issue #446 AC 2)" >&2
"$LOCAL" mark-indeterminate "$SHA" "lint gate lapsed $FWF_CONDUCTOR_E2E_MAX_ATTEMPTS/$FWF_CONDUCTOR_E2E_MAX_ATTEMPTS attempts" >&2
exit 1
