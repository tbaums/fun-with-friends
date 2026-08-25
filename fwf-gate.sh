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

usage() { echo "usage: fwf gate <role> [--e2e] [--cargo-build] [--tip-cmd 'CMD'] -- <command> [args...]" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }
shift

want_e2e=0
want_cargo_build=0
tip_cmd=""
while :; do
  case "${1:-}" in
    --e2e) want_e2e=1; shift ;;
    --cargo-build) want_cargo_build=1; shift ;;
    --tip-cmd) [ $# -ge 2 ] || { usage; exit 1; }; tip_cmd="$2"; shift 2 ;;
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

e2e_held=0
cargo_build_slot=""
_fwf_gate_release() {
  fwf_gate_lock_release "$role"
  [ "$e2e_held" = 1 ] && fwf_e2e_lock_release
  fwf_cargo_build_slot_release "$cargo_build_slot"
}
trap _fwf_gate_release EXIT

if [ "$want_e2e" = 1 ]; then
  fwf_e2e_lock_acquire "$role" || { echo "fwf gate: e2e lock busy, deferring" >&2; exit "$EX_SKIPPED"; }
  e2e_held=1
fi

# issue #138 piece C: bound how many roles build cargo at once. Held for the
# WHOLE wrapped command (not just the isolate step below), since the actual
# build/test happens inside it — released by the trap above on any exit path.
if [ "$want_cargo_build" = 1 ]; then
  cargo_build_slot="$(fwf_cargo_build_slot_acquire "$role")" \
    || { echo "fwf gate: cargo build slots busy, deferring" >&2; exit "$EX_SKIPPED"; }
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

if [ -n "$tip_cmd" ]; then
  tip_after="$(eval "$tip_cmd" 2>/dev/null)" || tip_after=""
  # A failed/empty re-read is the SAME uncertainty as a confirmed move -- we
  # genuinely don't know whether the ref changed, so this must fail closed to
  # STALE, never fall through to recording a real (and promotable) verdict.
  if [ -z "$tip_after" ]; then
    echo "fwf gate: could not re-read the tip after this run (ref transiently unreadable) — verdict is STALE, not promotable" >&2
    fwf_gate_tip_record "$role" "$tip_before" "stale"
    rc="$EX_STALE"
  elif [ "$tip_after" != "$tip_before" ]; then
    echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) — verdict is STALE, not promotable" >&2
    fwf_gate_tip_record "$role" "$tip_before" "stale"
    rc="$EX_STALE"
  else
    fwf_gate_tip_record "$role" "$tip_before" "$([ "$rc" -eq 0 ] && echo green || echo red)"
  fi
fi

exit "$rc"
