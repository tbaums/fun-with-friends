#!/usr/bin/env bash
# fwf suggest — describe what you're trying to do; get a factory design back.
#
# Builds a catalog of the SHIPPED templates dynamically (templates/*/ —
# description, roles, base, defaults), composes an advisor prompt around your
# goal, and asks claude to recommend either a prebuilt template or a custom
# design — launch command, per-role model picks from $FWF_MODEL_MENU with
# rationale, a template.sh sketch when custom is warranted, and the fwf eval
# commands that would verify the model picks.
#
# Needs no profile — this is exactly what you run BEFORE you have one.
#
# Usage: fwf-suggest.sh [--model M] <description of what you're trying to do>
#        (or pipe the description on stdin)
# Env:   FWF_SUGGEST_CLAUDE_CMD  command to invoke instead of `claude`
#        FWF_SUGGEST_TIMEOUT     hard timeout in seconds (default 300)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"   # FWF_MODEL_MENU + generic knob names; profile NOT required

die() { echo "fwf suggest: $*" >&2; exit 1; }

ADVISOR_MODEL=""
GOAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)   [ $# -ge 2 ] || die "--model needs a value"; ADVISOR_MODEL="$2"; shift 2;;
    --model=*) ADVISOR_MODEL="${1#*=}"; shift;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) GOAL="$GOAL $1"; shift;;
  esac
done
GOAL="${GOAL# }"
if [ -z "$GOAL" ] && [ ! -t 0 ]; then GOAL="$(cat)"; fi
[ -n "$GOAL" ] || die "describe what you're trying to do: fwf suggest \"refactor my legacy monolith safely\""

# --- catalog the shipped templates from disk (stays true as templates evolve) --
catalog() {
  local d name desc base extras pairs roles t
  for d in "$DIR"/templates/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    desc=""; base=""; extras=""; pairs=""
    if [ -f "$d/template.sh" ]; then
      desc="$(sed -n 's/^# fwf template: //p' "$d/template.sh" | head -1)"
      base="$(sed -n 's/^FWF_TEMPLATE_BASE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$d/template.sh" | head -1)"
      extras="$(grep '^FWF_EXTRA_ROLES=' "$d/template.sh" | head -1 || true)"
      pairs="$(grep '^FWF_PAIRS=' "$d/template.sh" | head -1 || true)"
    fi
    roles=""
    for t in "$d"*.tmpl; do [ -e "$t" ] && roles="$roles $(basename "$t" .tmpl)"; done
    echo "- ${name}: ${desc:-no description}"
    echo "    own prompt files:${roles:- none}${base:+   (inherits everything else from '$base')}"
    [ -n "$pairs" ]  && echo "    default sizing: $pairs"
    [ -n "$extras" ] && echo "    extra panes:    $extras"
  done
  return 0   # the loop's last conditional must not become our exit status (set -e)
}

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/fwf-suggest.XXXXXX")"
trap 'rm -f "$PROMPT_FILE"' EXIT
{
  cat <<'EOF'
You are the FACTORY-DESIGN ADVISOR for fun-with-friends (fwf) — a tool that
stands up a multi-agent Claude Code factory over a git repo as two tmux
sessions: a coordination session (PM, GV/strategic critic, CAPTAIN — the one
pane the human talks to) and a floor of N implementer/QA pairs plus a
conductor. Work flows: gated issue specs (PM, hardened by GV) → atomic-claimed
branches → QA-gated merges to staging → conductor-gated promotion to
integration → human-approved release. A factory TEMPLATE re-aims every role's
prompt (and optionally adds panes) while reusing all of that machinery.

The human will describe what they are trying to do. Recommend the best factory
design for it. You CANNOT run commands; everything you need is below.

== SHIPPED TEMPLATES (catalog generated from this installation) ==
EOF
  catalog
  cat <<EOF

== RUNTIME KNOBS ==
- The launch command shape is EXACTLY: fwf up --template NAME [flags]
  (flags come AFTER the subcommand; 'up' is required).
- --pairs N — implementer/QA pair count. More pairs = throughput on INDEPENDENT
  work; refactor-shaped work collides on shared files and wants FEWER pairs.
- --model M and per-role --impl-model / --qa-model / --pm-model / --gv-model /
  --captain-model / --conductor-model (persist as FWF_MODEL / FWF_MODEL_<ROLE>).
  EXTRA roles have no CLI flag — set their model as an env var on the launch:
  FWF_MODEL_<NAME> (uppercased), e.g. FWF_MODEL_SRE=… fwf up --template dev-sre.
- Custom templates: a directory templates/<name>/ with role .tmpl files plus
  template.sh; FWF_TEMPLATE_BASE="<existing>" inherits any prompt not
  overridden; FWF_EXTRA_ROLES="name:session:interval[:color]" adds panes.

== MODEL MENU (recommend ONLY from these ids) ==
$(printf '%s' "$FWF_MODEL_MENU" | tr '|' '\n' | sed 's/^ */- /')

== MODEL-ASSIGNMENT HEURISTIC ==
Match strength to seat, not prestige to everything: high-volume mechanical
seats with a deterministic gate (QA gate runs, surveying) tolerate the cheap
model; building (implementers) wants the all-rounder; synthesis, strategy, and
judgment seats (captain, GV, refactor-planner, portfolio-synthesizer) are
where the strong model pays for itself. The human can VERIFY any pick with
'fwf eval --role <role> [--template <t>] --models <a>,<b>' — role-level
scenario evals scored by an LLM judge.

== THE HUMAN'S GOAL ==
$GOAL

== ANSWER FORMAT (markdown, exactly these sections) ==
## Recommendation
One line: "prebuilt: <name>" or "custom: <proposed-name> (base: <name>)".
## Why
Short paragraph tying the goal to the design; name the strongest alternative
and why it loses.
## Launch
One fenced bash block with the exact command(s), including --pairs and every
per-role model flag you recommend.
## Per-role models
A table: role | model | why (one line each). Cover every seat the design runs.
## Custom template sketch
ONLY if custom: a fenced bash block with the complete template.sh
(description line, FWF_TEMPLATE_BASE, FWF_PAIRS/FWF_EXTRA_ROLES defaults),
then a bullet list of which role prompts to override and the ONE behavioral
change each override makes. If prebuilt: write "not needed".
## Verify
1-3 fwf eval commands that would sanity-check the riskiest model picks, and
one sentence on what result would change your recommendation.
EOF
} > "$PROMPT_FILE"

# claude invocation (overridable for hermetic tests); array-split so a
# multi-word override works.
read -r -a CLAUDE_CMD_ARR <<EOF2
${FWF_SUGGEST_CLAUDE_CMD:-claude}
EOF2

# Portable hard timeout; stdin wired EXPLICITLY inside (a backgrounded command
# otherwise reads /dev/null and starves claude -p). The watchdog detaches its
# stdio AND trap-reaps its own sleep: an orphaned sleep would otherwise hold a
# captured-stdout pipe open and block callers like $(fwf suggest …) for the
# full timeout.
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

echo "fwf suggest: thinking about: $GOAL" >&2
if [ -n "$ADVISOR_MODEL" ]; then
  run_with_timeout "${FWF_SUGGEST_TIMEOUT:-300}" "$PROMPT_FILE" "${CLAUDE_CMD_ARR[@]}" -p --model "$ADVISOR_MODEL" \
    || die "advisor call failed or timed out"
else
  run_with_timeout "${FWF_SUGGEST_TIMEOUT:-300}" "$PROMPT_FILE" "${CLAUDE_CMD_ARR[@]}" -p \
    || die "advisor call failed or timed out"
fi
