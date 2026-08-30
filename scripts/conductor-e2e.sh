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
# fwf-release-ci-gate.sh oracle) as a second step before falling through to
# the local suite. GitHub CI is now permanently disabled (operator notice,
# ci.yml disabled, release.yml packaging-only) -- with no context ever
# reporting, that consult polled the FULL 1200s timeout on every cold-cache
# cycle before falling through anyway, turning a ~20min cold cycle into
# ~42min. Dropped entirely rather than degraded to a zero-wait check: a
# check against a permanently-disabled CI system has no path to ever
# returning green, so keeping it (even non-blocking) is dead weight with no
# offsetting benefit. Per the operator's own direction: never wait on,
# retrigger, or block on a GitHub run. fwf-release-ci-gate.sh itself is
# untouched -- it's still used elsewhere (release.yml branch-protection
# checks) and still has its own tests; only this caller stops consulting it.
#
# FAIL-SAFE BY CONSTRUCTION, UNCHANGED: the local suite is skipped ONLY on a
# definitive green (exit 0) from fwf-local-ci.sh for THIS EXACT SHA. Pending,
# red, absent, script-missing -- anything else at all -- falls through to the
# full local run. This can make the gate faster; it cannot make it more
# permissive.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHA="$(git rev-parse HEAD 2>/dev/null)"

# 1) LOCAL CI FIRST (operator direction 2026-08-29): the box has 332G free, 17G
# RAM and 12 cores, so a suite we already ran here is the fastest and most
# reliable oracle available -- GitHub evicted 5 jobs today and had not even
# STARTED on the staging tip when this was written. Not a self-hosted Actions
# runner: this repo is PUBLIC, and a registered runner would execute fork-PR
# code on a box holding the factory OAuth token, tailnet and SSH keys.
LOCAL="$DIR/fwf-local-ci.sh"
if [ -n "$SHA" ] && [ -x "$LOCAL" ]; then
  if out="$("$LOCAL" verdict "$SHA" 2>&1)"; then
    echo "conductor-e2e: local CI already GREEN for $SHA — skipping the re-run (#385)"
    echo "$out"
    exit 0
  fi
fi

# 2) nothing cached -- run the suite here and RECORD the result, so the next
# consult (this role's next cycle, or any other role on this box) is a cache
# hit instead of another full re-run. This is what makes local CI the
# DEFAULT rather than an opportunistic shortcut.
if [ -n "$SHA" ] && [ -x "$LOCAL" ]; then
  exec "$LOCAL" run
fi
exec bash test/run.sh
