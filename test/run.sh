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

section "fwf upgrade — hermetic, stubbed gh"
GHSTUB="$TMP/ghstub"; mkdir -p "$GHSTUB"
cat > "$GHSTUB/gh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  api) [ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1; echo "${FAKE_LATEST:-v0.0.0}";;
  release)  # gh release download TAG -R repo -p pat -D destdir
    dest=""
    while [ $# -gt 0 ]; do [ "$1" = "-D" ] && dest="$2"; shift; done
    cp "$FWF_TEST_TARBALL" "$dest/";;
  *) exit 1;;
esac
EOS
chmod +x "$GHSTUB/gh"
REALV="$(cat "$ROOT/VERSION")"
assert_contains "help mentions upgrade" "$("$ROOT/fwf" help)" "upgrade [--check]"
"$ROOT/fwf" upgrade --bogus >/dev/null 2>&1 && bad "upgrade rejects unknown flag" || ok "upgrade rejects unknown flag"
UPC="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v$REALV" "$ROOT/fwf" upgrade --check 2>&1)" && ok "--check up-to-date exits 0" || bad "--check up-to-date exits 0"
assert_contains "up-to-date reported" "$UPC" "up to date"
UPA="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v99.0.0" "$ROOT/fwf" upgrade --check 2>&1)"
assert_contains "upgrade-available reported" "$UPA" "upgrade available"
UPF="$(PATH="$GHSTUB:$PATH" FAKE_GH_FAIL=1 "$ROOT/fwf" upgrade --check 2>&1)" && bad "gh failure exits nonzero" || ok "gh failure exits nonzero"
assert_contains "gh failure hints at clone pull" "$UPF" "pull --ff-only"

# end-to-end TARBALL upgrade: old extracted install -> stubbed latest release
bash "$ROOT/scripts/package.sh" >/dev/null
TARBALL="$ROOT/dist/fwf-$REALV.tar.gz"
UPHOME="$TMP/upgrade"; mkdir -p "$UPHOME/bin"
tar -C "$UPHOME" -xzf "$TARBALL" && mv "$UPHOME/fwf-$REALV" "$UPHOME/fwf-old"
printf '0.0.1\n' > "$UPHOME/fwf-old/VERSION"
UPOUT="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v$REALV" FWF_TEST_TARBALL="$TARBALL" FWF_UPGRADE_BIN="$UPHOME/bin" \
  "$UPHOME/fwf-old/fwf" upgrade 2>&1)" && ok "tarball upgrade exits 0" || bad "tarball upgrade exits 0" "$UPOUT"
[ -x "$UPHOME/fwf-$REALV/fwf" ] && ok "new version extracted alongside" || bad "new version extracted alongside"
LINK="$(readlink "$UPHOME/bin/fwf" || true)"
assert_contains "symlink re-pointed to new install" "$LINK" "fwf-$REALV/fwf"
[ -d "$UPHOME/fwf-old" ] && ok "old install left for rollback" || bad "old install left for rollback"
assert_eq "upgraded copy reports new version" "$REALV" "$("$UPHOME/bin/fwf" version)"
assert_contains "respawn note printed" "$UPOUT" "fwf respawn"
rm -rf "$ROOT/dist"

section "local issues backend (issue #26) — store CLI"
ISSRUN="$TMP/issrun"
ISS() { FWF_RUN_DIR="$ISSRUN" FWF_PROFILE=example "$ROOT/fwf-issues.sh" "$@"; }
OUT="$(ISS create --title "Fix pagination" --body "page 2 repeats an item" --label product-wip --label bug)"
assert_contains "create prints number + path" "$OUT" "LI-1 created"
ISS create --title "Dark mode" >/dev/null
[ -f "$ISSRUN"/issues/example/open/1-fix-pagination.md ] && ok "one md file per issue, status dir" || bad "issue file layout"
assert_contains "list shows both"         "$(ISS list)" "LI-2"
assert_contains "label filter"            "$(ISS list --label bug)" "LI-1"
LSEARCH="$(ISS list --search "is:open -label:product-wip")"
assert_contains "search negative label keeps LI-2" "$LSEARCH" "LI-2"
case "$LSEARCH" in *LI-1*) bad "search negative label drops LI-1";; *) ok "search negative label drops LI-1";; esac
# claim mutex semantics: append-ordered comments, first CLAIM wins
ISS comment 1 --body "CLAIM impl2" >/dev/null
ISS comment 1 --body "CLAIM impl1" >/dev/null
if command -v jq >/dev/null 2>&1; then
  assert_eq "first CLAIM wins" "CLAIM impl2" "$(ISS view 1 --json comments --jq '[.comments[] | select(.body|startswith("CLAIM "))][0].body')"
  assert_eq "labels json shape" "product-wip" "$(ISS view 1 --json labels --jq '.labels[0].name')"
  assert_eq "list json titles" "Dark mode" "$(ISS list --json number,title --jq '.[1].title')"
else
  printf '  skip jq-dependent assertions (jq not installed)\n'
fi
# edit/close/reopen/export
ISS edit 1 --remove-label product-wip --add-label approved >/dev/null
assert_contains "edit relabeled" "$(ISS list --label approved)" "LI-1"
ISS close 2 --comment "dup of LI-1" >/dev/null
assert_contains "closed moved state" "$(ISS list --state closed)" "LI-2"
[ -f "$ISSRUN"/issues/example/closed/2-dark-mode.md ] && ok "close moves the file" || bad "close moves the file"
ISS reopen 2 >/dev/null
assert_contains "reopen moves back" "$(ISS list)" "LI-2"
EXP="$(ISS export)"
assert_contains "export carries body"     "$EXP" "page 2 repeats an item"
assert_contains "export carries comments" "$EXP" "CLAIM impl1"
ISS view 99 >/dev/null 2>&1 && bad "missing issue rejected" || ok "missing issue rejected"
# removing the LAST label must not die (pipefail regression) and must unblock surveys
ISS create --title "Gated thing" --label product-wip >/dev/null
ISS edit 3 --remove-label product-wip >/dev/null 2>&1 && ok "remove last label survives" || bad "remove last label survives"
assert_contains "un-gated issue enters survey" "$(ISS list --search "is:open -label:product-wip")" "LI-3"

section "local issues backend — render integration"
LIMPL="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 1")"
assert_contains "gh issue rewritten to fwf issues" "$LIMPL" "fwf --profile example issues list"
case "$LIMPL" in *"gh issue"*) bad "no gh issue remains";; *) ok "no gh issue remains";; esac
assert_contains "issue refs become LI-"   "$LIMPL" "Closes LI-<num>"
assert_contains "implementer addendum appended" "$LIMPL" "LOCAL ISSUES MODE"
LCAP="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/captain.tmpl' ''")"
assert_contains "captain closes at release"  "$LCAP" "CLOSE SHIPPED ISSUES AT RELEASE"
assert_contains "captain mines the store"    "$LCAP" "issues export"
GHIMPL="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 1")"
assert_contains "gh mode untouched: gh issue" "$GHIMPL" "gh issue list"
assert_contains "gh mode untouched: Closes #" "$GHIMPL" "Closes #<num>"
case "$GHIMPL" in *"LOCAL ISSUES MODE"*) bad "gh mode has no addendum";; *) ok "gh mode has no addendum";; esac
FWF_ISSUES=bogus FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "bogus backend rejected" || ok "bogus backend rejected"
case "$("$ROOT/fwf" templates)" in *_local-issues*) bad "_local-issues hidden from templates";; *) ok "_local-issues hidden from templates";; esac
assert_contains "help mentions --issues" "$("$ROOT/fwf" help)" "--issues gh|local"

section "no-push guard in local mode (issue #28) — real git fixture"
PUSHD="$TMP/push"; mkdir -p "$PUSHD"
git init -q --bare "$PUSHD/origin.git"
git clone -q "$PUSHD/origin.git" "$PUSHD/repo" 2>/dev/null
( cd "$PUSHD/repo" && git config user.email t@t.co && git config user.name t \
  && echo hi > README && git add -A && git commit -qm init && git branch -M main && git push -q origin main )
cat > "$ROOT/profiles/.__pushtest.sh" <<EOF
FWF_REPO="$PUSHD/repo"
WT_PREFIX="pt"
WT_BASE="$PUSHD/wt"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
EOF
# local mode provision: ladder stays local, guard installed, nothing pushed
FWF_ISSUES=local FWF_RUN_DIR="$PUSHD/run" FWF_PROFILE=.__pushtest "$ROOT/fwf-provision.sh" >/dev/null 2>&1 \
  && ok "local provision runs" || bad "local provision runs"
git -C "$PUSHD/repo" show-ref --verify --quiet refs/heads/staging && ok "staging exists locally" || bad "staging exists locally"
git --git-dir "$PUSHD/origin.git" show-ref --quiet refs/heads/staging && bad "staging NOT pushed" || ok "staging NOT pushed"
git --git-dir "$PUSHD/origin.git" show-ref --quiet refs/heads/integration && bad "integration NOT pushed" || ok "integration NOT pushed"
PUSHHOOK="$(git -C "$PUSHD/repo" rev-parse --absolute-git-dir)/hooks/pre-push"
grep -q "fwf no-push guard" "$PUSHHOOK" 2>/dev/null && ok "guard installed" || bad "guard installed"
# the guard actually blocks — and the human override actually works
PUSHOUT="$(cd "$PUSHD/repo" && git push origin staging 2>&1)" && bad "push blocked by guard" || ok "push blocked by guard"
assert_contains "block message names the override" "$PUSHOUT" "FWF_ALLOW_PUSH=1"
git --git-dir "$PUSHD/origin.git" show-ref --quiet refs/heads/staging && bad "blocked push left no ref" || ok "blocked push left no ref"
( cd "$PUSHD/repo" && FWF_ALLOW_PUSH=1 git push -q origin staging ) && ok "human override pushes" || bad "human override pushes"
# guard blocks from a WORKTREE too (agents live in worktrees)
( cd "$PUSHD/wt/pt-impl1" && git push origin impl1/work >/dev/null 2>&1 ) && bad "worktree push blocked" || ok "worktree push blocked"
# gh-mode provision on the same repo: guard removed, ladder pushed
FWF_RUN_DIR="$PUSHD/run" FWF_PROFILE=.__pushtest "$ROOT/fwf-provision.sh" >/dev/null 2>&1
grep -q "fwf no-push guard" "$PUSHHOOK" 2>/dev/null && bad "guard removed in gh mode" || ok "guard removed in gh mode"
git --git-dir "$PUSHD/origin.git" show-ref --quiet refs/heads/integration && ok "gh mode pushes the ladder" || bad "gh mode pushes the ladder"
rm -f "$ROOT/profiles/.__pushtest.sh"

section "no-push flow in the rendered prompts (issue #28)"
NPIMPL="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 1")"
assert_contains "impl: never push"            "$NPIMPL" "NEVER run \`git push\`"
assert_contains "impl: local handoff signal"  "$NPIMPL" "READY-FOR-REVIEW impl1"
NPQA="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/qa.tmpl' 1")"
assert_contains "qa: no PRs, local queue"     "$NPQA" "there are NO pull requests here"
assert_contains "qa: frees the shared branch" "$NPQA" "git switch --detach staging"
NPCON="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/conductor.tmpl' ''")"
assert_contains "conductor: never fetch/pull/push" "$NPCON" "NEVER fetch/pull/push"
NPCAP="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/captain.tmpl' ''")"
assert_contains "captain: sole exception, per-instance" "$NPCAP" "FWF_ALLOW_PUSH=1"
GHCAP="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/captain.tmpl' ''")"
case "$GHCAP" in *FWF_ALLOW_PUSH*) bad "gh mode has no push-guard text";; *) ok "gh mode has no push-guard text";; esac

section "profile persistence of template/issues + per-template identity (issues #30/#31)"
cat > "$ROOT/profiles/.__persist.sh" <<EOF
FWF_REPO="$TMP/x"; WT_PREFIX="px"; WT_BASE="$TMP"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
FWF_TEMPLATE="\${FWF_TEMPLATE:-refactor}"
FWF_ISSUES="\${FWF_ISSUES:-local}"
EOF
PERSIST="$(FWF_PROFILE=.__persist bash -c "source '$ROOT/lib.sh'; echo \"\$FWF_TEMPLATE|\$FWF_ISSUES|\$BUILD_SESSION|\$FWF_DISPLAY_IMPL\"")"
assert_eq "profile ':-' template persists (the #30 bug)" "refactor|local|friends-refactor-build|REFAC" "$PERSIST"
ENVWIN="$(FWF_TEMPLATE=dev FWF_ISSUES=gh FWF_PROFILE=.__persist bash -c "source '$ROOT/lib.sh'; echo \"\$FWF_TEMPLATE|\$FWF_ISSUES|\$BUILD_SESSION|\$FWF_DISPLAY_IMPL\"")"
assert_eq "env still beats profile ':-'" "dev|gh|friends-build|IMPL" "$ENVWIN"
rm -f "$ROOT/profiles/.__persist.sh"
IDENT="$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; echo \"\$COORD_SESSION|\$FWF_DISPLAY_IMPL|\$FWF_DISPLAY_QA|\$FWF_DISPLAY_CONDUCTOR|\$FWF_DISPLAY_PM\"")"
assert_eq "ideation identity + session name" "friends-ideation-coord|GEN|CRITIC|SYNTH|FRAMER" "$IDENT"
DEVIDENT="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; echo \"\$BUILD_SESSION|\$FWF_DISPLAY_IMPL\"")"
assert_eq "dev keeps classic names" "friends-build|IMPL" "$DEVIDENT"

section "gh-write guard in local mode (issue #34)"
GGRUN="$TMP/ggrun"
# install the guard via the real code path, then swap in a recording fake gh
FWF_RUN_DIR="$GGRUN" FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_install_ghguard"
[ -x "$GGRUN/ghguard/gh" ] && ok "guard wrapper installed" || bad "guard wrapper installed"
GGFWF="$(readlink "$GGRUN/ghguard/fwf")"
assert_contains "fwf resolvable in panes (the gh-fallback cause)" "$GGFWF" "fwf"
"$GGRUN/ghguard/fwf" version >/dev/null 2>&1 && ok "guard-dir fwf actually runs" || bad "guard-dir fwf actually runs"
# Re-install with a fake `gh` first on PATH so the wrapper BAKES it as the
# real gh — exercising the resolution logic itself, with no sed -i (BSD/GNU
# sed disagree on -i '' and CI runs both).
mkdir -p "$TMP/fakebin"
printf '#!/usr/bin/env bash\necho "REAL-GH RAN: $*"\n' > "$TMP/fakebin/gh"; chmod +x "$TMP/fakebin/gh"
FWF_RUN_DIR="$GGRUN" FWF_ISSUES=local FWF_PROFILE=example bash -c "PATH='$TMP/fakebin':\$PATH; source '$ROOT/lib.sh'; fwf_install_ghguard"
GG() { "$GGRUN/ghguard/gh" "$@"; }
# reads pass through
assert_contains "issue list passes"   "$(GG issue list 2>&1)" "REAL-GH RAN: issue list"
assert_contains "pr view passes"      "$(GG pr view 12 2>&1)" "REAL-GH RAN"
assert_contains "auth status passes"  "$(GG auth status 2>&1)" "REAL-GH RAN"
assert_contains "api GET passes"      "$(GG api repos/x/y 2>&1)" "REAL-GH RAN"
# mutations blocked, fail-closed
GG issue create --title x >/dev/null 2>&1 && bad "issue create blocked" || ok "issue create blocked"
GG issue comment 5 --body x >/dev/null 2>&1 && bad "issue comment blocked" || ok "issue comment blocked"
GG label create wip >/dev/null 2>&1 && bad "label create blocked" || ok "label create blocked"
GG pr merge 7 >/dev/null 2>&1 && bad "pr merge blocked" || ok "pr merge blocked"
GG api -X POST repos/x/y/issues >/dev/null 2>&1 && bad "api POST blocked" || ok "api POST blocked"
GG api --method DELETE repos/x >/dev/null 2>&1 && bad "api DELETE blocked" || ok "api DELETE blocked"
GG workflow run ci >/dev/null 2>&1 && bad "unknown-verb fail-closed" || ok "unknown-verb fail-closed"
GGMSG="$(GG issue create --title x 2>&1 || true)"
assert_contains "block names the local CLI"  "$GGMSG" "fwf issues"
assert_contains "block names the override"   "$GGMSG" "FWF_ALLOW_GH=1"
# the human override passes through
assert_contains "FWF_ALLOW_GH=1 authorizes" "$(FWF_ALLOW_GH=1 GG issue create --title x 2>&1)" "REAL-GH RAN: issue create"
# pane launch command carries the guard PATH in local mode only
GCMD="$(FWF_RUN_DIR="$GGRUN" FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$CLAUDE_CMD\"")"
assert_contains "local CLAUDE_CMD prepends guard PATH" "$GCMD" "ghguard"
GCMD_GH="$(FWF_RUN_DIR="$GGRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$CLAUDE_CMD\"")"
case "$GCMD_GH" in *ghguard*) bad "gh mode CLAUDE_CMD unguarded";; *) ok "gh mode CLAUDE_CMD unguarded";; esac

section "pane recovery helpers (issue #36)"
RL_DEV="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_label impl2; echo; fwf_role_label captain")"
assert_contains "dev impl label canonical" "$RL_DEV" "IMPL2 · any issue → instant draft PR · impl2/*"
assert_contains "captain label canonical"  "$RL_DEV" "CAPTAIN · you talk here"
RL_IDE="$(FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_label impl2; echo; fwf_role_label conductor")"
assert_contains "ideation impl label wears GEN" "$RL_IDE" "GEN2 · IMPL2 ·"
assert_contains "ideation conductor wears SYNTH" "$RL_IDE" "SYNTH · CONDUCTOR ·"
assert_eq "role color matches pair" "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_color qa2")" "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; pair_color 2")"
# creating a pane without a live session fails loudly, not silently
CRP="$(FWF_SESSION=fwf-selftest-$$ FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_create_role_pane captain" 2>&1)" && bad "create pane needs session" || ok "create pane needs session"
assert_contains "create-pane error names fwf up" "$CRP" "fwf up"

section "lean loop ticks (issue #38) — role prompt persisted to disk"
RPF="$(FWF_RUN_DIR="$TMP/armrun" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_write_role_prompt impl2 implementer 2")"
assert_contains "prompt file is per-profile+role" "$RPF" "prompts/example-impl2.prompt"
assert_contains "file holds the rendered role"    "$(cat "$RPF")" "You are implementer impl2"
RPF_IDE="$(FWF_RUN_DIR="$TMP/armrun" FWF_TEMPLATE=ideation FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_write_role_prompt impl1 implementer 1")"
assert_contains "template-aware render persisted" "$(cat "$RPF_IDE")" "IDEA GENERATOR"

section "fwf dash (issue #40) — decision inbox + actions"
DRUN="$TMP/dashrun"
DSH()  { FWF_RUN_DIR="$DRUN" FWF_PROFILE=example FWF_ISSUES=local "$ROOT/fwf-dash.sh" "$@"; }
ISSD() { FWF_RUN_DIR="$DRUN" FWF_PROFILE=example FWF_ISSUES=local "$ROOT/fwf-issues.sh" "$@"; }
# Three issues: a signed-off gated draft (a real decision), a gated draft the GV
# has NOT signed off (not yet a decision), and an ordinary open issue.
ISSD create --title "un-gate: KB folder merge" --body "merge the folders" --label product-wip >/dev/null
ISSD comment 1 --body "GV-SIGNOFF: strategically sound; risks called out." >/dev/null
ISSD create --title "dark mode toggle" --body "stub spec" --label product-wip >/dev/null
ISSD create --title "fix pagination" --body "page 2 repeats an item" >/dev/null

# The decision queue is exactly: open + WIP_LABEL + a GV-SIGNOFF comment.
DEC="$(DSH decisions)"
assert_contains "signed-off gated draft is a decision" "$DEC" "un-gate: KB folder merge"
case "$DEC" in *"dark mode toggle"*) bad "gated-but-unsigned must be excluded";; *) ok "gated-but-unsigned excluded";; esac
case "$DEC" in *"fix pagination"*)   bad "ungated issue must be excluded";;     *) ok "ungated issue excluded";; esac

# Issues tab lists every open issue and flags the gated ones.
ISS_TAB="$(DSH issues)"
assert_contains "issues tab lists ungated issues too" "$ISS_TAB" "fix pagination"
assert_contains "issues tab flags a gated issue"      "$ISS_TAB" "gated"
UNGATED_FLAG="$(printf '%s\n' "$ISS_TAB" | awk -F'\t' '$1==3{print $2}')"
assert_eq "ungated issue carries no gate flag" "" "$UNGATED_FLAG"

# Action construction — local backend, asserted through the dryrun seam.
APP="$(FWF_DASH_DRYRUN=1 DSH act approve 1)"
assert_contains "approve posts the go-ahead comment" "$APP" "comment 1 --body go ahead"
assert_contains "approve un-gates (removes WIP label)" "$APP" "edit 1 --remove-label product-wip"
REJ="$(FWF_DASH_DRYRUN=1 DSH act reject 1 needs a benchmark)"
assert_contains "reject comments the reason" "$REJ" "comment 1 --body needs a benchmark"
case "$REJ" in *remove-label*) bad "reject must NOT un-gate";; *) ok "reject keeps the gate"; esac
COM="$(FWF_DASH_DRYRUN=1 DSH act comment 1 please add acceptance criteria)"
assert_contains "comment posts the given text" "$COM" "comment 1 --body please add acceptance criteria"

# Same verbs on the gh backend build gh commands (identical behavior, different leaf).
GHD() { FWF_RUN_DIR="$DRUN" FWF_PROFILE=example FWF_ISSUES=gh FWF_DASH_DRYRUN=1 "$ROOT/fwf-dash.sh" "$@"; }
GAP="$(GHD act approve 384)"
assert_contains "gh approve -> gh issue comment" "$GAP" "gh issue comment 384 --body go ahead"
assert_contains "gh approve -> gh issue edit"    "$GAP" "gh issue edit 384 --remove-label product-wip"
assert_contains "gh open -> gh issue view --web" "$(GHD act open 384)" "gh issue view 384 --web"

# Regression: gh's plain columns (number/STATE/title/…) differ from the local
# store's (number/title/…), so the dash reads titles via the gh-shaped
# `--json number,title --jq` both backends share — never by column position.
mkdir -p "$TMP/dashbin"
cat > "$TMP/dashbin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# Stands in for `gh issue list … --json number,title --jq '.[]|"\(.number)\t\(.title)"'`.
[ "$1" = "issue" ] || exit 0
case "$2" in list) printf '512\tWire the new auth flow\n';; *) exit 0;; esac
FAKEGH
chmod +x "$TMP/dashbin/gh"
GH_TAB="$(PATH="$TMP/dashbin:$PATH" FWF_RUN_DIR="$DRUN" FWF_PROFILE=example FWF_ISSUES=gh "$ROOT/fwf-dash.sh" issues)"
assert_contains "gh issues tab reads the real title" "$GH_TAB" "Wire the new auth flow"
case "$GH_TAB" in *"$(printf '\tOPEN\t')"*) bad "gh STATE column must not leak as title";; *) ok "gh title parsed via --json, not column"; esac

# Role controls wrap the existing scripts.
assert_contains "respawn wraps fwf-respawn.sh" "$(FWF_DASH_DRYRUN=1 DSH act respawn impl2)" "fwf-respawn.sh impl2"
assert_contains "stop wraps fwf-stop.sh"       "$(FWF_DASH_DRYRUN=1 DSH act stop)"          "fwf-stop.sh"

# Roles roster + captain passthrough, derived from tmux pane state via a fake tmux
# that stands up a CAPTAIN pane (live) and an IMPL1 pane (idle shell).
mkdir -p "$TMP/dashbin"
cat > "$TMP/dashbin/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift || true
_pane() { local p=""; while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { p="$2"; shift; }; shift; done; printf '%s' "$p"; }
case "$sub" in
  has-session)     exit 0;;                         # every session "exists"
  list-panes)      printf '%s\n' '%0' '%1';;        # two panes per session
  show)            case "$(_pane "$@")" in
                     %0) echo 'CAPTAIN · you talk here · loop 2m';;
                     %1) echo 'IMPL1 · any issue → instant draft PR · impl1/*';;
                   esac;;
  display-message) case "$(_pane "$@")" in %0) echo node;; %1) echo bash;; esac;;
  *) exit 0;;
esac
FAKE
chmod +x "$TMP/dashbin/tmux"
ROLES_OUT="$(PATH="$TMP/dashbin:$PATH" DSH roles)"
assert_contains "captain pane on a busy command reads live" "$ROLES_OUT" "$(printf 'captain\t● live')"
assert_contains "impl1 on a bare shell reads idle"          "$ROLES_OUT" "$(printf 'impl1\t○ idle')"
assert_contains "an unmatched role reads down"              "$ROLES_OUT" "$(printf 'impl2\t· down')"
PT="$(PATH="$TMP/dashbin:$PATH" FWF_RUN_DIR="$DRUN" FWF_PROFILE=example FWF_ISSUES=gh FWF_DASH_DRYRUN=1 "$ROOT/fwf-dash.sh" act passthrough ship it tonight)"
assert_contains "passthrough send-keys to the CAPTAIN pane" "$PT" "send-keys -t %0 -l ship it tonight"

# The optional status.json overlay (needs jq): fresh -> rendered, stale -> ignored.
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$DRUN/state/example"
  cat > "$DRUN/state/example/status.json" <<'JSON'
{ "prod": "v9.9 ✓ · e2e ✓",
  "pipeline": "staging +2 ahead · integration clean · main = prod",
  "roles": [ { "id": "impl1", "issue": 441, "title": "auth refactor" } ],
  "decisions": [
    { "id": "1",   "kind": "ungate",  "issue": 1,    "recommendation": "ship" },
    { "id": "REL", "kind": "release", "issue": null, "title": "release v9.9 -> main", "gv": "gate ✓" }
  ] }
JSON
  BRD="$(DSH board)"
  assert_contains "fresh status.json fills prod"        "$BRD" "prod v9.9 ✓"
  assert_contains "fresh status.json marks itself"      "$BRD" "status.json ✓"
  assert_contains "fresh status.json overlays pipeline" "$BRD" "staging +2 ahead"
  DEC2="$(DSH decisions)"
  assert_contains "decision enriched with recommendation" "$DEC2" "captain: ship"
  assert_contains "release decision shows as its own row"  "$DEC2" "release v9.9"
  # Age it out: a fixed past mtime is unambiguously stale on both BSD and GNU touch.
  touch -t 202001010000 "$DRUN/state/example/status.json"
  BRD2="$(DSH board)"
  case "$BRD2" in *"status.json ✓"*) bad "a stale overlay must be ignored";; *) ok "stale overlay ignored (degrades to derived)"; esac
  DEC3="$(DSH decisions)"
  case "$DEC3" in *"release v9.9"*) bad "stale release decision must drop";; *) ok "stale release decision dropped"; esac
else
  printf '  skip status.json overlay (jq not installed)\n'
fi

section "dispatcher: bad input is rejected"
"$ROOT/fwf" bogus-cmd >/dev/null 2>&1 && bad "unknown command rejected" || ok "unknown command rejected"
"$ROOT/fwf" init >/dev/null 2>&1 && bad "init without arg rejected" || ok "init without arg rejected"
"$ROOT/fwf" dash bogus-view >/dev/null 2>&1 && bad "dash rejects unknown subcommand" || ok "dash rejects unknown subcommand"

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
