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
# Verdict file: $FWF_RUN/local-ci/<sha>  ->  "green" | "red <n> failed"
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
    green) echo "local-ci: $sha is GREEN (recorded on $(hostname))"; exit 0;;
    "")    echo "local-ci: no verdict recorded for $sha" >&2; exit 1;;
    *)     echo "local-ci: $sha is $v" >&2; exit 1;;
  esac
fi

# run mode: verify the CURRENT checkout and record under its HEAD sha
sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" || { echo "not a git tree" >&2; exit 2; }
log="$VDIR/$sha.log"
echo "local-ci: running required suites for $sha on $(hostname) ($(nproc) cores)"

rc=0
bash "$DIR/test/run.sh" > "$log" 2>&1 || rc=$?
summary="$(grep -E '^[0-9]+ passed,' "$log" | tail -1)"

# A run is only valid if it actually finished: a truncated log is NOT green.
if [ -z "$summary" ]; then
  echo "red truncated" > "$VDIR/$sha"
  echo "local-ci: REFUSING to record a verdict — no summary line, the run did not finish" >&2
  exit 1
fi
failed="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]*\) failed.*/\1/p')"
if [ "$rc" = 0 ] && [ "${failed:-1}" = 0 ]; then
  echo green > "$VDIR/$sha"
  echo "local-ci: GREEN — $summary"
else
  echo "red ${failed:-?} failed" > "$VDIR/$sha"
  echo "local-ci: RED — $summary (exit $rc)" >&2
  exit 1
fi
