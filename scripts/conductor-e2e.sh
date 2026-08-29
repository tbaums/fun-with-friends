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
# #303 already built the "is CI green for this exact SHA" oracle for the release
# job (fwf-release-ci-gate.sh). This reuses it.
#
# FAIL-SAFE BY CONSTRUCTION: the local suite is skipped ONLY on a definitive
# green (exit 0) from that oracle for THIS EXACT SHA. Pending, red, absent,
# rate-limited, script-missing -- anything else at all -- falls through to the
# full local run, i.e. exactly today's behaviour. This can make the gate faster;
# it cannot make it more permissive.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHA="$(git rev-parse HEAD 2>/dev/null)"
GATE="$DIR/fwf-release-ci-gate.sh"

if [ -n "$SHA" ] && [ -x "$GATE" ]; then
  if out="$("$GATE" "$SHA" 2>&1)"; then
    echo "conductor-e2e: ci.yml is already GREEN for $SHA — skipping the local re-run (#385)"
    echo "$out"
    exit 0
  fi
  echo "conductor-e2e: no definitive CI green for $SHA — running the full suite locally" >&2
  printf '%s\n' "$out" >&2
fi

exec bash test/run.sh
