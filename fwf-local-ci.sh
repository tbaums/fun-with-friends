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
# Verdict file: $FWF_RUN/local-ci/<sha>  ->  "green <N>s" | "green <N>s recovered:<n>"
#   | "red <N>s <n> failed" | "red truncated" | "lapsed <N>s <check-name>"
#   | "indeterminate [reason]"
#   (issue #407 adds the elapsed-seconds field; issue #446 adds lapsed/
#   indeterminate; issue #436 adds green's recovered:<n> suffix -- older
#   files on disk are the bare "green" / "red <n> failed" and still parse
#   -- `verdict` matches by PREFIX, not the whole line, on purpose)
# "lapsed": the suite passed but a required check (named) never actually
#   ran this cycle -- distinct from both green (ran, passed) and red (ran,
#   failed). "indeterminate": a caller (conductor-e2e.sh's bounded retry)
#   gave up after every attempt lapsed the same check.
# Consult with: fwf-local-ci.sh verdict <sha>   (exit 0 only when skip-eligible)
# Streak: fwf-local-ci.sh lapse-streak [check-name]   (consecutive lapses on this box)
#
# issue #436: a "green" verdict alone no longer means "never failed" -- a SHA
# that has ever recorded a genuine (non-infra, non-lapsed) red now stays
# "recovered:<n>" for <n> = consecutive clean greens since that red, and
# `verdict` only exits 0 once <n> >= 2 (two consecutive greens confirm a
# flake resolved; policy chosen on the issue). The fact that a SHA ever
# failed is tracked in a sibling $VDIR/<sha>.failed marker, OUTSIDE
# $VDIR/<sha>.runs/, so it is immune to the retention sweep below (AC 5) --
# and a SHA with NO $VDIR/<sha>.runs/ directory at all (the entire pre-#436
# corpus) resolves to UNKNOWN rather than GREEN, since there is no way to
# know whether it ever failed. An infrastructure red ("red truncated") or a
# lapsed check never touches the marker either way -- neither is a claim
# about the tree.
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

# issue #446: a run whose lint step never actually executed (killed under
# concurrent box load, a RAM-admission timeout, or the linter simply absent
# -- test/run.sh's #418/#427 skip idiom, the SAME marker fwf-gate.sh's #447
# fix keys off) must not record the same "green" token a run that actually
# ran the lint and passed does. #443's finding escaped to macOS this way:
# 308dac4 recorded green with shellcheck silently skipped, and
# conductor-e2e.sh skipped the re-run on that green two hours before the
# other runner caught the real defect. Named "lapsed", never folded into
# red or green: the SUITE did not fail (red would misreport a genuinely
# clean run as broken) and the CHECK did not run (green would repeat the
# defect this ticket exists to fix) -- those are different claims (AC 4).
FWF_LOCAL_CI_LAPSE_MARKER="${FWF_LOCAL_CI_LAPSE_MARKER-skip shellcheck (}"
FWF_LOCAL_CI_LAPSE_CHECK_NAME="${FWF_LOCAL_CI_LAPSE_CHECK_NAME:-shellcheck}"
# AC (3): a running count of consecutive `run` invocations (across ALL SHAs
# on this box, not per-SHA -- the question is "is the lint gate healthy on
# this host", not "did this one commit get unlucky") where the named check
# lapsed. Incremented on every lapse, reset to 0 the moment a run actually
# executes it (whether that run is green or red -- red-with-lint-ran still
# means the check itself worked). Best-effort, not lock-guarded: this is an
# observability counter, not a correctness gate, and the codebase's other
# simple counters (e.g. #427's own dispatch) carry the same tolerance.
LAPSE_STREAK_FILE="$VDIR/.lapse-streak-$FWF_LOCAL_CI_LAPSE_CHECK_NAME"

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
  # issue #436 AC (1)/(4): a key with no per-run history directory at all
  # predates #429's durable-history feature entirely (or this SHA was never
  # run under local-ci here) -- there is no way to know whether it has ever
  # failed, so it must resolve to UNKNOWN and NEVER take the skip-eligible
  # branch, regardless of what the key itself says. This is the MAJORITY
  # case for the pre-#429 corpus (every verdict written before that ticket
  # shipped), so it is checked first, ahead of the key content.
  if [ ! -d "$VDIR/$sha.runs" ]; then
    echo "local-ci: $sha is UNKNOWN (no run history recorded here -- pre-#429 or never run on this box)" >&2
    exit 1
  fi
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
      case "$dur" in
        # issue #436 AC (2)/(3): this SHA failed before ($sha.failed exists,
        # see the writer in `run` mode below) -- "green" alone can no longer
        # mean "skip eligible" for it. Require TWO CONSECUTIVE greens since
        # the last real failure (policy chosen on the issue) before the skip
        # is taken; the FIRST green after a red is real progress (the flake
        # may have resolved) but not yet confirmed, so it stays supersedable
        # information without being actionable on its own.
        *' recovered:'*)
          n="${dur##* recovered:}"
          case "$n" in
            1)
              echo "local-ci: $sha is GREEN but recovered:1 -- failed before, only one confirming green so far (issue #436: needs two consecutive greens before this is skip-eligible)" >&2
              exit 1
              ;;
            *)
              echo "local-ci: $sha is GREEN, recovered:${n} -- failed before, confirmed by ${n} consecutive greens, skip-eligible"
              exit 0
              ;;
          esac
          ;;
        *)
          echo "local-ci: $sha is GREEN (recorded on $(hostname))${dur:+, ${dur}}"
          exit 0
          ;;
      esac
      ;;
    # issue #446 AC (1): distinguishable by PREFIX from green, same idiom as
    # #407's own green-vs-green-with-duration split above -- a consumer that
    # only checks rc (conductor-e2e.sh's skip decision) already refuses on
    # this by construction; the word is here for the human/log reading it.
    lapsed|lapsed\ *)
      detail="${v#lapsed}"; detail="${detail# }"
      echo "local-ci: $sha LAPSED (recorded on $(hostname))${detail:+, ${detail}} -- a required check did not run this cycle; not green" >&2
      exit 1
      ;;
    indeterminate|indeterminate\ *)
      detail="${v#indeterminate}"; detail="${detail# }"
      echo "local-ci: $sha is INDETERMINATE (recorded on $(hostname))${detail:+, ${detail}}" >&2
      exit 1
      ;;
    "")    echo "local-ci: no verdict recorded for $sha" >&2; exit 1;;
    # issue #436 edge case (decided, not deferred): a truncated/infra run
    # says nothing about the TREE, only about the runner -- it must never be
    # read as "has failed". Called out explicitly rather than falling into
    # the generic red branch below so the exclusion is visible, not silent.
    "red truncated")
      echo "local-ci: $sha is red truncated -- an infrastructure failure, not counted as a tree failure (issue #436 edge case)" >&2
      exit 1
      ;;
    *)     echo "local-ci: $sha is $v" >&2; exit 1;;
  esac
fi

# issue #446 AC (3): the streak, in one command any consumer (a role's own
# report, `fwf dash`, a captain status note) can read without grepping logs
# -- "a counter nothing reads is the durable-but-not-binding gap #436 was
# filed on" is the ticket's own words for exactly this shape.
if [ "$cmd" = lapse-streak ]; then
  cat "$LAPSE_STREAK_FILE" 2>/dev/null || echo 0
  exit 0
fi

# issue #446 AC (2): conductor-e2e.sh's bounded-retry loop calls this once
# it has exhausted its attempts, so the terminal state is RECORDED and
# named -- "the verdict settles on INDETERMINATE" -- rather than left as
# whatever the last exhausted attempt's own "lapsed" record happened to
# say. Only ever writes the convenience pointer, never a $VDIR/<sha>.runs/
# entry: no suite execution happens at this step (each of the attempts
# that led here already wrote its own durable per-run "lapsed" record via
# the normal `run` path below), so there is nothing new to archive here --
# this call is bookkeeping on top of records that already exist.
if [ "$cmd" = mark-indeterminate ]; then
  [ -n "$sha" ] || { echo "usage: $0 mark-indeterminate <sha> [reason]" >&2; exit 2; }
  reason="${3:-}"
  echo "indeterminate${reason:+ $reason}" > "$VDIR/$sha"
  echo "local-ci: $sha marked INDETERMINATE${reason:+ ($reason)}" >&2
  exit 0
fi

# issue #457: was this SHA marked INDETERMINATE recently (within the given
# cooldown, in seconds)? Exit 0 (printing the age) if so, 1 otherwise --
# including "never marked" and "marked, but the cooldown has expired".
# conductor-e2e.sh's bounded retry (#446) only bounds ONE invocation; a
# PERSISTENTLY-lapsing check (the box structurally cannot give the check
# room to run, not a transient spike) meant every ~2min conductor tick
# independently re-ran the full 3-attempt cycle, discovering the same
# exhaustion each time -- 78 minutes and 4 full suites with zero verdict
# advance, observed on this box. This lets a caller back off instead of
# repeating a cycle that just failed, without a separate state file: the
# indeterminate marker mark-indeterminate already writes IS the cooldown
# clock, read by its own mtime.
if [ "$cmd" = indeterminate-recent ]; then
  [ -n "$sha" ] || { echo "usage: $0 indeterminate-recent <sha> <cooldown-secs>" >&2; exit 2; }
  cooldown="${3:?indeterminate-recent needs a cooldown in seconds}"
  f="$VDIR/$sha"
  [ -f "$f" ] || exit 1
  content="$(cat "$f" 2>/dev/null || echo '')"
  case "$content" in
    indeterminate*) ;;
    *) exit 1 ;;
  esac
  mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo '')"
  case "$mt" in ''|*[!0-9]*) exit 1 ;; esac
  now="$(date +%s)"; age=$((now - mt))
  if [ "$age" -lt "$cooldown" ]; then
    echo "indeterminate ${age}s ago (cooldown ${cooldown}s)"
    exit 0
  fi
  exit 1
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

# issue #436 AC (5): "has this SHA ever failed" must survive the retention
# sweep above, which only ages out files under $sha.runs/ -- by design, that
# is what the sweep is FOR (reclaiming logs), and this fact is not a log. A
# sibling file OUTSIDE $sha.runs/, never matched by _fwf_local_ci_prune's
# `*.runs/*` glob, carries it instead: its mere existence means "a genuine
# (non-infra, non-lapsed) red has been recorded for this SHA", and its
# content is the count of CONSECUTIVE clean greens recorded since that
# failure -- read by `verdict` above to decide skip-eligibility, written
# only here.
failed_marker="$VDIR/$sha.failed"

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
  # issue #436 edge case: a truncated run is an infrastructure claim, not a
  # tree claim -- $failed_marker is deliberately left untouched (neither
  # created nor reset nor incremented), so it says nothing about whether the
  # tree itself has ever failed.
  echo "red truncated" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  echo "local-ci: REFUSING to record a verdict — no summary line, the run did not finish [run $run_id]" >&2
  exit 1
fi
failed="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]*\) failed.*/\1/p')"

# issue #446: whether the lint gate itself ran this cycle, independent of
# whether the SUITE passed -- the streak (AC 3) counts every lapse,
# including one that happens to coincide with an unrelated red, because the
# question it answers ("is the lint gate actually executing") is orthogonal
# to whether the run's OTHER assertions passed.
lapsed=0
if [ -n "$FWF_LOCAL_CI_LAPSE_MARKER" ] && grep -qF -- "$FWF_LOCAL_CI_LAPSE_MARKER" "$log"; then
  lapsed=1
fi
if [ "$lapsed" = 1 ]; then
  streak=$(( $(cat "$LAPSE_STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
else
  streak=0
fi
echo "$streak" > "$LAPSE_STREAK_FILE"

if [ "$rc" = 0 ] && [ "${failed:-1}" = 0 ] && [ "$lapsed" = 1 ]; then
  # issue #446 AC (1)/(4): the suite did not fail and the check did not run
  # -- a distinct claim from both green (check ran, passed) and red (suite
  # failed). Never "green": that is the exact defect #443 escaped through.
  # issue #436: a lapsed check is, like an infra red, a claim about the
  # runner rather than the tree -- $failed_marker is left untouched here too.
  echo "lapsed ${elapsed}s ${FWF_LOCAL_CI_LAPSE_CHECK_NAME}" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  echo "local-ci: LAPSED — $summary (${elapsed}s), but $FWF_LOCAL_CI_LAPSE_CHECK_NAME never ran (streak: $streak) [run $run_id]" >&2
  exit 1
elif [ "$rc" = 0 ] && [ "${failed:-1}" = 0 ]; then
  if [ -f "$failed_marker" ]; then
    n="$(cat "$failed_marker" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0;; esac
    n=$((n + 1))
    echo "$n" > "$failed_marker" 2>/dev/null
    echo "green ${elapsed}s recovered:${n}" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
    echo "local-ci: GREEN, recovered:${n} — $summary (${elapsed}s) [run $run_id]"
  else
    echo "green ${elapsed}s" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
    echo "local-ci: GREEN — $summary (${elapsed}s) [run $run_id]"
  fi
else
  # issue #436 AC (2)/(3): a genuine (non-infra, non-lapsed-only) red --
  # mark this SHA as having failed and reset the consecutive-greens count to
  # 0, so the NEXT green is recovered:1 (not yet skip-eligible) rather than
  # silently resuming as if nothing happened.
  echo 0 > "$failed_marker" 2>/dev/null
  echo "red ${elapsed}s ${failed:-?} failed" | tee "$VDIR/$sha" "$verdict_run_file" >/dev/null
  if [ "$lapsed" = 1 ]; then
    echo "local-ci: RED — $summary (exit $rc, ${elapsed}s); note: $FWF_LOCAL_CI_LAPSE_CHECK_NAME also lapsed this run (streak: $streak) [run $run_id]" >&2
  else
    echo "local-ci: RED — $summary (exit $rc, ${elapsed}s) [run $run_id]" >&2
  fi
  exit 1
fi
