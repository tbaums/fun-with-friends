#!/usr/bin/env bash
# fwf-gate-rust-scope.sh — issue #138, piece B (SHADOW MODE). A profile whose
# GATE_CMD includes a Rust suite (e.g. `cd dash && cargo fmt --check && ...`)
# can call this BEFORE that suite to log what the future diff-scoped gate
# WOULD have decided — without ever skipping anything. This is the low-blast-
# radius first increment of the ticket: the classifier meets real branches
# now, and every gate accumulates the would-skip / would-run data the future
# A->B keep-or-drop-B decision needs, while the full suite still runs on
# every branch throughout (see fwf_gate_rust_scope_decide in lib.sh for the
# fail-open/fail-safe classification rules).
#
# Usage: fwf gate-rust-scope --against BRANCH --safe GLOB [--safe GLOB ...]
#                             [--log FILE] [--full-suite-secs N]
#   --against BRANCH    branch/ref to diff the whole current branch against
#                        (merge-base..HEAD — never last-commit-only).
#   --safe GLOB          a path glob considered safe to skip on (repeatable).
#                        Only if EVERY changed file matches some --safe glob
#                        does this classify as SKIP; anything else is RUN.
#   --log FILE            shadow log to append to. Default:
#                        $FWF_RUN/gate-rust-shadow/<profile>.log
#   --full-suite-secs N   wall-clock the full Rust suite took THIS run
#                        (optional — pass it after you measure, so the log can
#                        answer the A->B measurement AC without a separate
#                        measurement pass).
#
# FWF_GATE_FULL=1 forces a RUN verdict regardless of the diff — the kill
# switch named in the ticket. It changes nothing observable yet (shadow mode
# never withholds the suite either way) but is plumbed and tested now so step
# 4 (flipping B to enforcing) has nothing left to wire.
#
# Exit code: ALWAYS 0. This tool observes; it never gates. The caller is
# responsible for running the full Rust suite regardless of the verdict
# printed here, for as long as B stays in shadow.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() {
  echo "usage: fwf gate-rust-scope --against BRANCH [--safe GLOB]... [--log FILE] [--full-suite-secs N]" >&2
}

against=""
safe=()
log="$FWF_RUN/gate-rust-shadow/$PROFILE.log"
full_secs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --against) against="${2:?--against needs a value}"; shift 2 ;;
    --safe) safe+=("${2:?--safe needs a value}"); shift 2 ;;
    --log) log="${2:?--log needs a value}"; shift 2 ;;
    --full-suite-secs) full_secs="${2:?--full-suite-secs needs a value}"; shift 2 ;;
    *) echo "fwf-gate-rust-scope.sh: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done
[ -n "$against" ] || { usage; exit 2; }

if [ "${FWF_GATE_FULL:-0}" = "1" ]; then
  verdict="RUN kill-switch: FWF_GATE_FULL=1 forces the full suite regardless of the diff"
else
  verdict="$(fwf_gate_rust_scope_decide "$against" ${safe[@]+"${safe[@]}"})"
fi
decision="${verdict%% *}"
reason="${verdict#* }"

if [ "$decision" = "SKIP" ]; then
  echo "Rust suite WOULD SKIP — diff vs $reason touched no rust-relevant paths (shadow mode: running it anyway)"
else
  echo "Rust suite WOULD RUN — $reason"
fi

mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf 'ts=%s decision=%s against=%s full_suite_secs=%s reason=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$decision" "$against" "${full_secs:-NA}" "$reason" >> "$log"

exit 0
