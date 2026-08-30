#!/usr/bin/env bash
# fwf-local-ci.sh — run the required CI suites ON THIS BOX and record a verdict
# that our own gates can consult, instead of waiting on GitHub Actions.
#
# WHY NOT A SELF-HOSTED ACTIONS RUNNER: tbaums/fun-with-friends is a PUBLIC
# repo. A registered self-hosted runner would execute arbitrary fork-PR code on
# this machine, which holds the factory OAuth token, tailnet access and SSH
# keys. GitHub warns against exactly this. This script is pull-only: it reads
# our own tree and writes a local verdict. Nothing inbound ever runs here.
#
# Verdict file: $FWF_RUN/local-ci/<sha>  ->  "green <N>s" | "red <N>s <n> failed"
#   | "red truncated" (issue #407 adds the elapsed-seconds field; older
#   files on disk are the bare "green" / "red <n> failed" and still parse
#   -- `verdict` matches by PREFIX, not the whole line, on purpose)
# Consult with: fwf-local-ci.sh verdict <sha>   (exit 0 only on a recorded green)
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN="${FWF_RUN:-$HOME/.fun-with-friends}"
VDIR="$RUN/local-ci"; mkdir -p "$VDIR"

cmd="${1:-run}"; sha="${2:-}"

if [ "$cmd" = verdict ]; then
  [ -n "$sha" ] || { echo "usage: $0 verdict <sha>" >&2; exit 2; }
  v="$(cat "$VDIR/$sha" 2>/dev/null)"
  case "$v" in
    # issue #407: a completed run now records "green <N>s", not the bare
    # word -- matched by PREFIX, not the whole line (a whole-line match is
    # exactly the #404 regression this ticket would otherwise re-introduce
    # through a different door: appending a duration would make every
    # future green verdict fail to match and never take the skip path).
    # Verdict files already on disk are the old bare "green" -- also
    # matched by this same prefix pattern, so no backfill/migration needed.
    green|green\ *)
      dur="${v#green}"; dur="${dur# }"
      echo "local-ci: $sha is GREEN (recorded on $(hostname))${dur:+, ${dur}}"
      exit 0
      ;;
    "")    echo "local-ci: no verdict recorded for $sha" >&2; exit 1;;
    *)     echo "local-ci: $sha is $v" >&2; exit 1;;
  esac
fi

# run mode: verify the CURRENT checkout and record under its HEAD sha
sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" || { echo "not a git tree" >&2; exit 2; }
log="$VDIR/$sha.log"
echo "local-ci: running required suites for $sha on $(hostname) ($(nproc) cores)"

# issue #407: wall-clock for the FULL run (test/run.sh + the memory-
# admission suite below), recorded on the verdict line -- the driver has
# had no way to see how long a gate took once its process exits.
start_ts="$(date +%s)"

rc=0
bash "$DIR/test/run.sh" > "$log" 2>&1 || rc=$?

# MEMORY-ADMISSION GATE (issue #156, moved here 2026-08-29). This used to be a
# dedicated step in ci.yml/release.yml. CI is off GitHub now, so the gate lives
# where the suite lives -- on our own hardware. It is NOT nested inside
# test/run.sh on purpose: #156's suite spawns memory-hungry children and nesting
# it got the whole outer gate SIGKILLed mid-run as "wedged" (the #123 anomaly).
# It stays a separate invocation, and a red here is a red verdict.
if [ -f "$DIR/test/mem-admit-test.sh" ]; then
  echo "--- memory-admission suite (issue #156) ---" >> "$log"
  bash "$DIR/test/mem-admit-test.sh" >> "$log" 2>&1 || rc=$?
fi
elapsed="$(( $(date +%s) - start_ts ))"
summary="$(grep -E '^[0-9]+ passed,' "$log" | tail -1)"

# A run is only valid if it actually finished: a truncated log is NOT green.
# No duration recorded here -- AC (5): a run that did not finish has no
# real wall-clock to report (it was killed mid-flight, not measured), and
# "red truncated" must stay exactly what it already is so it never looks
# like a completed, timed run.
if [ -z "$summary" ]; then
  echo "red truncated" > "$VDIR/$sha"
  echo "local-ci: REFUSING to record a verdict — no summary line, the run did not finish" >&2
  exit 1
fi
failed="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]*\) failed.*/\1/p')"
if [ "$rc" = 0 ] && [ "${failed:-1}" = 0 ]; then
  echo "green ${elapsed}s" > "$VDIR/$sha"
  echo "local-ci: GREEN — $summary (${elapsed}s)"
else
  echo "red ${elapsed}s ${failed:-?} failed" > "$VDIR/$sha"
  echo "local-ci: RED — $summary (exit $rc, ${elapsed}s)" >&2
  exit 1
fi
