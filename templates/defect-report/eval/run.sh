#!/usr/bin/env bash
# defect-report acceptance eval — SCAFFOLD (see this dir's README.md).
#
# This does NOT launch a factory. Run-level acceptance requires running the
# defect-report pipeline once per adversarial fixture (and, for
# baseline-comparison, a separate single-model session per instance too),
# which must be a STANDALONE run (never nested inside a build/eval — OOM on
# the 8-core box). This scaffold instead:
#   1) validates each fixture has MANIFEST.md + expected.md,
#   2) prints the standalone command an operator runs for that fixture,
#   3) prints the assertion to check the resulting report/DELIVERY.md (or,
#      for baseline-comparison, the blinded-scoring outcome) against expected.md.
#
# Usage:  run.sh [fixture …]        (default: all fixtures under fixtures/)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$DIR/fixtures"

log() { printf '[defect-report-eval] %s\n' "$*"; }
die() { printf '[defect-report-eval] ERROR: %s\n' "$*" >&2; exit 1; }

# Which fixtures to check (args, or every subdir of fixtures/).
wanted=()
if [ "$#" -gt 0 ]; then
  wanted=("$@")
else
  for d in "$FIXTURES_DIR"/*/; do
    [ -d "$d" ] && wanted+=("$(basename "$d")")
  done
fi
[ "${#wanted[@]}" -gt 0 ] || die "no fixtures found under $FIXTURES_DIR"

fail=0
for name in "${wanted[@]}"; do
  fdir="$FIXTURES_DIR/$name"
  [ -d "$fdir" ] || { log "MISSING fixture dir: $name"; fail=1; continue; }
  for f in MANIFEST.md expected.md; do
    if [ -f "$fdir/$f" ]; then
      log "ok   $name/$f"
    else
      log "MISS $name/$f"; fail=1
    fi
  done
  if [ "$name" = "baseline-comparison" ]; then
    cat <<EOF
  --- $name: standalone acceptance steps (NOT run here — this is the thesis run) ---
    1. for each of 2 model tiers x 6 paired (skill,target) instances (24 runs):
         a. run Arm F: fwf --template defect-report up      # to DELIVERY.md
         b. run Arm S: one continuous single-model session given the SAME skill
            doc, the SAME contract-loader-derived checklist, and the same
            single human-gate opportunity (see ../README.md's fair-baseline note)
    2. strip arm-identifying metadata from both arms' outputs; run the blinded
       scorer TWICE per artifact; report the raw agreement rate
    3. apply the pre-registered decision rule (../README.md) per tier
    4. report BOTH tiers plainly, including a losing tier if one occurs, plus
       each arm's logged cost and the resulting cost multiple
EOF
  else
    cat <<EOF
  --- $name: standalone acceptance steps (NOT run here) ---
    1. seed this fixture's defect + source of truth per $fdir/MANIFEST.md
    2. fwf --template defect-report up    # attach, run the pipeline to DELIVERY.md
    3. assert runs/<run-slug>/report.md + DELIVERY.md satisfy $fdir/expected.md
EOF
  fi
done

# This scaffold is a fixture linter + runbook printer. Launching the factory
# (and, for baseline-comparison, the paired single-model arm) and diffing the
# result against expected.md is the STANDALONE acceptance step, intentionally
# left to a human so no factory is ever nested inside a build/eval run.
log "SCAFFOLD: no factory launched. Wire the standalone launch + result assertion to complete acceptance."
[ "$fail" -eq 0 ] || die "one or more fixtures are missing MANIFEST.md/expected.md"
log "all requested fixtures present."
