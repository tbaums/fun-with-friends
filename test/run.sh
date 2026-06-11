#!/usr/bin/env bash
# fun-with-friends functional test suite. Self-contained (no bats), 3.2-clean.
# Exercises detection, name derivation, profile generation (incl. fail-closed),
# the generated profile loading through lib.sh + prompt rendering, and the fwf
# dispatcher's read-only commands. Builds throwaway git fixtures in a tmpdir;
# never touches the real profiles/ dir, the network, tmux, gh, or claude.
#
# Usage: test/run.sh   (exits non-zero on any failure)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fwf-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
# assert_eq <label> <expected> <actual>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
# assert_contains <label> <haystack> <needle>
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] did not contain [$3]";; esac; }
section() { printf '\n# %s\n' "$1"; }

# Build a git fixture repo: mkfix <name> then drop files into $FIX.
mkfix() { FIX="$TMP/$1"; mkdir -p "$FIX"; ( cd "$FIX" && git init -q && git config user.email t@t.co && git config user.name t ); }
commitfix() { ( cd "$FIX" && git add -A && git commit -qm init ); }

source "$ROOT/lib/detect.sh"
source "$ROOT/lib/profile.sh"

# --------------------------------------------------------------------------
section "name derivation"
assert_eq "https .git URL"      "bar"      "$(derive_name https://github.com/foo/bar.git)"
assert_eq "trailing slash"      "bar"      "$(derive_name https://github.com/foo/bar/)"
assert_eq "ssh URL"             "repo"     "$(derive_name git@github.com:foo/repo.git)"
assert_eq "local path"          "myproj"   "$(derive_name /home/me/myproj)"
assert_eq "lowercase + dashes"  "my-cool-repo" "$(derive_name My_Cool.Repo)"

section "url recognition"
is_url https://github.com/a/b.git && ok "https is url"   || bad "https is url"
is_url git@github.com:a/b.git     && ok "ssh is url"     || bad "ssh is url"
is_url /tmp/local                 && bad "path not url"  || ok "path not url"

# --------------------------------------------------------------------------
section "detection: rust workspace"
mkfix rust; printf '[workspace]\nmembers=["a"]\n' > "$FIX/Cargo.toml"
fwf_detect "$FIX"
assert_eq "kind"  "Rust" "$DETECT_KIND"
assert_eq "gate"  "cargo test --workspace" "$DETECT_GATE"
assert_eq "build" "cargo build --workspace" "$DETECT_BUILD"
assert_eq "e2e"   "" "$DETECT_E2E"

section "detection: rust single crate"
mkfix rust1; printf '[package]\nname="a"\n' > "$FIX/Cargo.toml"
fwf_detect "$FIX"
assert_eq "gate (no --workspace)" "cargo test" "$DETECT_GATE"

section "detection: node + pnpm + playwright + typecheck"
mkfix node; printf '{"scripts":{"test":"jest","build":"tsc","dev":"vite","typecheck":"tsc --noEmit"},"devDependencies":{"@playwright/test":"^1"}}\n' > "$FIX/package.json"
printf 'lock\n' > "$FIX/pnpm-lock.yaml"
fwf_detect "$FIX"
assert_eq "kind"  "Node (pnpm)" "$DETECT_KIND"
assert_eq "gate"  "pnpm test && pnpm typecheck" "$DETECT_GATE"
assert_eq "build" "pnpm build" "$DETECT_BUILD"
assert_eq "e2e"   "pnpm exec playwright test" "$DETECT_E2E"
assert_eq "dev"   "pnpm dev" "$DETECT_DEV"

section "detection: node yarn, explicit e2e script wins"
mkfix node2; printf '{"scripts":{"test":"vitest","test:e2e":"playwright test"}}\n' > "$FIX/package.json"
printf 'lock\n' > "$FIX/yarn.lock"
fwf_detect "$FIX"
assert_eq "kind" "Node (yarn)" "$DETECT_KIND"
assert_eq "e2e (explicit script)" "yarn test:e2e" "$DETECT_E2E"

section "detection: go"
mkfix go; printf 'module x\n' > "$FIX/go.mod"
fwf_detect "$FIX"
assert_eq "kind"  "Go" "$DETECT_KIND"
assert_eq "gate"  "go test ./..." "$DETECT_GATE"
assert_eq "build" "go build ./..." "$DETECT_BUILD"

section "detection: python poetry"
mkfix py; printf '[tool.poetry]\nname="x"\n' > "$FIX/pyproject.toml"
fwf_detect "$FIX"
assert_eq "kind" "Python (poetry)" "$DETECT_KIND"
assert_eq "gate" "poetry run pytest" "$DETECT_GATE"

section "detection: unknown"
mkfix blank; echo hi > "$FIX/README"
fwf_detect "$FIX"
assert_eq "kind" "unknown" "$DETECT_KIND"
assert_eq "gate" "" "$DETECT_GATE"

# --------------------------------------------------------------------------
section "profile generation: detected node repo"
mkfix gennode; printf '{"scripts":{"test":"jest","build":"tsc"},"devDependencies":{"@playwright/test":"^1"}}\n' > "$FIX/package.json"
commitfix
fwf_detect "$FIX"
OUT="$TMP/gennode.sh"
fwf_write_profile "$OUT" "gennode" "$FIX" "$TMP/ws" "main"
bash -n "$OUT" && ok "generated profile is valid bash" || bad "generated profile is valid bash"
PROF="$(cat "$OUT")"
assert_contains "has FWF_REPO"  "$PROF" "FWF_REPO=\"\${FWF_REPO:-$FIX}\""
assert_contains "playwright e2e setup added" "$PROF" "E2E_SETUP_CMD='npx playwright install'"

section "profile generation: unknown repo is FAIL-CLOSED"
mkfix genblank; echo x > "$FIX/README"
fwf_detect "$FIX"
OUT="$TMP/genblank.sh"
fwf_write_profile "$OUT" "genblank" "$FIX" "$TMP/ws" "master"
GATE_LINE="$(grep '^GATE_CMD=' "$OUT")"
assert_contains "gate fails closed (false)" "$GATE_LINE" "false"
assert_contains "e2e defaults to true"      "$(grep '^E2E_CMD=' "$OUT")" "E2E_CMD='true'"
assert_contains "default branch baked in"   "$(grep '^DEFAULT_BRANCH=' "$OUT")" "master"

section "generated profile loads via lib.sh and renders a prompt"
# Put the generated profile where lib.sh looks, in an isolated FWF_DIR copy.
RUN="$(FWF_PROFILE="" bash -c '
  set -e
  cp "'"$OUT"'" "'"$ROOT"'/profiles/.__test_genblank.sh"
  trap "rm -f '"$ROOT"'/profiles/.__test_genblank.sh" EXIT
  FWF_PROFILE=.__test_genblank bash -c "source '"$ROOT"'/lib.sh; printf \"%s|%s\" \"\$DEFAULT_BRANCH\" \"\$(fwf_render '"$ROOT"'/templates/dev/qa.tmpl 1 | cut -c1-12)\""
')"
assert_eq "lib.sh sees baked default branch" "master" "${RUN%%|*}"
assert_contains "qa prompt renders" "${RUN#*|}" "You are qa1"

section "implementer prompt carries the atomic-claim protocol"
IMPL_RUN="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 2")"
assert_contains "claim comment is the mutex"   "$IMPL_RUN" "CLAIM impl2"
assert_contains "claim is verified after post" "$IMPL_RUN" "RE-CHECK you won"
assert_contains "captain assignment honored"   "$IMPL_RUN" "ASSIGNED impl2"

# --------------------------------------------------------------------------
section "dispatcher: read-only commands"
assert_eq "version"        "$(cat "$ROOT/VERSION")" "$("$ROOT/fwf" version)"
assert_eq "-v alias"       "$(cat "$ROOT/VERSION")" "$("$ROOT/fwf" -v)"
assert_eq "--version alias" "$(cat "$ROOT/VERSION")" "$("$ROOT/fwf" --version)"
assert_contains "help mentions start" "$("$ROOT/fwf" help)" "start <url|path>"
# doctor reports tool status and exits non-zero if any are missing (correct on a
# bare runner with no tmux/gh/claude) — assert it RAN, not that it returned 0.
DOC="$("$ROOT/fwf" doctor 2>&1 || true)"
assert_contains "doctor runs" "$DOC" "workspace :"
# profiles lists at least the example template shipped in the repo
assert_contains "profiles lists shipped profile" "$("$ROOT/fwf" profiles)" "example"
# captain --print renders the CAPTAIN prompt with placeholders resolved
CAPTAIN="$("$ROOT/fwf" --profile example captain --print 2>&1)"
assert_contains "captain --print renders prompt" "$CAPTAIN" "CAPTAIN"
assert_contains "captain resolves placeholders"  "$CAPTAIN" "staging"

section "dispatcher: resume --clear-only clears the sentinel"
RUNDIR="$TMP/run"; mkdir -p "$RUNDIR"; : > "$RUNDIR/STOP"
RES="$(FWF_RUN_DIR="$RUNDIR" "$ROOT/fwf" --profile example resume --clear-only 2>&1)"
[ -e "$RUNDIR/STOP" ] && bad "resume --clear-only removes sentinel" || ok "resume --clear-only removes sentinel"
assert_contains "resume --clear-only message" "$RES" "cleared STOP sentinel"

section "floor lifecycle flags (issue #6) — no live tmux needed"
# Isolated session names guarantee we never touch a real factory.
FU_ENV="FWF_PROFILE=example FWF_SESSION=fwf-selftest-$$"
# up: unknown flag rejected before any tmux work
env $FU_ENV "$ROOT/fwf-up.sh" --bogus >/dev/null 2>&1 && bad "up rejects unknown flag" || ok "up rejects unknown flag"
# up --floor-only without a live coord session points at the full launch path
UPOUT="$(env $FU_ENV "$ROOT/fwf-up.sh" --floor-only 2>&1)" && bad "floor-only up needs coord session" || ok "floor-only up needs coord session"
assert_contains "floor-only up suggests full up" "$UPOUT" "run a full 'fwf up' instead"
# down: --floor-only + --purge don't combine
env $FU_ENV "$ROOT/fwf-down.sh" --floor-only --purge >/dev/null 2>&1 && bad "down rejects floor-only+purge" || ok "down rejects floor-only+purge"
# down --floor-only with nothing up reports cleanly and leaves captain advice
DOWNOUT="$(env $FU_ENV "$ROOT/fwf-down.sh" --floor-only 2>&1)" && ok "floor-only down is safe when nothing is up" || bad "floor-only down is safe when nothing is up"
assert_contains "floor-only down names the comeback" "$DOWNOUT" "fwf up --floor-only"
# help advertises the floor lifecycle
assert_contains "help mentions --floor-only" "$("$ROOT/fwf" help)" "--floor-only"

section "runtime sizing + models (issue #7)"
# PAIRS derives from FWF_PAIRS after the profile loads
ROLES5="$(FWF_PAIRS=5 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_all_roles" )"
assert_eq "FWF_PAIRS=5 -> 14 roles" "14" "$(printf '%s\n' "$ROLES5" | grep -c .)"
assert_contains "impl5 exists" "$ROLES5" "impl5"
assert_contains "qa5 exists"   "$ROLES5" "qa5"
# bogus pair counts are rejected at source time
FWF_PAIRS=banana FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_PAIRS=banana rejected" || ok "FWF_PAIRS=banana rejected"
FWF_PAIRS=0      FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_PAIRS=0 rejected"      || ok "FWF_PAIRS=0 rejected"
# per-role model overrides layer correctly: role beats floor-wide beats none
CMDS="$(FWF_MODEL=haiku FWF_MODEL_IMPL=sonnet FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd impl2; echo; fwf_claude_cmd qa1; echo; fwf_claude_cmd pm")"
assert_contains "impl override wins"        "$(printf '%s' "$CMDS" | sed -n 1p)" "--model sonnet"
assert_contains "floor default reaches qa"  "$(printf '%s' "$CMDS" | sed -n 2p)" "--model haiku"
assert_contains "floor default reaches pm"  "$(printf '%s' "$CMDS" | sed -n 3p)" "--model haiku"
NOMODEL="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd impl1")"
case "$NOMODEL" in *--model*) bad "no override -> no --model flag";; *) ok "no override -> no --model flag";; esac
# pair colors cycle for any pair count
C4="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; pair_color 4")"
C7="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; pair_color 7")"
C1="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; pair_color 1")"
[ -n "$C4" ] && ok "pair_color 4 defined" || bad "pair_color 4 defined"
assert_eq "palette cycles (7 wraps to 1)" "$C1" "$C7"
# respawn refuses a role beyond the configured floor (before any tmux work)
RSP="$(FWF_PAIRS=2 FWF_PROFILE=example "$ROOT/fwf-respawn.sh" impl3 2>&1)" && bad "respawn beyond floor rejected" || ok "respawn beyond floor rejected"
assert_contains "respawn names the bound" "$RSP" "FWF_PAIRS=2"
# dispatcher accepts the flags after the subcommand and validates them
UPFLAG="$(FWF_PROFILE=example "$ROOT/fwf" up --pairs banana 2>&1)" && bad "fwf up --pairs banana rejected" || ok "fwf up --pairs banana rejected"
assert_contains "rejection is the lib.sh guard" "$UPFLAG" "positive integer"
assert_contains "help mentions --pairs"      "$("$ROOT/fwf" help)" "--pairs N"
assert_contains "help mentions --impl-model" "$("$ROOT/fwf" help)" "--impl-model"

section "factory templates (issue #10)"
TLIST="$("$ROOT/fwf" templates)"
assert_contains "templates lists dev"      "$TLIST" "dev"
assert_contains "templates lists refactor" "$TLIST" "refactor"
assert_contains "help mentions --template" "$("$ROOT/fwf" help)" "--template NAME"
# unknown template rejected at source time
FWF_TEMPLATE=bogus FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "unknown template rejected" || ok "unknown template rejected"
# an incomplete template (missing role tmpls) is rejected with the role named
mkdir -p "$ROOT/templates/.__broken"; : > "$ROOT/templates/.__broken/implementer.tmpl"
BROKEN="$(FWF_TEMPLATE=.__broken FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" 2>&1)" && bad "incomplete template rejected" || ok "incomplete template rejected"
assert_contains "missing role named" "$BROKEN" "has no qa.tmpl"
rm -rf "$ROOT/templates/.__broken"
# refactor template: prompts render with the behavior-preservation spine intact
RIMPL="$(FWF_TEMPLATE=refactor FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/implementer.tmpl\" 1")"
assert_contains "refactorer characterizes first"   "$RIMPL" "CHARACTERIZE FIRST"
assert_contains "refactorer keeps claim protocol"  "$RIMPL" "CLAIM impl1"
assert_contains "refactorer never edits expectations" "$RIMPL" "NEVER EDIT EXISTING TEST EXPECTATIONS"
RQA="$(FWF_TEMPLATE=refactor FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/qa.tmpl\" 1")"
assert_contains "verifier checks behavior contract" "$RQA" "BEHAVIOR-CONTRACT CHECK"
# template.sh defaults apply (refactor => 2 pairs) and env still wins
assert_eq "refactor defaults to 2 pairs" "8"  "$(FWF_TEMPLATE=refactor FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_all_roles" | grep -c .)"
assert_eq "env FWF_PAIRS beats template" "10" "$(FWF_PAIRS=3 FWF_TEMPLATE=refactor FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_all_roles" | grep -c .)"
# captain --print honors --template
RCAP="$("$ROOT/fwf" --profile example captain --print --template refactor 2>&1)"
assert_contains "captain --print honors --template" "$RCAP" "REFACTORING FACTORY"

section "ideation template (issue #9)"
assert_contains "templates lists ideation" "$("$ROOT/fwf" templates)" "ideation"
IGEN="$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/implementer.tmpl\" 2")"
assert_contains "generator has a stance"          "$IGEN" "ANALOGY TRANSFER"
assert_contains "generator diverges before reading" "$IGEN" "DIVERGE FIRST, READ THE PORTFOLIO SECOND"
assert_contains "generator never closes challenges" "$IGEN" "the challenge outlives your batch"
ICRIT="$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/qa.tmpl\" 1")"
assert_contains "critic hardens feasibility"  "$ICRIT" "NOVEL-BUT-INFEASIBLE"
assert_contains "critic protects the weird"   "$ICRIT" "protect the weird ones"
ISYN="$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$FWF_TEMPLATE_DIR/conductor.tmpl\" ''")"
assert_contains "synthesizer owns the portfolio" "$ISYN" "PORTFOLIO.md"
assert_contains "synthesizer ranks pairwise"     "$ISYN" "PAIRWISE"
assert_eq "ideation keeps 3 pairs" "10" "$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_all_roles" | grep -c .)"

section "extra roles + template inheritance (issue #17)"
assert_contains "templates lists dev-sre" "$("$ROOT/fwf" templates)" "dev-sre"
# dev-sre adds the sre role to the roster (11 = 10 stock + sre)
SRE_ROLES="$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_all_roles")"
assert_eq "dev-sre roster is 11 roles" "11" "$(printf '%s\n' "$SRE_ROLES" | grep -c .)"
assert_contains "sre in roster" "$SRE_ROLES" "sre"
# extra-role metadata parses
assert_eq "sre session"  "coord" "$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_extra_session sre")"
assert_eq "sre interval" "2m"    "$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_extra_interval sre")"
# prompt inheritance: implementer falls back to the dev base; captain is overridden
SRE_IMPL="$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path implementer)\" 1")"
assert_contains "implementer inherited from dev" "$SRE_IMPL" "You are implementer impl1"
SRE_CAP="$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path captain)\" ''")"
assert_contains "captain override: one-writer contract" "$SRE_CAP" "ZERO ops actions"
SRE_TMPL="$(FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path sre)\" ''")"
assert_contains "sre prompt: not human-facing" "$SRE_TMPL" "NOT human-facing"
assert_contains "sre prompt: root-cause directive" "$SRE_TMPL" "ESCALATE TO ROOT CAUSE"
# a declared extra role without a resolvable tmpl is rejected at source time
FWF_EXTRA_ROLES="ghost:coord:1m" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "missing extra tmpl rejected" || ok "missing extra tmpl rejected"
# respawn recognizes the extra role (fails on the absent session, not usage)
SRER="$(FWF_TEMPLATE=dev-sre FWF_SESSION=fwf-selftest-$$ FWF_PROFILE=example "$ROOT/fwf-respawn.sh" sre 2>&1)" && bad "respawn sre recognized" || ok "respawn sre recognized"
assert_contains "respawn sre fails on session, not usage" "$SRER" "no tmux session"

section "eval harness (issue #8) — hermetic, stubbed claude"
STUB="$TMP/claude-stub.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
echo '{"score": 7.5, "pass": true, "violations": [], "rationale": "stub"}'
EOS
chmod +x "$STUB"
EVOUT="$TMP/eval-results"
EVRUN="$(FWF_EVAL_CLAUDE_CMD="$STUB" FWF_EVAL_RESULTS_DIR="$EVOUT" "$ROOT/eval/run.sh" \
  --role implementer --template dev --scenario claim-race --models alpha,beta --trials 2 2>&1)" \
  && ok "eval run exits 0" || bad "eval run exits 0" "$EVRUN"
EVREPORT="$(ls "$EVOUT"/*/report.md 2>/dev/null | head -1)"
[ -n "$EVREPORT" ] && ok "report written" || bad "report written"
assert_contains "both models in report"   "$(cat "$EVREPORT")" "| claim-race | beta | 2 | 7.5 | true |"
assert_contains "mean table present"      "$(cat "$EVREPORT")" "Mean score per model"
assert_contains "mean computed"           "$(cat "$EVREPORT")" "| alpha | 7.50 | 2 |"
TRANSCRIPTS="$(find "$EVOUT" -name '*.response.txt' | grep -c .)"
assert_eq "4 candidate transcripts saved" "4" "$TRANSCRIPTS"
assert_contains "prompt embeds the real role prompt" "$(cat "$EVOUT"/*/claim-race-alpha-t1.prompt.txt)" "You are implementer impl1"
assert_contains "prompt embeds the scenario"         "$(cat "$EVOUT"/*/claim-race-alpha-t1.prompt.txt)" "CLAIM impl3"
# guard rails
"$ROOT/eval/run.sh" --role bogus --models x >/dev/null 2>&1 && bad "unknown role rejected" || ok "unknown role rejected"
"$ROOT/eval/run.sh" --role qa >/dev/null 2>&1 && bad "missing --models rejected" || ok "missing --models rejected"
FWF_EVAL_CLAUDE_CMD="$STUB" FWF_EVAL_RESULTS_DIR="$EVOUT" "$ROOT/eval/run.sh" --role qa --template dev --scenario nope --models a >/dev/null 2>&1 && bad "unknown scenario rejected" || ok "unknown scenario rejected"
# every shipped scenario dir is complete (scenario.md + rubric.md)
SCEN_OK=1
for d in "$ROOT"/eval/scenarios/*/*/*/; do
  [ -f "$d/scenario.md" ] && [ -f "$d/rubric.md" ] || { SCEN_OK=0; bad "scenario complete: $d"; }
done
[ "$SCEN_OK" = 1 ] && ok "all shipped scenarios complete"
assert_contains "help mentions eval" "$("$ROOT/fwf" help)" "eval --role"

section "fwf suggest (issue #23) — hermetic, stubbed advisor"
SGSTUB="$TMP/suggest-stub.sh"
cat > "$SGSTUB" <<EOS
#!/usr/bin/env bash
cat > "$TMP/suggest-prompt.txt"
echo "STUB-ADVICE: prebuilt: refactor"
EOS
chmod +x "$SGSTUB"
SOUT="$(FWF_SUGGEST_CLAUDE_CMD="$SGSTUB" "$ROOT/fwf" suggest "make my legacy python monolith maintainable without changing behavior" 2>/dev/null)" \
  && ok "suggest exits 0" || bad "suggest exits 0"
assert_contains "advisor response passed through" "$SOUT" "STUB-ADVICE"
SPROMPT="$(cat "$TMP/suggest-prompt.txt")"
assert_contains "prompt embeds the goal"          "$SPROMPT" "legacy python monolith"
assert_contains "catalog lists dev"               "$SPROMPT" "- dev: classic feature factory"
assert_contains "catalog lists refactor"          "$SPROMPT" "- refactor: behavior-preserving"
assert_contains "catalog lists ideation"          "$SPROMPT" "- ideation: ideation factory"
assert_contains "catalog lists dev-sre"           "$SPROMPT" "- dev-sre: dev factory"
assert_contains "catalog carries inheritance"     "$SPROMPT" "(inherits everything else from 'dev')"
assert_contains "catalog carries extra panes"     "$SPROMPT" "FWF_EXTRA_ROLES"
assert_contains "model menu included"             "$SPROMPT" "claude-haiku-4-5-20251001"
assert_contains "answer contract included"        "$SPROMPT" "## Per-role models"
assert_contains "eval verification taught"        "$SPROMPT" "fwf eval --role"
assert_contains "canonical launch shape taught"   "$SPROMPT" "fwf up --template NAME"
# extra roles honor FWF_MODEL_<NAME> (the knob the advisor recommends)
SREMODEL="$(FWF_MODEL_SRE=opus-test FWF_TEMPLATE=dev-sre FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd sre")"
assert_contains "FWF_MODEL_SRE honored" "$SREMODEL" "--model opus-test"
# advisor --model is NOT swallowed by the dispatcher's runtime-flag parser
FWF_SUGGEST_CLAUDE_CMD="$SGSTUB" "$ROOT/fwf" suggest --model test-model "any goal" >/dev/null 2>&1 \
  && ok "suggest --model accepted" || bad "suggest --model accepted"
[ -z "${FWF_MODEL:-}" ] && ok "suggest --model not exported as FWF_MODEL" || bad "suggest --model leaked"
# stdin path and the empty-goal guard
printf 'ship a v1 quickly' | FWF_SUGGEST_CLAUDE_CMD="$SGSTUB" "$ROOT/fwf" suggest >/dev/null 2>&1
assert_contains "stdin goal works" "$(cat "$TMP/suggest-prompt.txt")" "ship a v1 quickly"
"$ROOT/fwf" suggest </dev/null >/dev/null 2>&1 && bad "empty goal rejected" || ok "empty goal rejected"
assert_contains "help mentions suggest" "$("$ROOT/fwf" help)" "suggest <description>"

section "dispatcher: bad input is rejected"
"$ROOT/fwf" bogus-cmd >/dev/null 2>&1 && bad "unknown command rejected" || ok "unknown command rejected"
"$ROOT/fwf" init >/dev/null 2>&1 && bad "init without arg rejected" || ok "init without arg rejected"

# --------------------------------------------------------------------------
section "shellcheck (if available)"
if command -v shellcheck >/dev/null 2>&1; then
  # Policy: fail on warnings + errors; allow info-level style nits (the
  # `cmd && ok || bad` idiom, intentional word-splitting). SC2034 is annotated
  # at the top of config/profile files (vars consumed in other sourced scripts).
  # Lint only the repo's shipped scripts — not user-local/generated profiles,
  # which live in profiles/ but aren't part of the repo.
  if shellcheck -s bash -S warning \
       "$ROOT/fwf" "$ROOT"/*.sh "$ROOT"/lib/*.sh "$ROOT/profiles/example.sh" \
       "$ROOT"/templates/*/template.sh "$ROOT/eval/run.sh" "$ROOT/test/run.sh"; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported issues"
  fi
else
  printf '  skip shellcheck (not installed)\n'
fi

# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
