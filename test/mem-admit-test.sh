#!/usr/bin/env bash
# Standalone test for the issue #156 build-serialization mechanism:
#   - fwf_free_ram_gb            (ground-truth free-RAM probe)
#   - fwf_mem_admit / _release   (measure+reserve admission, strategy b)
#   - _fwf_mem_admit_reap        (dead-holder reap + orphaned-build-tree kill)
#   - fwf-gate.sh pgleader       (hole #1: a kill takes cargo down WITH the gate)
#
# Runs on a plain Mac (or Linux) with NO multi-agent factory, NO tmux, NO cargo,
# NO network. Builds throwaway state under a tmpdir; touches nothing real.
# What it CANNOT prove here, and needs the real box for, is documented in
# docs/proposals/156-build-serialization.md (the reservation NUMBERS / peaks).
#
# Usage: test/mem-admit-test.sh   (exits non-zero on any failure)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fwf-mem-admit.XXXXXX")"
export FWF_RUN_DIR="$TMP/run"
export FWF_PROFILE=example
PASS=0; FAIL=0
STRAYS=()
cleanup() {
  local p
  for p in ${STRAYS[@]+"${STRAYS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

echo "== fwf_free_ram_gb =="
FREE="$(fwf_free_ram_gb)"
case "$FREE" in
  ''|*[!0-9]*) bad "fwf_free_ram_gb returns a non-negative integer" "got [$FREE]";;
  *) ok "fwf_free_ram_gb returns a non-negative integer ($FREE GiB)";;
esac
# issue #404: "sees SOME free RAM" (a bare >0 check) used to be asserted
# here too, and it is the wrong shape -- 0 is a perfectly legitimate,
# correctly-measured reading at a genuine momentary low, not a sensor
# defect (a concurrent shellcheck run on this box can transiently drive
# free RAM toward 0). The non-negative-integer check above already covers
# "the sensor returns a real number, never UNKNOWN-as-fabricated-0"; a
# second assertion demanding that number be strictly positive adds no
# correctness value and only adds a live-host flake. Dropped rather than
# pinned via the FWF_FREE_RAM_GB_OVERRIDE seam (lib.sh) precisely because
# this section is testing the REAL platform probe against the REAL box --
# overriding it here would defeat the point.

echo "== admission at the SHIPPED (unmodified) defaults — issue #286 AC (d) =="
# No threshold overrides above this point: FWF_MEM_ADMIT_FLOOR_GB and
# FWF_MEM_RESERVE_BUILD_GB are still exactly what config.sh ships. Every
# OTHER admission test in this file deliberately substitutes its own
# thresholds (FLOOR_GB=0, RESERVE_BUILD_GB=999999, etc.) to force a
# deterministic result regardless of box size — which is EXACTLY why a bad
# shipped default (issue #286: FWF_MEM_ADMIT_ENABLE flipped to 1 with no
# real-box calibration) was invisible to every one of them. This is the one
# assertion in this file that isn't: it reads the real config.sh values and
# states the box size the verdict depends on, so a wrong default shows up
# here even when every synthetic-threshold test above stays green.
#
# Bounded wait/poll cadence only (NOT floor/reserve — those stay shipped),
# so this test is fast on either branch rather than reproducing #286's own
# 900s stall if this box happens to refuse.
SHIPPED_NEED=$(( FWF_MEM_RESERVE_BUILD_GB + FWF_MEM_ADMIT_FLOOR_GB ))
# issue #404: FREE is re-measured HERE, immediately before the admission
# call it's compared against, rather than reusing the one sampled ~30 lines
# above at the top of the file. fwf_mem_admit takes its own internal
# reading to decide, so a stale FREE from long before that call is a TOCTOU
# race against whatever else is using RAM on this box in between (a
# concurrent shellcheck run can move it meaningfully in that window) --
# this assertion is deliberately reading the REAL box (see the comment
# above), so the fix is narrowing the gap between measurement and decision
# to near-zero, not pinning a synthetic value.
FREE="$(fwf_free_ram_gb)"
echo "   shipped: floor=${FWF_MEM_ADMIT_FLOOR_GB}GiB reserve=${FWF_MEM_RESERVE_BUILD_GB}GiB -> a single --cargo-build holder needs >= ${SHIPPED_NEED}GiB free; this box measured ${FREE}GiB"
T_SHIPPED="$(FWF_MEM_ADMIT_TIMEOUT=5 FWF_MEM_ADMIT_POLL=1 fwf_mem_admit implshipped "$FWF_MEM_RESERVE_BUILD_GB" 2>/dev/null)"; R_SHIPPED=$?
case "$FREE" in
  ''|*[!0-9]*) bad "SHIPPED-defaults admission decision is checkable on this box" "fwf_free_ram_gb returned [$FREE], cannot state a box size";;
  *)
    if [ "$FREE" -ge "$SHIPPED_NEED" ]; then
      [ "$R_SHIPPED" = 0 ] && [ -n "$T_SHIPPED" ] \
        && ok "a --cargo-build holder IS admitted at the SHIPPED defaults on this ${FREE}GiB box (needs ${SHIPPED_NEED}GiB)" \
        || bad "a --cargo-build holder is admitted at the SHIPPED defaults on this ${FREE}GiB box (needs ${SHIPPED_NEED}GiB)" "rc=$R_SHIPPED token=[$T_SHIPPED]"
      fwf_mem_admit_release "$T_SHIPPED"
    else
      [ "$R_SHIPPED" = 1 ] && [ -z "$T_SHIPPED" ] \
        && ok "this ${FREE}GiB box correctly REFUSES a --cargo-build holder at the SHIPPED defaults (needs ${SHIPPED_NEED}GiB) -- not silently granted" \
        || bad "this ${FREE}GiB box correctly refuses admission at the SHIPPED defaults (needs ${SHIPPED_NEED}GiB)" "rc=$R_SHIPPED token=[$T_SHIPPED]"
    fi
    ;;
esac

echo "== fwf_free_ram_gb / fwf_mem_admit: an UNREADABLE probe reports UNKNOWN, never a fabricated 0GiB — issue #286 AC (f) =="
# Shadow the probe to simulate every unreadable-probe path at once (Darwin
# hw.pagesize, Darwin vm_stat, Linux /proc/meminfo all collapse to this same
# UNKNOWN contract from fwf_mem_admit's side). (f3): this must go RED if the
# UNKNOWN/measured-zero distinction is removed -- both direct assertions
# below fail if fwf_mem_admit's messages go back to reporting "free 0GiB"
# for an unreadable probe.
fwf_free_ram_gb() { echo UNKNOWN; }
UNKNOWN_OUT="$(FWF_MEM_ADMIT_TIMEOUT=2 FWF_MEM_ADMIT_POLL=1 FWF_MEM_ADMIT_FLOOR_GB=8 FWF_MEM_RESERVE_BUILD_GB=6 fwf_mem_admit implunknown 6 2>&1 >/dev/null)"
UNKNOWN_RC=$?
# (f) edge case, stated: UNKNOWN is not "admit unconditionally" -- a
# genuinely empty box must still be refused, and an unmeasurable one is
# refused the same way (distinguishable in the MESSAGE, not the decision).
[ "$UNKNOWN_RC" = 1 ] && ok "an unreadable free-RAM probe REFUSES admission (rc=1), never admits unconditionally" \
  || bad "an unreadable free-RAM probe refuses admission" "rc=$UNKNOWN_RC"
case "$UNKNOWN_OUT" in
  *"free UNKNOWN"*) ok "the refusal message says UNKNOWN, not a fabricated '0GiB' reading" ;;
  *) bad "the refusal message says UNKNOWN, not a fabricated 0GiB reading" "got: $UNKNOWN_OUT" ;;
esac
case "$UNKNOWN_OUT" in
  *"free 0GiB"*) bad "(f3) the message must NOT claim a measured '0GiB' for an unreadable probe" "got: $UNKNOWN_OUT" ;;
  *) ok "(f3) the message never claims a measured 0GiB for an unreadable probe" ;;
esac
# Restore the real platform probe for every test below.
unset -f fwf_free_ram_gb
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

echo "== admission: grant, reserve-sum, release =="
# Floor 0 and a tiny reserve so admission always succeeds regardless of the box.
export FWF_MEM_ADMIT_FLOOR_GB=0
T1="$(FWF_MEM_RESERVE_BUILD_GB=1 fwf_mem_admit implA 1)"; R1=$?
[ "$R1" = 0 ] && [ -n "$T1" ] && ok "first admit granted, returned a token ($T1)" \
  || bad "first admit granted, returned a token" "rc=$R1 token=[$T1]"
[ -f "$MEM_ADMIT/$T1" ] && ok "reservation entry written" || bad "reservation entry written" "no $MEM_ADMIT/$T1"
assert_field() { local got; got="$(_fwf_e2e_owner_field "$2" "$MEM_ADMIT/$1")"; \
  [ "$got" = "$3" ] && ok "reservation $2=$3" || bad "reservation $2=$3" "got [$got]"; }
assert_field "$T1" reserved_gb 1
assert_field "$T1" role implA

T2="$(fwf_mem_admit implB 2)"; R2=$?
[ "$R2" = 0 ] && [ -n "$T2" ] && ok "second admit granted" || bad "second admit granted" "rc=$R2"
SUM="$(_fwf_mem_admit_reserved_sum)"
[ "$SUM" = 3 ] && ok "reserved sum reflects BOTH live reservations (1+2=3)" \
  || bad "reserved sum reflects both live reservations" "got [$SUM]"

echo "== admission: denial when reserve exceeds free-minus-reserved (TOCTOU floor) =="
# A reserve larger than any box has free must be DENIED, promptly (short timeout),
# never granted — this is the guarantee that prevents oversubscription.
DENY="$(FWF_MEM_ADMIT_TIMEOUT=1 FWF_MEM_ADMIT_POLL=1 fwf_mem_admit implC 999999 2>/dev/null)"; RD=$?
[ "$RD" = 1 ] && [ -z "$DENY" ] && ok "impossible reserve is DENIED (rc=1), not granted" \
  || bad "impossible reserve is denied" "rc=$RD token=[$DENY]"

fwf_mem_admit_release "$T1"; fwf_mem_admit_release "$T2"
[ ! -f "$MEM_ADMIT/$T1" ] && [ ! -f "$MEM_ADMIT/$T2" ] && ok "release removes both reservation entries" \
  || bad "release removes both reservation entries"
[ "$(_fwf_mem_admit_reserved_sum)" = 0 ] && ok "reserved sum back to 0 after release" \
  || bad "reserved sum back to 0 after release"

echo "== reap: dead holder dropped, live holder kept =="
mkdir -p "$MEM_ADMIT"
# a LIVE reservation (this test's own pid) must survive a reap
printf 'role=live\npid=%s\npgid=%s\npgleader=0\nhost=%s\nreserved_gb=4\nacquired=%s\n' \
  "$$" "$$" "$(hostname)" "$(date +%s)" > "$MEM_ADMIT/res-live"
# a DEAD reservation (an impossible pid) must be reaped
printf 'role=dead\npid=999999999\npgid=999999999\npgleader=0\nhost=%s\nreserved_gb=4\nacquired=%s\n' \
  "$(hostname)" "$(( $(date +%s) - 10 ))" > "$MEM_ADMIT/res-dead"
_fwf_mem_admit_reap
[ -f "$MEM_ADMIT/res-live" ] && ok "reap keeps a LIVE same-host reservation" \
  || bad "reap keeps a live same-host reservation"
[ ! -f "$MEM_ADMIT/res-dead" ] && ok "reap drops a DEAD reservation" \
  || bad "reap drops a dead reservation"
rm -f "$MEM_ADMIT/res-live"

echo "== reap: hole #1 — a dead pgleader's orphaned build tree is SIGKILLed =="
# Build a real process group: a perl leader forks a child (the stand-in for
# cargo), prints "leaderpid childpid", then the LEADER EXITS — orphaning the
# child but leaving it in process group = leaderpid. leaderpid is now a dead
# pid, exactly the SIGKILL-orphan scenario (respawn-pane -k killed the gate,
# cargo kept building in the leaderless group).
PG_OUT="$(perl -e '
  use POSIX qw(setpgid);
  setpgid(0,0) or die "setpgid: $!";
  $|=1;
  my $pid = fork();
  if ($pid == 0) {
    # Detach the child from the command-substitution pipe, or $() blocks until
    # the child (our orphaned build stand-in) exits — and reparent stdio so it
    # keeps running quietly after the leader exits.
    open(STDIN,  "<", "/dev/null");
    open(STDOUT, ">", "/dev/null");
    open(STDERR, ">", "/dev/null");
    exec "sleep", "120";
    die "exec: $!";
  }
  print "$$ $pid\n";
')"
LEADER_PID="${PG_OUT%% *}"; CHILD_PID="${PG_OUT##* }"
STRAYS+=("$CHILD_PID")
# ensure the leader has actually exited (dead pid) before we reap
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$LEADER_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CHILD_PID" 2>/dev/null && ok "orphaned build stand-in is alive before reap (pid $CHILD_PID)" \
  || bad "orphaned build stand-in is alive before reap" "pid $CHILD_PID already gone"
printf 'role=orphaned\npid=%s\npgid=%s\npgleader=1\nhost=%s\nreserved_gb=4\nacquired=%s\n' \
  "$LEADER_PID" "$LEADER_PID" "$(hostname)" "$(( $(date +%s) - 10 ))" > "$MEM_ADMIT/res-orphan"
_fwf_mem_admit_reap
[ ! -f "$MEM_ADMIT/res-orphan" ] && ok "reap drops the dead pgleader reservation" \
  || bad "reap drops the dead pgleader reservation"
GONE=0
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CHILD_PID" 2>/dev/null || { GONE=1; break; }; sleep 0.2; done
[ "$GONE" = 1 ] && ok "hole #1: the orphaned build tree was SIGKILLed by the reap (pid $CHILD_PID gone)" \
  || bad "hole #1: orphaned build tree SIGKILLed by reap" "pid $CHILD_PID still alive"

echo "== reap safety: a non-pgleader reservation's group is NOT signalled =="
# guard check: _fwf_mem_admit_kill_group must refuse when pgleader != 1, when the
# pgid is our OWN group, when it's 1, and when it's non-integer.
OWNPGID="$(ps -o pgid= -p $$ | tr -d ' ')"
_fwf_mem_admit_kill_group "$(hostname)" 0 "$OWNPGID" 2>/dev/null; ok "kill_group is a no-op for pgleader=0"
_fwf_mem_admit_kill_group "$(hostname)" 1 "$OWNPGID" 2>/dev/null; ok "kill_group refuses to signal our OWN group"
_fwf_mem_admit_kill_group "$(hostname)" 1 1        2>/dev/null; ok "kill_group refuses pgid 1"
_fwf_mem_admit_kill_group "$(hostname)" 1 notanint 2>/dev/null; ok "kill_group refuses a non-integer pgid"
# (these four are guard-verifications: each returns 0 without killing anything,
# proving the fail-safe conditions that stop it hitting an unrelated pane shell.)

echo "== fwf-gate.sh: it becomes a process-group leader (pgid == pid) =="
# Wrap a command that records the GATE's own pid and pgid, then exits fast.
PGF="$TMP/gate-pgid.txt"
FWF_GATE_PGLEADER_ENABLE=1 "$ROOT/fwf-gate.sh" pgcheck -- \
  bash -c 'echo "$PPID $(ps -o pgid= -p $PPID | tr -d " ")" > "'"$PGF"'"' >/dev/null 2>&1
if [ -f "$PGF" ]; then
  GATEPID="$(cut -d' ' -f1 "$PGF")"; GATEPGID="$(cut -d' ' -f2 "$PGF")"
  [ -n "$GATEPID" ] && [ "$GATEPID" = "$GATEPGID" ] \
    && ok "the gate process is a process-group leader (pid $GATEPID == pgid $GATEPGID)" \
    || bad "the gate process is a process-group leader" "pid=$GATEPID pgid=$GATEPGID"
else
  bad "the gate process is a process-group leader" "gate never wrote $PGF"
fi

echo "== fwf-gate.sh: hole #1 — a trappable kill takes the wrapped child down WITH the gate =="
# The wrapped command backgrounds a long sleep (cargo stand-in) and records its
# pid, then waits. We signal the whole GROUP (negative pid) so the trap fires
# without bash deferring it behind the foreground `wait`; the trap must release
# and reap the group so the sleep dies too — never orphaned.
SLEEPPIDF="$TMP/gate-sleep.pid"
FWF_GATE_PGLEADER_ENABLE=1 "$ROOT/fwf-gate.sh" pgkill -- \
  bash -c 'sleep 120 & echo $! > "'"$SLEEPPIDF"'"; wait' >/dev/null 2>&1 &
GATE_BG_PID=$!
STRAYS+=("$GATE_BG_PID")
# wait for the wrapped sleep to register
for _ in $(seq 1 25); do [ -s "$SLEEPPIDF" ] && break; sleep 0.2; done
if [ -s "$SLEEPPIDF" ]; then
  SLEEPPID="$(cat "$SLEEPPIDF")"; STRAYS+=("$SLEEPPID")
  kill -0 "$SLEEPPID" 2>/dev/null && ok "wrapped build stand-in is running (pid $SLEEPPID)" \
    || bad "wrapped build stand-in is running" "pid $SLEEPPID not alive"
  # signal the gate's process group -> trap releases + kills the group
  GATE_PGID="$(ps -o pgid= -p "$GATE_BG_PID" 2>/dev/null | tr -d ' ')"
  if [ -n "$GATE_PGID" ]; then kill -TERM -"$GATE_PGID" 2>/dev/null; else kill -TERM "$GATE_BG_PID" 2>/dev/null; fi
  wait "$GATE_BG_PID" 2>/dev/null
  DEAD=0
  for _ in $(seq 1 25); do kill -0 "$SLEEPPID" 2>/dev/null || { DEAD=1; break; }; sleep 0.2; done
  [ "$DEAD" = 1 ] && ok "hole #1: killing the gate took the wrapped build down too (pid $SLEEPPID gone, not orphaned)" \
    || bad "hole #1: killing the gate took the wrapped build down too" "pid $SLEEPPID still alive — ORPHANED"
else
  bad "hole #1 gate kill test" "wrapped command never registered its pid"
fi

echo "== DEFAULT #138 path (BLOCKER 1): the SLOT reaper is tree-aware — a dead pgleader's orphan is SIGKILLed, no 2nd build stacks =="
# This is the FATAL default-path fix: with FWF_MEM_ADMIT_ENABLE=0 the cargo-build
# SEMAPHORE reaper runs, NOT the admission reaper. Prove it now group-kills an
# orphaned build tree before freeing the slot (previously tree-blind → the next
# gate stacked a 2nd build on the still-running orphan). Same orphan construction
# as the admission-path test, driven through fwf_cargo_build_slot_acquire.
PG2="$(perl -e '
  use POSIX qw(setpgid);
  setpgid(0,0) or die "setpgid: $!";
  $|=1;
  my $pid = fork();
  if ($pid == 0) {
    open(STDIN,  "<", "/dev/null");
    open(STDOUT, ">", "/dev/null");
    open(STDERR, ">", "/dev/null");
    exec "sleep", "120";
    die "exec: $!";
  }
  print "$$ $pid\n";
')"
L2="${PG2%% *}"; C2="${PG2##* }"
STRAYS+=("$C2")
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$L2" 2>/dev/null || break; sleep 0.2; done
kill -0 "$C2" 2>/dev/null && ok "default-path orphan stand-in alive before reap (pid $C2)" \
  || bad "default-path orphan stand-in alive before reap" "pid $C2 already gone"
# Stamp a dead-pgleader slot owner exactly as fwf_cargo_build_slot_acquire writes it now.
mkdir -p "$CARGO_BUILD_LOCK/slot-1"
printf 'role=orphaned\npid=%s\npgid=%s\npgleader=1\nhost=%s\nworktree=%s\nacquired=%s\n' \
  "$L2" "$L2" "$(hostname)" "$PWD" "$(( $(date +%s) - 10 ))" > "$CARGO_BUILD_LOCK/slot-1/owner"
# A fresh acquirer (concurrency 1) must reap the dead slot AND take the orphan
# tree down BEFORE it is granted the freed slot.
GOT="$(FWF_CARGO_BUILD_CONCURRENCY=1 FWF_CARGO_BUILD_LOCK_TIMEOUT=5 FWF_CARGO_BUILD_LOCK_POLL=1 fwf_cargo_build_slot_acquire freshbuild)"; RG=$?
[ "$RG" = 0 ] && [ "$GOT" = 1 ] && ok "default path: fresh acquirer reaps the dead slot and is granted it" \
  || bad "default path: fresh acquirer reaps the dead slot and is granted it" "rc=$RG slot=[$GOT]"
GONE2=0
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$C2" 2>/dev/null || { GONE2=1; break; }; sleep 0.2; done
[ "$GONE2" = 1 ] && ok "BLOCKER 1: the SLOT reaper SIGKILLed the orphaned build tree (pid $C2 gone — no 2nd build stacks on it)" \
  || bad "BLOCKER 1: the SLOT reaper SIGKILLed the orphaned build tree" "pid $C2 still alive — a 2nd build would stack on the orphan"
fwf_cargo_build_slot_release 1
rm -rf "$CARGO_BUILD_LOCK/slot-1.reap"

echo "== BLOCKER 1: the DEFAULT-path slot owner now records pgid + pgleader =="
# The reaper can only group-kill if the owner file carries the group. Prove a
# normal acquire stamps them (this test is the pgleader=0 case; that's fine —
# the reaper's fail-safe simply declines to signal a non-pgleader group).
GOT3="$(FWF_CARGO_BUILD_CONCURRENCY=1 fwf_cargo_build_slot_acquire stamped)"; RG3=$?
OWN3="$CARGO_BUILD_LOCK/slot-$GOT3/owner"
if [ "$RG3" = 0 ] && [ -f "$OWN3" ]; then
  P3="$(_fwf_e2e_owner_field pgid "$OWN3")"; PL3="$(_fwf_e2e_owner_field pgleader "$OWN3")"
  case "$P3" in ''|*[!0-9]*) bad "slot owner records an integer pgid" "got [$P3]";; *) ok "slot owner records an integer pgid ($P3)";; esac
  [ -n "$PL3" ] && ok "slot owner records a pgleader field ($PL3)" || bad "slot owner records a pgleader field" "empty"
else
  bad "slot acquire for pgid/pgleader stamp check" "rc=$RG3 slot=[$GOT3]"
fi
fwf_cargo_build_slot_release "$GOT3"

echo "== BLOCKER 3: an OWNERLESS decision mutex is reaped via dir-mtime fallback =="
# A SIGKILL between `mkdir "$mutex"` and the owner write leaves a decision dir
# with NO owner file. Previously the empty ts returned "not stale" forever,
# wedging ALL admissions. The dir-mtime fallback must now reap it.
mkdir -p "$MEM_ADMIT/decision"          # ownerless: deliberately write NO owner file
[ ! -f "$MEM_ADMIT/decision/owner" ] && ok "constructed an ownerless decision mutex (no owner file)" \
  || bad "constructed an ownerless decision mutex"
FWF_MEM_ADMIT_DECISION_STALE_SECS=0 _fwf_mem_admit_reap_mutex
[ ! -d "$MEM_ADMIT/decision" ] && ok "BLOCKER 3: ownerless mutex reaped via dir-mtime fallback (admissions no longer wedged)" \
  || bad "BLOCKER 3: ownerless mutex reaped via dir-mtime fallback" "decision dir still present — admissions wedged forever"
rm -rf "$MEM_ADMIT/decision.reap"

echo "== BLOCKER 2: fwf-gate.sh RELEASES the #123 per-role gate lock across the admission wait =="
# With admission ON and an impossible reserve, fwf_mem_admit blocks (polls). The
# gate must NOT hold its per-role gate lock during that wait, or admission_wait +
# build could cross FWF_GATE_LOCK_MAX_RUN_SECS and the reaper stacks a 2nd gate.
#
# The check must catch the TRUE acquire->release transition, NOT the pre-acquire
# startup window (poll #1 fires before the gate has mkdir'd its lock, so a bare
# first-absent read passes even against a mutant that HOLDS the lock across the
# wait). So drive the gate's stderr to a log and wait until it LOGS that it has
# ENTERED the blocking RAM-admission wait — which happens strictly AFTER it
# acquired and then released the gate lock — and only THEN assert the lock dir is
# absent while the gate is still alive. A mutant that holds the lock across the
# wait still logs the wait but leaves the lock dir PRESENT at that point, so this
# assertion FAILS against it (the old pre-acquire-absent read never could).
LOCKDIR="$(fwf_gate_lock_dir admitwait)"
AWLOG="$TMP/admitwait.log"
FWF_MEM_ADMIT_ENABLE=1 FWF_GATE_PGLEADER_ENABLE=1 \
FWF_MEM_ADMIT_FLOOR_GB=0 FWF_MEM_RESERVE_BUILD_GB=999999 \
FWF_MEM_ADMIT_TIMEOUT=30 FWF_MEM_ADMIT_POLL=1 FWF_MEM_ADMIT_REPORT_SECS=1 \
  "$ROOT/fwf-gate.sh" admitwait --cargo-build -- true >/dev/null 2>"$AWLOG" &
GATE_WAIT_PID=$!
STRAYS+=("$GATE_WAIT_PID")
# Wait until the gate has ENTERED the blocking admission wait (logged "RAM
# admission"), then — only once we KNOW it is past acquire+release — assert the
# lock dir is absent. ENTERED_WAIT stays 0 if it never got there (checked below).
ENTERED_WAIT=0; RELEASED=0
for _ in $(seq 1 50); do
  kill -0 "$GATE_WAIT_PID" 2>/dev/null || break     # exited early (checked below)
  if grep -q "RAM admission" "$AWLOG" 2>/dev/null; then
    ENTERED_WAIT=1
    # Past acquire+release now: an absent lock here is the DURING-WAIT release,
    # not the pre-acquire window — the present->absent transition we require.
    [ -d "$LOCKDIR" ] || RELEASED=1
    break
  fi
  sleep 0.2
done
if kill -0 "$GATE_WAIT_PID" 2>/dev/null && [ "$ENTERED_WAIT" = 1 ] && [ "$RELEASED" = 1 ] && [ ! -d "$LOCKDIR" ]; then
  ok "BLOCKER 2: gate lock is RELEASED while the gate is still alive and waiting on RAM admission"
else
  bad "BLOCKER 2: gate lock released during admission wait" "entered_wait=$ENTERED_WAIT released=$RELEASED gate_alive=$(kill -0 "$GATE_WAIT_PID" 2>/dev/null && echo yes || echo no) lockdir_present=$([ -d "$LOCKDIR" ] && echo yes || echo no)"
fi
# Tear the waiting gate down. It never got admitted, so it has no build child —
# a single-pid SIGKILL suffices (a group kill here risks the test's own group).
kill -KILL "$GATE_WAIT_PID" 2>/dev/null
wait "$GATE_WAIT_PID" 2>/dev/null
rm -rf "$LOCKDIR" "$MEM_ADMIT"

echo "== BLOCKER 2 (DEFAULT #138 path): fwf-gate.sh RELEASES the #123 gate lock across the SLOT-acquire wait =="
# The adversarial-verifier blocker: the release/re-acquire hand-off was applied
# ONLY to the admission path. Prove it now holds on the AS-SHIPPED default path
# (FWF_MEM_ADMIT_ENABLE=0), where fwf_cargo_build_slot_acquire can block up to 900s
# for a slot. If the gate held its per-role gate lock across that wait, slot_wait +
# build could cross FWF_GATE_LOCK_MAX_RUN_SECS and the reaper would stack a 2nd
# gate (a #151-class double-build). Occupy the only slot with a LIVE holder (this
# test's own pid — never reaped) so the gate is forced to WAIT, then assert its
# gate-lock dir is ABSENT while it is still alive and polling.
rm -rf "$CARGO_BUILD_LOCK"
mkdir -p "$CARGO_BUILD_LOCK/slot-1"
printf 'role=occupant\npid=%s\npgid=%s\npgleader=0\nhost=%s\nworktree=%s\nacquired=%s\n' \
  "$$" "$$" "$(hostname)" "$PWD" "$(date +%s)" > "$CARGO_BUILD_LOCK/slot-1/owner"
DLOCKDIR="$(fwf_gate_lock_dir defaultwait)"
DLOG="$TMP/defaultwait.log"
FWF_MEM_ADMIT_ENABLE=0 FWF_GATE_PGLEADER_ENABLE=1 \
FWF_CARGO_BUILD_CONCURRENCY=1 FWF_CARGO_BUILD_LOCK_TIMEOUT=30 FWF_CARGO_BUILD_LOCK_POLL=1 \
  "$ROOT/fwf-gate.sh" defaultwait --cargo-build -- true >/dev/null 2>"$DLOG" &
GATE_DEF_PID=$!
STRAYS+=("$GATE_DEF_PID")
# Same present->absent discipline as the admission check: poll #1 fires during the
# gate's pre-acquire startup window, so a bare first-absent read passes even
# against a mutant that HOLDS the gate lock across fwf_cargo_build_slot_acquire's
# wait. Instead wait until the gate LOGS that it entered the blocking slot wait
# ("waiting for a cargo build slot") — strictly AFTER acquire+release — then
# assert the lock dir is absent while the gate is still alive and polling. A
# lock-holding mutant logs the same wait but leaves the lock PRESENT here → FAIL.
DENTERED=0; DRELEASED=0
for _ in $(seq 1 50); do
  kill -0 "$GATE_DEF_PID" 2>/dev/null || break     # exited early (checked below)
  if grep -q "waiting for a cargo build slot" "$DLOG" 2>/dev/null; then
    DENTERED=1
    [ -d "$DLOCKDIR" ] || DRELEASED=1
    break
  fi
  sleep 0.2
done
if kill -0 "$GATE_DEF_PID" 2>/dev/null && [ "$DENTERED" = 1 ] && [ "$DRELEASED" = 1 ] && [ ! -d "$DLOCKDIR" ]; then
  ok "BLOCKER 2 (default path): gate lock is RELEASED while the gate is still alive and waiting on a cargo build slot"
else
  bad "BLOCKER 2 (default path): gate lock released during slot-acquire wait" "entered_wait=$DENTERED released=$DRELEASED gate_alive=$(kill -0 "$GATE_DEF_PID" 2>/dev/null && echo yes || echo no) lockdir_present=$([ -d "$DLOCKDIR" ] && echo yes || echo no)"
fi
# Tear the waiting gate down. It never got a slot, so it has no build child —
# a single-pid SIGKILL suffices (a group kill here risks the test's own group).
kill -KILL "$GATE_DEF_PID" 2>/dev/null
wait "$GATE_DEF_PID" 2>/dev/null
rm -rf "$DLOCKDIR" "$CARGO_BUILD_LOCK"

echo
echo "mem-admit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
