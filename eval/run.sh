#!/usr/bin/env bash
# fwf eval — role-level model evaluation harness (issue #8).
#
# Renders a role's PRODUCTION prompt (template × role, through the real
# fwf_render path), confronts it with a scenario fixture (a snapshot of factory
# state: issue lists, PR lists, diffs, gate output), runs it through
# `claude -p --model M` for each candidate model, and scores every response
# with an LLM judge against the scenario's rubric. Output: a markdown report +
# raw transcripts per run, mean score per model.
#
# Usage:
#   eval/run.sh --role ROLE --models M1,M2[,…] [--template T] [--scenario NAME]
#               [--trials N] [--judge-model M]
#     ROLE     implementer | qa | conductor | pm | gv | captain
#     models   one candidate per claude --model value; the literal value
#              "default" means "no --model flag" (the CLI's default model)
#   Scenarios live in eval/scenarios/<template>/<role>/<name>/{scenario.md,rubric.md};
#   omit --scenario to run all of the role's scenarios.
#
# Env knobs (also how the test suite keeps this hermetic):
#   FWF_EVAL_CLAUDE_CMD   command to invoke instead of `claude` (may contain args)
#   FWF_EVAL_RESULTS_DIR  where run dirs are written (default eval/results)
#   FWF_EVAL_TIMEOUT      per-call hard timeout in seconds (default 300)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVAL_DIR="$DIR/eval"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}
die() { echo "fwf eval: $*" >&2; exit 1; }
log() { printf '[eval %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

ROLE=""; TEMPLATE="dev"; MODELS=""; SCENARIO=""; TRIALS=1; JUDGE_MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)        ROLE="$2"; shift 2;;
    --template)    TEMPLATE="$2"; shift 2;;
    --models)      MODELS="$2"; shift 2;;
    --scenario)    SCENARIO="$2"; shift 2;;
    --trials)      TRIALS="$2"; shift 2;;
    --judge-model) JUDGE_MODEL="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) die "unknown flag '$1' (try --help)";;
  esac
done
[ -n "$ROLE" ]   || { usage >&2; die "--role is required"; }
[ -n "$MODELS" ] || { usage >&2; die "--models is required"; }
case "$ROLE" in implementer|qa|conductor|pm|gv|captain) ;; *) die "unknown role '$ROLE'";; esac
case "$TRIALS" in ''|*[!0-9]*|0) die "--trials must be a positive integer";; esac

# Render the role prompt exactly as production does (profile only supplies
# names/branches to the placeholders; example is deterministic for that).
PROFILE="${FWF_PROFILE:-example}"
RENDERED="$(FWF_TEMPLATE="$TEMPLATE" FWF_PROFILE="$PROFILE" bash -c \
  "source '$DIR/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/$ROLE.tmpl\" 1")" \
  || die "could not render $TEMPLATE/$ROLE.tmpl"

SCEN_BASE="$EVAL_DIR/scenarios/$TEMPLATE/$ROLE"
[ -d "$SCEN_BASE" ] || die "no scenarios for $TEMPLATE/$ROLE (looked in $SCEN_BASE)"
SCEN_DIRS=""
if [ -n "$SCENARIO" ]; then
  [ -d "$SCEN_BASE/$SCENARIO" ] || die "no scenario '$SCENARIO' under $SCEN_BASE"
  SCEN_DIRS="$SCEN_BASE/$SCENARIO"
else
  for d in "$SCEN_BASE"/*/; do [ -d "$d" ] && SCEN_DIRS="$SCEN_DIRS ${d%/}"; done
  [ -n "$SCEN_DIRS" ] || die "no scenarios found under $SCEN_BASE"
fi

# The claude invocation (overridable for hermetic tests); split into an array
# so a multi-word override ("python3 /x/stub.py") works.
read -r -a CLAUDE_CMD_ARR <<EOF
${FWF_EVAL_CLAUDE_CMD:-claude}
EOF
EVAL_TIMEOUT="${FWF_EVAL_TIMEOUT:-300}"

# Portable hard timeout (macOS has no `timeout`): run the command in the
# background with a watchdog. stdin must be wired EXPLICITLY inside — a
# backgrounded command in a non-interactive script otherwise reads /dev/null,
# silently starving `claude -p` of its prompt. The watchdog detaches its stdio
# AND trap-reaps its own sleep: killing just the subshell orphans the sleep,
# which then holds any captured-stdout pipe open for the full timeout.
run_with_timeout() { # $1=secs $2=stdin-file, rest=command…
  local secs="$1" infile="$2"; shift 2
  "$@" < "$infile" & local pid=$!
  ( trap 'kill "$!" 2>/dev/null; exit 0' TERM
    sleep "$secs" & wait "$!"
    kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null & local wpid=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  return "$rc"
}

claude_call() { # $1=model ("default" = CLI default)  $2=prompt-file  stdout=response
  if [ "$1" = "default" ]; then
    run_with_timeout "$EVAL_TIMEOUT" "$2" "${CLAUDE_CMD_ARR[@]}" -p
  else
    run_with_timeout "$EVAL_TIMEOUT" "$2" "${CLAUDE_CMD_ARR[@]}" -p --model "$1"
  fi
}

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${FWF_EVAL_RESULTS_DIR:-$EVAL_DIR/results}/$TS-$TEMPLATE-$ROLE"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.md"
SCORES="$OUTDIR/scores.tsv"
: > "$SCORES"

{
  echo "# fwf eval — $TEMPLATE/$ROLE"
  echo
  echo "- run: $TS · models: $MODELS · trials/model: $TRIALS · judge: ${JUDGE_MODEL:-default}"
  echo "- prompt: templates/$TEMPLATE/$ROLE.tmpl rendered via profile '$PROFILE'"
  echo
  echo "| scenario | model | trial | score (0-10) | pass |"
  echo "|---|---|---|---|---|"
} > "$REPORT"

FAILED=0
for scen_dir in $SCEN_DIRS; do
  scen="$(basename "$scen_dir")"
  [ -f "$scen_dir/scenario.md" ] || die "$scen is missing scenario.md"
  [ -f "$scen_dir/rubric.md" ]   || die "$scen is missing rubric.md"

  for model in $(printf '%s' "$MODELS" | tr ',' ' '); do
    t=1
    while [ "$t" -le "$TRIALS" ]; do
      tag="$scen-$model-t$t"
      log "candidate: $tag"
      {
        echo "=== EVALUATION HARNESS ==="
        echo "You are an fwf factory agent under evaluation. You CANNOT run commands or use tools; every command output you would observe is already given in the SCENARIO below. Reply with exactly two sections:"
        echo "CYCLE ACTION: the single action path you take this cycle — the exact commands you would run, in order, plus any comment/PR/issue bodies you would post, verbatim."
        echo "REASONING: a brief justification."
        echo
        echo "=== YOUR ROLE PROMPT ==="
        printf '%s\n' "$RENDERED"
        echo
        echo "=== SCENARIO (the state you observe this tick) ==="
        cat "$scen_dir/scenario.md"
      } > "$OUTDIR/$tag.prompt.txt"

      if ! claude_call "$model" "$OUTDIR/$tag.prompt.txt" > "$OUTDIR/$tag.response.txt" 2>"$OUTDIR/$tag.err.txt"; then
        log "candidate FAILED (timeout or error): $tag — see $tag.err.txt"
        echo "| $scen | $model | $t | ERR | — |" >> "$REPORT"
        FAILED=1; t=$((t+1)); continue
      fi

      log "judge:     $tag"
      {
        echo "You are the JUDGE in an evaluation harness for multi-agent factory roles. Score the CANDIDATE RESPONSE against the RUBRIC, in the context of the SCENARIO. Be strict: rubric violations cost their stated points; actions the rubric forbids mean pass=false regardless of score. Output EXACTLY ONE line of JSON and nothing else:"
        echo '{"score": <0-10>, "pass": <true|false>, "violations": ["…"], "rationale": "<one sentence>"}'
        echo
        echo "=== RUBRIC ==="
        cat "$scen_dir/rubric.md"
        echo
        echo "=== SCENARIO ==="
        cat "$scen_dir/scenario.md"
        echo
        echo "=== CANDIDATE RESPONSE ==="
        cat "$OUTDIR/$tag.response.txt"
      } > "$OUTDIR/$tag.judge-prompt.txt"

      if ! claude_call "${JUDGE_MODEL:-default}" "$OUTDIR/$tag.judge-prompt.txt" > "$OUTDIR/$tag.judge.txt" 2>>"$OUTDIR/$tag.err.txt"; then
        log "judge FAILED: $tag"
        echo "| $scen | $model | $t | ERR(judge) | — |" >> "$REPORT"
        FAILED=1; t=$((t+1)); continue
      fi

      score="$(grep -o '"score"[[:space:]]*:[[:space:]]*[0-9.]*' "$OUTDIR/$tag.judge.txt" | head -1 | grep -o '[0-9.]*$' || true)"
      pass="$(grep -o '"pass"[[:space:]]*:[[:space:]]*\(true\|false\)' "$OUTDIR/$tag.judge.txt" | head -1 | grep -o '\(true\|false\)$' || true)"
      if [ -z "$score" ]; then
        log "judge output unparseable: $tag"
        echo "| $scen | $model | $t | ERR(parse) | — |" >> "$REPORT"
        FAILED=1; t=$((t+1)); continue
      fi
      log "scored:    $tag -> $score (pass=$pass)"
      echo "| $scen | $model | $t | $score | ${pass:-?} |" >> "$REPORT"
      printf '%s\t%s\t%s\t%s\n' "$scen" "$model" "$t" "$score" >> "$SCORES"
      t=$((t+1))
    done
  done
done

{
  echo
  echo "## Mean score per model"
  echo
  echo "| model | mean | n |"
  echo "|---|---|---|"
  awk -F'\t' '{ sum[$2]+=$4; n[$2]++ } END { for (m in n) printf "| %s | %.2f | %d |\n", m, sum[m]/n[m], n[m] }' "$SCORES"
} >> "$REPORT"

log "report: $REPORT"
echo
cat "$REPORT"
[ "$FAILED" = 0 ] || { log "one or more trials errored"; exit 1; }
