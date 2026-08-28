#!/usr/bin/env bash
# fwf-gate.sh — the shared guarded-launch helper (issue #123): the ONE
# entrypoint every tick-driven gate/e2e launcher (qa PR re-review gate, impl
# gate, conductor promotion-e2e) routes through, so the gate-pileup's two
# root causes are fixed exactly once, not per-role/per-template:
#
#   (A) per-role single-flight lock (fwf_gate_lock_acquire/release, lib.sh) —
#       a role whose OWN prior gate is still in flight does not launch a
#       second; it skips this tick. Fail-closed: indeterminate liveness also
#       skips, never stacks. A wedged-but-alive holder past the max-run
#       ceiling is reaped as an anomaly (see lib.sh for the reasoning).
#   (B) hermetic gate under CROSS-agent concurrency — with --e2e, additionally
#       takes the existing floor-wide e2e lock (fwf_e2e_lock_acquire/release,
#       issue #65). That lock is the documented serialize-lock FALLBACK for a
#       harness whose ports are fixed and can't be made ephemeral cheaply
#       (profiles/example.sh's E2E_CMD contract). The fast per-commit
#       GATE_CMD path does not take --e2e: it isn't meant to share ports with
#       anything, so floor-wide serialization would only add a throughput
#       bottleneck with no hermeticity benefit.
#
# --cargo-build (issue #138 piece C) additionally bounds how many roles run a
# full cargo build SIMULTANEOUSLY, via a SEMAPHORE — not a mutex like the e2e
# lock: up to FWF_CARGO_BUILD_CONCURRENCY roles hold a build slot at once
# (fwf_cargo_build_slot_acquire/release, lib.sh), so N concurrent full builds
# no longer CPU/IO-thrash each other. Auto-appended by fwf_render whenever a
# profile's GATE_CMD/E2E_CMD contains "cargo" (see lib.sh) — a profile with no
# Rust suite never passes it and pays zero overhead.
#
# Usage: fwf gate <role> [--e2e] [--cargo-build] [--tip-cmd 'CMD'] -- <command> [args...]
#   <role>     the per-role lock key (e.g. impl2, qa2, conductor) — the
#              literal role tag used elsewhere (heartbeat path, etc).
#   --e2e      ALSO take the floor-wide e2e lock. Use for an E2E_CMD-class
#              run; omit for the fast GATE_CMD (see above).
#   --cargo-build  ALSO take a cargo-build concurrency slot (see above).
#   --tip-cmd  Make this gate TIP-triggered, not just timer-triggered (issue
#              #202): CMD is evaluated (via `eval`, in the caller's cwd) to
#              read the value of whatever ref this gate cares about (e.g.
#              `git rev-parse origin/staging`), BEFORE the lock is acquired.
#              If that value matches the last COMPLETED gate's recorded value
#              for this role, the lock is never taken and this run exits
#              EX_SKIPPED — a timer tick that finds nothing new to gate costs
#              nothing. CMD is re-evaluated after the wrapped command exits;
#              if the value moved DURING the run, the verdict is for a
#              superseded tip and must never read as promotable, so this run
#              instead exits EX_STALE (regardless of the wrapped command's own
#              rc) and the run is recorded as stale, not green/red. Otherwise
#              the wrapped command's rc is recorded as this tip's verdict
#              (green/red) so an unchanged tip is skipped on the NEXT tick
#              too. Set FWF_GATE_FORCE=1 to force a re-run of an unchanged tip
#              (the "explicit resume" escape hatch). State lives under
#              fwf_gate_tip_marker_path (lib.sh) — persisted by this script,
#              never by a role's memory.
#   --tip-ancestry  Ruling from issue #202/#254: "the ref changed" is the
#              wrong question — a completed, valid verdict must not be
#              discarded just because the tip moved, ONLY because what was
#              gated is no longer in the promotable history. Requires
#              --tip-cmd, and the two values MUST be commit-ish (this runs
#              `git merge-base --is-ancestor`, so a non-git --tip-cmd value —
#              a content hash, a checksum — makes the ancestry call error,
#              which (below) fails closed to STALE forever; --tip-ancestry is
#              only for a git-ref --tip-cmd). When the tip moved during the
#              run: if the BEFORE value is still an ancestor of the AFTER
#              value (the ordinary case — someone merged on top), the verdict
#              stands and is recorded green/red as the wrapped command
#              returned — newer commits ride the next cycle. If it is NOT an
#              ancestor (force-push, rebase, history rewritten) or ancestry
#              could not be determined (shallow clone, missing objects), this
#              still fails to STALE/76 exactly as without the flag. Without
#              this flag: ANY tip move is STALE regardless of ancestry — the
#              pre-#254 behaviour, kept as the default so an OLD rendered
#              prompt (no flag) degrades to "wasteful but safe", never to
#              "promotes a SHA the gate never fully verdicted". A caller that
#              relaxes this MUST ALSO pin its promote step to the recorded
#              tip's literal hash, never a re-resolved ref (issue #254 AC
#              (d)+(e)) — the ancestry test only makes a fixed ref usable, the
#              literal-hash promote is what actually uses it safely.
#   <command>  exec'd directly via "$@" after the lock(s) are held — no extra
#              shell re-parsing, so a multi-command GATE_CMD string must be
#              passed through `bash -c '...'` by the caller (that's exactly
#              how __GATE__/__E2E__/__PROMOTE_GATE__ render it — see
#              lib.sh's fwf_render).
#
# Exit codes: the wrapped command's own exit code on a real run; 75 (the
# traditional EX_TEMPFAIL) when this tick was SKIPPED — a prior gate for this
# role is still running, a --e2e run found the floor-wide lock busy, a
# --cargo-build run found every build slot busy past its timeout, or
# --tip-cmd found the watched ref unchanged since the last completed gate; 76
# (EX_STALE) when --tip-cmd detected the watched ref moved DURING the run —
# a real result exists but is for a superseded tip and must not be treated as
# promotable. Callers MUST treat 75 as "nothing to report, try again next
# tick" and 76 as "a verdict exists but don't act on it, the next tick will
# gate the new tip" — never as a gate failure; an agent that greps for a
# green/red gate result should check for both exit codes first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- issue #156 hole #1: kill-safe process-group ownership -------------------
# Become a process-group LEADER exactly once (guarded by a sentinel), BEFORE any
# lock/admission work, so the cargo child launched below inherits our group. A
# kill then takes cargo down WITH us — trappable signals via the trap installed
# further down, and an untrappable SIGKILL (tmux `respawn-pane -k`) via the
# memory-admission reaper, which SIGKILLs the stamped group when it drops our
# now-dead reservation. Without this, a killed gate ORPHANS a multi-GB cargo
# (reparented to PID1, still building) while its lock auto-releases, and the
# next agent stacks a SECOND build on top of the orphan — the failed prototype's
# fatal flaw. macOS has no setsid(1); /usr/bin/perl (present on macOS and Linux)
# does setpgid then re-execs the original argv. FAIL-CLOSED when the leader is
# REQUIRED but perl is absent — never silently run ungrouped.
if [ "${FWF_GATE_PGLEADER_ENABLE:-1}" = 1 ] && [ -z "${_FWF_GATE_IS_PGLEADER:-}" ]; then
  if command -v perl >/dev/null 2>&1; then
    export _FWF_GATE_IS_PGLEADER=1
    exec perl -e 'use POSIX qw(setpgid); setpgid(0,0) or die "setpgid: $!"; exec @ARGV or die "exec: $!"' -- "$0" "$@"
  else
    echo "fwf gate: FWF_GATE_PGLEADER_ENABLE=1 but perl is absent — refusing to gate ungrouped (set FWF_GATE_PGLEADER_ENABLE=0 to override)" >&2
    exit 1
  fi
fi

# --- issue #175: do not leak OUR profile resolution into the wrapped command --
# Sourcing lib.sh below resolves a profile — we need it, for the lock paths —
# and in doing so SETS FWF_PROFILE/FWF_PAIRS/FWF_REPO in this shell. Those
# values are OURS, not the caller's. Running the wrapped command with them
# still set hands it an ambient profile it never asked for.
#
# That is not cosmetic: test/run.sh builds its own throwaway fixtures, and an
# inherited FWF_REPO/FWF_PROFILE overrides them — measured at 41 otherwise-
# passing tests going RED. Because the gate always runs inside a pane where
# those ARE set, the gate was false-RED on EVERY cycle, so no implementer
# could ever reach green. Correct values leak just as harmfully as wrong ones;
# this is about provenance, not validity.
#
# Snapshot the caller's real environment HERE, before the source, and restore
# it verbatim before handing control to the wrapped command.
_fwf_gate_had_profile=0; _fwf_gate_had_pairs=0; _fwf_gate_had_repo=0
_fwf_gate_old_profile=""; _fwf_gate_old_pairs=""; _fwf_gate_old_repo=""
if [ -n "${FWF_PROFILE+x}" ]; then _fwf_gate_had_profile=1; _fwf_gate_old_profile="$FWF_PROFILE"; fi
if [ -n "${FWF_PAIRS+x}" ];   then _fwf_gate_had_pairs=1;   _fwf_gate_old_pairs="$FWF_PAIRS"; fi
if [ -n "${FWF_REPO+x}" ];    then _fwf_gate_had_repo=1;    _fwf_gate_old_repo="$FWF_REPO"; fi

# Restore the caller's environment exactly: a var the caller had stays with its
# ORIGINAL value; a var the caller did not have is unset, not blanked (an empty
# FWF_PROFILE is not the same as an absent one to a ${VAR:-default} reader).
_fwf_gate_env_restore() {
  if [ "$_fwf_gate_had_profile" = 1 ]; then export FWF_PROFILE="$_fwf_gate_old_profile"; else unset FWF_PROFILE; fi
  if [ "$_fwf_gate_had_pairs" = 1 ];   then export FWF_PAIRS="$_fwf_gate_old_pairs";     else unset FWF_PAIRS; fi
  if [ "$_fwf_gate_had_repo" = 1 ];    then export FWF_REPO="$_fwf_gate_old_repo";       else unset FWF_REPO; fi
}

# shellcheck source=lib.sh
source "$DIR/lib.sh"

EX_SKIPPED=75
EX_STALE=76

usage() { echo "usage: fwf gate <role> [--e2e] [--cargo-build] [--tip-cmd 'CMD'] [--tip-ancestry] -- <command> [args...]" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }
shift

want_e2e=0
want_cargo_build=0
tip_cmd=""
want_tip_ancestry=0
while :; do
  case "${1:-}" in
    --e2e) want_e2e=1; shift ;;
    --cargo-build) want_cargo_build=1; shift ;;
    --tip-cmd) [ $# -ge 2 ] || { usage; exit 1; }; tip_cmd="$2"; shift 2 ;;
    --tip-ancestry) want_tip_ancestry=1; shift ;;
    *) break ;;
  esac
done

[ "${1:-}" = "--" ] || { usage; exit 1; }
shift
[ $# -gt 0 ] || { echo "fwf gate: no command given after --" >&2; usage; exit 1; }

# --tip-cmd (issue #202): decide BEFORE the lock is ever taken, so a tick that
# finds nothing new to gate never contends for it.
tip_before=""
if [ -n "$tip_cmd" ]; then
  tip_before="$(eval "$tip_cmd")" || { echo "fwf gate: --tip-cmd failed to resolve a value — refusing to skip on an unknown tip" >&2; exit 1; }
  if verdict="$(fwf_gate_tip_unchanged "$role" "$tip_before")"; then
    echo "fwf gate: no re-gate: tip unchanged at $tip_before, last verdict $verdict" >&2
    exit "$EX_SKIPPED"
  fi
fi

fwf_gate_lock_acquire "$role" || exit "$EX_SKIPPED"
gate_lock_held=1   # issue #156 BLOCKER 2: tracked so the release trap never rm's

e2e_held=0
cargo_build_slot=""
mem_token=""
# Only release the #123 per-role gate lock if WE currently hold it. During the
# admission wait (below) we deliberately drop it and a sibling tick may take it;
# an unconditional release here would then rm the sibling's lock. gate_lock_held
# is the guard.
_fwf_gate_release() {
  [ "$gate_lock_held" = 1 ] && fwf_gate_lock_release "$role"
  [ "$e2e_held" = 1 ] && fwf_e2e_lock_release
  fwf_cargo_build_slot_release "$cargo_build_slot"
  fwf_mem_admit_release "$mem_token"
}
trap _fwf_gate_release EXIT

# issue #156 hole #1: on a TRAPPABLE kill, release the lock(s) AND take the
# whole process group (cargo included) down WITH it — never leave cargo orphaned
# building while the lock is gone. Only meaningful when we're the pgleader; the
# single `kill -KILL -$$` is one syscall that reaps the whole group atomically
# (us included), so locks are released FIRST. An untrappable SIGKILL bypasses
# this entirely — that path is covered by the admission reaper, not here.
_fwf_gate_signal_cleanup() {
  trap - TERM INT HUP EXIT
  _fwf_gate_release
  [ -n "${_FWF_GATE_IS_PGLEADER:-}" ] && kill -KILL -"$$" 2>/dev/null
  exit 143
}
trap _fwf_gate_signal_cleanup TERM INT HUP

if [ "$want_e2e" = 1 ]; then
  fwf_e2e_lock_acquire "$role" || { echo "fwf gate: e2e lock busy, deferring" >&2; exit "$EX_SKIPPED"; }
  e2e_held=1
fi

# issue #156 BLOCKER 2 (SHARED hand-off): run a BLOCKING resource wait WITHOUT
# holding the #123 per-role gate lock, then re-acquire it before the build — so
# the lock's max-run ceiling (FWF_GATE_LOCK_MAX_RUN_SECS=1800, measured from
# acquire) only ever times the ACTUAL build, never wait+build. Used by BOTH the
# default #138 slot-acquire path AND the admission path — ONE implementation, so
# the release/re-acquire hand-off can never again be applied to one path but not
# the other (the exact asymmetry an adversarial verifier caught: it had been
# bolted onto the admission path only, leaving the as-shipped DEFAULT path holding
# the gate lock across fwf_cargo_build_slot_acquire's up-to-900s wait).
#
#   $1     name of the shell var to receive the acquired handle (slot number /
#          mem token the wait command echoes) — set ONLY on success.
#   $2     name of the release fn (takes the handle) called to free the resource
#          if we WIN the wait but LOSE the gate-lock re-acquire — so a losing
#          re-acquirer never leaks its slot/token. Single-flight: the build starts
#          ONLY after a successful re-acquire, so two builds for one role never run
#          at once.
#   $3...  the blocking wait command + args; its stdout is the handle.
#
# Releases the gate lock and clears gate_lock_held FIRST, so the EXIT / TERM-INT-
# HUP trap (_fwf_gate_release) honors the not-held window and never rm's a
# sibling's lock that was taken while we waited. The re-acquire goes through
# fwf_gate_lock_acquire, which mkdir's a fresh lock dir and RE-STAMPS acquired=now,
# so the ceiling restarts at build start.
# rc 0 = holds the resource AND re-holds the gate lock (gate_lock_held=1), out var
#        set — caller proceeds to build. rc 1 = deferred: either the wait timed out
#        (the wait fn already logged why) or we lost the re-acquire (logged here) —
#        in both cases the resource is freed and gate_lock_held is 0; the caller
#        must exit EX_SKIPPED.
_fwf_gate_locked_wait() {
  local __outvar="$1" __release_fn="$2"; shift 2
  local __handle
  fwf_gate_lock_release "$role"; gate_lock_held=0
  __handle="$("$@")" || return 1
  # issue #156 BLOCKER 2 (signal window): publish the won handle to the caller's
  # outvar (cargo_build_slot / mem_token) BEFORE re-acquiring the gate lock,
  # mirroring the old direct-assignment admission code. A trappable TERM/INT/HUP
  # arriving DURING fwf_gate_lock_acquire (resource already won, lock not yet
  # re-held) then finds the handle in the global, so _fwf_gate_signal_cleanup ->
  # _fwf_gate_release clean-releases it in that window instead of reading an empty
  # global and leaking the won slot/token until the next dead-pid reap.
  printf -v "$__outvar" '%s' "$__handle"
  if ! fwf_gate_lock_acquire "$role"; then
    echo "fwf gate: resource acquired but the per-role gate lock was taken during the wait — deferring this tick" >&2
    # Free EXACTLY once: unpublish the handle FIRST so the EXIT/TERM-INT-HUP trap's
    # _fwf_gate_release cannot ALSO free it (a double-free could rm a slot/token a
    # sibling has since re-acquired), THEN release via the local handle. Single-
    # flight holds: the build below starts only on the return-0 path, after a
    # successful re-acquire.
    printf -v "$__outvar" ''
    "$__release_fn" "$__handle"
    return 1
  fi
  gate_lock_held=1
  return 0
}

# Bound how many roles run a full cargo build at once. Two mechanisms, mutually
# exclusive per invocation — BOTH now route their blocking wait through the SAME
# _fwf_gate_locked_wait hand-off, so hole #3's bound holds identically on either:
# the #123 gate lock is DROPPED across the wait and only ever times the build, so
# slot_wait + build < 1800 and admission_wait + build < 1800 by construction (the
# wait no longer counts against the 1800s max-run ceiling), and a 25min sibling
# build can never push a waiting gate past that ceiling into a reaper-induced
# double-build.
#
#   FWF_MEM_ADMIT_ENABLE=1 (issue #156, strategy b — the chosen design): gate the
#   START on MEASURED free RAM. fwf_mem_admit holds only a sub-second decision
#   mutex, NEVER a lock across the build. reserve_gb comes from the op-class (e2e
#   build vs plain build).
#
#   default (issue #138 piece C): the pre-existing concurrency SEMAPHORE. It is
#   held for the wrapped command, but — like the admission path — its up-to-900s
#   fwf_cargo_build_slot_acquire WAIT now happens with the #123 gate lock RELEASED,
#   so wait+build no longer trips the ceiling. Kept as the safe fallback until
#   criterion (3)'s real-box profiling calibrates the reservation sizes.
if [ "$want_cargo_build" = 1 ]; then
  if [ "${FWF_MEM_ADMIT_ENABLE:-0}" = 1 ]; then
    if [ "$want_e2e" = 1 ]; then reserve_gb="$FWF_MEM_RESERVE_E2E_GB"; else reserve_gb="$FWF_MEM_RESERVE_BUILD_GB"; fi
    _fwf_gate_locked_wait mem_token fwf_mem_admit_release fwf_mem_admit "$role" "$reserve_gb" \
      || exit "$EX_SKIPPED"
  else
    _fwf_gate_locked_wait cargo_build_slot fwf_cargo_build_slot_release fwf_cargo_build_slot_acquire "$role" \
      || exit "$EX_SKIPPED"
  fi
fi

# Per-worktree cargo target isolation (issue #151): guarantee this gate builds
# ONLY its own worktree's source — never a dir shared with a sibling worktree,
# which is the one mechanism that lets a gate go GREEN on code not on its branch.
# cwd here is the pane's worktree. No-op for non-Rust gates. Fail CLOSED: if
# isolation can't be established, do NOT run the command — a red gate is safe.
#
# issue #268: only let this configure sccache (RUSTC_WRAPPER/SCCACHE_DIR) when
# the wrapped command is actually going to build cargo (--cargo-build was
# passed, mirroring the concurrency semaphore's own gating above) — otherwise
# every ordinary gate invocation (e.g. `-- bash -c "bash test/run.sh"`, which
# is every role's routine fast gate) leaked sccache into an unrelated wrapped
# command's environment regardless of whether it touched cargo at all.
fwf_cargo_isolate "$want_cargo_build" || { echo "fwf gate: could not isolate cargo target — refusing to run gate" >&2; exit 1; }

# Hand the wrapped command the CALLER's environment, not ours (issue #175).
# Deliberately after fwf_cargo_isolate, which still needs our resolution.
_fwf_gate_env_restore

rc=0
"$@" || rc=$?

# issue #220 AC (r)/(r0): record a SHA-keyed, reviewer-readable verdict --
# see fwf_gate_verdict_record's own doc comment (lib.sh) for why this is a
# SEPARATE store from fwf_gate_tip_record just below, never the same file.
# Recorded alongside every fwf_gate_tip_record call (identical role/verdict/
# reason, just re-keyed by tip instead of role) so the two stores can never
# silently drift apart.
_fwf_gate_record_verdict() { # $1=tip/sha  $2=verdict  $3=reason(optional)
  fwf_gate_tip_record "$role" "$1" "$2" "${3:-}"
  fwf_gate_verdict_record "$1" "$role" "$2" "${3:-}"
}

if [ -n "$tip_cmd" ]; then
  tip_after="$(eval "$tip_cmd" 2>/dev/null)" || tip_after=""
  # A failed/empty re-read is the SAME uncertainty as a confirmed move -- we
  # genuinely don't know whether the ref changed, so this must fail closed to
  # STALE, never fall through to recording a real (and promotable) verdict.
  if [ -z "$tip_after" ]; then
    echo "fwf gate: could not re-read the tip after this run (ref transiently unreadable) — verdict is STALE, not promotable" >&2
    _fwf_gate_record_verdict "$tip_before" "stale"
    rc="$EX_STALE"
  elif [ "$tip_after" != "$tip_before" ] && [ "$want_tip_ancestry" != 1 ]; then
    echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) — verdict is STALE, not promotable" >&2
    _fwf_gate_record_verdict "$tip_before" "stale"
    rc="$EX_STALE"
  elif [ "$tip_after" != "$tip_before" ]; then
    # issue #254: "the ref changed" is the wrong question -- ancestry is.
    # Distinguish a clean "not an ancestor" (git exit 1) from "could not
    # determine" (any other non-zero -- shallow clone, missing objects): both
    # fail closed to STALE, but the operator's next action differs (AC h).
    git merge-base --is-ancestor "$tip_before" "$tip_after"
    anc_rc=$?
    if [ "$anc_rc" -eq 0 ]; then
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after), but $tip_before is still an ancestor -- verdict stands, promote it by its literal hash" >&2
      _fwf_gate_record_verdict "$tip_before" "$([ "$rc" -eq 0 ] && echo green || echo red)"
    elif [ "$anc_rc" -eq 1 ]; then
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) and $tip_before is NOT an ancestor of $tip_after (history rewritten) — verdict is STALE, not promotable" >&2
      _fwf_gate_record_verdict "$tip_before" "stale" "not-ancestor"
      rc="$EX_STALE"
    else
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) and ancestry could not be determined (git merge-base --is-ancestor exit $anc_rc — shallow clone or missing objects?) — verdict is STALE, not promotable" >&2
      _fwf_gate_record_verdict "$tip_before" "stale" "indeterminate-ancestry"
      rc="$EX_STALE"
    fi
  else
    _fwf_gate_record_verdict "$tip_before" "$([ "$rc" -eq 0 ] && echo green || echo red)"
  fi
else
  # AC (r0): "a gate invoked WITHOUT --tip-cmd must still record its
  # verdict." No externally-supplied tip exists here, so the natural
  # identifier for "what was actually tested" is the invoking worktree's
  # own HEAD -- the code state the wrapped command just ran against. Only
  # fwf_gate_verdict_record fires (never fwf_gate_tip_record): the #202
  # skip-optimization marker is meaningless without a --tip-cmd to compare
  # against, and writing it here would let a --tip-cmd-less call for this
  # role clobber a --tip-cmd caller's skip state.
  verdict_head="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  fwf_gate_verdict_record "$verdict_head" "$role" "$([ "$rc" -eq 0 ] && echo green || echo red)"
fi

exit "$rc"
