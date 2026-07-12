#!/usr/bin/env bash
# consulting acceptance eval — SCAFFOLD (see this dir's README.md).
#
# This does NOT launch a factory. Engagement-level acceptance requires running the
# consulting funnel once per fixture to a DOSSIER, which must be a STANDALONE run
# (never nested inside a build/eval — OOM on the 8-core box). This scaffold instead:
#   1) validates each fixture has MANIFEST.md + expected.md,
#   2) prints the standalone command an operator runs for that engagement,
#   3) prints the assertion to check the emitted DOSSIER.md against expected.md.
#
# Usage:  run.sh [fixture …]        (default: all fixtures under fixtures/)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$DIR/fixtures"

log() { printf '[consulting-eval] %s\n' "$*"; }
die() { printf '[consulting-eval] ERROR: %s\n' "$*" >&2; exit 1; }

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
  cat <<EOF
  --- $name: standalone acceptance steps (NOT run here) ---
    1. build/seed this fixture's target repo + factory config per expected.md
    2. cp $fdir/MANIFEST.md \$FWF_REPO/MANIFEST.md
    3. fwf --profile consulting up        # attach, run the funnel to a DOSSIER
    4. assert findings/<slug>/DOSSIER.md satisfies $fdir/expected.md
EOF
done

if [ "$name" = "reproducibility" ] 2>/dev/null || printf '%s\n' "${wanted[@]}" | grep -qx reproducibility; then
  log "reproducibility: run steps 3-4 twice and diff the two premise verdicts (must converge)"
fi

# This scaffold is a fixture linter + runbook printer. Launching the factory and
# diffing the DOSSIER is the STANDALONE acceptance step, intentionally left to a
# human so no factory is ever nested inside a build/eval run.
log "SCAFFOLD: no factory launched. Wire the standalone launch + DOSSIER assertion to complete acceptance."
[ "$fail" -eq 0 ] || die "one or more fixtures are missing MANIFEST.md/expected.md"
log "all requested fixtures present."
