#!/usr/bin/env bash
# fwf-local-ci.sh — run the required CI suites ON THIS BOX and record a verdict
# that our own gates can consult, instead of waiting on GitHub Actions.
#
# WHY NOT A SELF-HOSTED ACTIONS RUNNER: tbaums/fun-with-friends is a PUBLIC
# repo. A registered self-hosted runner would execute arbitrary fork-PR code on
# this machine, which holds the factory OAuth token, tailnet and SSH keys.
# GitHub warns against exactly this. This script is pull-only: it reads our
# own tree and writes a local verdict. Nothing inbound ever runs here.
#
# Verdict file: $FWF_RUN/local-ci/<sha>  ->  "green <N>s" | "red <N>s <n> failed"
#   | "red truncated" (issue #407 adds the elapsed-seconds field; older
#   files on disk are the bare "green" / "red <n> failed" and still parse
#   -- `verdict` matches by PREFIX, not the whole line, on purpose)
# Consult with: fwf-local-ci.sh verdict <sha>   (exit 0 only on a recorded green)
#
# issue #425: this SHARED flat file used to be the run's OWN log destination
# too (`> "$VDIR/$sha.log"`), and two runs of the same SHA -- the observed
# case: a worktree and the conductor both gating the promoted tip -- are two
# opens of that one filename. The second run's `>` truncates the first's,
# so a recorded verdict can end up standing over another run's partial
# output, or (worse, actually observed) a completed red's own evidence gets
# destroyed by a later green with no trace either transition ever happened.
# Fixed additively, not by replacing the pointer: every run ALSO writes an
# append-only, uniquely-named record under $VDIR/<sha>.runs/ (verdict +
# paired log, never overwritten by any other run, concurrent or not) -- the
# durable, discoverable history AC (5) asks for. $VDIR/<sha> itself keeps
# being the same "latest verdict" convenience pointer it always was (every
# EXISTING consumer -- fwf-local-ci.sh verdict, conductor-e2e.sh, the #407
# tests -- reads it unchanged), so a genuine re-run can still resolve a
# flake into green exactly as before; what changed is that the red it
# resolved is no longer erased, just superseded -- `ls $VDIR/<sha>.runs/`
# always shows every run that ever happened for that SHA, verdict and log
# both, until the retention sweep below ages them out.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN="${FWF_RUN:-$HOME/.fun-with-friends}"
VDIR="$RUN/local-ci"; mkdir -p "$VDIR"

# issue #425 edge case: per-run records accumulate where the old single
# shared name did not -- unbounded growth on the factory box is exactly how
# #405's 1359 orphans happened. Swept opportunistically on every `run`
# (mirrors the #156 admission reaper's self-healing pattern) rather than a
# separate cron: anything past this age is deleted, verdict and log
# together, by mtime. Default matches a work week; override for a shorter
# retention window in constrained environments.
FWF_LOCAL_CI_RETAIN_SECS="${FWF_LOCAL_CI_RETAIN_SECS:-604800}"
_fwf_local_ci_prune() {
  local now cutoff f mt
  now="$(date +%s)"; cutoff=$(( now - FWF_LOCAL_CI_RETAIN_SECS ))
  for f in "$VDIR"/*.runs/*; do
    [ -e "$f" ] || continue
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo '')"
    case "$mt" in ''|*[!0-9]*) continue;; esac
    [ "$mt" -lt "$cutoff" ] && rm -f "$f"
  done
}

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
trap _fwf_local_ci_prune EXIT   # issue #425: sweep aged-out per-run records on every exit path

# issue #425 AC (1): a per-run, never-reused name for BOTH the log and the
# durable verdict record -- date+pid+random rather than date+pid alone,
# since two runs starting in the exact same wall-clock second is the
# concurrent case this AC exists to cover, and pid ALONE can't disambiguate
# two DIFFERENT worktrees' processes if a container/namespace ever made pids
# collide across them. mkdir -p is safe under concurrent first-runs at a
# brand-new SHA (mkdir -p never errors on a dir another process just made).
runs_dir="$VDIR/$sha.runs"; mkdir -p "$runs_dir"
run_id="$(date +%s)-$$-$RANDOM"
log="$runs_dir/$run_id.log"
verdict_run_file="$runs_dir/$run_id"
echo "local-ci: running required suites for $sha on $(hostname) ($(nproc) cores) [run $run_id]"

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
  echo "red truncated" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  echo "local-ci: REFUSING to record a verdict — no summary line, the run did not finish [run $run_id]" >&2
  exit 1
fi
failed="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]*\) failed.*/\1/p')"
if [ "$rc" = 0 ] && [ "${failed:-1}" = 0 ]; then
  echo "green ${elapsed}s" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  echo "local-ci: GREEN — $summary (${elapsed}s) [run $run_id]"
else
  echo "red ${elapsed}s ${failed:-?} failed" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  echo "local-ci: RED — $summary (exit $rc, ${elapsed}s) [run $run_id]" >&2
  exit 1
fi
