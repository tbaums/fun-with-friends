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
# Usage: fwf gate <role> [--e2e] -- <command> [args...]
#   <role>     the per-role lock key (e.g. impl2, qa2, conductor) — the
#              literal role tag used elsewhere (heartbeat path, etc).
#   --e2e      ALSO take the floor-wide e2e lock. Use for an E2E_CMD-class
#              run; omit for the fast GATE_CMD (see above).
#   <command>  exec'd directly via "$@" after the lock(s) are held — no extra
#              shell re-parsing, so a multi-command GATE_CMD string must be
#              passed through `bash -c '...'` by the caller (that's exactly
#              how __GATE__/__E2E__ render it — see lib.sh's fwf_render).
#
# Exit codes: the wrapped command's own exit code on a real run; 75 (the
# traditional EX_TEMPFAIL) when this tick was SKIPPED — a prior gate for this
# role is still running, or a --e2e run found the floor-wide lock busy.
# Callers MUST treat 75 as "nothing to report, try again next tick", never as
# a gate failure — an agent that greps for a green/red gate result should
# check for this exit code first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

EX_SKIPPED=75

usage() { echo "usage: fwf gate <role> [--e2e] -- <command> [args...]" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }
shift

want_e2e=0
if [ "${1:-}" = "--e2e" ]; then want_e2e=1; shift; fi

[ "${1:-}" = "--" ] || { usage; exit 1; }
shift
[ $# -gt 0 ] || { echo "fwf gate: no command given after --" >&2; usage; exit 1; }

fwf_gate_lock_acquire "$role" || exit "$EX_SKIPPED"

e2e_held=0
_fwf_gate_release() {
  fwf_gate_lock_release "$role"
  [ "$e2e_held" = 1 ] && fwf_e2e_lock_release
}
trap _fwf_gate_release EXIT

if [ "$want_e2e" = 1 ]; then
  fwf_e2e_lock_acquire "$role" || { echo "fwf gate: e2e lock busy, deferring" >&2; exit "$EX_SKIPPED"; }
  e2e_held=1
fi

# Per-worktree cargo target isolation (issue #151): guarantee this gate builds
# ONLY its own worktree's source — never a dir shared with a sibling worktree,
# which is the one mechanism that lets a gate go GREEN on code not on its branch.
# cwd here is the pane's worktree. No-op for non-Rust gates. Fail CLOSED: if
# isolation can't be established, do NOT run the command — a red gate is safe.
fwf_cargo_isolate || { echo "fwf gate: could not isolate cargo target — refusing to run gate" >&2; exit 1; }

rc=0
"$@" || rc=$?
exit "$rc"
