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

# Isolate every tmux fixture onto a THROWAWAY tmux server. Without this the
# suite's real-tmux blocks (fwf-up.sh / fwf-down.sh fixtures, kill-session
# cleanup) run against whatever server the caller is on — and when the suite
# runs as a factory GATE_CMD, that caller is a pane INSIDE a live factory, so
# it inherits $TMUX and operates on the operator's own server alongside the
# running swarm and their unrelated sessions. Unsetting TMUX and pointing
# TMUX_TMPDIR at a per-run dir gives the fixtures their own server, reachable
# by nothing else and torn down with the tmpdir.
export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"
unset TMUX

# HERMETICITY (issue #175): this suite builds its own throwaway fixtures and
# pins their env explicitly at each call site. An ambient FWF_REPO/FWF_PROFILE/
# FWF_PAIRS from the caller silently OVERRIDES those fixtures — measured at 41
# otherwise-passing tests going RED. It bit hardest as a factory GATE_CMD,
# where those vars are always set (and set CORRECTLY — a valid value overrides
# a fixture exactly as destructively as a wrong one), making the gate false-RED
# on every cycle. fwf-gate.sh no longer leaks its own resolution, but the suite
# must not depend on the caller's environment either: a green run has to mean
# the code is good, not that the operator's shell happened to be clean.
unset FWF_REPO FWF_PROFILE FWF_PAIRS

trap 'tmux kill-server 2>/dev/null; rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
# assert_eq <label> <expected> <actual>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
# assert_contains <label> <haystack> <needle>
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] did not contain [$3]";; esac; }
# assert_not_contains <label> <haystack> <needle>
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contained [$3]";; *) ok "$1";; esac; }
# assert_log_eventually_contains <label> <logfile> <needle> [timeout-secs]
# Bounded wait-for-condition, for asserting on an async log append (issue
# #185) instead of a single fixed-time read that can sample before the append
# lands. Presence-based (grep over the whole file, not the last line only) so
# it stays correct even if a later line changes the tail -- e.g. floor-up
# followed by an immediate floor-down. On a genuine miss it times out and
# fails with a clear message; it does not silently pass.
assert_log_eventually_contains() {
  local label="$1" log="$2" needle="$3" timeout="${4:-5}" tries i=0
  tries=$((timeout * 5)) # poll every 0.2s
  while [ "$i" -lt "$tries" ]; do
    grep -q -F -- "$needle" "$log" 2>/dev/null && { ok "$label"; return; }
    sleep 0.2
    i=$((i + 1))
  done
  bad "$label" "no [$needle] line appeared in $log within ${timeout}s (last line: $(tail -n1 "$log" 2>/dev/null))"
}
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
section "fwf_repo_slug: gh -R scope resolves the factory repo, not CWD (#145)"
assert_eq "env FWF_GHCACHE_REPO wins" "foo/bar" \
  "$(FWF_GHCACHE_REPO=foo/bar bash -c "source '$ROOT/lib.sh'; fwf_repo_slug")"
mkfix slug-ssh; ( cd "$FIX" && git remote add origin git@github.com:foo/baz.git )
assert_eq "derive from ssh remote"    "foo/baz" \
  "$(FWF_REPO="$FIX" bash -c "unset FWF_GHCACHE_REPO; source '$ROOT/lib.sh'; fwf_repo_slug")"
mkfix slug-https; ( cd "$FIX" && git remote add origin https://github.com/foo/qux.git )
assert_eq "derive from https remote"  "foo/qux" \
  "$(FWF_REPO="$FIX" bash -c "unset FWF_GHCACHE_REPO; source '$ROOT/lib.sh'; fwf_repo_slug")"

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
  FWF_PROFILE=.__test_genblank bash -c "source '"$ROOT"'/lib.sh; printf \"%s|%s\" \"\$DEFAULT_BRANCH\" \"\$(fwf_render '"$ROOT"'/templates/dev/qa.tmpl 1)\""
')"
assert_eq "lib.sh sees baked default branch" "master" "${RUN%%|*}"
assert_contains "qa prompt renders" "${RUN#*|}" "You are qa1"

section "implementer prompt carries the atomic-claim protocol"
IMPL_RUN="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 2")"
assert_contains "claim comment is the mutex"   "$IMPL_RUN" "CLAIM impl2"
assert_contains "claim is verified after post" "$IMPL_RUN" "RE-CHECK you won"
assert_contains "captain assignment honored"   "$IMPL_RUN" "ASSIGNED impl2"

section "implementer resumes its own in-flight draft, never idles behind it (#99 Fix 1)"
assert_contains "dev: claim-only draft is a resume target"     "$IMPL_RUN" "RESUME it"
assert_contains "dev: checks out own branch before resuming"   "$IMPL_RUN" "starts on the wrong branch with no memory of the claim"
assert_contains "dev: bounded escalation on a stalled draft"   "$IMPL_RUN" "2+ consecutive cycles"
assert_contains "dev: escalation posts the @captain BLOCKED comment" "$IMPL_RUN" "stalled with no progress"
for t in refactor ideation validate; do
  TR="$(FWF_PROFILE=example FWF_TEMPLATE="$t" bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/$t/implementer.tmpl' 2")"
  assert_contains "$t: claim-only draft is a resume target"   "$TR" "RESUME it"
  assert_contains "$t: checks out own branch before resuming" "$TR" "starts on the wrong branch with no memory of the claim"
  assert_contains "$t: bounded escalation on a stalled draft" "$TR" "2+ consecutive cycles"
done
# dev-sre has no own implementer.tmpl (FWF_TEMPLATE_BASE=dev) — confirm it
# actually inherits dev's, so the Fix 1 language reaches it too.
assert_eq "dev-sre has no own implementer.tmpl (inherits dev's)" "" \
  "$([ -f "$ROOT/templates/dev-sre/implementer.tmpl" ] && echo present)"
DEVSRE_RUN="$(FWF_PROFILE=example FWF_TEMPLATE=dev-sre bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path implementer)\" 2")"
assert_contains "dev-sre inherits the resume-own-draft language from dev" "$DEVSRE_RUN" "RESUME it"

section "step-0 tick: a monotonic loop-tick bump, never the pane glyph (#99 Fix 2 / #133)"
assert_eq "impl+id -> impl<id>"    "impl3"     "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_tag_for_tmpl '$ROOT/templates/dev/implementer.tmpl' 3")"
assert_eq "qa+id -> qa<id>"        "qa3"       "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_tag_for_tmpl '$ROOT/templates/dev/qa.tmpl' 3")"
assert_eq "pm (no id) -> pm"       "pm"        "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_tag_for_tmpl '$ROOT/templates/dev/pm.tmpl' ''")"
assert_eq "captain (no id) -> captain" "captain" "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_tag_for_tmpl '$ROOT/templates/dev/captain.tmpl' ''")"
assert_eq "extra role (sre) -> its own basename" "sre" "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_role_tag_for_tmpl '$ROOT/templates/dev-sre/sre.tmpl' ''")"
HB_QA3="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/qa.tmpl' 3")"
assert_contains "rendered step-0 bumps the per-role tick counter (#133)" "$HB_QA3" "fwf tick qa3"
assert_contains "tick write is framed as durable, NOT the pane glyph" "$HB_QA3" "never the pane glyph"
# every base role template (every factory design, excluding _local-issues
# overlay fragments, which compose onto a base and have no loop of their own)
# carries the step-0 tick bump — the monotonic loop-tick counter (#133) that
# superseded the bare heartbeat touch. __ROLETAG__ renders to the role tag.
MISSING_TICK=""
while IFS= read -r -d '' f; do
  /usr/bin/grep -q "fwf tick __ROLETAG__" "$f" || MISSING_TICK="$MISSING_TICK $f"
done < <(find "$ROOT/templates" -name "*.tmpl" ! -path "*_local-issues*" -print0)
assert_eq "every role template (all factory designs) carries the step-0 tick bump" "" "$MISSING_TICK"
assert_eq "no template still uses the superseded bare heartbeat touch" "0" \
  "$(find "$ROOT/templates" -name "*.tmpl" -exec /usr/bin/grep -l "touch __HEARTBEAT__" {} \; | wc -l | tr -d ' ')"
assert_eq "_local-issues overlays are excluded (no loop of their own)" "0" \
  "$(find "$ROOT/templates/_local-issues" -name "*.tmpl" -exec /usr/bin/grep -l "fwf tick __ROLETAG__" {} \; | wc -l | tr -d ' ')"

# --------------------------------------------------------------------------
section "build-provenance stamp: role->model map recorded on every PR"
prov_env() { FWF_PROFILE=example FWF_MODEL=claude-sonnet-5 FWF_MODEL_PM=claude-opus-4-8 FWF_MODEL_GV=claude-opus-4-8 FWF_MODEL_CAPTAIN=claude-opus-4-8 bash -c "source '$ROOT/lib.sh'; $1"; }
# fwf_model_for: per-role override -> floor default -> "" (CLI default).
assert_eq "fwf_model_for pm -> override"          "claude-opus-4-8" "$(prov_env 'fwf_model_for pm')"
assert_eq "fwf_model_for impl2 -> floor default"  "claude-sonnet-5" "$(prov_env 'fwf_model_for impl2')"
assert_eq "fwf_model_for qa1 -> floor default"    "claude-sonnet-5" "$(prov_env 'fwf_model_for qa1')"
assert_eq "fwf_model_for gv -> override"          "claude-opus-4-8" "$(prov_env 'fwf_model_for gv')"
assert_eq "fwf_model_for unset role -> empty (CLI default)" "" "$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_model_for impl2")"
# fwf_seat_model_pairs: the single roster both fwf_provenance_block AND
# fwf_credit_block (lib/pr_context.sh, #134) consume, so they can't drift
# apart the way credit did (hardcoded "impl qa" while provenance already
# looped all six seats).
SEAT_PAIRS="$(prov_env 'fwf_seat_model_pairs')"
assert_eq "seat roster covers all six seats" "6" "$(printf '%s\n' "$SEAT_PAIRS" | grep -c .)"
assert_contains "seat roster carries the pm seat's resolved model" "$SEAT_PAIRS" "$(printf 'pm\tclaude-opus-4-8')"
assert_contains "seat roster carries the impl seat's resolved model" "$SEAT_PAIRS" "$(printf 'impl\tclaude-sonnet-5')"
# fwf_provenance_block: exactly one fwf-Provenance trailer carrying fwf@sha,
# profile, and every seat's model.
PROV="$(prov_env 'fwf_provenance_block')"
assert_contains "provenance is an fwf-Provenance trailer with fwf@sha" "$PROV" "fwf-Provenance: fwf="
assert_contains "provenance carries the profile"                       "$PROV" "profile=example"
assert_contains "provenance carries the pm seat model"                 "$PROV" "pm=claude-opus-4-8"
assert_contains "provenance carries the impl seat model"               "$PROV" "impl=claude-sonnet-5"
assert_contains "provenance carries the conductor seat"                "$PROV" "conductor="
assert_eq "provenance has no embedded newlines (single line)" "0" "$(printf '%s' "$PROV" | tr -cd '\n' | wc -c | tr -d ' ')"
# A seat with no override AND no floor default records cli-default, never blank.
PROV_BLANK="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_provenance_block")"
assert_contains "unset seat -> cli-default (never blank)" "$PROV_BLANK" "impl=cli-default"
# __PROVENANCE__ substitutes into both the merge body and the PR-create body.
assert_contains "qa merge body carries the provenance trailer" \
  "$(prov_env "fwf_render '$ROOT/templates/validate/qa.tmpl' 1")" "fwf-Provenance: fwf="
assert_contains "implementer PR body carries the provenance trailer" \
  "$(prov_env "fwf_render '$ROOT/templates/consulting/implementer.tmpl' 2")" "fwf-Provenance: fwf="
# COVERAGE: every PR-producing template (excluding _local-issues, which never
# opens an upstream PR) MUST carry __PROVENANCE__ — else a factory could ship
# un-attributed work, the exact instrumentation gap that makes a post-hoc
# "did quality regress?" diagnosis impossible.
MISSING_PROV=""
while IFS= read -r -d '' f; do
  if /usr/bin/grep -qE 'gh pr (create|merge)' "$f"; then
    /usr/bin/grep -q "__PROVENANCE__" "$f" || MISSING_PROV="$MISSING_PROV $f"
  fi
done < <(find "$ROOT/templates" -name "*.tmpl" ! -path "*_local-issues*" -print0)
assert_eq "every PR-producing template carries the provenance stamp" "" "$MISSING_PROV"
# No unsubstituted __PROVENANCE__ leaks through a render.
assert_eq "no stray __PROVENANCE__ after render" "" \
  "$(prov_env "fwf_render '$ROOT/templates/validate/qa.tmpl' 1" | /usr/bin/grep -o '__PROVENANCE__' | head -1)"

# --------------------------------------------------------------------------
section "PR body context-fold + built-with credit (issue #106)"
pctx_env() { FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }
# fwf_sanitize_pr_text: the denylist + pattern sweep, portable across BSD sed
# (macOS, no \b support in -E) and GNU sed. This is a regression guard for a
# real bug: the first cut of this sanitizer used \b, which silently NEVER
# matches on this repo's own dev machine (macOS /usr/bin/sed) — every rule
# below would otherwise pass straight through unsanitized.
SANI_IN="mentions impl3 and impl__ID__ and qa2 and CLAIM impl1 and ASSIGNED qa4
GV-SIGNOFF then GV-CHANGES; QA-APPROVED: #1 and QA-CHANGES-REQUESTED: #2 and IMPL-ADDRESSED: #3
captain, conductor, gv, pm all met in the worktree on the floor to review the gate
staging branch and integration branch; origin/staging and origin/integration
product-wip and release-hold; Owner: impl9  WIP
FWF_TOKEN_BUDGET and LI-42 and impl2/issue-9-slug and fwf-self-abc123 and ~/.fun-with-friends/state/x"
SANI_OUT="$(pctx_env "fwf_sanitize_pr_text" <<<"$SANI_IN")"
for tok in 'impl3' 'impl__ID__' 'qa2' 'CLAIM impl1' 'ASSIGNED qa4' 'GV-SIGNOFF' 'GV-CHANGES' \
           'QA-APPROVED:' 'QA-CHANGES-REQUESTED:' 'IMPL-ADDRESSED:' 'captain' 'conductor' \
           'worktree' 'floor' 'gate' 'staging branch' 'integration branch' 'origin/staging' \
           'origin/integration' 'product-wip' 'release-hold' 'Owner:' 'FWF_TOKEN_BUDGET' \
           'LI-42' 'impl2/issue-9-slug' 'fwf-self-abc123' '.fun-with-friends'; do
  case "$SANI_OUT" in
    *"$tok"*) bad "sanitizer strips '$tok'" "leaked: $SANI_OUT";;
    *)        ok "sanitizer strips '$tok'";;
  esac
done
# bare "WIP" (not part of a larger word) is deleted entirely, not replaced.
case "$SANI_OUT" in *WIP*) bad "sanitizer deletes bare WIP";; *) ok "sanitizer deletes bare WIP";; esac
# adjacent tokens sharing a boundary char (the specific bug the \b rewrite fixed)
# must ALL convert, not just the outermost ones.
ADJ="$(pctx_env "fwf_sanitize_pr_text" <<<"impl1 impl2 impl3")"
assert_eq "adjacent role tokens all sanitized (no boundary-consuming gap)" \
  "the implementer the implementer the implementer" "$ADJ"
# sensitive-data scrub (constraint 3): secret/token/key SHAPES, not just fwf vocab.
SEC_IN='ghp_abcdefghijklmnopqrstuvwxyz012345 AKIAABCDEFGHIJKLMNOP sk-abcdefghijklmnopqrstuvwx api_key: sup3rsecret'
SEC_OUT="$(pctx_env "fwf_sanitize_pr_text" <<<"$SEC_IN")"
case "$SEC_OUT" in
  *ghp_*|*AKIAABCDEFGHIJKLMNOP*|*sk-abcdefghijklmnopqrstuvwx*|*sup3rsecret*)
    bad "sensitive-data scrub redacts secret-shaped tokens" "leaked: $SEC_OUT";;
  *) ok "sensitive-data scrub redacts secret-shaped tokens";;
esac

# fwf_credit_block: on (default) / minimal / off, model-family-agnostic via
# fwf_model_for, reading the SAME six-seat roster as fwf_provenance_block
# (#134 — credit used to hardcode "impl qa" and drop every other seat).
cred_env() { FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }
# Mixed-model profile (pm on opus, everyone else on the sonnet floor default):
# credit must list BOTH models, not just the ones "impl qa" used to loop.
CRED_ON="$(FWF_MODEL=claude-sonnet-5 FWF_MODEL_PM=claude-opus-4-8 cred_env "fwf_credit_block")"
assert_contains "credit (on) carries the fwf link"       "$CRED_ON" "github.com/tbaums/fun-with-friends"
assert_contains "credit (on) carries the Claude mention"  "$CRED_ON" "Claude"
assert_contains "credit (on) lists the floor-default seats' model" "$CRED_ON" "claude-sonnet-5"
assert_contains "credit (on) lists the pm-only seat's model (was dropped pre-#134)" "$CRED_ON" "claude-opus-4-8"
# A third distinct model (conductor) must also survive — groupings are derived
# from the profile's real model values at render time, not a hardcoded split.
CRED_THREE="$(FWF_MODEL=claude-sonnet-5 FWF_MODEL_PM=claude-opus-4-8 FWF_MODEL_CONDUCTOR=claude-haiku-4-5 cred_env "fwf_credit_block")"
for tok in claude-sonnet-5 claude-opus-4-8 claude-haiku-4-5; do
  assert_contains "credit (on, 3 distinct models) lists $tok" "$CRED_THREE" "$tok"
done
# Homogeneous profile (every seat the SAME model): legitimately collapses to
# one model line, not the bug — asserted, not just left untested.
CRED_UNIFORM="$(FWF_MODEL=claude-sonnet-5 cred_env "fwf_credit_block")"
assert_contains "credit (on, uniform profile) lists the one model" "$CRED_UNIFORM" "claude-sonnet-5"
assert_eq "credit (on, uniform profile) lists it exactly once" "1" \
  "$(printf '%s' "$CRED_UNIFORM" | grep -o "claude-sonnet-5" | wc -l | tr -d ' ')"
# No overrides at all -> every seat is CLI-default (unconfigured): omitted
# from the model list entirely, never rendered as a blank "()" or "cli-default".
CRED_UNSET="$(cred_env "fwf_credit_block")"
assert_contains "credit (on, no seats configured) still carries the link" "$CRED_UNSET" "github.com/tbaums/fun-with-friends"
case "$CRED_UNSET" in
  *"()"*|*cli-default*) bad "credit (on, no seats configured) never renders a blank/cli-default model" "$CRED_UNSET";;
  *) ok "credit (on, no seats configured) never renders a blank/cli-default model";;
esac
# minimal: shortens the surrounding prose but keeps FULL model disclosure —
# the disclosure bar isn't a coverage knob (this is the behavior #134 fixed;
# minimal used to drop the model list entirely).
CRED_MIN="$(FWF_MODEL=claude-sonnet-5 FWF_MODEL_PM=claude-opus-4-8 FWF_CREDIT=minimal cred_env "fwf_credit_block")"
assert_contains "credit (minimal) still carries the link"        "$CRED_MIN" "github.com/tbaums/fun-with-friends"
assert_contains "credit (minimal) still discloses every model (floor default)" "$CRED_MIN" "claude-sonnet-5"
assert_contains "credit (minimal) still discloses every model (pm override)"   "$CRED_MIN" "claude-opus-4-8"
case "$CRED_MIN" in
  *"multi-agent Claude Code dev factory"*) bad "credit (minimal) drops the descriptive aside" "$CRED_MIN";;
  *) ok "credit (minimal) drops the descriptive aside";;
esac
CRED_OFF="$(FWF_PROFILE=example FWF_CREDIT=off bash -c "source '$ROOT/lib.sh'; fwf_credit_block")"
assert_eq "credit (off) prints nothing" "" "$CRED_OFF"
# --issues local defaults FWF_CREDIT to off (constraint 4/5: not our repo until configured).
CRED_LOCAL_DEFAULT="$(FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$FWF_CREDIT\"")"
assert_eq "--issues local defaults FWF_CREDIT to off" "off" "$CRED_LOCAL_DEFAULT"
CRED_REMOTE_DEFAULT="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$FWF_CREDIT\"")"
assert_eq "remote (gh) mode defaults FWF_CREDIT to on" "on" "$CRED_REMOTE_DEFAULT"

# fwf_pr_body_guard: fail-closed backstop (PM item 2) — re-scans the ACTUAL
# rendered output right before it would ship, independent of the sanitizer.
GUARD_CLEAN="$(pctx_env "fwf_pr_body_guard" <<<"a normal reviewer-facing sentence with no fwf vocabulary")"
assert_eq "guard passes clean text through unchanged" \
  "a normal reviewer-facing sentence with no fwf vocabulary" "$GUARD_CLEAN"
GUARD_LEAK_OUT="$(pctx_env "fwf_pr_body_guard" <<<"still mentions impl3 raw" 2>/tmp/fwf-guard-err.$$)"
GUARD_LEAK_RC=$?
GUARD_LEAK_ERR="$(cat /tmp/fwf-guard-err.$$ 2>/dev/null)"; rm -f "/tmp/fwf-guard-err.$$"
assert_eq "guard blocks a surviving fwf-internal token (rc)" "1" "$GUARD_LEAK_RC"
assert_eq "guard blocks a surviving fwf-internal token (no stdout)" "" "$GUARD_LEAK_OUT"
assert_contains "guard names the offending line on stderr" "$GUARD_LEAK_ERR" "impl3"

# fwf_context_block: mechanical extraction from a fixture ticket's structured
# body sections + a linked docs/proposals/<n>-*.md, via the LOCAL issue store
# (--issues local) so this test needs no network / no real gh issue.
PCTXRUN="$TMP/pr-context-run"
PISS() { FWF_RUN_DIR="$PCTXRUN" FWF_PROFILE=example "$ROOT/fwf-issues.sh" "$@"; }
FIX1_BODY='## Problem / intent
The thing is broken for real users in a real way.

## Decisions & tradeoffs
- Chose mechanical extraction over an LLM pass: no per-render spend, no fabrication risk.

## Alternatives considered
- An LLM-drawn summary — rejected: fabrication risk, per-call cost.

## Acceptance criteria
- The fix ships behind a flag.

## Testing
- Unit tests cover the new branch.'
PISS create --title "Fix the thing" --body "$FIX1_BODY" >/dev/null
PISS comment 1 --body "CAPTAIN -> PM: ball is in your court, GV-SIGNOFF pending" >/dev/null
PCTXREPO="$TMP/pr-context-repo"; mkdir -p "$PCTXREPO/docs/proposals"
printf '# Proposal: fix the thing\n\nDo the fix this way.\n' > "$PCTXREPO/docs/proposals/1-fix-the-thing.md"
CTX1="$(FWF_ISSUES=local FWF_RUN_DIR="$PCTXRUN" FWF_REPO="$PCTXREPO" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_context_block 1")"
assert_contains "context fold has the heading"        "$CTX1" "## Context & rationale"
assert_contains "context fold carries the ticket title" "$CTX1" "Fix the thing"
assert_contains "context fold carries the intro"       "$CTX1" "broken for real users"
assert_contains "context fold carries decisions"       "$CTX1" "mechanical extraction over an LLM pass"
assert_contains "context fold carries alternatives"    "$CTX1" "fabrication risk, per-call cost"
assert_contains "context fold carries acceptance criteria" "$CTX1" "ships behind a flag"
assert_contains "context fold carries testing"         "$CTX1" "Unit tests cover the new branch"
assert_contains "context fold folds in the linked proposal" "$CTX1" "Do the fix this way"
# (a) the extraction source is the BODY's structured sections + linked
# proposals ONLY — the comment thread (role-coordination prose) must NEVER
# surface, even though a comment exists on this very fixture issue (PM
# round-2 decision: exclusion-by-scope is the primary leak control).
case "$CTX1" in
  *"CAPTAIN"*|*"ball is in your court"*|*"GV-SIGNOFF"*) bad "comment thread must never be a context-fold source" "$CTX1";;
  *) ok "comment thread must never be a context-fold source";;
esac

# (d) multi-ticket PRs: fold both, ordered by issue number regardless of call order.
PISS create --title "Second ticket" --body "## Problem / intent
A second, unrelated issue." >/dev/null
CTX2="$(FWF_ISSUES=local FWF_RUN_DIR="$PCTXRUN" FWF_REPO="$PCTXREPO" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_context_block 2 1")"
assert_contains "two-ticket fold carries ticket 1" "$CTX2" "Fix the thing"
assert_contains "two-ticket fold carries ticket 2" "$CTX2" "Second ticket"
BEFORE_TICKET2="${CTX2%%Second ticket*}"
case "$BEFORE_TICKET2" in
  *"Fix the thing"*) ok "two-ticket fold orders by issue number, not call order";;
  *) bad "two-ticket fold orders by issue number, not call order" "$CTX2";;
esac

# fwf pr-context CLI (the entrypoint an agent actually runs at PR-create/
# squash-merge time): same fixture, through the dispatcher end-to-end.
CLI_CTX="$(FWF_ISSUES=local FWF_RUN_DIR="$PCTXRUN" FWF_REPO="$PCTXREPO" FWF_PROFILE=example "$ROOT/fwf" pr-context 1 2>&1)"
assert_contains "fwf pr-context prints the context fold" "$CLI_CTX" "## Context & rationale"
assert_contains "fwf pr-context has no fwf-internal leak" "$CLI_CTX" "Fix the thing"
case "$CLI_CTX" in *impl[0-9]*|*QA-*) bad "fwf pr-context output has no fwf-internal token" "$CLI_CTX";; *) ok "fwf pr-context output has no fwf-internal token";; esac

# COVERAGE (mirrors #80's provenance coverage above): every PR-producing
# template (excluding _local-issues, which never opens an upstream PR — same
# constraint-5 exemption as __PROVENANCE__'s) MUST carry __CREDIT__.
MISSING_CREDIT=""
while IFS= read -r -d '' f; do
  if /usr/bin/grep -qE 'gh pr (create|merge)' "$f"; then
    /usr/bin/grep -q "__CREDIT__" "$f" || MISSING_CREDIT="$MISSING_CREDIT $f"
  fi
done < <(find "$ROOT/templates" -name "*.tmpl" ! -path "*_local-issues*" -print0)
assert_eq "every PR-producing template carries the built-with credit" "" "$MISSING_CREDIT"
# COVERAGE: every template whose PR/commit actually CLOSES a ticket ("Closes
# #<num>"/"Closes #<n>") must wire in the context-fold CLI (fwf pr-context) —
# narrower than the credit check above because a few factory designs (e.g.
# validate/ideation/consulting) intentionally never close the ticket their PR
# references (a hypothesis/challenge/engagement outlives a single section),
# so folding a full ticket distillation into every one of their PRs would be
# noise, not signal; the ticket's own "Anchor" language ties context-fold to
# the issue-closing squash-merge moment.
MISSING_CTX=""
while IFS= read -r -d '' f; do
  # only the actual gh pr create/merge command LINE decides "closes a ticket"
  # here — validate/ideation/consulting mention "Closes #<n>" in unrelated
  # prose (e.g. explicitly telling the agent NOT to write it) without their
  # gh pr command line ever containing it.
  prline="$(/usr/bin/grep -E 'gh pr (create|merge)' "$f" || true)"
  if printf '%s' "$prline" | /usr/bin/grep -qE 'Closes #<n'; then
    printf '%s' "$prline" | /usr/bin/grep -q "fwf pr-context" || MISSING_CTX="$MISSING_CTX $f"
  fi
done < <(find "$ROOT/templates" -name "*.tmpl" ! -path "*_local-issues*" -print0)
assert_eq "every issue-closing template wires in the context-fold CLI" "" "$MISSING_CTX"
# No unsubstituted __CREDIT__/__CONTEXT__ leaks through a render.
assert_eq "no stray __CREDIT__ after render" "" \
  "$(prov_env "fwf_render '$ROOT/templates/dev/qa.tmpl' 1" | /usr/bin/grep -o '__CREDIT__' | head -1)"

section "QA adversarial artifact review on green gates (issue #119)"
# Composed/rendered, not a raw-file grep — proves the c2 step actually
# survives fwf_render (a future edit/rebase that silently strips or rewords
# it away would go red here, per the test-efficacy check c2.2 itself demands).
DEVQA_RENDERED="$(prov_env "fwf_render '$ROOT/templates/dev/qa.tmpl' 1")"
assert_contains "dev/qa composed/rendered prompt carries the ADVERSARIAL ARTIFACT REVIEW step" \
  "$DEVQA_RENDERED" "ADVERSARIAL ARTIFACT REVIEW"
assert_contains "dev/qa composed/rendered prompt cites issue #119" \
  "$DEVQA_RENDERED" "issue #119"
assert_contains "dev/qa composed/rendered prompt requires trying to break load-bearing changes" \
  "$DEVQA_RENDERED" "TRY TO BREAK IT"
assert_contains "dev/qa composed/rendered prompt checks conformance to the source ticket" \
  "$DEVQA_RENDERED" "CONFORMANCE TO THE SOURCE TICKET"

section "authorization ground rules injected into EVERY role prompt (issue #150)"
# The fabricated-authorization fix: fwf_render prepends a non-negotiable
# ground-rules block to every rendered role prompt (no template can omit it,
# any future template inherits it). These assertions render composed prompts
# (not raw-file greps) so a future edit that strips or rerenders the block away
# goes red here. Role-aware on ONE axis: the captain keeps a human channel
# (documented human-facing seat); every other role has none.
GR_HDR="AUTHORIZATION GROUND RULES"
GR_GHOST="Reading another role's pane is never observing the human"
GR_FAB="Never write or imply that a human confirmed"
GR_LABEL="Authorization is a POSITIVE, attributable, mechanically checkable artifact"
GR_HOLD="HOLD and post the doubt as an open question"
GR_CAP_CHANNEL="genuine text a person types directly into YOUR OWN pane"
GR_NO_CHANNEL="You have NO channel to the human"
# The mechanism signal (#150): the block must name the checker AND carry the
# RESOLVED sentinel token (__UNGATE_SENTINEL__ substituted to its value), proving
# roles are pointed at 'fwf authz' + a positive artifact, not a label inference.
GR_CHECKER="fwf authz <issue>"
GR_SENTINEL="OPERATOR-UNGATE"
# #208: naming fwf authz as the SOLE oracle, and stating that a non-AUTHORIZED
# verdict is a HOLD regardless of belief about why (closes the "reclassify the
# refusal as a malfunction" hole) — asserted on the rendered prompt, not just
# the source, so a future edit that drops the clause goes red here.
GR_SOLE_ORACLE="is the SOLE authorization oracle"
GR_REGARDLESS_OF_BELIEF="regardless of your belief about why it is non-AUTHORIZED"
# Assert the block + its shared bullets are present for a non-captain role, and
# that a non-captain is told it has NO channel (never the captain's channel
# clause). $1=label $2=template-relpath $3=id(optional, unquoted so an empty
# id splits to nothing — no SC2089/SC2090 literal-quote lint).
gr_assert_no_channel() {
  # Guard against a false green: fwf_render prepends the block even when the
  # template is missing (cat fails, rc still 0), so a path typo would pass every
  # block assertion vacuously. Require the file to exist first.
  if [ ! -f "$ROOT/templates/$2" ]; then bad "$1: template file exists (path typo?)"; return; fi
  local R; R="$(prov_env "fwf_render '$ROOT/templates/$2' ${3:-}")"
  assert_contains     "$1: ground-rules header present"          "$R" "$GR_HDR"
  assert_contains     "$1: ghost-text-is-not-input rule present" "$R" "$GR_GHOST"
  assert_contains     "$1: no-fabricated-confirmation rule"      "$R" "$GR_FAB"
  assert_contains     "$1: authorization-is-a-checkable-artifact rule" "$R" "$GR_LABEL"
  assert_contains     "$1: names the fwf authz checker"          "$R" "$GR_CHECKER"
  assert_contains     "$1: carries the resolved un-gate sentinel" "$R" "$GR_SENTINEL"
  assert_contains     "$1: hold-and-ask-under-doubt rule"        "$R" "$GR_HOLD"
  assert_contains     "$1: sole-authorization-oracle rule"       "$R" "$GR_SOLE_ORACLE"
  assert_contains     "$1: non-AUTHORIZED is a HOLD regardless of belief" "$R" "$GR_REGARDLESS_OF_BELIEF"
  assert_contains     "$1: non-captain gets NO human channel"    "$R" "$GR_NO_CHANNEL"
  assert_not_contains "$1: non-captain must NOT get a channel"   "$R" "$GR_CAP_CHANNEL"
}
# Universality: every build-floor + coordination role, across >1 template family.
gr_assert_no_channel "dev/implementer"     "dev/implementer.tmpl" 2
gr_assert_no_channel "dev/qa"              "dev/qa.tmpl" 1
gr_assert_no_channel "dev/pm"             "dev/pm.tmpl"
gr_assert_no_channel "dev/gv"            "dev/gv.tmpl"
gr_assert_no_channel "dev/conductor"    "dev/conductor.tmpl"
gr_assert_no_channel "validate/qa"       "validate/qa.tmpl" 1
gr_assert_no_channel "user-testing/pm"  "user-testing/pm.tmpl"
# Captain is the sole exception: keeps a human channel, still gets every shared rule.
CAPR="$(prov_env "fwf_render \"\$(fwf_tmpl_path captain)\" ''")"
# Body-sanity (not just the prepended block): "dwell" is captain-body content
# in the example profile's template — proves the render isn't vacuously the
# block alone (mirrors the existing captain-render tests below).
assert_contains "captain: body (not just block) rendered"     "$CAPR" "dwell"
assert_contains "captain: ground-rules header present"        "$CAPR" "$GR_HDR"
assert_contains "captain: retains its human channel"          "$CAPR" "$GR_CAP_CHANNEL"
assert_contains "captain: ghost-text-is-not-input rule"       "$CAPR" "$GR_GHOST"
assert_contains "captain: no-fabricated-confirmation rule"    "$CAPR" "$GR_FAB"
assert_contains "captain: authorization-is-a-checkable-artifact rule" "$CAPR" "$GR_LABEL"
assert_contains "captain: names the fwf authz checker"        "$CAPR" "$GR_CHECKER"
assert_contains "captain: carries the resolved un-gate sentinel" "$CAPR" "$GR_SENTINEL"
assert_contains "captain: sole-authorization-oracle rule"       "$CAPR" "$GR_SOLE_ORACLE"
assert_contains "captain: non-AUTHORIZED is a HOLD regardless of belief" "$CAPR" "$GR_REGARDLESS_OF_BELIEF"
assert_not_contains "captain must NOT be told it has NO channel" "$CAPR" "$GR_NO_CHANNEL"

section "fwf_wait_heartbeat: polls a plain file, no tmux needed (#99 Fix 2)"
HBT="$TMP/heartbeat-test"; mkdir -p "$HBT"
hb_test() { FWF_PROFILE=example FWF_RUN_DIR="$HBT/run" FWF_HEARTBEAT_POLL_SECS=1 bash -c "source '$ROOT/lib.sh'; $1"; }
hb_test 'mkdir -p "$(dirname "$(fwf_heartbeat_path impl9)")"'
NOFILE_RC="$(hb_test 'fwf_wait_heartbeat impl9 $(date +%s) 2 >/dev/null 2>&1; echo $?')"
assert_eq "missing heartbeat file -> times out (rc 1)" "1" "$NOFILE_RC"
hb_test 'touch -t 202001010000 "$(fwf_heartbeat_path impl9)"'
STALE_RC="$(hb_test 'fwf_wait_heartbeat impl9 $(date +%s) 2 >/dev/null 2>&1; echo $?')"
assert_eq "stale (pre-arm) heartbeat -> times out (rc 1), not a false pass" "1" "$STALE_RC"
hb_test 'touch "$(fwf_heartbeat_path impl9)"'
FRESH_OUT="$(hb_test 'fwf_wait_heartbeat impl9 $(( $(date +%s) - 5 )) 2')"
[ -n "$FRESH_OUT" ] && ok "fresh heartbeat -> succeeds and echoes the mtime" || bad "fresh heartbeat -> succeeds and echoes the mtime"

section "fwf_verify_respawn_tick: verified tick / bounded re-nudge / no false success (#99 Fix 2)"
VT="$TMP/verify-tick-test"; mkdir -p "$VT"
vt_run() { FWF_PROFILE=example FWF_RUN_DIR="$VT/run" FWF_HEARTBEAT_POLL_SECS=1 bash -c "source '$ROOT/lib.sh'; mkdir -p \"\$(dirname \"\$(fwf_heartbeat_path impl9)\")\"; $1"; }
# already-ticking pane: verified on the FIRST wait, renudge never called.
vt_run 'rm -f "$(fwf_heartbeat_path impl9)"; touch "$(fwf_heartbeat_path impl9)"
  _n() { echo NUDGE_FIRED; }
  fwf_verify_respawn_tick impl9 $(( $(date +%s) - 5 )) 2 _n' > "$VT/out1.txt" 2>&1
assert_contains "already-ticking pane verifies immediately" "$(cat "$VT/out1.txt")" "respawn verified: first tick observed ("
case "$(cat "$VT/out1.txt")" in *NUDGE_FIRED*) bad "renudge must NOT fire when the first wait already succeeds";; *) ok "renudge must NOT fire when the first wait already succeeds";; esac
# a wedged-looking pane that the re-nudge actually unsticks.
vt_run 'rm -f "$(fwf_heartbeat_path impl9)"
  _n() { touch "$(fwf_heartbeat_path impl9)"; }
  fwf_verify_respawn_tick impl9 $(date +%s) 2 _n; echo "RC=$?"' > "$VT/out2.txt" 2>&1
assert_contains "re-nudge that lands still verifies (after one re-nudge)" "$(cat "$VT/out2.txt")" "first tick observed after one re-nudge"
assert_contains "verified-after-renudge exits 0" "$(cat "$VT/out2.txt")" "RC=0"
# a pane that NEVER ticks, even after the re-nudge: fails loudly, never a false success.
vt_run 'rm -f "$(fwf_heartbeat_path impl9)"
  _n() { :; }
  fwf_verify_respawn_tick impl9 $(date +%s) 2 _n; echo "RC=$?"' > "$VT/out3.txt" 2>&1
assert_contains "never-ticking pane: clear failure message" "$(cat "$VT/out3.txt")" "did NOT tick after arming"
assert_contains "never-ticking pane: exits nonzero" "$(cat "$VT/out3.txt")" "RC=1"
case "$(cat "$VT/out3.txt")" in *"respawn verified"*) bad "never-ticking pane must NEVER print a success line";; *) ok "never-ticking pane must NEVER print a success line";; esac

section "fwf tick: monotonic per-role loop-tick counter — the reliable liveness signal (#133)"
TK="$TMP/tick-test"; mkdir -p "$TK"
tk() { FWF_PROFILE=example FWF_RUN_DIR="$TK/run" bash -c "source '$ROOT/lib.sh'; $1"; }
assert_eq "unticked role reads 0 (never errors)"       "0" "$(tk 'fwf_tick_read impl9')"
assert_eq "first bump returns 1"                        "1" "$(tk 'fwf_tick_bump impl9')"
assert_eq "counter STRICTLY increases across bumps"     "3" "$(tk 'fwf_tick_bump impl9 >/dev/null; fwf_tick_bump impl9 >/dev/null; fwf_tick_read impl9')"
assert_eq "per-role: bumping impl9 leaves qa9 at 0"     "0" "$(tk 'fwf_tick_read qa9')"
assert_eq "a bump also refreshes the heartbeat (boot-gate/respawn stay wired)" "yes" \
  "$(tk 'fwf_tick_bump impl9 >/dev/null; [ -f "$(fwf_heartbeat_path impl9)" ] && echo yes || echo no')"
# malformed counter file must degrade to 0, never crash arithmetic.
assert_eq "malformed counter file -> reads 0"          "0" \
  "$(tk 'mkdir -p "$(dirname "$(fwf_tick_path impl9)")"; printf garbage > "$(fwf_tick_path impl9)"; fwf_tick_read impl9')"
# the `fwf tick` subcommand is the agent-facing entrypoint and echoes the count.
assert_eq "fwf tick <role> subcommand bumps + echoes the count" "1" \
  "$(FWF_PROFILE=example FWF_RUN_DIR="$TK/run2" "$ROOT/fwf" tick impl9)"
TICK_USAGE="$(FWF_PROFILE=example FWF_RUN_DIR="$TK/run3" "$ROOT/fwf" tick 2>&1 || true)"
assert_contains "fwf tick with no role errors with usage" "$TICK_USAGE" "usage: fwf tick <role>"

section "fwf tick: context-derived profile beats ambient env, so a live role's heartbeat never misroutes (#182)"
# A worktree carrying a `.fwf-profile` marker (as fwf-provision.sh now writes)
# must win over a stray/leftover ambient FWF_PROFILE for the tick/heartbeat
# write — that's the concretely-reproduced bug: an ambient value from an
# unrelated shell silently misrouting a live role's heartbeat, making it look
# DEAD to health-gate/respawn.
MARKED="$TMP/marked-worktree"; mkdir -p "$MARKED"
( cd "$MARKED" && git init -q && printf 'example\n' > .fwf-profile )
CTX_RUN="$TK/run-ctx"
CTX_OUT="$(cd "$MARKED" && FWF_PROFILE=WRONG-AMBIENT FWF_RUN_DIR="$CTX_RUN" "$ROOT/fwf" tick impl9 2>"$CTX_RUN.stderr")"
assert_eq "marked worktree: tick still echoes the bumped count" "1" "$CTX_OUT"
assert_eq "marked worktree: heartbeat lands under the MARKER's profile (example), not ambient" \
  "yes" "$([ -f "$CTX_RUN/state/example/tick/impl9" ] && echo yes || echo no)"
assert_eq "marked worktree: nothing written under the wrong ambient profile" \
  "no" "$([ -e "$CTX_RUN/state/WRONG-AMBIENT" ] && echo yes || echo no)"
assert_contains "marked worktree: mismatch is logged with the issue number" \
  "$(cat "$CTX_RUN.stderr" 2>/dev/null)" "issue #182"
assert_contains "marked worktree: mismatch log names both the ambient and context values" \
  "$(cat "$CTX_RUN.stderr" 2>/dev/null)" "WRONG-AMBIENT"

# No marker (not a provisioned worktree) + ambient set to a profile with NO
# live activity while another profile demonstrably IS live: warn (phantom
# alarm), but this is advisory-only — there is no marker to confirm the
# correct profile, so tick still falls back to today's ambient-trust write
# (LAST RESORT), unchanged from pre-#182 behavior. Needs a second REAL
# profile file (a phantom ambient profile still has to pass lib.sh's own
# "unknown profile" check, unrelated to #182) — same throwaway-visible-profile
# pattern as the --profile position-independence tests above.
cat > "$ROOT/profiles/zzp182.sh" <<EOF
FWF_REPO="$TMP/x182"; WT_PREFIX="zzp182"; WT_BASE="$TMP"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
FWF_ISSUES=local
EOF
UNMARKED="$TMP/unmarked-plain-dir"; mkdir -p "$UNMARKED"
PHANTOM_RUN="$TK/run-phantom"
mkdir -p "$PHANTOM_RUN/state/example/tick"
touch "$PHANTOM_RUN/state/example/tick/qa1"   # "example" has live activity
PHANTOM_OUT="$(cd "$UNMARKED" && FWF_PROFILE=zzp182 FWF_RUN_DIR="$PHANTOM_RUN" "$ROOT/fwf" tick impl9 2>"$PHANTOM_RUN.stderr")"
assert_eq "no marker + phantom ambient: tick STILL succeeds (warn-only, never blocks)" "1" "$PHANTOM_OUT"
assert_eq "no marker + phantom ambient: still writes under ambient (no marker to redirect to)" \
  "yes" "$([ -f "$PHANTOM_RUN/state/zzp182/tick/impl9" ] && echo yes || echo no)"
assert_contains "no marker + phantom ambient: alarms that the swarm looks live elsewhere" \
  "$(cat "$PHANTOM_RUN.stderr" 2>/dev/null)" "may be misrouting"

# No marker, ambient set, but NO other profile is live either (cold start) —
# must NOT alarm: a role legitimately first-up in a fresh profile is healthy.
COLD_RUN="$TK/run-cold"
COLD_OUT="$(cd "$UNMARKED" && FWF_PROFILE=zzp182 FWF_RUN_DIR="$COLD_RUN" "$ROOT/fwf" tick impl9 2>"$COLD_RUN.stderr")"
assert_eq "cold start: tick succeeds" "1" "$COLD_OUT"
case "$(cat "$COLD_RUN.stderr" 2>/dev/null)" in
  *"#182"*) bad "cold start (no sibling profile live) must NOT alarm";;
  *)        ok  "cold start (no sibling profile live) must NOT alarm";;
esac
rm -f "$ROOT/profiles/zzp182.sh"

section "fwf_wedge_verdict: steady-state wedge classifier — PURE (delta_tick, delta_tokens, elapsed) -> verdict (#165)"
# Pure predicate: sample tuples in -> asserted verdict out, exactly like
# fwf_pr_is_stale_stub. FWF_WEDGE_MIN_SECS pinned so the flat-for threshold is
# deterministic (600s here). No state, no tmux, no tokens sampled.
wv() { FWF_PROFILE=example FWF_WEDGE_MIN_SECS=600 bash -c "source '$ROOT/lib.sh'; fwf_wedge_verdict $1"; }
# HEALTHY: the tick advanced — alive regardless of tokens or elapsed.
assert_eq "tick advanced -> HEALTHY"                         "HEALTHY" "$(wv '1 0 9999')"
assert_eq "tick advanced even with tokens flowing -> HEALTHY" "HEALTHY" "$(wv '5 4000 30')"
# WORKING (the whole point of the ticket): tick STATIC but tokens still flowing
# past the threshold is a healthy long cycle — must NOT be reaped as WEDGED.
assert_eq "tick static BUT tokens flowing past threshold -> WORKING (not WEDGED)" \
  "WORKING" "$(wv '0 12000 9999')"
assert_eq "tick static, one token of flow -> WORKING"        "WORKING" "$(wv '0 1 700')"
# WORKING (grace): both static but not yet past the flat-for threshold.
assert_eq "both flat but within grace (elapsed < threshold) -> WORKING" \
  "WORKING" "$(wv '0 0 120')"
assert_eq "both flat exactly at threshold-1 -> WORKING"      "WORKING" "$(wv '0 0 599')"
# WEDGED: tick static AND tokens flat, sustained past the threshold — the ONLY
# reapable verdict, and only when BOTH signals are dead.
assert_eq "tick static AND tokens flat past threshold -> WEDGED" "WEDGED" "$(wv '0 0 600')"
assert_eq "tick static AND tokens flat well past threshold -> WEDGED" "WEDGED" "$(wv '0 0 3600')"
# Robustness: malformed/negative inputs degrade to 0 — never crash, never a
# fabricated WEDGED from garbage.
assert_eq "malformed tick delta degrades to 0 (flat) -> WEDGED at threshold" "WEDGED" "$(wv 'x 0 600')"
assert_eq "malformed token delta treated as flat -> WEDGED"  "WEDGED" "$(wv '0 x 600')"
assert_eq "negative token delta (cache reset) treated as flat -> WEDGED" "WEDGED" "$(wv '0 -50 600')"

section "fwf_verify_boot_ticks: boot health-gate — first-tick verify + re-arm + dead-role escalation (#133)"
BG="$TMP/boot-gate"; mkdir -p "$BG"
bg() { FWF_PROFILE=example FWF_RUN_DIR="$BG/run" FWF_HEARTBEAT_POLL_SECS=1 bash -c "source '$ROOT/lib.sh'; mkdir -p \"\$(dirname \"\$(fwf_heartbeat_path impl1)\")\"; $1"; }
# All-healthy floor: every role already ticking -> gate passes, no dead roles.
bg 'now=$(date +%s); for r in impl1 impl2 conductor; do touch "$(fwf_heartbeat_path $r)"; done
  _n() { :; }
  fwf_verify_boot_ticks "$((now-2))" _n "impl1:2" "impl2:2" "conductor:2"; echo "RC=$?"; echo "DEAD=[${FWF_BOOT_DEAD_ROLES[*]}]"' > "$BG/out1.txt" 2>&1
assert_contains "all-healthy floor: every role verifies"      "$(cat "$BG/out1.txt")" "first tick verified — impl1"
assert_contains "all-healthy floor: gate returns 0"           "$(cat "$BG/out1.txt")" "RC=0"
assert_contains "all-healthy floor: no dead roles"            "$(cat "$BG/out1.txt")" "DEAD=[]"
# A laggard that the re-arm (renudge) actually revives -> verified, not dead.
bg 'now=$(date +%s); touch "$(fwf_heartbeat_path impl1)"; rm -f "$(fwf_heartbeat_path impl2)"
  _n() { case "$1" in impl2) touch "$(fwf_heartbeat_path impl2)";; esac; }
  fwf_verify_boot_ticks "$((now-2))" _n "impl1:2" "impl2:2"; echo "RC=$?"; echo "DEAD=[${FWF_BOOT_DEAD_ROLES[*]}]"' > "$BG/out2.txt" 2>&1
assert_contains "re-armed laggard that ticks verifies on pass 2"  "$(cat "$BG/out2.txt")" "first tick verified after re-arm — impl2"
assert_contains "revived laggard: gate returns 0"                 "$(cat "$BG/out2.txt")" "RC=0"
assert_contains "revived laggard: no dead roles"                  "$(cat "$BG/out2.txt")" "DEAD=[]"
# A role that never ticks even after re-arm -> named dead, gate returns 1.
bg 'now=$(date +%s); touch "$(fwf_heartbeat_path impl1)"; rm -f "$(fwf_heartbeat_path conductor)"
  _n() { :; }
  fwf_verify_boot_ticks "$((now-2))" _n "impl1:2" "conductor:2"; echo "RC=$?"; echo "DEAD=[${FWF_BOOT_DEAD_ROLES[*]}]"' > "$BG/out3.txt" 2>&1
assert_contains "never-ticking role: named as dead"           "$(cat "$BG/out3.txt")" "never fired a first tick: conductor"
assert_contains "never-ticking role: gate returns 1"          "$(cat "$BG/out3.txt")" "RC=1"
assert_contains "never-ticking role: exported in FWF_BOOT_DEAD_ROLES" "$(cat "$BG/out3.txt")" "DEAD=[conductor]"
case "$(cat "$BG/out3.txt")" in *"first tick verified after re-arm — conductor"*) bad "dead role must NEVER print a verified line";; *) ok "dead role must NEVER print a verified line";; esac
# fwf up must actually WIRE the gate: run it after arming, and hard-respawn any
# role it reports dead — so a wedged boot self-recovers with no manual respawn.
assert_contains "fwf up runs the boot health-gate after arming" \
  "$(cat "$ROOT/fwf-up.sh")" "fwf_verify_boot_ticks"
assert_contains "fwf up hard-respawns any role the gate reports dead" \
  "$(cat "$ROOT/fwf-up.sh")" "hard-respawning wedged role"
assert_contains "fwf up captures the boot epoch BEFORE arming (first tick counts)" \
  "$(cat "$ROOT/fwf-up.sh")" "BOOT_EPOCH="

section "fwf_pr_is_stale_stub: only auto-close empty, stale, DRAFT claim stubs (#133)"
sp() { bash -c "source '$ROOT/lib.sh'; $1; echo \$?"; }
assert_eq "empty draft older than grace -> close (0)"    "0" "$(sp 'fwf_pr_is_stale_stub true 0 1000 900')"
assert_eq "draft WITH a real diff -> keep (1)"           "1" "$(sp 'fwf_pr_is_stale_stub true 3 1000 900')"
assert_eq "empty draft younger than grace -> keep (1)"   "1" "$(sp 'fwf_pr_is_stale_stub true 0 100 900')"
assert_eq "empty but NOT a draft (ready PR) -> keep (1)" "1" "$(sp 'fwf_pr_is_stale_stub false 0 1000 900')"
assert_eq "iso8601 UTC parses to epoch"  "1786457002" "$(bash -c "source '$ROOT/lib.sh'; fwf_iso_to_epoch 2026-08-11T14:03:22Z")"

section "fwf-respawn.sh: hardens a silent no-op respawn with a kill+relaunch escalation (#133)"
assert_contains "respawn escalates to a hard pane recycle when the soft re-nudge doesn't tick" \
  "$(cat "$ROOT/fwf-respawn.sh")" "escalating to a hard kill+relaunch"
assert_contains "respawn never reports success without a re-verified tick after escalation" \
  "$(cat "$ROOT/fwf-respawn.sh")" "after a hard pane relaunch (escalated recovery)"

section "fwf_interval_seconds: normalizes /loop-style intervals for arithmetic (issue #116)"
ivs_test() { bash -c "source '$ROOT/lib.sh'; $1"; }
assert_eq "3m -> 180"   "180"   "$(ivs_test 'fwf_interval_seconds 3m')"
assert_eq "2m -> 120"   "120"   "$(ivs_test 'fwf_interval_seconds 2m')"
assert_eq "2h -> 7200"  "7200"  "$(ivs_test 'fwf_interval_seconds 2h')"
assert_eq "45s -> 45"   "45"    "$(ivs_test 'fwf_interval_seconds 45s')"
assert_eq "1d -> 86400" "86400" "$(ivs_test 'fwf_interval_seconds 1d')"
assert_eq "bare integer passes through unchanged" "300" "$(ivs_test 'fwf_interval_seconds 300')"
IVS_BAD_RC="$(ivs_test 'fwf_interval_seconds bogus >/dev/null 2>&1; echo $?')"
assert_eq "malformed interval -> rc 1, not a crash" "1" "$IVS_BAD_RC"
IVS_BAD_MSG="$(ivs_test 'fwf_interval_seconds bogus 2>&1 >/dev/null')"
assert_contains "malformed interval names the bad value" "$IVS_BAD_MSG" "invalid interval 'bogus'"
IVS_EMPTY_RC="$(ivs_test 'fwf_interval_seconds "" >/dev/null 2>&1; echo $?')"
assert_eq "empty interval -> rc 1, not a crash" "1" "$IVS_EMPTY_RC"

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

section "fwf doctor: usage-schema smoke-test (#95) — catches Claude Code transcript drift before it silently under-reports"
DT="$TMP/doctor-usage"; mkdir -p "$DT/pwd" "$DT/claude-projects"
DSLUG_DIR="$(cd "$DT/pwd" && pwd)"; DSLUG="${DSLUG_DIR//\//-}"; DSLUG="${DSLUG//./-}"
doctor_usage() { ( cd "$DT/pwd" && FWF_CLAUDE_PROJECTS_DIR="$DT/claude-projects" "$ROOT/fwf" doctor 2>&1 || true ) | grep "usage schema"; }
assert_contains "no transcript dir yet -> skip, not a false pass/fail" "$(doctor_usage)" "skip (no Claude Code transcript dir"
mkdir -p "$DT/claude-projects/$DSLUG"
printf '{"type":"user","message":{}}\n' > "$DT/claude-projects/$DSLUG/s.jsonl"
assert_contains "transcript dir but no assistant line yet -> skip, not a false pass" "$(doctor_usage)" "no assistant-type line found"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1}}}\n' >> "$DT/claude-projects/$DSLUG/s.jsonl"
assert_contains "matching schema -> ok" "$(doctor_usage)" "usage schema: ok"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"totally_different_field":1}}}\n' > "$DT/claude-projects/$DSLUG/s.jsonl"
DRIFT="$(doctor_usage)"
assert_contains "drifted schema -> WARNING, names the expected shape" "$DRIFT" "WARNING"
assert_contains "drift warning names the fields fwf usage reads" "$DRIFT" "message.usage.{input,output}_tokens"
# Differential, not absolute: doctor's exit also reflects unrelated checks
# (tmux/git/gh/claude presence) that vary by environment, so compare the SAME
# environment with vs. without the drifted transcript rather than asserting
# a specific exit code.
EXIT_NO_TRANSCRIPT="$(cd "$DT/pwd" && FWF_CLAUDE_PROJECTS_DIR="$DT/claude-projects-none" "$ROOT/fwf" doctor >/dev/null 2>&1; echo $?)"
EXIT_WITH_DRIFT="$(cd "$DT/pwd" && FWF_CLAUDE_PROJECTS_DIR="$DT/claude-projects" "$ROOT/fwf" doctor >/dev/null 2>&1; echo $?)"
assert_eq "schema drift is informational only — doesn't change doctor's exit code" "$EXIT_NO_TRANSCRIPT" "$EXIT_WITH_DRIFT"
# profiles lists at least the example template shipped in the repo
assert_contains "profiles lists shipped profile" "$("$ROOT/fwf" profiles)" "example"
# captain --print renders the CAPTAIN prompt with placeholders resolved
CAPTAIN="$("$ROOT/fwf" --profile example captain --print 2>&1)"
assert_contains "captain --print renders prompt" "$CAPTAIN" "CAPTAIN"
assert_contains "captain resolves placeholders"  "$CAPTAIN" "staging"

section "--profile position-independence (issue #69)"
# Two throwaway VISIBLE profiles (list_profiles globs *.sh with no dotglob,
# so a leading-dot name like the .__persist.sh fixtures above would stay
# invisible and never trigger real ambiguity) force the "multiple profiles
# exist" case so we can prove which one --profile actually selected.
cat > "$ROOT/profiles/zzflagtest-a.sh" <<EOF
FWF_REPO="$TMP/x"; WT_PREFIX="flaga"; WT_BASE="$TMP"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
FWF_ISSUES=local
EOF
cat > "$ROOT/profiles/zzflagtest-b.sh" <<EOF
FWF_REPO="$TMP/x"; WT_PREFIX="flagb"; WT_BASE="$TMP"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
FWF_ISSUES=local
EOF
# with multiple profiles present, no --profile anywhere is genuinely ambiguous
AMBIG="$("$ROOT/fwf" captain --print 2>&1)"
case "$AMBIG" in *"multiple profiles exist"*) ok "ambiguous profile rejected";; *) bad "ambiguous profile rejected" "$AMBIG";; esac
assert_contains "ambiguity error names both positions" "$AMBIG" "before OR after the command"
assert_contains "ambiguity error names FWF_PROFILE"    "$AMBIG" "FWF_PROFILE=NAME"
# pre-subcommand --profile still works (regression, #7-style)
PRE="$("$ROOT/fwf" --profile zzflagtest-b captain --print 2>&1)"
assert_contains "pre-subcommand --profile resolves" "$PRE" "CAPTAIN"
# post-subcommand --profile on a parse_runtime_flags command (captain)
POST_RTF="$("$ROOT/fwf" captain --profile zzflagtest-b --print 2>&1)"
assert_contains "post-subcommand --profile (runtime-flags cmd)" "$POST_RTF" "CAPTAIN"
# post-subcommand --profile=NAME spelling
POST_EQ="$("$ROOT/fwf" captain --profile=zzflagtest-b --print 2>&1)"
assert_contains "post-subcommand --profile=NAME" "$POST_EQ" "CAPTAIN"
# post-subcommand --profile on a bare `engine()` command NOT in the
# runtime-flags list (issues/dash/pr-review-state/stop) — the exact repro
# from #69 (`fwf dash --profile NAME`); `issues list` needs no gh/tmux.
DASHLIKE="$("$ROOT/fwf" issues --profile zzflagtest-b list 2>&1)"
case "$DASHLIKE" in *"multiple profiles exist"*) bad "post-subcommand --profile on bare engine cmd" "$DASHLIKE";; *) ok "post-subcommand --profile on bare engine cmd";; esac
# last --profile wins when given in both positions with different values
FWF_RUN_DIR="$TMP/lastwins" "$ROOT/fwf" --profile zzflagtest-a issues --profile zzflagtest-b create --title probe >/dev/null 2>&1
LASTWINS="$(FWF_RUN_DIR="$TMP/lastwins" "$ROOT/fwf" --profile zzflagtest-b issues list 2>&1)"
assert_contains "last --profile (post) wins over pre" "$LASTWINS" "probe"
NOTINA="$(FWF_RUN_DIR="$TMP/lastwins" "$ROOT/fwf" --profile zzflagtest-a issues list 2>&1)"
case "$NOTINA" in *probe*) bad "last-wins: earlier profile untouched" "$NOTINA";; *) ok "last-wins: earlier profile untouched";; esac
rm -f "$ROOT/profiles/zzflagtest-a.sh" "$ROOT/profiles/zzflagtest-b.sh"

section "dispatcher: resume --clear-only clears the sentinel"
RUNDIR="$TMP/run"; mkdir -p "$RUNDIR"; : > "$RUNDIR/STOP"
RES="$(FWF_RUN_DIR="$RUNDIR" "$ROOT/fwf" --profile example resume --clear-only 2>&1)"
[ -e "$RUNDIR/STOP" ] && bad "resume --clear-only removes sentinel" || ok "resume --clear-only removes sentinel"
assert_contains "resume --clear-only message" "$RES" "cleared STOP sentinel"

section "floor lifecycle flags (issue #6, per-plane split by #105) — no live tmux needed"
# Isolated session names guarantee we never touch a real factory.
# FWF_MIN_FREE_GB=0 disables the disk-pressure guard so these flag-logic
# tests don't depend on the runner's free disk.
FU_ENV="FWF_PROFILE=example FWF_SESSION=fwf-selftest-$$ FWF_MIN_FREE_GB=0"
# up: unknown flag rejected before any tmux work
env $FU_ENV "$ROOT/fwf-up.sh" --bogus >/dev/null 2>&1 && bad "up rejects unknown flag" || ok "up rejects unknown flag"
# up --floor-only / --build-only / --pm-only without a live coord session all
# point at the full launch path (none of the partial modes can bootstrap).
for FLAG in --floor-only --build-only --pm-only; do
  UPOUT="$(env $FU_ENV "$ROOT/fwf-up.sh" "$FLAG" 2>&1)" && bad "$FLAG up needs coord session" || ok "$FLAG up needs coord session"
  assert_contains "$FLAG up suggests full up" "$UPOUT" "run a full 'fwf up' instead"
done
# down: --floor-only/--build-only/--pm-only + --purge don't combine (rejected
# before the flags reach any cooldown/deadlock check, so no stub needed here)
for FLAG in --floor-only --build-only --pm-only; do
  env $FU_ENV "$ROOT/fwf-down.sh" "$FLAG" --purge >/dev/null 2>&1 && bad "down rejects $FLAG+purge" || ok "down rejects $FLAG+purge"
done
# (down-with-nothing-up now also runs the #105 deadlock guards, which shell
# out to gh/git — see the dedicated hermetic section below for those)
# help advertises the per-plane flags
HELP_OUT="$("$ROOT/fwf" help)"
assert_contains "help mentions --floor-only" "$HELP_OUT" "--floor-only"
assert_contains "help mentions --build-only" "$HELP_OUT" "--build-only"
assert_contains "help mentions --pm-only"    "$HELP_OUT" "--pm-only"
assert_contains "help mentions --coord-only" "$HELP_OUT" "--coord-only"
# up --coord-only is the ONE partial-up flag that must NOT require a live
# coord session (issue #155 — it's the cold-bootstrap path for coordination,
# the opposite precondition of --floor-only/--build-only/--pm-only above).
UPCOOUT="$(env $FU_ENV "$ROOT/fwf-up.sh" --coord-only 2>&1)"
case "$UPCOOUT" in
  *"run a full 'fwf up' instead"*) bad "up --coord-only must not require an existing coord session" "$UPCOOUT";;
  *) ok "up --coord-only does not require an existing coord session";;
esac

section "floor-lifecycle event log (issue #85, per-plane by #105): fwf_floor_event / fwf_plane_idle_state"
# Pure file I/O (lib.sh) — no tmux/gh needed for the read/write primitives.
F85RUN="$TMP/run85"; mkdir -p "$F85RUN"
F85ENV="FWF_RUN_DIR=$F85RUN FWF_PROFILE=example"
assert_eq "no log yet -> build plane idle inactive" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"
# (b) floor-down is appended with actor/reason/ts/epoch/plane and survives a re-read
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain 'queue empty; nothing in flight'"
F85LOG="$F85RUN/state/example/floor-events.log"
[ -f "$F85LOG" ] && ok "floor-events.log created" || bad "floor-events.log created"
F85LAST="$(tail -n1 "$F85LOG")"
assert_contains "floor-down line names the actor" "$F85LAST" "captain"
assert_contains "floor-down line carries the reason" "$F85LAST" "queue empty; nothing in flight"
case "$F85LAST" in *"floor-down"*) ok "last line is floor-down";; *) bad "last line is floor-down" "$F85LAST";; esac
assert_eq "plane defaults to build when omitted" "build" "$(printf '%s' "$F85LAST" | cut -f6)"
F85EPOCH="$(printf '%s' "$F85LAST" | cut -f2)"
case "$F85EPOCH" in ''|*[!0-9]*) bad "epoch field is numeric" "$F85EPOCH";; *) ok "epoch field is numeric";; esac
F85TS="$(printf '%s' "$F85LAST" | cut -f1)"
case "$F85TS" in [0-9][0-9][0-9][0-9]-*T*Z) ok "ts field is ISO-8601 UTC";; *) bad "ts field is ISO-8601 UTC" "$F85TS";; esac
# (a) fwf_plane_idle_state now reports active, carrying the same reason
F85IDLE="$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build")"
assert_eq "plane_idle_state active after floor-down" "true" "$(printf '%s' "$F85IDLE" | cut -f1)"
assert_contains "plane_idle_state carries the reason" "$F85IDLE" "queue empty; nothing in flight"
# a DIFFERENT plane (pm) is untouched by a build-plane event
assert_eq "pm plane stays inactive while only build has a floor-down" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state pm" | cut -f1)"
# an explicit pm-plane event is tracked independently of build
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain 'pm reason' pm"
assert_eq "pm plane active after its own floor-down" "true" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state pm" | cut -f1)"
assert_eq "build plane STILL active (independent of pm)" "true" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-up '' '' pm"
assert_eq "pm floor-up clears ONLY pm, not build" "true" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"
assert_eq "pm plane cleared by its own floor-up" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state pm" | cut -f1)"
# (b-up-paths / idempotency) floor-up clears it; repeated transitions stay coherent
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-up '' ''"
assert_eq "floor-up clears build plane idle" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain r2; fwf_floor_event floor-up '' ''; fwf_floor_event floor-down captain r3"
assert_eq "repeated down/up/down stays coherent (last event wins)" "true" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"
# (bound) capped at the last 200 lines; the dash still reads the correct last event
F85CAPRUN="$TMP/run85cap"; mkdir -p "$F85CAPRUN/state/example"
F85CAPLOG="$F85CAPRUN/state/example/floor-events.log"
i=1; while [ "$i" -le 205 ]; do printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$i" >> "$F85CAPLOG"; i=$((i+1)); done
env FWF_RUN_DIR="$F85CAPRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain capped"
assert_eq "log capped at 200 lines" "200" "$(wc -l < "$F85CAPLOG" | tr -d ' ')"
assert_eq "dash still reads the correct (capped) last event, legacy 5-column rows read as plane build" "true" \
  "$(env FWF_RUN_DIR="$F85CAPRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state build" | cut -f1)"

section "fwf dash data (issue #85): roles_json renders floor_idle, distinct from a crash"
DD85="$ROOT/fwf-dash-data.sh"
FI_ON='{"active":true,"since":"2026-01-01T00:00:00Z","reason":"queue empty; nothing in flight","actor":"captain"}'
FI_OFF='{"active":false,"since":"","reason":"","actor":""}'
# no pane anywhere (stub tmux always "down") + floor_idle active -> every
# non-captain role reads floor_idle; the captain (never torn down by
# --floor-only) is excluded and stays a real "down".
NOPANE_TMUX="$TMP/nopane85bin"; mkdir -p "$NOPANE_TMUX"
cat > "$NOPANE_TMUX/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in has-session) exit 1;; list-panes) exit 0;; *) exit 1;; esac
STUB
chmod +x "$NOPANE_TMUX/tmux"
R85_IDLE="$(PATH="$NOPANE_TMUX:$PATH" FWF_PROFILE=example bash -c "source '$DD85'; roles_json '$FI_ON'")"
assert_eq "impl1 renders floor_idle when idle+no pane" "floor_idle" \
  "$(printf '%s' "$R85_IDLE" | jq -r '.[] | select(.role=="impl1") | .state')"
assert_contains "impl1 detail names the actor+reason" \
  "$(printf '%s' "$R85_IDLE" | jq -r '.[] | select(.role=="impl1") | .detail')" "captain"
assert_eq "captain is EXCLUDED from floor_idle (never torn down by --floor-only)" "down" \
  "$(printf '%s' "$R85_IDLE" | jq -r '.[] | select(.role=="captain") | .state')"
# same no-pane fixture, but floor_idle inactive (a REAL crash, no floor-down
# logged) -> every role reads down, never floor_idle. RED if this and the
# idle case above ever render the same state.
R85_CRASH="$(PATH="$NOPANE_TMUX:$PATH" FWF_PROFILE=example bash -c "source '$DD85'; roles_json '$FI_OFF'")"
assert_eq "impl1 renders down on a real crash (no floor-down logged)" "down" \
  "$(printf '%s' "$R85_CRASH" | jq -r '.[] | select(.role=="impl1") | .state')"
case "$(printf '%s' "$R85_CRASH" | jq -c '[.[] | .state] | unique')" in
  *floor_idle*) bad "crash fixture must never show floor_idle";;
  *) ok "crash fixture never shows floor_idle";;
esac
# top-level floor_idle_json passes through active/since/reason/actor untouched
F85TOPRUN="$TMP/run85top"; mkdir -p "$F85TOPRUN/state/example"
printf '2026-01-01T00:00:00Z\t0\tfloor-down\thuman\tmanual test\n' > "$F85TOPRUN/state/example/floor-events.log"
F85TOP="$(FWF_RUN_DIR="$F85TOPRUN" FWF_PROFILE=example bash -c "source '$DD85'; floor_idle_json")"
assert_eq "floor_idle_json.active" "true"  "$(printf '%s' "$F85TOP" | jq -r '.active')"
assert_eq "floor_idle_json.actor"  "human" "$(printf '%s' "$F85TOP" | jq -r '.actor')"
assert_eq "floor_idle_json.reason" "manual test" "$(printf '%s' "$F85TOP" | jq -r '.reason')"

section "fwf_write_pane_env: malformed FWF_PANE_ENV entries are skipped, not sourced (issue #181 review)"
# The written file is SOURCED by every pane (fwf_claude_cmd) — a name that
# only passes a first-char check (the original bug) would let an embedded
# command substitution execute during that source. Validate the WHOLE name.
PE_RUN="$TMP/paneenv-inject"; mkdir -p "$PE_RUN"
PE_MARKER="$TMP/paneenv-pwned-$$"
rm -f "$PE_MARKER"
GOOD_VAR=plain_value
env GOOD_VAR="$GOOD_VAR" FWF_RUN_DIR="$PE_RUN" FWF_PROFILE=example \
  FWF_PANE_ENV="GOOD_VAR,FOO\$(touch $PE_MARKER)BAR,;rm -rf /tmp,9BADSTART" \
  bash -c "source '$ROOT/lib.sh'; fwf_write_pane_env"
PE_FILE="$PE_RUN/state/example/pane-env.sh"
[ -f "$PE_FILE" ] || bad "pane-env file written even with a mixed good/malformed list"
assert_contains "well-formed var still written" "$(cat "$PE_FILE" 2>/dev/null)" "export GOOD_VAR=plain_value"
assert_not_contains "command-substitution name not written" "$(cat "$PE_FILE" 2>/dev/null)" 'FOO$('
assert_not_contains "semicolon-leading name not written" "$(cat "$PE_FILE" 2>/dev/null)" 'rm -rf'
assert_not_contains "digit-leading name not written" "$(cat "$PE_FILE" 2>/dev/null)" '9BADSTART'
# The real end-to-end proof: actually SOURCE the written file, the same way
# every pane does, and confirm the injection never fires.
bash -c "source '$PE_FILE'" >/dev/null 2>&1
if [ -e "$PE_MARKER" ]; then bad "sourcing the file never executes an injected command"; else ok "sourcing the file never executes an injected command"; fi
rm -f "$PE_MARKER"

if command -v tmux >/dev/null 2>&1; then
  section "floor-lifecycle wiring (issue #85): fwf-up.sh / fwf-respawn.sh append floor-up on success (real tmux, stubbed claude)"
  # A fast, non-shell "claude" stand-in: tmux reports its pane_current_command
  # as soon as the shell execs it, so fwf_ensure_claude's shell-vs-not-shell
  # poll resolves on its first ~1s tick instead of the real 15s×5 retry budget
  # (there being no real `claude` to ever take over the pane).
  F85CLAUDE="$TMP/claude85-stub.sh"
  cat > "$F85CLAUDE" <<'EOS'
#!/usr/bin/env bash
exec sleep 300
EOS
  chmod +x "$F85CLAUDE"
  # fwf-up.sh's fwf_install_ghguard reads FWF_REPO's origin remote — needs a
  # REAL git repo (the example profile's placeholder $HOME/your-repo isn't
  # one), or it fails closed under set -e before ever reaching the pane work.
  F85REPO="$TMP/wt85fakerepo"; mkdir -p "$F85REPO"
  git -C "$F85REPO" init -q
  git -C "$F85REPO" remote add origin https://github.com/fake/fake.git

  # --- (b-up-paths) fwf-up.sh --floor-only, around a pre-existing CAPTAIN ----
  F85AWT="$TMP/wt85a"
  mkdir -p "$F85AWT/ex-impl1" "$F85AWT/ex-qa1" "$F85AWT/ex-conductor" "$F85AWT/ex-pm" "$F85AWT/ex-gv" "$F85AWT/ex-captain"
  F85ARUN="$TMP/run85a"; mkdir -p "$F85ARUN/state/example"
  F85ALOG="$F85ARUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85ALOG"
  F85ASESS="fwf-selftest-85a-$$"
  tmux new-session -d -s "${F85ASESS}-coord" -c "$F85AWT/ex-captain"
  tmux set -p -t "${F85ASESS}-coord" @l "CAPTAIN"
  # FWF_SKIP_BOOT_GATE=1: this test asserts floor-EVENT logging, not the boot
  # health-gate — and the stub claude never ticks, so the gate would otherwise
  # wait out a full window per role (then hard-respawn each) before returning.
  # The gate itself is covered in isolation above (fwf_verify_boot_ticks).
  env FWF_PROFILE=example FWF_RUN_DIR="$F85ARUN" FWF_SESSION="$F85ASESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F85AWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --floor-only >/dev/null 2>&1
  assert_contains "fwf-up.sh --floor-only appends floor-up" "$(tail -n1 "$F85ALOG")" "floor-up"
  tmux kill-session -t "${F85ASESS}-coord" 2>/dev/null
  tmux kill-session -t "${F85ASESS}-build" 2>/dev/null

  # --- a full `fwf up` (GV explicitly called this out) — neither session ----
  # exists yet, so this exercises the FULL (non-floor-only) launch path.
  F85BWT="$TMP/wt85b"
  mkdir -p "$F85BWT/ex-impl1" "$F85BWT/ex-qa1" "$F85BWT/ex-conductor" "$F85BWT/ex-pm" "$F85BWT/ex-gv" "$F85BWT/ex-captain"
  F85BRUN="$TMP/run85b"; mkdir -p "$F85BRUN/state/example"
  F85BLOG="$F85BRUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85BLOG"
  F85BSESS="fwf-selftest-85b-$$"
  env FWF_PROFILE=example FWF_RUN_DIR="$F85BRUN" FWF_SESSION="$F85BSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F85BWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" >/dev/null 2>&1
  # #185: the floor-up append lands asynchronously relative to fwf-up.sh
  # returning, so a single fixed-time tail -n1 right after can flake by
  # sampling before it lands. Bounded poll for presence instead.
  assert_log_eventually_contains "a full 'fwf up' appends floor-up" "$F85BLOG" "floor-up"
  tmux kill-session -t "${F85BSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F85BSESS}-build" 2>/dev/null

  # --- (issue #155) fwf-up.sh --coord-only: bring up coordination alone -----
  # (a) from a fully cold state: creates coord (PM+GV+CAPTAIN), no build floor.
  F155AWT="$TMP/wt155a"; mkdir -p "$F155AWT/ex-pm" "$F155AWT/ex-gv" "$F155AWT/ex-captain"
  F155ARUN="$TMP/run155a"; mkdir -p "$F155ARUN/state/example"
  F155ALOG="$F155ARUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F155ALOG"
  F155ASESS="fwf-selftest-155a-$$"
  env FWF_PROFILE=example FWF_RUN_DIR="$F155ARUN" FWF_SESSION="$F155ASESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F155AWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --coord-only >/dev/null 2>&1
  assert_eq "--coord-only from cold: exits 0" "0" "$?"
  if tmux has-session -t "${F155ASESS}-coord" 2>/dev/null; then ok "--coord-only from cold: coord session created"; else bad "--coord-only from cold: coord session created"; fi
  if tmux has-session -t "${F155ASESS}-build" 2>/dev/null; then bad "--coord-only from cold: no build session created"; else ok "--coord-only from cold: no build session created"; fi
  assert_contains "--coord-only from cold: appends floor-up (pm plane)" "$(tail -n1 "$F155ALOG")" "floor-up"
  tmux kill-session -t "${F155ASESS}-coord" 2>/dev/null
  tmux kill-session -t "${F155ASESS}-build" 2>/dev/null

  # (b) coord already up: a clean no-op, not an error — pane count unchanged,
  # no build session created either.
  F155BWT="$TMP/wt155b"; mkdir -p "$F155BWT/ex-captain"
  F155BRUN="$TMP/run155b"; mkdir -p "$F155BRUN/state/example"
  F155BSESS="fwf-selftest-155b-$$"
  tmux new-session -d -s "${F155BSESS}-coord" -c "$F155BWT/ex-captain"
  tmux set -p -t "${F155BSESS}-coord" @l "CAPTAIN"
  PANES155B_BEFORE="$(tmux list-panes -t "${F155BSESS}-coord" | wc -l)"
  F155BOUT="$TMP/f155bout.txt"
  env FWF_PROFILE=example FWF_RUN_DIR="$F155BRUN" FWF_SESSION="$F155BSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F155BWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --coord-only >"$F155BOUT" 2>&1
  assert_eq "--coord-only on an already-up coord: exits 0 (no-op, not an error)" "0" "$?"
  assert_contains "--coord-only on an already-up coord: says nothing to do" "$(cat "$F155BOUT")" "already up"
  PANES155B_AFTER="$(tmux list-panes -t "${F155BSESS}-coord" | wc -l)"
  assert_eq "--coord-only no-op: coord pane count unchanged" "$PANES155B_BEFORE" "$PANES155B_AFTER"
  if tmux has-session -t "${F155BSESS}-build" 2>/dev/null; then bad "--coord-only no-op: no build session created"; else ok "--coord-only no-op: no build session created"; fi
  tmux kill-session -t "${F155BSESS}-coord" 2>/dev/null

  # (qa2 adversarial, issue #155): every OTHER up-path confirms its plane up
  # and clears any logged IDLE even on a no-op (see fwf-up.sh's own comment
  # at _fwf_log_plane_up_events — "even when nothing new gets created below,
  # since an up-path was still invoked for that plane and confirms it up").
  # --coord-only's already-up branch exits at the top, before that call is
  # ever reached — so unlike --build-only/--pm-only's already-up no-op, it
  # should NOT silently leave a stale pm-plane IDLE marker behind.
  F155DWT="$TMP/wt155d"; mkdir -p "$F155DWT/ex-captain"
  F155DRUN="$TMP/run155d"; mkdir -p "$F155DRUN/state/example"
  F155DLOG="$F155DRUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\tpm\n' > "$F155DLOG"
  F155DSESS="fwf-selftest-155d-$$"
  tmux new-session -d -s "${F155DSESS}-coord" -c "$F155DWT/ex-captain"
  tmux set -p -t "${F155DSESS}-coord" @l "CAPTAIN"
  env FWF_PROFILE=example FWF_RUN_DIR="$F155DRUN" FWF_SESSION="$F155DSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F155DWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --coord-only >/dev/null 2>&1
  F155DIDLE="$(env FWF_PROFILE=example FWF_RUN_DIR="$F155DRUN" bash -c "source '$ROOT/lib.sh'; fwf_plane_idle_state pm" | cut -f1)"
  assert_eq "--coord-only no-op on an already-up coord still clears a stale pm-plane IDLE (matches --build-only/--pm-only's no-op)" "false" "$F155DIDLE"
  tmux kill-session -t "${F155DSESS}-coord" 2>/dev/null

  # (c) SYMMETRIC RECOVERY (acceptance criterion): build floor already UP,
  # coord DOWN -> --coord-only brings up coord alongside it WITHOUT disrupting
  # the running floor (the mirror of --build-only-alongside-coord).
  F155CWT="$TMP/wt155c"; mkdir -p "$F155CWT/ex-impl1" "$F155CWT/ex-pm" "$F155CWT/ex-gv" "$F155CWT/ex-captain"
  F155CRUN="$TMP/run155c"; mkdir -p "$F155CRUN/state/example"
  F155CSESS="fwf-selftest-155c-$$"
  tmux new-session -d -s "${F155CSESS}-build" -c "$F155CWT/ex-impl1"
  tmux set -p -t "${F155CSESS}-build" @l "IMPL1"
  BUILD155C_BEFORE="$(tmux list-panes -t "${F155CSESS}-build" | wc -l)"
  F155COUT="$TMP/f155cout.txt"
  env FWF_PROFILE=example FWF_RUN_DIR="$F155CRUN" FWF_SESSION="$F155CSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F155CWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --coord-only >"$F155COUT" 2>&1
  assert_eq "--coord-only symmetric recovery (floor up, coord down): exits 0" "0" "$?"
  if tmux has-session -t "${F155CSESS}-coord" 2>/dev/null; then ok "--coord-only symmetric recovery: coord session created"; else bad "--coord-only symmetric recovery: coord session created"; fi
  BUILD155C_AFTER="$(tmux list-panes -t "${F155CSESS}-build" | wc -l)"
  assert_eq "--coord-only symmetric recovery: running build floor left untouched (pane count)" "$BUILD155C_BEFORE" "$BUILD155C_AFTER"
  tmux kill-session -t "${F155CSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F155CSESS}-build" 2>/dev/null

  # --- a floor-role fwf-respawn.sh (pm) -- captain is excluded (never torn ---
  # down by --floor-only, so respawning it is not an "IDLE cleared" signal).
  F85CWT="$TMP/wt85c"; mkdir -p "$F85CWT/ex-captain" "$F85CWT/ex-pm"
  F85CRUN="$TMP/run85c"; mkdir -p "$F85CRUN/state/example"
  F85CLOG="$F85CRUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85CLOG"
  F85CSESS="fwf-selftest-85c-$$"
  tmux new-session -d -s "${F85CSESS}-coord" -c "$F85CWT/ex-captain"
  tmux set -p -t "${F85CSESS}-coord" @l "CAPTAIN"
  # issue #116: the stub claude never ticks, so fwf-respawn.sh's post-arm
  # verify legitimately runs out its full window before returning — override
  # the interval/margin/poll to keep that window (and this test) fast instead
  # of waiting out the real ~5m30s PM default.
  env FWF_PROFILE=example FWF_RUN_DIR="$F85CRUN" FWF_SESSION="$F85CSESS" \
      FWF_WT_BASE="$F85CWT" FWF_CLAUDE_CMD="$F85CLAUDE" \
      FWF_PM_INTERVAL=1s FWF_RESPAWN_VERIFY_MARGIN=1 FWF_HEARTBEAT_POLL_SECS=1 \
      "$ROOT/fwf-respawn.sh" pm >/dev/null 2>&1
  assert_contains "fwf-respawn.sh of a floor role (pm) appends floor-up" "$(tail -n1 "$F85CLOG")" "floor-up"
  # respawning the CAPTAIN itself must NOT append floor-up — it was never the
  # thing --floor-only tore down, so its respawn says nothing about the floor.
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85CLOG"
  env FWF_PROFILE=example FWF_RUN_DIR="$F85CRUN" FWF_SESSION="$F85CSESS" \
      FWF_WT_BASE="$F85CWT" FWF_CLAUDE_CMD="$F85CLAUDE" \
      FWF_CAPTAIN_INTERVAL=1s FWF_RESPAWN_VERIFY_MARGIN=1 FWF_HEARTBEAT_POLL_SECS=1 \
      "$ROOT/fwf-respawn.sh" captain >/dev/null 2>&1
  case "$(tail -n1 "$F85CLOG")" in
    *floor-up*) bad "respawning the captain must not clear floor_idle";;
    *) ok "respawning the captain must not clear floor_idle";;
  esac
  tmux kill-session -t "${F85CSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F85CSESS}-build" 2>/dev/null

  # --- issue #116: fwf-respawn.sh must not crash on a unit-suffixed interval -
  # ("3m"/"2m"/etc — the real default shape of every *_INTERVAL) when computing
  # its post-arm verify window. Uses a fast interval + margin so the (expected,
  # legitimate) never-ticks timeout resolves in a couple seconds instead of
  # fwf-respawn.sh's real ~minutes-long window.
  F116WT="$TMP/wt116"; mkdir -p "$F116WT/ex-captain" "$F116WT/ex-pm"
  F116RUN="$TMP/run116"; mkdir -p "$F116RUN/state/example"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' \
    > "$F116RUN/state/example/floor-events.log"
  F116SESS="fwf-selftest-116-$$"
  tmux new-session -d -s "${F116SESS}-coord" -c "$F116WT/ex-captain"
  tmux set -p -t "${F116SESS}-coord" @l "CAPTAIN"
  F116OUT="$TMP/f116out.txt"
  env FWF_PROFILE=example FWF_RUN_DIR="$F116RUN" FWF_SESSION="$F116SESS" \
      FWF_WT_BASE="$F116WT" FWF_CLAUDE_CMD="$F85CLAUDE" \
      FWF_PM_INTERVAL=1s FWF_RESPAWN_VERIFY_MARGIN=1 FWF_HEARTBEAT_POLL_SECS=1 \
      "$ROOT/fwf-respawn.sh" pm >"$F116OUT" 2>&1
  case "$(cat "$F116OUT")" in
    *"value too great for base"*) bad "#116: unit-suffixed interval must not crash the verify-window arithmetic";;
    *"unbound variable"*)         bad "#116: unit-suffixed interval must not leave \$window unbound";;
    *) ok "#116: unit-suffixed interval (3m-shaped) no longer crashes fwf-respawn.sh's arithmetic";;
  esac
  # the stub claude never touches a heartbeat, so verification legitimately
  # times out — proving the run got PAST the arithmetic into the real check.
  assert_contains "#116: past the arithmetic, reaches the real (legitimate) tick-timeout path" \
    "$(cat "$F116OUT")" "did NOT tick"
  tmux kill-session -t "${F116SESS}-coord" 2>/dev/null
  tmux kill-session -t "${F116SESS}-build" 2>/dev/null

  section "fwf up on a never-provisioned profile fails loud, never launches into \$HOME (issue #142)"
  # WT_BASE exists but is EMPTY — no worktrees at all, exactly the
  # never-provisioned state (fwf up run instead of fwf start/provision).
  F142WT="$TMP/wt142-empty"; mkdir -p "$F142WT"
  F142RUN="$TMP/run142"; mkdir -p "$F142RUN"
  F142SESS="fwf-selftest-142-$$"
  F142OUT="$TMP/f142out.txt"
  env FWF_PROFILE=example FWF_RUN_DIR="$F142RUN" FWF_SESSION="$F142SESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F142WT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" >"$F142OUT" 2>&1
  F142RC=$?
  assert_eq "fwf up on an unprovisioned profile exits nonzero" "1" "$F142RC"
  assert_contains "error names the missing worktrees" "$(cat "$F142OUT")" "no worktrees for profile"
  assert_contains "error points at the fix" "$(cat "$F142OUT")" "fwf provision"
  if tmux has-session -t "${F142SESS}-build" 2>/dev/null; then bad "no build session created"; else ok "no build session created"; fi
  if tmux has-session -t "${F142SESS}-coord" 2>/dev/null; then bad "no coord session created"; else ok "no coord session created"; fi
  tmux kill-session -t "${F142SESS}-coord" 2>/dev/null
  tmux kill-session -t "${F142SESS}-build" 2>/dev/null

  # Regression: --floor-only around a live captain, where only PM/GV already
  # have worktrees (captain's is created for the tmux anchor) but impl/qa
  # don't — the build-plane preflight must still catch it even though the
  # coord session is already up and untouched by this run.
  F142BWT="$TMP/wt142-partial"; mkdir -p "$F142BWT/ex-captain" "$F142BWT/ex-pm" "$F142BWT/ex-gv"
  F142BSESS="fwf-selftest-142b-$$"
  tmux new-session -d -s "${F142BSESS}-coord" -c "$F142BWT/ex-captain"
  tmux set -p -t "${F142BSESS}-coord" @l "CAPTAIN"
  F142BOUT="$TMP/f142bout.txt"
  env FWF_PROFILE=example FWF_RUN_DIR="$F142RUN" FWF_SESSION="$F142BSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F142BWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" --floor-only >"$F142BOUT" 2>&1
  assert_eq "--floor-only on missing impl/qa worktrees also fails loud" "1" "$?"
  assert_contains "--floor-only error names impl1" "$(cat "$F142BOUT")" "impl1"
  if tmux has-session -t "${F142BSESS}-build" 2>/dev/null; then bad "--floor-only: no build session created"; else ok "--floor-only: no build session created"; fi
  tmux kill-session -t "${F142BSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F142BSESS}-build" 2>/dev/null

  section "agent panes reliably get FWF_PANE_ENV-forwarded vars, even on a pre-existing tmux server (issue #143)"
  # The whole point of the bug: a NEW pane inherits the tmux SERVER's env from
  # whenever the server itself first started, not the shell that just ran
  # `fwf up` — so this uses the shared default-socket server (already running
  # on this box from earlier tests, i.e. genuinely pre-existing), never a
  # freshly-started one, or the test would pass by accident.
  F143WT="$TMP/wt143"; mkdir -p "$F143WT/ex-impl1" "$F143WT/ex-qa1" "$F143WT/ex-conductor" "$F143WT/ex-pm" "$F143WT/ex-gv" "$F143WT/ex-captain"
  F143RUN="$TMP/run143"; mkdir -p "$F143RUN/state/example"
  F143SESS="fwf-selftest-143-$$"
  F143_SECRET="shh-$$-$(date +%N 2>/dev/null || echo x)"; export F143_SECRET   # a value the ambient server never saw
  env FWF_PROFILE=example FWF_RUN_DIR="$F143RUN" FWF_SESSION="$F143SESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F143WT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 FWF_PANE_ENV=F143_SECRET \
      "$ROOT/fwf-up.sh" >/dev/null 2>&1
  IMPL1_PANE="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_find_pane '${F143SESS}-build' 'IMPL1 ·'" 2>/dev/null || true)"
  # pane_pid is the pane's ORIGINAL shell — `ps eww` on macOS/Linux reflects
  # a process's environ as captured at ITS OWN exec() time, never live-updated
  # by that shell's own later `export`, so the sourced var only shows up on
  # the CHILD it forks (the claude stub) — walk to that child.
  SHELL_PID="$([ -n "$IMPL1_PANE" ] && tmux display -p -t "$IMPL1_PANE" '#{pane_pid}' 2>/dev/null || true)"
  IMPL1_PID="$([ -n "$SHELL_PID" ] && pgrep -P "$SHELL_PID" 2>/dev/null | head -1 || true)"
  if [ -n "$IMPL1_PID" ]; then
    assert_contains "FWF_PANE_ENV var reaches the pane's actual process env" \
      "$(ps eww "$IMPL1_PID" 2>/dev/null)" "F143_SECRET=$F143_SECRET"
  else
    bad "FWF_PANE_ENV var reaches the pane's actual process env" "could not find impl1 pane pid"
  fi
  assert_eq "pane-env file is chmod 600" "600" \
    "$(stat -c '%a' "$F143RUN/state/example/pane-env.sh" 2>/dev/null || stat -f '%Lp' "$F143RUN/state/example/pane-env.sh" 2>/dev/null)"
  tmux kill-session -t "${F143SESS}-coord" 2>/dev/null
  tmux kill-session -t "${F143SESS}-build" 2>/dev/null

  # Regression: without FWF_PANE_ENV set, no pane-env file, no source prefix —
  # existing behavior (and existing tests above) must be untouched.
  F143BWT="$TMP/wt143b"; mkdir -p "$F143BWT/ex-impl1" "$F143BWT/ex-qa1" "$F143BWT/ex-conductor" "$F143BWT/ex-pm" "$F143BWT/ex-gv" "$F143BWT/ex-captain"
  F143BRUN="$TMP/run143b"; mkdir -p "$F143BRUN/state/example"
  F143BSESS="fwf-selftest-143b-$$"
  env FWF_PROFILE=example FWF_RUN_DIR="$F143BRUN" FWF_SESSION="$F143BSESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F143BWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
      FWF_SKIP_BOOT_GATE=1 \
      "$ROOT/fwf-up.sh" >/dev/null 2>&1
  if [ -e "$F143BRUN/state/example/pane-env.sh" ]; then bad "no pane-env file when FWF_PANE_ENV unset"; else ok "no pane-env file when FWF_PANE_ENV unset"; fi
  tmux kill-session -t "${F143BSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F143BSESS}-build" 2>/dev/null
  unset F143_SECRET
else
  printf '  skip real-tmux floor-lifecycle wiring tests (tmux not installed)\n'
fi

section "floor-down cooldown guard (issue #88, per-plane by #105): fwf_plane_last_up_epoch / fwf_plane_cooldown_remaining"
# Pure file I/O (lib.sh) — no tmux needed for the read-only cooldown math.
F88RUN="$TMP/run88lib"; mkdir -p "$F88RUN/state/example"
F88ENV="FWF_RUN_DIR=$F88RUN FWF_PROFILE=example"
F88LIBLOG="$F88RUN/state/example/floor-events.log"
# no log at all -> no prior up on record -> cooldown never blocks
assert_eq "no log -> no last-up epoch (build)" "" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_last_up_epoch build")"
assert_eq "no log -> cooldown remaining 0 (build)" "0" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
assert_eq "no log -> cooldown remaining 0 (pm)" "0" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining pm")"
# a log that has only ever seen floor-down (never a floor-up) -> still unguarded
printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tfirst ever down\n' > "$F88LIBLOG"
assert_eq "floor-down-only log -> no last-up epoch" "" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_last_up_epoch build")"
assert_eq "floor-down-only log -> cooldown remaining 0" "0" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
# a recent floor-up -> remaining cooldown is positive and bounded by FWF_BUILD_COOLDOWN
NOW="$(date +%s)"
printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$NOW" > "$F88LIBLOG"
REM="$(env $F88ENV FWF_BUILD_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
case "$REM" in ''|*[!0-9]*) bad "recent floor-up -> remaining is numeric" "$REM";; *) ok "recent floor-up -> remaining is numeric";; esac
[ "$REM" -gt 0 ] && [ "$REM" -le 100 ] && ok "recent floor-up -> 0 < remaining <= cooldown" || bad "recent floor-up -> 0 < remaining <= cooldown" "$REM"
# FWF_FLOOR_COOLDOWN (legacy) still works, aliased into FWF_BUILD_COOLDOWN
REM_LEGACY="$(env $F88ENV FWF_FLOOR_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
[ "$REM_LEGACY" -gt 0 ] && [ "$REM_LEGACY" -le 100 ] && ok "legacy FWF_FLOOR_COOLDOWN still bounds the build plane's cooldown" \
  || bad "legacy FWF_FLOOR_COOLDOWN still bounds the build plane's cooldown" "$REM_LEGACY"
# the pm plane is a SEPARATE cooldown, unaffected by a build-plane floor-up
assert_eq "pm plane cooldown independent of build's recent floor-up" "0" \
  "$(env $F88ENV FWF_BUILD_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining pm")"
printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tpm\n' "$NOW" >> "$F88LIBLOG"
REM_PM="$(env $F88ENV FWF_PM_COOLDOWN=50 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining pm")"
[ "$REM_PM" -gt 0 ] && [ "$REM_PM" -le 50 ] && ok "pm plane's own recent floor-up bounds ITS cooldown via FWF_PM_COOLDOWN" \
  || bad "pm plane's own recent floor-up bounds ITS cooldown via FWF_PM_COOLDOWN" "$REM_PM"
# an old floor-up (past the cooldown window) -> remaining is 0
OLD=$(( NOW - 1000 ))
printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$OLD" > "$F88LIBLOG"
assert_eq "elapsed floor-up -> cooldown remaining 0" "0" "$(env $F88ENV FWF_BUILD_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
# the LAST floor-up wins, not the first, when there are several in the log
{
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$OLD"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-down\tcaptain\tr\n' "$OLD"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$NOW"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-down\tcaptain\tr2\n' "$NOW"
} > "$F88LIBLOG"
REM2="$(env $F88ENV FWF_BUILD_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining build")"
[ "$REM2" -gt 0 ] && [ "$REM2" -le 100 ] && ok "cooldown keys off the LAST floor-up, not the first" || bad "cooldown keys off the LAST floor-up, not the first" "$REM2"
assert_eq "fwf_plane_cooldown_remaining rejects an unknown plane" "1" \
  "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_plane_cooldown_remaining bogus >/dev/null 2>&1; echo \$?")"
# bogus FWF_FLOOR_COOLDOWN / FWF_BUILD_COOLDOWN / FWF_PM_COOLDOWN are all
# rejected at source time, same style as FWF_PAIRS
env $F88ENV FWF_FLOOR_COOLDOWN=banana bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_FLOOR_COOLDOWN=banana rejected" || ok "FWF_FLOOR_COOLDOWN=banana rejected"
env $F88ENV FWF_BUILD_COOLDOWN=banana bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_BUILD_COOLDOWN=banana rejected" || ok "FWF_BUILD_COOLDOWN=banana rejected"
env $F88ENV FWF_PM_COOLDOWN=banana bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_PM_COOLDOWN=banana rejected" || ok "FWF_PM_COOLDOWN=banana rejected"

section "captain.tmpl (issue #88, per-plane by #105): dwell + deterministic cooldown are both stated"
CAPRENDER="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path captain)\" ''")"
assert_contains "captain prompt mentions the dwell" "$CAPRENDER" "dwell"
assert_contains "captain prompt names FWF_BUILD_COOLDOWN" "$CAPRENDER" "FWF_BUILD_COOLDOWN"
assert_contains "captain prompt names FWF_PM_COOLDOWN" "$CAPRENDER" "FWF_PM_COOLDOWN"
assert_contains "captain prompt calls the cooldown deterministic" "$CAPRENDER" "DETERMINISTIC"
assert_contains "captain prompt mentions --force" "$CAPRENDER" "--force"
assert_contains "captain prompt mentions --build-only" "$CAPRENDER" "--build-only"
assert_contains "captain prompt mentions --pm-only" "$CAPRENDER" "--pm-only"
assert_contains "captain prompt states GV never idles" "$CAPRENDER" "GV never idles"
assert_contains "captain prompt names the deadlock guard" "$CAPRENDER" "DEADLOCK GUARD"

if command -v tmux >/dev/null 2>&1; then
  section "fwf-down.sh cooldown guards (issue #88, per-plane by #105): real tmux"
  # Fixture for the #105 DEADLOCK guards to resolve "safe" (0 open PRs,
  # staging == integration, 0 open product-wip issues) so THIS section's
  # tests exercise ONLY the cooldown guard, not the deadlock guard (that gets
  # its own dedicated section below).
  # Configurable via F88_PR_COUNT / F88_WIP_COUNT (default 0 == "safe"), so
  # the SAME stub serves both this section (always safe) and the dedicated
  # deadlock-guard section below (which drives each count deliberately).
  F88GHSTUB="$TMP/gh88stub"; mkdir -p "$F88GHSTUB"
  cat > "$F88GHSTUB/gh" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") echo "${F88_PR_COUNT:-0}";;
  "issue list") echo "${F88_WIP_COUNT:-0}";;
  *) echo 0;;
esac
EOS
  chmod +x "$F88GHSTUB/gh"
  F88ORIGIN="$TMP/origin88.git"; git init -q --bare "$F88ORIGIN"
  F88REPO="$TMP/repo88"
  git clone -q "$F88ORIGIN" "$F88REPO" 2>/dev/null
  ( cd "$F88REPO" && git config user.email t@t.co && git config user.name t \
    && echo hi > f && git add -A && git commit -qm init \
    && git branch -M main && git push -q origin main \
    && git branch staging && git push -q origin staging \
    && git branch integration && git push -q origin integration )

  F88TRUN="$TMP/run88tmux"; mkdir -p "$F88TRUN/state/example"
  F88TLOG="$F88TRUN/state/example/floor-events.log"
  F88SESS="fwf-selftest-88-$$"
  F88ENVT="FWF_PROFILE=example FWF_RUN_DIR=$F88TRUN FWF_SESSION=$F88SESS FWF_BUILD_COOLDOWN=300 FWF_PM_COOLDOWN=300 FWF_REPO=$F88REPO PATH=$F88GHSTUB:$PATH"

  # --- BUILD-ONLY: refused within cooldown; sessions/panes stay up -----------
  tmux new-session -d -s "${F88SESS}-coord" -c "$TMP"
  tmux set -p -t "${F88SESS}-coord" @l "CAPTAIN"
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  RECENT_UP="$(date +%s)"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tbuild\n' "$RECENT_UP" > "$F88TLOG"
  REFUSED="$(env $F88ENVT "$ROOT/fwf-down.sh" --build-only 2>&1)" && bad "cooldown refuses too-soon build-only down" || ok "cooldown refuses too-soon build-only down"
  assert_contains "refusal names the remaining cooldown" "$REFUSED" "remaining"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && ok "build session stays up when refused" || bad "build session stays up when refused"
  tmux has-session -t "${F88SESS}-coord" 2>/dev/null && ok "coord session stays up when refused" || bad "coord session stays up when refused"
  assert_contains "log unchanged (no floor-down appended) when refused" "$(tail -n1 "$F88TLOG")" "floor-up"

  # --- --force overrides the cooldown (but not the deadlock guard) -----------
  env $F88ENVT "$ROOT/fwf-down.sh" --build-only --force >/dev/null 2>&1 && ok "--force overrides cooldown" || bad "--force overrides cooldown"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "--force actually tears down the build session" || ok "--force actually tears down the build session"
  assert_contains "--force still logs floor-down" "$(tail -n1 "$F88TLOG")" "floor-down"

  # --- cooldown elapsed -> tears down normally without --force ----------------
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  OLD_UP=$(( $(date +%s) - 1000 ))
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tbuild\n' "$OLD_UP" > "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --build-only >/dev/null 2>&1 && ok "elapsed cooldown allows build-only down" || bad "elapsed cooldown allows build-only down"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "elapsed-cooldown down actually tears down" || ok "elapsed-cooldown down actually tears down"

  # --- no prior floor-up on record (first-ever down) -> allowed ---------------
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  rm -f "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --build-only >/dev/null 2>&1 && ok "no prior floor-up on record allows down" || bad "no prior floor-up on record allows down"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "no-record down actually tears down" || ok "no-record down actually tears down"

  # --- PM-ONLY: its own independent cooldown (FWF_PM_COOLDOWN), pane-based ---
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"   # recreate for isolation from prior asserts
  tmux split-window -h -t "${F88SESS}-coord" -c "$TMP"
  tmux set -p -t "$(tmux list-panes -t "${F88SESS}-coord" -F '#{pane_id}' | tail -1)" @l "PM · refine loop"
  PMPANE_COUNT_BEFORE="$(tmux list-panes -t "${F88SESS}-coord" | wc -l | tr -d ' ')"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tpm\n' "$RECENT_UP" > "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --pm-only >/dev/null 2>&1 && bad "cooldown refuses too-soon pm-only down" || ok "cooldown refuses too-soon pm-only down"
  PMPANE_COUNT_AFTER="$(tmux list-panes -t "${F88SESS}-coord" | wc -l | tr -d ' ')"
  assert_eq "PM pane survives a refused pm-only down" "$PMPANE_COUNT_BEFORE" "$PMPANE_COUNT_AFTER"
  # build's cooldown is INDEPENDENT of pm's — a fresh pm floor-up must not
  # block a build-only down whose OWN cooldown has elapsed.
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tbuild\n' "$OLD_UP" >> "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --build-only >/dev/null 2>&1 && ok "build-only unaffected by pm's independent (still-fresh) cooldown" \
    || bad "build-only unaffected by pm's independent (still-fresh) cooldown"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "build-only tore down despite pm's fresh cooldown" || ok "build-only tore down despite pm's fresh cooldown"
  # elapsed pm cooldown -> pm-only allowed, tears down the PM pane
  OLD_PM=$(( $(date +%s) - 1000 ))
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tpm\n' "$OLD_PM" >> "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --pm-only >/dev/null 2>&1 && ok "elapsed pm cooldown allows pm-only down" || bad "elapsed pm cooldown allows pm-only down"
  PMPANE_COUNT_FINAL="$(tmux list-panes -t "${F88SESS}-coord" | wc -l | tr -d ' ')"
  [ "$PMPANE_COUNT_FINAL" -lt "$PMPANE_COUNT_BEFORE" ] && ok "pm-only actually tears down the PM pane" || bad "pm-only actually tears down the PM pane" "$PMPANE_COUNT_FINAL vs $PMPANE_COUNT_BEFORE"
  tmux has-session -t "${F88SESS}-coord" 2>/dev/null && ok "coord SESSION (captain) survives a pm-only down" || bad "coord SESSION (captain) survives a pm-only down"

  # --- --floor-only refuses as ONE ATOMIC unit if EITHER sub-cooldown blocks -
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"   # recreate build for this scenario
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tbuild\n' "$RECENT_UP" > "$F88TLOG"   # build fresh (blocks)
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tpm\n' "$OLD_PM" >> "$F88TLOG"        # pm elapsed (would allow)
  env $F88ENVT "$ROOT/fwf-down.sh" --floor-only >/dev/null 2>&1 && bad "floor-only refused when ONLY build's cooldown is fresh" || ok "floor-only refused when ONLY build's cooldown is fresh"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && ok "build session untouched by the refused --floor-only" || bad "build session untouched by the refused --floor-only"

  # --- DEADLOCK GUARDS (issue #105 acceptance criterion 1) — --force lifts
  # the COOLDOWN but must NEVER lift these; every scenario below has an
  # elapsed cooldown so the guard under test is isolated from #88's.
  section "fwf-down.sh deadlock guards (issue #105 acceptance criterion 1): real tmux"
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tbuild\n' "$OLD_UP" > "$F88TLOG"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\tpm\n' "$OLD_PM" >> "$F88TLOG"

  # (1a) build-only refused while an open PR exists — --force does NOT override
  BDOUT="$(env $F88ENVT F88_PR_COUNT=2 "$ROOT/fwf-down.sh" --build-only --force 2>&1)" && bad "build-only refused while a PR is open" || ok "build-only refused while a PR is open"
  assert_contains "refusal names the open PR(s)" "$BDOUT" "open PR"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && ok "build session untouched (deadlock refusal survives --force)" || bad "build session untouched (deadlock refusal survives --force)"

  # (1a-cont) build-only refused while staging is ahead of integration (mid-promotion)
  ( cd "$F88REPO" && git fetch -q origin && git checkout -q staging && echo more >> f && git commit -qam more && git push -q origin staging ) >/dev/null 2>&1
  BDOUT2="$(env $F88ENVT F88_PR_COUNT=0 "$ROOT/fwf-down.sh" --build-only --force 2>&1)" && bad "build-only refused mid-promotion (staging ahead of integration)" || ok "build-only refused mid-promotion (staging ahead of integration)"
  assert_contains "refusal names mid-promotion" "$BDOUT2" "mid-promotion"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && ok "build session untouched (mid-promotion refusal)" || bad "build session untouched (mid-promotion refusal)"
  ( cd "$F88REPO" && git push -q origin staging:integration ) >/dev/null 2>&1   # resync so the next assertion sees a clean repo

  # (1a-safe) once the PR count is 0 and staging==integration, build-only proceeds
  env $F88ENVT F88_PR_COUNT=0 "$ROOT/fwf-down.sh" --build-only --force >/dev/null 2>&1 && ok "build-only proceeds once the deadlock guard is clear" || bad "build-only proceeds once the deadlock guard is clear"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "build session torn down once safe" || ok "build session torn down once safe"

  # (1b) pm-only refused while an open product-wip draft exists — --force does NOT override
  tmux split-window -h -t "${F88SESS}-coord" -c "$TMP"
  tmux set -p -t "$(tmux list-panes -t "${F88SESS}-coord" -F '#{pane_id}' | tail -1)" @l "PM · refine loop"
  PDOUT="$(env $F88ENVT F88_PR_COUNT=0 F88_WIP_COUNT=1 "$ROOT/fwf-down.sh" --pm-only --force 2>&1)" && bad "pm-only refused while a product-wip draft is open" || ok "pm-only refused while a product-wip draft is open"
  assert_contains "refusal names the product-wip draft(s)" "$PDOUT" "product-wip"
  tmux list-panes -t "${F88SESS}-coord" -F '#{@l}' | grep -q "PM" && ok "PM pane untouched (deadlock refusal survives --force)" || bad "PM pane untouched (deadlock refusal survives --force)"

  # (1c) ambiguity (gh query fails outright) -> decline and stay up, never silently idle
  F88BADGH="$TMP/gh88bad"; mkdir -p "$F88BADGH"
  cat > "$F88BADGH/gh" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$F88BADGH/gh"
  ADOUT="$(env FWF_PROFILE=example FWF_RUN_DIR=$F88TRUN FWF_SESSION=$F88SESS FWF_BUILD_COOLDOWN=300 FWF_PM_COOLDOWN=300 FWF_REPO=$F88REPO "PATH=$F88BADGH:$PATH" "$ROOT/fwf-down.sh" --pm-only --force 2>&1)" && bad "ambiguous (gh failure) declines rather than silently idling" || ok "ambiguous (gh failure) declines rather than silently idling"
  assert_contains "ambiguity refusal explains why" "$ADOUT" "assuming blocked"
  tmux list-panes -t "${F88SESS}-coord" -F '#{@l}' | grep -q "PM" && ok "PM pane untouched on ambiguous refusal" || bad "PM pane untouched on ambiguous refusal"

  # --- GV-REACHABLE (constraint 2): no idle path may ever tear down the GV ---
  GVPANE="$(tmux split-window -P -F '#{pane_id}' -h -t "${F88SESS}-coord" -c "$TMP")"
  tmux set -p -t "$GVPANE" @l "GRAND VIZIER"
  env $F88ENVT F88_PR_COUNT=0 F88_WIP_COUNT=0 "$ROOT/fwf-down.sh" --pm-only --force >/dev/null 2>&1
  tmux list-panes -t "${F88SESS}-coord" -F '#{pane_id}' | grep -qx "$GVPANE" && ok "GV pane survives a pm-only teardown" || bad "GV pane survives a pm-only teardown"
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  env $F88ENVT F88_PR_COUNT=0 "$ROOT/fwf-down.sh" --build-only --force >/dev/null 2>&1
  tmux list-panes -t "${F88SESS}-coord" -F '#{pane_id}' | grep -qx "$GVPANE" && ok "GV pane survives a build-only teardown" || bad "GV pane survives a build-only teardown"
  tmux has-session -t "${F88SESS}-coord" 2>/dev/null && ok "coord SESSION (captain+GV) survives every deadlock/idle path above" || bad "coord SESSION (captain+GV) survives every deadlock/idle path above"

  tmux kill-session -t "${F88SESS}-coord" 2>/dev/null
  tmux kill-session -t "${F88SESS}-build" 2>/dev/null
else
  printf '  skip real-tmux floor-down cooldown tests (tmux not installed)\n'
fi

section "disk-pressure guard — refuses below the free-space floor"
# An impossibly high floor must refuse before any tmux work; portable df runs.
GUARDOUT="$(env FWF_PROFILE=example FWF_SESSION=fwf-selftest-$$ FWF_MIN_FREE_GB=999999 "$ROOT/fwf-up.sh" 2>&1)" && bad "guard refuses below floor" || ok "guard refuses below floor"
assert_contains "guard names the shortfall" "$GUARDOUT" "REFUSING to start"
# Floor of 0 disables the guard (it must not be the thing that blocks here).
G0="$(env FWF_PROFILE=example FWF_SESSION=fwf-selftest-$$ FWF_MIN_FREE_GB=0 "$ROOT/fwf-up.sh" --floor-only 2>&1)"
case "$G0" in *"REFUSING to start"*) bad "floor 0 disables guard";; *) ok "floor 0 disables guard";; esac

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
# output style defaults to Concise for every seat (issue #187), is overridable,
# and composes with --model; empty means no --settings flag at all
STYLECMD="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd captain")"
assert_contains "default output style is Concise" "$STYLECMD" '--settings \{\"outputStyle\":\"Concise\"\}'
STYLEOVERRIDE="$(FWF_OUTPUT_STYLE=Explanatory FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd captain")"
assert_contains "FWF_OUTPUT_STYLE override honored" "$STYLEOVERRIDE" '--settings \{\"outputStyle\":\"Explanatory\"\}'
STYLEOFF="$(FWF_OUTPUT_STYLE='' FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd captain")"
case "$STYLEOFF" in *--settings*) bad "FWF_OUTPUT_STYLE=\"\" disables --settings";; *) ok "FWF_OUTPUT_STYLE=\"\" disables --settings";; esac
STYLEWITHMODEL="$(FWF_MODEL_IMPL=sonnet FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd impl1")"
assert_contains "output style composes with --model (model)" "$STYLEWITHMODEL" "--model sonnet"
assert_contains "output style composes with --model (settings)" "$STYLEWITHMODEL" '--settings \{\"outputStyle\":\"Concise\"\}'
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
assert_contains "gh failure hints at clone fetch+merge" "$UPF" "fetch --tags"

# regression (issue #71): a git *worktree* has .git as a FILE (gitdir: …), not
# a dir — and every fwf-self swarm role runs from a worktree.  Build a
# standalone install whose .git is a file.
WT71="$TMP/wt71"; mkdir -p "$WT71/lib"
cp "$ROOT/fwf" "$ROOT/config.sh" "$ROOT/VERSION" "$WT71/"
cp "$ROOT/lib"/*.sh "$WT71/lib/"
printf 'gitdir: /some/repo/.git/worktrees/wt71\n' > "$WT71/.git"

# issue #78: pulling a worktree IN PLACE is unsafe (feature branch / detached
# HEAD / dirty) — a worktree install must be pointed at its main checkout
# instead, never advised (or made) to pull itself. Covers both the offline
# hint (fwf:329) and the online upgrade dispatch (fwf:335). Goes RED on the
# old `[ -e ]`-only offline hint / `[ -d ]`-only dispatch, which both treated
# this worktree as either "plain clone, pull it" or "no .git, tarball over it."
UPWT="$(PATH="$GHSTUB:$PATH" FAKE_GH_FAIL=1 "$WT71/fwf" upgrade --check 2>&1)"
assert_contains "offline+worktree points at the main checkout" "$UPWT" "/some/repo"
case "$UPWT" in
  *"-C $WT71"*) bad "offline+worktree must not advise pulling the worktree itself" ;;
  *)            ok "offline+worktree must not advise pulling the worktree itself" ;;
esac

UPWTONLINE="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v99.0.0" "$WT71/fwf" upgrade 2>&1)" \
  && bad "online worktree upgrade refuses (exit nonzero)" "$UPWTONLINE" \
  || ok "online worktree upgrade refuses (exit nonzero)"
assert_contains "online worktree refusal points at the main checkout" "$UPWTONLINE" "/some/repo"
assert_contains "online worktree refusal names fwf upgrade"           "$UPWTONLINE" "fwf upgrade"

# dangling/unresolvable .git (present, not a dir, not a recognized worktree
# gitdir shape): refuse — never silently fall through to the tarball path,
# which would extract a release right on top of an existing git checkout.
WTDANGLE="$TMP/wtdangle"; mkdir -p "$WTDANGLE/lib"
cp "$ROOT/fwf" "$ROOT/config.sh" "$ROOT/VERSION" "$WTDANGLE/"
cp "$ROOT/lib"/*.sh "$WTDANGLE/lib/"
printf 'not a gitdir line\n' > "$WTDANGLE/.git"
DANGLE="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v99.0.0" "$WTDANGLE/fwf" upgrade 2>&1)" \
  && bad "dangling .git refuses (exit nonzero)" "$DANGLE" \
  || ok "dangling .git refuses (exit nonzero)"
assert_contains "dangling .git refusal does not silently tarball" "$DANGLE" "refusing to guess"
[ -e "$WTDANGLE/fwf-99.0.0" ] && bad "dangling .git must not extract a tarball" || ok "dangling .git must not extract a tarball"

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

# git-clone upgrade must converge on the RELEASE TAG, not whatever the tracked
# branch tip happens to be (#125) — simulate main having moved past the last
# cut release and assert the clone still lands exactly on the release.
section "fwf upgrade — git-clone install converges on the release tag, not unreleased main (#125)"
GCPD="$TMP/gitclone-upgrade"; mkdir -p "$GCPD"
git init -q --bare "$GCPD/origin.git"
tar -C "$GCPD" -xzf "$TARBALL"
mv "$GCPD/fwf-$REALV" "$GCPD/seed"
( cd "$GCPD/seed" && git init -q && git config user.email t@t.co && git config user.name t
  printf '0.0.1\n' > VERSION && git add -A && git commit -qm "v0.0.1" && git tag v0.0.1
  printf '%s\n' "$REALV" > VERSION && git add -A && git commit -qm "v$REALV" && git tag "v$REALV"
  printf '%s-dev\n' "$REALV" > VERSION && git add -A && git commit -qm "unreleased work past the last cut release"
  git remote add origin "$GCPD/origin.git" && git push -q origin HEAD:main && git push -q origin --tags )
git -C "$GCPD/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$GCPD/origin.git" "$GCPD/install" 2>/dev/null
( cd "$GCPD/install" && git checkout -q v0.0.1 && git checkout -q -B main )
assert_eq "git-clone install starts at the old release" "0.0.1" "$(cat "$GCPD/install/VERSION")"
GCUPG="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v$REALV" "$GCPD/install/fwf" upgrade 2>&1)" \
  && ok "git-clone upgrade exits 0" || bad "git-clone upgrade exits 0" "$GCUPG"
assert_eq "git-clone install lands on the release tag, not unreleased main" "$REALV" "$(cat "$GCPD/install/VERSION")"
assert_contains "git-clone upgrade message names convergence" "$GCUPG" "converged on release"
echo dirty >> "$GCPD/install/VERSION"
PATH="$GHSTUB:$PATH" FAKE_LATEST="v$REALV" "$GCPD/install/fwf" upgrade >/dev/null 2>&1 \
  && bad "dirty git-clone install refuses to upgrade" || ok "dirty git-clone install refuses to upgrade"

# QA adversarial check (#125, issue #119 adversarial-artifact-review): a clean
# but truly DIVERGED git-clone install (a committed local change off the
# release lineage, not just an uncommitted dirty tree) must refuse via
# ff-only rather than silently rewriting/discarding local history.
git clone -q "$GCPD/origin.git" "$GCPD/install2" 2>/dev/null
( cd "$GCPD/install2" && git checkout -q v0.0.1 && git checkout -q -B main \
  && git config user.email t@t.co && git config user.name t \
  && printf '0.0.1-local\n' > VERSION && git commit -qam "local-only work, diverges from the release lineage" )
assert_eq "diverged git-clone install starts at its local version" "0.0.1-local" "$(cat "$GCPD/install2/VERSION")"
GCDIVRC=0
GCDIV="$(PATH="$GHSTUB:$PATH" FAKE_LATEST="v$REALV" "$GCPD/install2/fwf" upgrade 2>&1)" || GCDIVRC=$?
[ "$GCDIVRC" -ne 0 ] \
  && ok "diverged git-clone install refuses to upgrade (ff-only, not a silent rewrite)" \
  || bad "diverged git-clone install refuses to upgrade" "$GCDIV"
assert_contains "diverged-refusal message names the divergence" "$GCDIV" "diverged"
assert_eq "diverged install's local VERSION is untouched by the refused upgrade" "0.0.1-local" "$(cat "$GCPD/install2/VERSION")"

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

section "fwf up/provision on a local/remoteless repo (issue #141) — real git fixture, no origin at all"
# Symptom 1: fwf_install_ghguard's origin-remote lookup used to abort the
# WHOLE caller under set -e when there is no origin remote at all (not just
# an unreachable one) — silently, before any pane work ran.
NOREMOTE="$TMP/noremote141"; mkdir -p "$NOREMOTE"
git -C "$NOREMOTE" init -q
git -C "$NOREMOTE" config user.email t@t.co && git -C "$NOREMOTE" config user.name t
NRRUN="$TMP/norun141"
NROUT="$(FWF_RUN_DIR="$NRRUN" FWF_REPO="$NOREMOTE" FWF_ISSUES=local FWF_PROFILE=example \
  bash -c "set -euo pipefail; source '$ROOT/lib.sh'; fwf_install_ghguard; echo GHGUARD-DONE" 2>&1)"
assert_contains "ghguard install completes under set -e with no remote at all (doesn't silently abort)" \
  "$NROUT" "GHGUARD-DONE"
[ -x "$NRRUN/ghguard/gh" ] && ok "guard still installed with no remote" || bad "guard still installed with no remote"

# Symptom 2: fwf-provision.sh's unconditional `git fetch origin` used to abort
# the same way, before even reaching the local-mode branch ladder / worktrees.
NR2="$TMP/noremote141b"; mkdir -p "$NR2"
git -C "$NR2" init -q
git -C "$NR2" config user.email t@t.co && git -C "$NR2" config user.name t
( cd "$NR2" && echo hi > README && git add -A && git commit -qm init && git branch -M main )
cat > "$ROOT/profiles/.__noremote141.sh" <<EOF
FWF_REPO="$NR2"
WT_PREFIX="nr"
WT_BASE="$TMP/wt141"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
EOF
NR2OUT="$(FWF_ISSUES=local FWF_RUN_DIR="$TMP/run141b" FWF_PROFILE=.__noremote141 "$ROOT/fwf-provision.sh" 2>&1)"
NR2RC=$?
assert_eq "provision succeeds on a fresh git-init repo with no remote at all" "0" "$NR2RC"
assert_contains "provision warns loudly instead of aborting silently" "$NR2OUT" "could not fetch origin"
git -C "$NR2" show-ref --verify --quiet refs/heads/staging && ok "staging created locally with no remote" || bad "staging created locally with no remote"
git -C "$NR2" show-ref --verify --quiet refs/heads/integration && ok "integration created locally with no remote" || bad "integration created locally with no remote"
rm -f "$ROOT/profiles/.__noremote141.sh"

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

section "no shared-branch collision on claim/gate (issue #91): implementers and read-only conductors never hold local staging"
NCIMPL="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/implementer.tmpl' 1")"
assert_contains "impl: claims branch off origin/staging" "$NCIMPL" "git switch -c impl1/issue-<num>-<slug> origin/staging"
case "$NCIMPL" in *"git switch staging &&"*) bad "impl: never checks out local staging";; *) ok "impl: never checks out local staging";; esac
NCCON="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/conductor.tmpl' ''")"
assert_contains "conductor (dev, read-only): detaches for e2e"    "$NCCON" "git switch --detach origin/staging"
assert_contains "conductor (dev, read-only): promotes from origin/staging" "$NCCON" "git merge --ff-only origin/staging"
case "$NCCON" in *"git switch staging &&"*) bad "conductor (dev): never checks out local staging";; *) ok "conductor (dev): never checks out local staging";; esac
# the validate/ideation adjudicators DO legitimately hold local staging (they commit
# VERDICT.md/PORTFOLIO.md directly to it) — confirm that's still intact, and that
# their promote step still reads from origin/staging like everyone else's.
NCVAL="$(FWF_PROFILE=example FWF_TEMPLATE=validate bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/validate/conductor.tmpl' ''")"
assert_contains "adjudicator: still holds staging to commit the ledger" "$NCVAL" "git switch staging && git pull --ff-only"
assert_contains "adjudicator: promotes from origin/staging"             "$NCVAL" "git merge --ff-only origin/staging"
NCVALIMPL="$(FWF_PROFILE=example FWF_TEMPLATE=validate bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/validate/implementer.tmpl' 1")"
case "$NCVALIMPL" in *"git switch staging &&"*) bad "analyst: never checks out local staging";; *) ok "analyst: never checks out local staging";; esac
NCQA="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/dev/qa.tmpl' 1")"
assert_contains "qa: told never to check out shared staging" "$NCQA" "NEVER \`git switch\`/\`git checkout\` the shared staging"

section "fwf startup upgrade-staleness check (issue #94, from the #79 proposal) — hermetic, stubbed gh"
VSSTUB="$TMP/vsstub"; mkdir -p "$VSSTUB"
cat > "$VSSTUB/gh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  api)
    [ -n "${VS_CALL_LOG:-}" ] && echo x >> "$VS_CALL_LOG"
    [ "${VS_HANG:-0}" = 1 ] && sleep 300
    [ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
    echo "${FAKE_LATEST:-v0.0.0}";;
  *) exit 1;;
esac
EOS
chmod +x "$VSSTUB/gh"
vs_run() { PATH="$VSSTUB:$PATH" FWF_RUN_DIR="$1" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $2"; }

# (a) local == latest -> no warning
VSRUN="$TMP/vs-a"; mkdir -p "$VSRUN/upgrade-check"
printf 'v%s' "$REALV" > "$VSRUN/upgrade-check/latest"; printf '%s' "$(date +%s)" > "$VSRUN/upgrade-check/ts"
VSA="$(vs_run "$VSRUN" 'fwf_version_skew_check')"
[ -z "$VSA" ] && ok "(a) local == latest: no warning" || bad "(a) local == latest: no warning" "got [$VSA]"

# (b) local > cached-latest (maintainer-ahead / just-released box) -> no warning
VSRUN="$TMP/vs-b"; mkdir -p "$VSRUN/upgrade-check"
printf 'v0.0.1' > "$VSRUN/upgrade-check/latest"; printf '%s' "$(date +%s)" > "$VSRUN/upgrade-check/ts"
VSB="$(vs_run "$VSRUN" 'fwf_version_skew_check')"
[ -z "$VSB" ] && ok "(b) local > cached-latest: no backwards-upgrade warning" || bad "(b) local > cached-latest: no backwards-upgrade warning" "got [$VSB]"

# (c) local < latest -> warning fires, on all three surfaces
VSRUN="$TMP/vs-c"; mkdir -p "$VSRUN/upgrade-check"
printf 'v99.0.0' > "$VSRUN/upgrade-check/latest"; printf '%s' "$(date +%s)" > "$VSRUN/upgrade-check/ts"
VSC="$(vs_run "$VSRUN" 'fwf_version_skew_check')"
assert_eq "(c) local < latest: check reports cur|latest" "$REALV|v99.0.0" "$VSC"
VSC_WARN="$(vs_run "$VSRUN" 'fwf_version_skew_warn' 2>&1)"
assert_contains "(c) fwf-up warning fires" "$VSC_WARN" "v99.0.0 is released"
VSC_DOC="$(vs_run "$VSRUN" 'fwf_doctor_version_line')"
assert_contains "(c) doctor line fires" "$VSC_DOC" "OUT OF DATE"

# cache location: must be under $FWF_RUN/upgrade-check, never $TMPDIR. The
# refresh that creates the dir is detached (that's the whole point — see
# never-block below), so give it a moment to land before asserting on it.
VSRUN="$TMP/vs-loc"
TMPDIR="$TMP/vs-loc-tmpdir" vs_run "$VSRUN" 'fwf_version_skew_check' >/dev/null
sleep 1
[ -d "$VSRUN/upgrade-check" ] && ok "cache created under \$FWF_RUN" || bad "cache created under \$FWF_RUN"
[ -e "$TMP/vs-loc-tmpdir/.fwf-latest-release" ] && bad "cache NOT written under \$TMPDIR" || ok "cache NOT written under \$TMPDIR"

# never-block: gh hangs -> fwf_version_skew_check still returns near-instantly
VSRUN="$TMP/vs-hang"
VS_START="$(date +%s)"
VS_HANG=1 vs_run "$VSRUN" 'fwf_version_skew_check' >/dev/null 2>&1
VS_ELAPSED=$(( $(date +%s) - VS_START ))
[ "$VS_ELAPSED" -lt 5 ] && ok "never-block: returns instantly even with gh hung" || bad "never-block: returns instantly even with gh hung" "took ${VS_ELAPSED}s"
pkill -f "sleep 300" >/dev/null 2>&1 || true   # reap the stub's detached hung refresh

# doctor could-not-check: ts past 3x the staleness window reads as could-not-check,
# never as up-to-date (a dead checker must be visibly distinct)
VSRUN="$TMP/vs-stale"; mkdir -p "$VSRUN/upgrade-check"
printf 'v99.0.0' > "$VSRUN/upgrade-check/latest"
printf '%s' "$(( $(date +%s) - 43200*4 ))" > "$VSRUN/upgrade-check/ts"
VS_STALE_DOC="$(vs_run "$VSRUN" 'fwf_doctor_version_line')"
assert_contains "doctor: stale ts reports could-not-check, not stale data" "$VS_STALE_DOC" "could not check"

# per-version silence: acked == latest silences; an older ack (or a newer
# release than the ack) re-arms
VSRUN="$TMP/vs-ack"; mkdir -p "$VSRUN/upgrade-check"
printf 'v99.0.0' > "$VSRUN/upgrade-check/latest"; printf '%s' "$(date +%s)" > "$VSRUN/upgrade-check/ts"
VS_ACKED="$(FWF_ACK_VERSION=v99.0.0 vs_run "$VSRUN" 'fwf_version_skew_check')"
[ -z "$VS_ACKED" ] && ok "silence: ack of current latest suppresses the warning" || bad "silence: ack of current latest suppresses the warning" "got [$VS_ACKED]"
VS_REARMED="$(FWF_ACK_VERSION=v98.0.0 vs_run "$VSRUN" 'fwf_version_skew_check')"
assert_eq "silence: a newer release re-arms despite an older ack" "$REALV|v99.0.0" "$VS_REARMED"

# full kill switch: disables the check ENTIRELY — no cache read/write, no network
VSRUN="$TMP/vs-killswitch"
VS_SKIP="$(FWF_SKIP_VERSION_CHECK=1 vs_run "$VSRUN" 'fwf_version_skew_check')"
[ -z "$VS_SKIP" ] && ok "kill switch: no warning" || bad "kill switch: no warning"
[ -e "$VSRUN/upgrade-check" ] && bad "kill switch: no cache dir touched at all" || ok "kill switch: no cache dir touched at all"

# single-flight: N concurrent stale-triggered refreshes make AT MOST ONE gh call
VSRUN="$TMP/vs-singleflight"
VS_CALLS="$TMP/vs-call-log"; : > "$VS_CALLS"
( VS_CALL_LOG="$VS_CALLS" vs_run "$VSRUN" 'fwf_version_skew_check' & \
  VS_CALL_LOG="$VS_CALLS" vs_run "$VSRUN" 'fwf_version_skew_check' & \
  VS_CALL_LOG="$VS_CALLS" vs_run "$VSRUN" 'fwf_version_skew_check' & \
  wait )
sleep 1
VS_CALL_COUNT="$(wc -l < "$VS_CALLS" | tr -d ' ')"
[ "$VS_CALL_COUNT" -le 1 ] && ok "single-flight: >=3 concurrent refreshes make <=1 gh call" || bad "single-flight: >=3 concurrent refreshes make <=1 gh call" "made $VS_CALL_COUNT calls"

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
# pane launch command carries the guard PATH in BOTH modes now (#57): the shim
# is the REST+ETag read cache in gh mode, and additionally the write guard in local.
GCMD="$(FWF_RUN_DIR="$GGRUN" FWF_ISSUES=local FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$CLAUDE_CMD\"")"
assert_contains "local CLAUDE_CMD prepends guard PATH" "$GCMD" "ghguard"
GCMD_GH="$(FWF_RUN_DIR="$GGRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; printf '%s' \"\$CLAUDE_CMD\"")"
assert_contains "gh mode CLAUDE_CMD prepends guard PATH (read cache)" "$GCMD_GH" "ghguard"

# fwf-ghcache.sh: reshape a SEEDED canonical REST snapshot offline (#57). With
# FWF_REAL_GH=/bin/false any network/GraphQL fallback would yield empty + fail,
# so a correct answer proves the cache served the open set from the snapshot.
CHROOT="$TMP/ghcache"; mkdir -p "$CHROOT/x__y"
printf '%s' '[{"number":9,"title":"Alpha","body":"a","state":"open","html_url":"u","created_at":"2026-01-03T00:00:00Z","updated_at":"2026-01-03T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[{"node_id":"L1","name":"bug","description":"d","color":"c"}],"assignees":[]},{"number":7,"title":"Beta","body":"b","state":"open","html_url":"u","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[],"assignees":[]}]' > "$CHROOT/x__y/issues.json"
touch "$CHROOT/x__y/issues.ts"
GHC() { FWF_GHCACHE_DIR="$CHROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH=/bin/false bash "$ROOT/fwf-ghcache.sh" "$@" 2>/dev/null; }
assert_eq "ghcache reshapes canonical offline" '9,7' "$(GHC serve issue list --json number,title --jq '[.[].number]|@csv')"
assert_eq "ghcache --label filter offline"    '9'   "$(GHC serve issue list --label bug --json number --jq '[.[].number]|@csv')"
assert_eq "ghcache projects gh-shaped labels"  '[{"labels":[{"id":"L1","name":"bug","description":"d","color":"c"}],"number":9}]' "$(GHC serve issue list --label bug --json number,labels)"

# fwf-ghcache.sh (#58): `--search` translation over the SAME canonical open-set
# snapshot list uses — only the recognized is:open/label:/-label: vocabulary.
SROOT="$TMP/ghcache-search"; mkdir -p "$SROOT/x__y"
printf '%s' '[
 {"number":1,"title":"A","body":"","state":"open","html_url":"u","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[],"assignees":[]},
 {"number":2,"title":"B","body":"","state":"open","html_url":"u","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[{"node_id":"L2","name":"product-wip","description":"","color":"c"}],"assignees":[]},
 {"number":3,"title":"C","body":"","state":"open","html_url":"u","created_at":"2026-01-03T00:00:00Z","updated_at":"2026-01-03T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[{"node_id":"L3","name":"release-hold","description":"","color":"c"}],"assignees":[]},
 {"number":4,"title":"D","body":"","state":"open","html_url":"u","created_at":"2026-01-04T00:00:00Z","updated_at":"2026-01-04T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[{"node_id":"L4","name":"idea","description":"","color":"c"}],"assignees":[]},
 {"number":5,"title":"E","body":"","state":"open","html_url":"u","created_at":"2026-01-05T00:00:00Z","updated_at":"2026-01-05T00:00:00Z","closed_at":null,"user":{"login":"b"},"labels":[{"node_id":"L5a","name":"product-wip","description":"","color":"c"},{"node_id":"L5b","name":"release-hold","description":"","color":"c"}],"assignees":[]}
]' > "$SROOT/x__y/issues.json"
touch "$SROOT/x__y/issues.ts"
GHCS() { FWF_GHCACHE_DIR="$SROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH=/bin/false bash "$ROOT/fwf-ghcache.sh" "$@" 2>/dev/null; }
assert_eq "search: is:open (qa queue pattern)" "1,2,3,4,5" "$(GHCS serve issue list --search "is:open" --json number --jq '[.[].number]|sort|@csv')"
assert_eq "search: is:open -label:product-wip -label:release-hold -label:idea (implementer survey)" "1" "$(GHCS serve issue list --search "is:open -label:product-wip -label:release-hold -label:idea" --json number --jq '[.[].number]|sort|@csv')"
assert_eq "search: is:open -label:product-wip -label:release-hold (pm/captain queued)" "1,4" "$(GHCS serve issue list --search "is:open -label:product-wip -label:release-hold" --json number --jq '[.[].number]|sort|@csv')"
assert_eq "search: is:open label:release-hold (pm held-issues list)" "3,5" "$(GHCS serve issue list --search "is:open label:release-hold" --json number --jq '[.[].number]|sort|@csv')"

# Fail-safe (#58 GV item 2, highest priority): an off-list --search string
# (author:, sort:, free text, a date qualifier, …) MUST fall through to real
# gh, never to a best-effort/empty translated result. A fake `gh` that prints
# a distinguishable sentinel proves the fallback path actually ran.
FAKEGH_SENTINEL="$TMP/fakegh-sentinel"
printf '#!/usr/bin/env bash\necho "REAL-GH-FALLBACK-RAN: $*"\n' > "$FAKEGH_SENTINEL"; chmod +x "$FAKEGH_SENTINEL"
FALLBACK_OUT="$(FWF_GHCACHE_DIR="$SROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH="$FAKEGH_SENTINEL" bash "$ROOT/fwf-ghcache.sh" serve issue list --search "author:someone" --json number 2>/dev/null)"
assert_contains "search: unrecognized token FAILS SAFE to real gh (not a translated snapshot)" "$FALLBACK_OUT" "REAL-GH-FALLBACK-RAN"

# Re-grep-at-build fixture (#58 spec): pin the exact set of --search literals
# built ENTIRELY from the recognized vocabulary (is:open/is:closed/label:x/
# -label:x) that templates/ actually emit today. If a template edit adds a
# new vocab-only pattern, this goes RED until fwf-ghcache.sh (and this pinned
# list) is updated to serve it — it must never silently mistranslate instead.
# NOTE: the case/while below is wrapped in a named function rather than
# inlined directly in a `$(...)` — bash 3.2 (macOS's /bin/bash, which this
# suite must stay clean under) fails to parse a `case` nested inside a
# `while` when that whole construct sits literally inside a command
# substitution ("syntax error near unexpected token `newline'"). A function
# call inside `$(...)` sidesteps it.
_search_literals_in_templates() {
  grep -rhoE -- '--search "[^"]*"' "$ROOT/templates" 2>/dev/null \
    | sed -E 's/^--search "//; s/"$//' | sort -u | while IFS= read -r s; do
        local vok=1 tok
        for tok in $s; do
          case "$tok" in
            is:open|is:closed|label:*|-label:*) ;;
            *) vok=0;;
          esac
        done
        [ "$vok" = 1 ] && printf '%s\n' "$s"
      done
}
FOUND_SEARCH="$(_search_literals_in_templates)"
EXPECT_SEARCH="$(printf '%s\n' \
  'is:open' \
  'is:open -label:__WIP_LABEL__ -label:__HOLD_LABEL__' \
  'is:open -label:__WIP_LABEL__ -label:__HOLD_LABEL__ -label:idea' \
  'is:open label:__HOLD_LABEL__' | sort)"
assert_eq "search: recognized --search literals in templates match the pinned/tested set" "$EXPECT_SEARCH" "$FOUND_SEARCH"

# fwf-ghcache.sh (#58): `issue/pr view --json …` REST reshape, byte-exact vs
# the GraphQL shape, plus cache-key correctness for comments.
VROOT="$TMP/ghcache-view"; mkdir -p "$VROOT/x__y/views"
printf '%s' '{"number":20,"title":"Fix the thing","body":"body text","state":"open","html_url":"https://github.com/x/y/issues/20","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","closed_at":null,"user":{"login":"alice"},"labels":[{"node_id":"L1","name":"bug","description":"d","color":"c"}],"assignees":[{"login":"bob"}]}' > "$VROOT/x__y/views/issue-20.json"
touch "$VROOT/x__y/views/issue-20.ts"
printf '%s' '{"number":30,"title":"Add feature","body":"pr body","state":"open","draft":false,"merged_at":null,"head":{"ref":"impl2/foo","sha":"abc123"},"base":{"ref":"staging"},"html_url":"https://github.com/x/y/pull/30","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","closed_at":null,"user":{"login":"carol"}}' > "$VROOT/x__y/views/pr-30.json"
touch "$VROOT/x__y/views/pr-30.ts"
GHV() { FWF_GHCACHE_DIR="$VROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH=/bin/false bash "$ROOT/fwf-ghcache.sh" "$@" 2>/dev/null; }
assert_eq "view: issue --json title,body byte-exact" '{"body":"body text","title":"Fix the thing"}' "$(GHV serve issue view 20 --json title,body)"
assert_eq "view: issue --json labels byte-exact vs GraphQL shape" '{"labels":[{"id":"L1","name":"bug","description":"d","color":"c"}]}' "$(GHV serve issue view 20 --json labels)"
assert_eq "view: pr --json title,isDraft,headRefName byte-exact" '{"headRefName":"impl2/foo","isDraft":false,"title":"Add feature"}' "$(GHV serve pr view 30 --json title,isDraft,headRefName)"
assert_eq "view: 404/unfetchable resource falls through, not a wrong empty result" "" "$(GHV serve issue view 999 --json title)"

# Cache-key correctness (#58 GV item 3): a comment-less call must NOT poison
# a later --json comments call of the SAME #N with a stale comment-less body
# — the base resource and comments are cached in separate files, keyed by
# resource identity alone, never by the requested --json field set.
assert_eq "view: comment-less call" '{"title":"Fix the thing"}' "$(GHV serve issue view 20 --json title)"
[ ! -f "$VROOT/x__y/views/20-comments.json" ] && ok "comments not fetched until actually requested" || bad "comments not fetched until actually requested"
printf '%s' '[{"id":111,"user":{"login":"dave"},"author_association":"CONTRIBUTOR","body":"CLAIM impl2","created_at":"2026-01-03T00:00:00Z","updated_at":"2026-01-03T00:00:00Z","html_url":"https://github.com/x/y/issues/20#issuecomment-111"}]' > "$VROOT/x__y/views/20-comments.json"
touch "$VROOT/x__y/views/20-comments.ts"
assert_eq "view: --json comments after a comment-less call is NOT stale" "CLAIM impl2" "$(GHV serve issue view 20 --json comments --jq '[.comments[].body][0]')"
assert_eq "view: comments shaped byte-exact (REST-unavailable GraphQL-only fields default sanely)" \
  '{"comments":[{"id":"111","author":{"login":"dave"},"authorAssociation":"CONTRIBUTOR","body":"CLAIM impl2","createdAt":"2026-01-03T00:00:00Z","includesCreatedEdit":false,"isMinimized":false,"minimizedReason":"","reactionGroups":[],"url":"https://github.com/x/y/issues/20#issuecomment-111","viewerDidAuthor":false}]}' \
  "$(GHV serve issue view 20 --json comments)"

# fwf-ghcache.sh (#58): `pr diff --name-only` follows ALL pages of
# /pulls/{n}/files (30/page) — a >30-file PR must not come back truncated,
# or a role wrongly concludes an untouched file was never touched.
FAKEGH_DIFF="$TMP/fakegh-diff"
cat > "$FAKEGH_DIFF" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  page="${2##*page=}"; page="${page%%&*}"
  case "$page" in
    1) jq -nc '[range(1;31) | {filename: ("file"+(.|tostring)+".txt")}]';;
    2) jq -nc '[range(31;36) | {filename: ("file"+(.|tostring)+".txt")}]';;
    *) echo '[]';;
  esac
  exit 0
fi
echo "REAL-GH-DIFF-FALLBACK: $*"
EOF
chmod +x "$FAKEGH_DIFF"
DROOT="$TMP/ghcache-diff"; mkdir -p "$DROOT/x__y"
DIFFOUT="$(FWF_GHCACHE_DIR="$DROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH="$FAKEGH_DIFF" bash "$ROOT/fwf-ghcache.sh" serve pr diff 55 --name-only 2>/dev/null)"
assert_eq "pr diff --name-only: full >30-file list, not truncated to page 1" "35" "$(printf '%s\n' "$DIFFOUT" | grep -c .)"
assert_contains "pr diff --name-only: includes a page-2 file (proves pagination ran)" "$DIFFOUT" "file35.txt"
DIFFOUT2="$(FWF_GHCACHE_DIR="$DROOT" FWF_GHCACHE_REPO=x/y FWF_GHCACHE_TTL=9999 FWF_REAL_GH="$FAKEGH_DIFF" bash "$ROOT/fwf-ghcache.sh" serve pr diff 55 --patch 2>/dev/null)"
assert_contains "pr diff (no --name-only) is not modeled, falls back to real gh" "$DIFFOUT2" "REAL-GH-DIFF-FALLBACK"

# fwf-ghcache.sh (#167): `invalidate <issue|pr> <n>` is the write-through
# cache-bust the operator un-gate fires so a just-approved ticket is visible on
# the NEXT read, not up to a full TTL later. It drops ONLY the `.ts` staleness
# stamps of the two signals a role reads — the canonical open-issues snapshot
# (the removed WIP label) and the issue's comment thread (the operator sentinel)
# — while KEEPING their `.etag` files so the forced refresh stays a cheap
# conditional, and never deleting the cached bodies (a failed refresh falls back).
IROOT="$TMP/ghcache-invalidate"; mkdir -p "$IROOT/x__y/views"
printf 'x' > "$IROOT/x__y/issues.json"; touch "$IROOT/x__y/issues.ts"; printf 'E-ISSUES' > "$IROOT/x__y/issues.etag"
printf 'x' > "$IROOT/x__y/prs.json";    touch "$IROOT/x__y/prs.ts";    printf 'E-PRS'    > "$IROOT/x__y/prs.etag"
printf 'x' > "$IROOT/x__y/views/42-comments.json"; touch "$IROOT/x__y/views/42-comments.ts"; printf 'E-CMT' > "$IROOT/x__y/views/42-comments.etag"
GHI() { FWF_GHCACHE_DIR="$IROOT" FWF_GHCACHE_REPO=x/y FWF_REAL_GH=/bin/false bash "$ROOT/fwf-ghcache.sh" "$@" 2>/dev/null; }
GHI invalidate issue 42
[ ! -f "$IROOT/x__y/issues.ts" ]            && ok "invalidate issue drops the canonical issues .ts"    || bad "invalidate issue drops the canonical issues .ts"
[ ! -f "$IROOT/x__y/views/42-comments.ts" ] && ok "invalidate issue drops the comment-thread .ts"      || bad "invalidate issue drops the comment-thread .ts"
[ -f "$IROOT/x__y/issues.etag" ]            && ok "invalidate KEEPS the canonical issues .etag"        || bad "invalidate KEEPS the canonical issues .etag"
[ -f "$IROOT/x__y/views/42-comments.etag" ] && ok "invalidate KEEPS the comment-thread .etag"          || bad "invalidate KEEPS the comment-thread .etag"
[ -f "$IROOT/x__y/issues.json" ] && [ -f "$IROOT/x__y/views/42-comments.json" ] && ok "invalidate preserves the cached bodies" || bad "invalidate preserves the cached bodies"
[ -f "$IROOT/x__y/prs.ts" ] && ok "invalidate issue leaves the prs snapshot .ts alone" || bad "invalidate issue leaves the prs snapshot .ts alone"
# the pr topic busts the prs snapshot instead (dash-act only fires `issue`, but
# the verb models both — a PR is an issue in GitHub's data model).
GHI invalidate pr 42
[ ! -f "$IROOT/x__y/prs.ts" ] && ok "invalidate pr drops the prs snapshot .ts" || bad "invalidate pr drops the prs snapshot .ts"
[ -f "$IROOT/x__y/prs.etag" ] && ok "invalidate pr KEEPS the prs snapshot .etag" || bad "invalidate pr KEEPS the prs snapshot .etag"
# a bad topic / non-numeric id is rejected, never a silent wrong-file removal.
GHI invalidate bogus 42 && bad "invalidate rejects an unknown topic" || ok "invalidate rejects an unknown topic"
GHI invalidate issue nope && bad "invalidate rejects a non-numeric id" || ok "invalidate rejects a non-numeric id"

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

section "dispatcher: bad input is rejected"
"$ROOT/fwf" bogus-cmd >/dev/null 2>&1 && bad "unknown command rejected" || ok "unknown command rejected"
"$ROOT/fwf" init >/dev/null 2>&1 && bad "init without arg rejected" || ok "init without arg rejected"

# --------------------------------------------------------------------------
# fwf dash action layer (#40 milestone 2): assert the EXACT constructed command
# via the FWF_DASH_DRYRUN seam — no tracker, no tmux, both backends. Same spirit
# as the gh-write-guard tests. FWF_REPO points at a non-git path so the gh path
# is deterministic (plain `gh issue`, no repo-dir cd).
act() { # <env-prefix...> -- verb args... ; echoes DRYRUN output
  FWF_PROFILE=example FWF_REPO="$TMP/no-such-repo" FWF_DASH_DRYRUN=1 \
    bash "$ROOT/fwf-dash-act.sh" "$@" 2>&1
}
section "dash act: gh backend constructs the right writes"
A_OUT="$(act approve 40)"
assert_contains "approve posts go-ahead comment" "$A_OUT" "gh issue comment 40 --body go ahead"
assert_contains "approve un-gates the label"     "$A_OUT" "gh issue edit 40 --remove-label product-wip"
# The un-gate must ALSO write-through-bust the gh read cache (#167), or a role
# stays blind to the fresh approval for up to a full TTL. Asserted via the same
# DRYRUN seam.
assert_contains "approve fires the write-through cache-bust (#167)" "$A_OUT" "fwf-ghcache.sh invalidate issue 40"
# The un-gate comment MUST carry the operator sentinel (#150): the positive,
# attributable authorization signal `fwf authz` later verifies. reject must NOT.
assert_contains     "approve emits the operator un-gate sentinel"  "$A_OUT" "OPERATOR-UNGATE #40"
assert_not_contains "reject must NOT emit the sentinel"            "$(act reject 40)" "OPERATOR-UNGATE"
assert_contains "reject default text"   "$(act reject 40)" "gh issue comment 40 --body Not yet"
assert_contains "reject custom text"    "$(act reject 40 needs a repro)" "gh issue comment 40 --body needs a repro"
assert_contains "comment posts body"    "$(act comment 40 looks good)" "gh issue comment 40 --body looks good"
assert_contains "open uses the browser" "$(act open 40)" "gh issue view 40 --web"

section "dash act: id normalization strips # and LI-"
assert_contains "strips leading #"  "$(act comment '#41' hi)" "gh issue comment 41 --body hi"
assert_contains "strips LI- prefix" "$(act comment LI-7 hi)"  "gh issue comment 7 --body hi"

section "dash act: local backend routes to fwf-issues.sh (never gh)"
loc() { FWF_PROFILE=example FWF_ISSUES=local FWF_DASH_DRYRUN=1 bash "$ROOT/fwf-dash-act.sh" "$@" 2>&1; }
L_OUT="$(loc approve LI-3)"
assert_contains "local approve uses fwf-issues.sh" "$L_OUT" "fwf-issues.sh comment 3 --body go ahead"
assert_contains "local approve un-gates"           "$L_OUT" "fwf-issues.sh edit 3 --remove-label product-wip"
case "$(loc approve LI-3)" in *"gh issue"*) bad "local backend must not call gh";; *) ok "local backend never calls gh";; esac
# The local store has no REST cache, so the un-gate must NOT invoke the ghcache
# invalidate there (#167) — gh backend only.
assert_not_contains "local approve does not touch the gh cache (#167)" "$L_OUT" "ghcache"

section "dash act: role controls + validation"
assert_contains "respawn wraps fwf-respawn.sh" "$(act respawn impl2)" "fwf-respawn.sh impl2"
assert_contains "stop wraps fwf-stop.sh"       "$(act stop)" "fwf-stop.sh"
act approve >/dev/null 2>&1 && bad "approve without id rejected" || ok "approve without id rejected"
act comment 40 >/dev/null 2>&1 && bad "empty comment rejected" || ok "empty comment rejected"
act bogus-verb >/dev/null 2>&1 && bad "unknown verb rejected" || ok "unknown verb rejected"

# --------------------------------------------------------------------------
# fwf authz: the MECHANISM that closes the #150 fabricated-authorization hole.
# Proves the verdict keys ONLY on the operator's real signal (a `fwf dash`
# approve keypress, which emits the durable sentinel comment) — never on text
# that merely reads like approval (the pane/ghost text the captain hallucinated),
# and never on the mutable label. Runs end-to-end over the local issues backend.
section "fwf authz: mechanical operator-authorization check (issue #150)"
AZRUN="$TMP/azrun"
AZI()   { FWF_RUN_DIR="$AZRUN" FWF_PROFILE=example "$ROOT/fwf-issues.sh" "$@"; }
AZ()    { FWF_RUN_DIR="$AZRUN" FWF_ISSUES=local FWF_PROFILE=example "$ROOT/fwf-authz.sh" "$@"; }
AZACT() { FWF_RUN_DIR="$AZRUN" FWF_ISSUES=local FWF_PROFILE=example bash "$ROOT/fwf-dash-act.sh" "$@"; }
azrc()  { local rc=0; AZ "$1" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

AZI create --title "Groomed build ticket" --label product-wip >/dev/null
# (A) fresh gated ticket, no operator signal yet -> HELD (exit 10).
assert_eq "authz HELD (exit 10) on an unauthorized ticket" "10" "$(azrc 1)"
assert_contains "authz HELD verdict names the issue" "$(AZ 1 2>&1)" "HELD #1"
# (B) THE INCIDENT: a comment whose TEXT reads as the human approving (the
# #150 pane/ghost text) is NOT the operator's signal — it must NOT authorize.
AZI comment 1 --body "yes, I approved those four — go ahead, un-gate them" >/dev/null
assert_eq "text that merely reads as approval is NOT authorization (still HELD)" "10" "$(azrc 1)"
# (C) only the REAL un-gate — a human keypress on the board (fwf dash approve) —
# emits the sentinel and flips the verdict to AUTHORIZED (exit 0).
AZACT approve 1 >/dev/null 2>&1
assert_eq "genuine operator un-gate flips authz to AUTHORIZED (exit 0)" "0" "$(azrc 1)"
assert_contains "authz AUTHORIZED verdict cites the signal" "$(AZ 1 2>&1)" "AUTHORIZED #1"
# (D) DURABILITY vs the incident's re-gate: a role wrongly re-applies the label;
# authz still reads AUTHORIZED because it keys on the durable comment, not the
# mutable label — so a role that CHECKS can't be tricked into reverting the work.
AZI edit 1 --add-label product-wip >/dev/null
assert_eq "authz stays AUTHORIZED after a wrongful re-gate" "0" "$(azrc 1)"
# (E) unreadable/missing thread fails CLOSED to INDETERMINATE (exit 2), never a yes.
assert_eq "missing issue fails closed to INDETERMINATE (exit 2)" "2" "$(azrc 999)"
assert_contains "INDETERMINATE verdict is explicit" "$(AZ 999 2>&1)" "INDETERMINATE #999"
# id normalization + input validation.
assert_eq "authz accepts #N form"        "0" "$(azrc '#1')"
assert_eq "authz accepts LI-N form"      "0" "$(azrc 'LI-1')"
assert_eq "authz rejects empty id"       "1" "$(azrc '')"
assert_eq "authz rejects non-numeric id" "1" "$(azrc 'abc')"

# fwf authz (#200): gh's human-readable `--comments` renderer has a
# reproducible bug — for some issues it returns 0 bytes with exit 0 and no
# stderr, making a genuinely-empty thread indistinguishable from a broken
# read. authz now reads the gh backend through the reliable `--json comments`
# REST path and keys INDETERMINATE on the read COMMAND failing, never on the
# thread text being empty — so a real zero-comment issue reads HELD, not
# INDETERMINATE, and the sentinel is still found when present.
AZGROOT="$TMP/authz-gh"; mkdir -p "$AZGROOT/x__y/views"
printf '%s' '{"number":40,"title":"gh-backed ticket","body":"","state":"open","html_url":"https://github.com/x/y/issues/40","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","closed_at":null,"user":{"login":"alice"},"labels":[],"assignees":[]}' > "$AZGROOT/x__y/views/issue-40.json"
touch "$AZGROOT/x__y/views/issue-40.ts"
printf '%s' '[]' > "$AZGROOT/x__y/views/40-comments.json"
touch "$AZGROOT/x__y/views/40-comments.ts"
AZG() { FWF_RUN_DIR="$AZGROOT/run" FWF_GHCACHE_DIR="$AZGROOT" FWF_GHCACHE_REPO=x/y FWF_PROFILE=example "$ROOT/fwf-authz.sh" "$@"; }
azgrc() { local rc=0; AZG "$1" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
assert_eq "authz: genuinely zero comments (successful read) is HELD, not INDETERMINATE" "10" "$(azgrc 40)"
assert_contains "authz HELD verdict on zero-comment issue" "$(AZG 40 2>&1)" "HELD #40"
printf '%s' '[{"id":222,"user":{"login":"ops"},"author_association":"OWNER","body":"OPERATOR-UNGATE tbaums/fun-with-friends#40: approved","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/x/y/issues/40#issuecomment-222"}]' > "$AZGROOT/x__y/views/40-comments.json"
touch "$AZGROOT/x__y/views/40-comments.ts"
assert_eq "authz: sentinel found via the --json comments path is AUTHORIZED" "0" "$(azgrc 40)"
assert_contains "authz AUTHORIZED verdict via JSON path" "$(AZG 40 2>&1)" "AUTHORIZED #40"

# --------------------------------------------------------------------------
# fwf dash DATA provider (#52): source the provider (main is guarded) and drive
# its derivation with stubbed di_read/gh_pr — no gh, no tmux. Pins the #51
# captain-sequenced decisions behaviour and activity bucketing/branch parsing.
DD="$ROOT/fwf-dash-data.sh"

section "dash data: captain_sequences_releases keys off the template (#51)"
assert_eq "refactor → captain-sequenced" "yes" \
  "$(FWF_PROFILE=example FWF_TEMPLATE=refactor bash -c "source '$DD'; captain_sequences_releases && echo yes || echo no")"
assert_eq "dev → human-decided" "no" \
  "$(FWF_PROFILE=example FWF_TEMPLATE=dev bash -c "source '$DD'; captain_sequences_releases && echo yes || echo no")"

section "dash data: decisions_json surfaces gated+GV-SIGNOFF in dev, not refactor (#51)"
DD_FIX='[{"number":9,"title":"x","gated":true,"body":"b"}]'
DD_STUB='di_read() { case "$*" in *"view 9"*) echo "GV-SIGNOFF ok";; esac; }; status_fresh() { return 1; }'
assert_eq "dev surfaces the decision" '["9"]' \
  "$(FWF_PROFILE=example FWF_TEMPLATE=dev bash -c "source '$DD'; $DD_STUB; decisions_json '$DD_FIX'" | jq -c '[.[].id]')"
assert_eq "refactor surfaces none" "[]" \
  "$(FWF_PROFILE=example FWF_TEMPLATE=refactor bash -c "source '$DD'; $DD_STUB; decisions_json '$DD_FIX'" | jq -c '.')"

section "dash data: activity_json buckets PRs + parses role/issue from the branch"
printf '%s' '[{"number":7,"title":"wip","isDraft":true,"baseRefName":"staging","headRefName":"impl1/issue-42-foo","statusCheckRollup":[]}]' > "$TMP/dd-open.json"
printf '%s' '[{"number":8,"title":"done","baseRefName":"integration","headRefName":"qa2/issue-43-bar","mergedAt":"2026-06-18T12:34:56Z"}]' > "$TMP/dd-merged.json"
DD_ACT="$(FWF_PROFILE=example FWF_TEMPLATE=dev bash -c "source '$DD'; STAGING_BRANCH=staging INTEGRATION_BRANCH=integration DEFAULT_BRANCH=main; gh_pr() { case \"\$*\" in *'--state open'*) cat '$TMP/dd-open.json';; *'--state merged'*) cat '$TMP/dd-merged.json';; esac; }; activity_json")"
assert_eq "draft PR → building bucket, role parsed" "impl1" "$(printf '%s' "$DD_ACT" | jq -r '.building[0].role')"
assert_eq "issue number parsed from branch"         "42"    "$(printf '%s' "$DD_ACT" | jq -r '.building[0].issue')"
assert_eq "merged PR bucketed by base branch"       "8"     "$(printf '%s' "$DD_ACT" | jq -r '.merged[0].pr')"
assert_eq "merged 'when' formatted from mergedAt"   "06-18 12:34" "$(printf '%s' "$DD_ACT" | jq -r '.merged[0].when')"

section "dash data: detail_view renders through the REAL gh cache from outside the repo (#57 regression)"
# The dash runs outside the target repo; the cache's fallback `gh issue view N`
# must still resolve the repo (via GH_REPO) or it fails "could not resolve" and
# the detail pane shows "detail unavailable". Stub `gh` on PATH so di_read's real
# `gh` IS the stub: it fails unless GH_REPO is set, else returns a canned thread.
mkdir -p "$TMP/dbin"
cat > "$TMP/dbin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${GH_REPO:-}" ] && { echo "GraphQL: Could not resolve to an issue with the number of ${3:-}." >&2; exit 1; }
case "$1 $2" in "issue view") printf '#%s · stub thread\nstate: OPEN\n' "$3"; exit 0;; esac
exit 1
STUB
chmod +x "$TMP/dbin/gh"
DD_DETAIL="$(cd "$TMP" && PATH="$TMP/dbin:$PATH" FWF_PROFILE=example FWF_GHCACHE_DIR="$TMP/ghcd" FWF_GHCACHE_REPO=o/r FWF_GHCACHE_TTL=9999 bash "$DD" detail 5 2>/dev/null)"
assert_contains "detail renders the thread via the cache" "$DD_DETAIL" "#5 · stub thread"
case "$DD_DETAIL" in *"detail unavailable"*) bad "detail must not be 'unavailable' when the cache has repo context";; *) ok "detail is not 'unavailable'";; esac

# --------------------------------------------------------------------------
# fwf dash: persist-the-launch-socket (#62, supersedes #57) — RED when the
# dash reads the wrong tmux socket. No real tmux touched anywhere: a stub
# `tmux` on PATH answers has-session/list-panes/show/display-message from a
# tiny fixture DB keyed by socket ("-S <path>", or "default" with no -S).
section "dash data (#62): \$TMUX capture parses only the socket-path field"
assert_eq "comma-form \$TMUX -> parsed path only (never the raw string)" "/priv/tmux-501/concierge" \
  "$(TMUX='/priv/tmux-501/concierge,10269,0' FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_tmux_socket_value")"
assert_eq "unset \$TMUX -> literal 'default' marker (never an empty string)" "default" \
  "$(env -u TMUX FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_tmux_socket_value")"
PERSISTRUN="$TMP/run62persist"
assert_eq "fwf_persist_tmux_socket writes FWF_TMUX_SOCKET to the documented per-profile state file" "default" \
  "$(env -u TMUX FWF_RUN_DIR="$PERSISTRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_persist_tmux_socket \"\$(fwf_tmux_socket_value)\"" >/dev/null; cat "$PERSISTRUN/state/example/tmux_socket" 2>/dev/null)"

section "dash data (#62): roles_json queries the PERSISTED socket, not the default/ambient one"
SOCKDB="$TMP/tmux62db"
mkdir -p "$SOCKDB/log.d"
SOCKPATH="$TMP/fakesock/mysock"
SOCKKEY="$(printf '%s' "$SOCKPATH" | tr -c 'A-Za-z0-9_' '_')"
mkdir -p "$SOCKDB/sessions/$SOCKKEY" "$SOCKDB/panes/$SOCKKEY" "$SOCKDB/labels" "$SOCKDB/cmds"
: > "$SOCKDB/sessions/$SOCKKEY/fwf-test62-build"
printf '%%1\n' > "$SOCKDB/panes/$SOCKKEY/fwf-test62-build"
printf 'IMPL1 · any issue -> instant draft PR · impl1/*\n' > "$SOCKDB/labels/%1"
printf 'claude\n' > "$SOCKDB/cmds/%1"
STUBBIN="$TMP/tmux62bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
db="${FAKE_TMUX_DB:?}"
sock=""
if [ "$1" = "-S" ]; then sock="$2"; shift 2; fi
key="$(printf '%s' "${sock:-default}" | tr -c 'A-Za-z0-9_' '_')"
case "$1" in
  has-session)      [ -f "$db/sessions/$key/$3" ] && exit 0 || exit 1 ;;
  list-panes)       cat "$db/panes/$key/$3" 2>/dev/null; exit 0 ;;
  show)             cat "$db/labels/$4" 2>/dev/null; exit 0 ;;
  display-message)  cat "$db/cmds/$4" 2>/dev/null; exit 0 ;;
  capture-pane)      exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUBBIN/tmux"
DASHENV="FAKE_TMUX_DB=$SOCKDB PATH=$STUBBIN:$PATH FWF_PROFILE=example FWF_BUILD_SESSION=fwf-test62-build FWF_PAIRS=1"

UPRUN="$TMP/run62up"; mkdir -p "$UPRUN/state/example"
printf '%s\n' "$SOCKPATH" > "$UPRUN/state/example/tmux_socket"
UPROLES="$(env $DASHENV FWF_RUN_DIR="$UPRUN" TMUX='/some/other/wrapper-sock,999,0' bash -c "source '$DD'; roles_json")"
assert_eq "role launched on a non-default socket reads UP once the socket is persisted" "live" \
  "$(printf '%s' "$UPROLES" | jq -r '.[] | select(.role=="impl1") | .state')"

NOFILERUN="$TMP/run62nofile"; mkdir -p "$NOFILERUN"
NOFILEROLES="$(env $DASHENV FWF_RUN_DIR="$NOFILERUN" bash -c "source '$DD'; roles_json")"
assert_eq "same fixture with NO persisted socket and no ambient \$TMUX reads DOWN (proves the UP above came from reading the persisted socket, not luck — this is what 'unset TMUX' regresses to)" "down" \
  "$(printf '%s' "$NOFILEROLES" | jq -r '.[] | select(.role=="impl1") | .state')"

FALLBACKRUN="$TMP/run62fallback"; mkdir -p "$FALLBACKRUN"
FALLBACKROLES="$(env $DASHENV FWF_RUN_DIR="$FALLBACKRUN" TMUX="$SOCKPATH,555,0" bash -c "source '$DD'; roles_json")"
assert_eq "absent-field migration fallback: no persisted socket yet, but the CURRENT \$TMUX has the sessions -> UP with no restart needed" "live" \
  "$(printf '%s' "$FALLBACKROLES" | jq -r '.[] | select(.role=="impl1") | .state')"

# --------------------------------------------------------------------------
# fwf dash BINARY RESOLVER (#63): FWF_DASH_BIN → cached arch+version binary →
# verified release-asset download → source `cargo build` fallback. Fully
# hermetic: a stubbed PATH (curl/cargo), a fake release tree served via a
# file:// FWF_DASH_RELEASE_BASE, FWF_DASH_CACHE_DIR + FWF_DASH_CRATE seams so we
# never touch the network, the real cache, or the real crate. Each fake "binary"
# just prints a tag so we can prove WHICH resolution path produced it.
section "dash resolver (#63): resolution order + checksum verify + offline fallback"
DVER="$(cat "$ROOT/VERSION")"
# Host slug, same mapping the resolver uses.
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in arm64|aarch64) DSLUG=darwin-arm64;; *) DSLUG="";; esac;;  # Intel Mac: no prebuilt (empty slug)
  Linux)  case "$(uname -m)" in x86_64|amd64) DSLUG=linux-x86_64;; aarch64|arm64) DSLUG=linux-arm64;; *) DSLUG="";; esac;;
  *) DSLUG="";;
esac
dsha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }
mkdashbin() { printf '#!/usr/bin/env bash\necho "DASH tag=%s"\n' "$2" > "$1"; chmod +x "$1"; }
# Stub PATH: real coreutils + jq stub (so the jq check passes) + a curl that
# resolves file:// URLs out of our fake release tree. cargo is stubbed per-case.
DBIN="$TMP/dashstub"; mkdir -p "$DBIN"
for t in bash env uname mktemp awk cat cp mv chmod mkdir rm dirname sha256sum shasum; do
  r="$(command -v "$t" 2>/dev/null)" && ln -sf "$r" "$DBIN/$t"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$DBIN/jq"; chmod +x "$DBIN/jq"
cat > "$DBIN/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; file://*) url="${1#file://}"; shift;; *) shift;; esac; done
[ -f "$url" ] || exit 22; cp "$url" "$out"
CURL
chmod +x "$DBIN/curl"
DEMPTY="$TMP/dash-empty-crate"; mkdir -p "$DEMPTY/target/release"   # crate seam w/ no prebuilt binary
# Fake release tree: <base>/v<ver>/{asset,checksums}
DREL="$TMP/dash-release"; DASSET="fwf-dash-${DVER}-${DSLUG}"
mkdir -p "$DREL/v$DVER"; mkdashbin "$DREL/v$DVER/$DASSET" downloaded
( cd "$DREL/v$DVER" && dsha "$DASSET" > "fwf-dash-${DVER}-checksums.txt" )
drun() { env -i HOME="$TMP/dhome" PATH="$DBIN:/usr/bin:/bin" TMPDIR="$TMP" FWF_PROFILE=example "$@" bash "$ROOT/fwf-dash.sh" 2>&1; }

if [ -z "$DSLUG" ]; then
  printf '  skip dash resolver (unsupported host arch)\n'
else
  # 1. FWF_DASH_BIN wins verbatim — no download, no cache written.
  mkdashbin "$TMP/dexplicit" explicit
  D1="$(drun FWF_DASH_BIN="$TMP/dexplicit" FWF_DASH_CACHE_DIR="$TMP/dc1" FWF_DASH_RELEASE_BASE="file://$DREL")"
  assert_contains "resolver: FWF_DASH_BIN runs verbatim" "$D1" "DASH tag=explicit"
  [ -d "$TMP/dc1" ] && bad "resolver: FWF_DASH_BIN must not populate cache" || ok "resolver: FWF_DASH_BIN writes no cache"

  # 2. FWF_DASH_BIN missing → error, never falls back to build.
  D2="$(drun FWF_DASH_BIN="$TMP/nope" FWF_DASH_CACHE_DIR="$TMP/dc2")"
  assert_contains "resolver: missing FWF_DASH_BIN errors" "$D2" "no runnable binary"
  case "$D2" in *"building from source"*) bad "resolver: missing FWF_DASH_BIN must not build";; *) ok "resolver: missing FWF_DASH_BIN does not build";; esac

  # 3. Cached arch+version binary used, no download.
  mkdir -p "$TMP/dc3"; mkdashbin "$TMP/dc3/fwf-dash-${DVER}-${DSLUG}" cache
  D3="$(drun FWF_DASH_CACHE_DIR="$TMP/dc3" FWF_DASH_RELEASE_BASE="file://$TMP/untouched")"
  assert_contains "resolver: cached binary runs" "$D3" "DASH tag=cache"

  # 4. Download → sha256 verify → cache → run.
  D4="$(drun FWF_DASH_CACHE_DIR="$TMP/dc4" FWF_DASH_RELEASE_BASE="file://$DREL")"
  assert_contains "resolver: verified download runs" "$D4" "DASH tag=downloaded"
  [ -x "$TMP/dc4/$DASSET" ] && ok "resolver: download is cached" || bad "resolver: download not cached"

  # 5. Tampered asset (checksum mismatch) → refuse + fall through to source.
  DREL5="$TMP/dash-release5"; mkdir -p "$DREL5/v$DVER"
  mkdashbin "$DREL5/v$DVER/$DASSET" good
  ( cd "$DREL5/v$DVER" && dsha "$DASSET" > "fwf-dash-${DVER}-checksums.txt" )
  printf 'tampered\n' >> "$DREL5/v$DVER/$DASSET"
  printf '#!/usr/bin/env bash\necho CARGO-RAN >&2\n' > "$DBIN/cargo"; chmod +x "$DBIN/cargo"
  D5="$(drun FWF_DASH_CACHE_DIR="$TMP/dc5" FWF_DASH_CRATE="$DEMPTY" FWF_DASH_RELEASE_BASE="file://$DREL5")"
  assert_contains "resolver: checksum mismatch refused" "$D5" "checksum mismatch"
  assert_contains "resolver: tamper falls through to source build" "$D5" "building from source"
  [ -x "$TMP/dc5/$DASSET" ] && bad "resolver: tampered asset must not be cached" || ok "resolver: tampered asset not cached"

  # 6. No matching asset + cargo present → source build attempted.
  D6="$(drun FWF_DASH_CACHE_DIR="$TMP/dc6" FWF_DASH_CRATE="$DEMPTY" FWF_DASH_RELEASE_BASE="file://$TMP/no-release")"
  assert_contains "resolver: no asset → source build" "$D6" "building from source"
  assert_contains "resolver: cargo actually invoked"  "$D6" "CARGO-RAN"

  # 7. No cargo + no prebuilt → clean die (proves die is defined; #63 latent bug).
  rm -f "$DBIN/cargo"
  D7="$(drun FWF_DASH_CACHE_DIR="$TMP/dc7" FWF_DASH_CRATE="$DEMPTY" FWF_DASH_RELEASE_BASE="file://$TMP/no-release")"
  assert_contains "resolver: helpful die when no cargo" "$D7" "cargo isn't installed"
  case "$D7" in *"command not found"*) bad "resolver: die must be defined (no 'command not found')";; *) ok "resolver: die is defined";; esac

  # 8. FWF_DASH_NO_DOWNLOAD bypasses the download even when an asset exists.
  printf '#!/usr/bin/env bash\necho CARGO-RAN >&2\n' > "$DBIN/cargo"; chmod +x "$DBIN/cargo"
  D8="$(drun FWF_DASH_CACHE_DIR="$TMP/dc8" FWF_DASH_CRATE="$DEMPTY" FWF_DASH_NO_DOWNLOAD=1 FWF_DASH_RELEASE_BASE="file://$DREL")"
  assert_contains "resolver: NO_DOWNLOAD bypasses download" "$D8" "building from source"
  rm -f "$DBIN/cargo"
fi

# --------------------------------------------------------------------------
section "user-testing template (issue #42) — roster + source-blind personas"
UT() { FWF_TEMPLATE=user-testing FWF_UT_APP_URL="http://localhost:3939" FWF_RUN_DIR="$TMP/utrun" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }
assert_contains "templates lists user-testing" "$("$ROOT/fwf" templates)" "user-testing"
# roster: exactly 3 personas + researcher + captain (qa/conductor/gv suppressed)
UT_ROLES="$(UT 'fwf_all_roles')"
assert_eq "roster is 5 roles" "5" "$(printf '%s\n' "$UT_ROLES" | grep -c .)"
assert_eq "roster = personas + researcher + captain" "impl1 impl2 impl3 pm captain" "$(printf '%s' "$UT_ROLES" | tr '\n' ' ' | sed 's/ $//')"
case "$UT_ROLES" in *qa*|*conductor*|*gv*) bad "qa/conductor/gv suppressed from roster";; *) ok "qa/conductor/gv suppressed from roster";; esac
# suppression + worktree-less helpers
UT 'fwf_role_suppressed qa1'       && ok "qa1 suppressed"            || bad "qa1 suppressed"
UT 'fwf_role_suppressed conductor' && ok "conductor suppressed"      || bad "conductor suppressed"
UT 'fwf_role_suppressed gv'        && ok "gv suppressed"             || bad "gv suppressed"
UT 'fwf_role_suppressed impl1'     && bad "persona impl1 NOT suppressed" || ok "persona impl1 NOT suppressed"
UT 'fwf_role_no_worktree impl2'    && ok "persona impl2 is worktree-less"  || bad "persona impl2 is worktree-less"
UT 'fwf_role_no_worktree pm'       && bad "researcher pm keeps a worktree" || ok "researcher pm keeps a worktree"
# persona cwd is a scratch dir under the UT root, never a worktree; pm cwd is its worktree
assert_contains "persona cwd is UT scratch" "$(UT 'fwf_role_cwd impl1')" "/ut/example/impl1"
case "$(UT 'fwf_role_cwd impl1')" in *ex-impl1*) bad "persona cwd must not be a worktree";; *) ok "persona cwd is not a worktree";; esac
assert_contains "researcher cwd IS a worktree" "$(UT 'fwf_role_cwd pm')" "ex-pm"
# identity + per-template session names
assert_eq "user-testing identity + sessions" "PERSONA|RESEARCHER|friends-user-testing-coord|friends-user-testing-build" \
  "$(UT 'echo "$FWF_DISPLAY_IMPL|$FWF_DISPLAY_PM|$COORD_SESSION|$BUILD_SESSION"')"
# default models: personas Sonnet, researcher Opus; env override still wins
assert_contains "persona defaults to sonnet"  "$(UT 'fwf_claude_cmd impl1')" "--model sonnet"
assert_contains "researcher defaults to opus" "$(UT 'fwf_claude_cmd pm')"    "--model opus"
assert_contains "FWF_MODEL_IMPL override wins" "$(FWF_MODEL_IMPL=haiku FWF_TEMPLATE=user-testing FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_claude_cmd impl1")" "--model haiku"

section "user-testing role contracts (issue #42) — rendered prompts"
PER="$(UT 'fwf_render "$(fwf_tmpl_path implementer)" 2')"
assert_contains "persona is source-blind"          "$PER" "STRUCTURALLY SOURCE-BLIND"
assert_contains "persona thinks aloud (EXPECT)"    "$PER" "EXPECT"
assert_contains "persona is banned from asserts"   "$PER" "never write a test file"
assert_contains "persona drives playwright as hands" "$PER" "PLAYWRIGHT"
assert_contains "persona 2 is mobile"              "$PER" "MOBILE viewport"
assert_contains "persona gets the app URL"         "$PER" "http://localhost:3939"
assert_contains "persona writes under the UT root" "$PER" "/ut/example"
case "$PER" in *"CLAIM impl"*) bad "persona must not inherit the impl claim protocol";; *) ok "persona has no impl claim protocol";; esac
RES="$(UT "fwf_render \"\$(fwf_tmpl_path pm)\" ''")"
assert_contains "researcher top-10 budget"         "$RES" "at most TEN"
assert_contains "researcher writes a report doc"   "$RES" "findings-report.md"
assert_contains "researcher keeps a scorecard"     "$RES" "scorecard.md"
assert_contains "researcher does not auto-file (trial one)" "$RES" "do NOT auto-file"
assert_contains "researcher reads tracker post-session"     "$RES" "AFTER PERSONA SESSIONS END"
CAP="$(UT "fwf_render \"\$(fwf_tmpl_path captain)\" ''")"
assert_contains "captain enforces scratch/UAT only" "$CAP" "SCRATCH/UAT"
assert_contains "captain holds ground truth"        "$CAP" "KNOWN-UNFIXED DEFECTS"
assert_contains "captain gates graduation"          "$CAP" "GATE WHAT GRADUATES"

section "user-testing prod-target refusal (issue #42)"
UTG() { FWF_TEMPLATE=user-testing FWF_UT_APP_URL="$1" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; ${2:-} fwf_ut_guard_target"; }
UTG "http://localhost:3939" 2>/dev/null            && ok "loopback target allowed"   || bad "loopback target allowed"
UTG "https://myapp-uat.internal/app" 2>/dev/null   && ok "uat host allowed"           || bad "uat host allowed"
UTG "https://app.example.com" 2>/dev/null          && bad "prod-looking host refused" || ok "prod-looking host refused"
UTG "" 2>/dev/null                                 && bad "empty target refused"       || ok "empty target refused"
UTG "https://app.example.com" "FWF_UT_ALLOW_TARGET=1" 2>/dev/null && ok "human override allows it" || bad "human override allows it"
FWF_TEMPLATE=dev UT_APP_URL="https://app.example.com" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_ut_guard_target" && ok "guard no-ops for other templates" || bad "guard no-ops for other templates"
assert_contains "refusal names the override" "$(FWF_TEMPLATE=user-testing FWF_UT_APP_URL=https://app.example.com FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_ut_guard_target" 2>&1)" "FWF_UT_ALLOW_TARGET=1"
# respawn refuses a suppressed role before any tmux work; recognizes a persona
UTRSP="$(FWF_TEMPLATE=user-testing FWF_SESSION=fwf-selftest-$$ FWF_PROFILE=example "$ROOT/fwf-respawn.sh" conductor 2>&1)" && bad "respawn refuses suppressed conductor" || ok "respawn refuses suppressed conductor"
assert_contains "respawn names the suppression" "$UTRSP" "suppressed"
UTRSP2="$(FWF_TEMPLATE=user-testing FWF_SESSION=fwf-selftest-$$ FWF_PROFILE=example "$ROOT/fwf-respawn.sh" impl1 2>&1)" && bad "respawn persona recognized" || ok "respawn persona recognized"
assert_contains "respawn persona hits session, not usage" "$UTRSP2" "no tmux session"

section "user-testing provisioning (issue #42) — personas get scratch dirs, not worktrees"
UTPD="$TMP/utprov"; mkdir -p "$UTPD"
git init -q --bare "$UTPD/origin.git"
git clone -q "$UTPD/origin.git" "$UTPD/repo" 2>/dev/null
( cd "$UTPD/repo" && git config user.email t@t.co && git config user.name t \
  && echo hi > README && git add -A && git commit -qm init && git branch -M main && git push -q origin main )
cat > "$ROOT/profiles/.__utprov.sh" <<EOF
FWF_REPO="$UTPD/repo"
WT_PREFIX="utp"
WT_BASE="$UTPD/wt"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
UT_APP_URL="http://localhost:3939"
EOF
FWF_TEMPLATE=user-testing FWF_ISSUES=local FWF_RUN_DIR="$UTPD/run" FWF_PROFILE=.__utprov "$ROOT/fwf-provision.sh" >/dev/null 2>&1 \
  && ok "user-testing provision runs" || bad "user-testing provision runs"
[ -d "$UTPD/wt/utp-impl1" ] && bad "persona impl1 has NO worktree" || ok "persona impl1 has no worktree"
[ -d "$UTPD/run/ut/.__utprov/impl1" ] && ok "persona impl1 got a scratch dir" || bad "persona impl1 got a scratch dir"
[ -d "$UTPD/wt/utp-qa1" ]        && bad "qa1 suppressed (no worktree)"        || ok "qa1 suppressed (no worktree)"
[ -d "$UTPD/wt/utp-conductor" ]  && bad "conductor suppressed (no worktree)"  || ok "conductor suppressed (no worktree)"
[ -d "$UTPD/wt/utp-gv" ]         && bad "gv suppressed (no worktree)"         || ok "gv suppressed (no worktree)"
[ -d "$UTPD/wt/utp-pm" ]         && ok "researcher pm has a worktree"         || bad "researcher pm has a worktree"
[ -d "$UTPD/wt/utp-captain" ]    && ok "captain has a worktree"               || bad "captain has a worktree"
rm -f "$ROOT/profiles/.__utprov.sh"

# --------------------------------------------------------------------------
section "user-testing trial-one learnings (issue #42) — browser, per-persona URL, coverage"
# helper: run an expression with the user-testing template + arbitrary inline env
UTE() { FWF_TEMPLATE=user-testing FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }
# per-persona app URL: UT_APP_URL_<id> overrides the shared URL; unset falls back
assert_eq "shared URL fallback" "http://localhost:3939" \
  "$(UTE 'UT_APP_URL=http://localhost:3939 fwf_ut_app_url 1')"
assert_eq "per-persona override wins" "http://localhost:3940" \
  "$(UTE 'UT_APP_URL=http://localhost:3939 UT_APP_URL_2=http://localhost:3940 fwf_ut_app_url 2')"
assert_eq "other persona keeps shared" "http://localhost:3939" \
  "$(UTE 'UT_APP_URL=http://localhost:3939 UT_APP_URL_2=http://localhost:3940 fwf_ut_app_url 1')"
# render substitutes THIS persona's URL into the prompt
assert_contains "persona 2 prompt gets its own URL" \
  "$(UTE 'UT_APP_URL=http://localhost:3939 UT_APP_URL_2=https://p2-uat.test fwf_render "$(fwf_tmpl_path implementer)" 2')" \
  "https://p2-uat.test"
# guard checks per-persona overrides too: a prod override is refused, all-UAT passes
UTE 'UT_APP_URL=http://localhost:3939 UT_APP_URL_3=https://app.example.com fwf_ut_guard_target' 2>/dev/null \
  && bad "guard refuses a prod per-persona override" || ok "guard refuses a prod per-persona override"
UTE 'UT_APP_URL=http://localhost:3939 UT_APP_URL_2=https://x-uat.internal fwf_ut_guard_target' 2>/dev/null \
  && ok "guard passes loopback + per-persona uat" || bad "guard passes loopback + per-persona uat"
# browser knob + setup commands
assert_eq "UT_BROWSER defaults to firefox" "firefox" "$(UTE 'echo "$UT_BROWSER"')"
assert_contains "setup cmds install the browser"   "$(UTE 'fwf_ut_browser_setup_cmds')" "npx playwright install firefox"
assert_contains "setup cmds add the playwright MCP" "$(UTE 'fwf_ut_browser_setup_cmds')" "claude mcp add playwright"
assert_contains "UT_BROWSER flows into setup cmds"  "$(UTE 'UT_BROWSER=chromium fwf_ut_browser_setup_cmds')" "--browser chromium"
# detection reads the CONFIG (~/.claude.json mcpServers), NOT a live `claude mcp
# list` probe — a registered-but-unconnectable MCP must read as PRESENT (the
# false-negative bug). Fixtures: one config WITH the server, one WITHOUT.
printf '{"mcpServers":{"playwright":{"command":"npx"}}}\n' > "$TMP/claude-with.json"
printf '{"mcpServers":{"other":{"command":"x"}}}\n'        > "$TMP/claude-without.json"
# registered → silent, rc 0 — and crucially does NOT depend on the claude binary
# being runnable (CLAUDE_CMD points at a missing bin, proving no live probe)
REG="$(UTE 'CLAUDE_CONFIG='"$TMP"'/claude-with.json CLAUDE_CMD=claude-nope-xyz fwf_ut_browser_preflight' 2>&1)"
assert_eq "registered MCP is silent (no false negative)" "" "$REG"
UTE 'CLAUDE_CONFIG='"$TMP"'/claude-with.json fwf_ut_browser_mcp_registered' && ok "registered detected from config" || bad "registered detected from config"
# not registered → WARNS (fail-open, rc 0) and names the fix
PF="$(UTE 'CLAUDE_CONFIG='"$TMP"'/claude-without.json fwf_ut_browser_preflight' 2>&1)"
UTE 'CLAUDE_CONFIG='"$TMP"'/claude-without.json fwf_ut_browser_preflight' >/dev/null 2>&1 && ok "preflight is fail-open (rc 0)" || bad "preflight is fail-open (rc 0)"
assert_contains "preflight names the setup" "$PF" "npx playwright install firefox"
assert_contains "preflight names the config path" "$PF" "claude-without.json"
UTE 'CLAUDE_CONFIG='"$TMP"'/claude-without.json fwf_ut_browser_mcp_registered' && bad "unregistered must be NO" || ok "unregistered detected from config"
# missing config file → unregistered (warns), never a crash
UTE 'CLAUDE_CONFIG='"$TMP"'/does-not-exist.json fwf_ut_browser_mcp_registered' && bad "missing config = NO" || ok "missing config reads unregistered"
# preflight is a no-op for every other template (no output)
assert_eq "preflight no-ops off-template" "" \
  "$(FWF_TEMPLATE=dev FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; CLAUDE_CONFIG=$TMP/claude-without.json fwf_ut_browser_preflight" 2>&1)"
# coverage beat in the persona prompt; quarantine guidance in the researcher prompt
assert_contains "persona has a coverage beat" "$(UTE 'fwf_render "$(fwf_tmpl_path implementer)" 1')" "COVERAGE BEAT"
assert_contains "persona sweeps nav + shortcuts" "$(UTE 'fwf_render "$(fwf_tmpl_path implementer)" 1')" "KEYBOARD SHORTCUTS"
assert_contains "researcher quarantines bleed" "$(UTE "fwf_render \"\$(fwf_tmpl_path pm)\" ''")" "QUARANTINE"

# --------------------------------------------------------------------------
section "user-testing deep sweep mode (issue #47) — archetype library + FWF_UT_MODE"
# new archetypes present in the library (all 9 are in every rendered prompt)
ILIB="$(UTE 'fwf_render "$(fwf_tmpl_path implementer)" 1')"
assert_contains "archetype 4 power user in library"   "$ILIB" "POWER USER"
assert_contains "archetype 5 slow-network in library" "$ILIB" "SLOW-NETWORK"
assert_contains "archetype 6 returning user in library" "$ILIB" "RETURNING USER"
assert_contains "archetype 7 privacy skeptic in library" "$ILIB" "PRIVACY"
assert_contains "archetype 8 i18n user in library"    "$ILIB" "NON-NATIVE-ENGLISH"
assert_contains "archetype 9 accessibility in library" "$ILIB" "ACCESSIBILITY USER"
# FWF_UT_MODE=deep expands to 9 personas; default stays at 3
assert_eq "deep mode sets FWF_PAIRS=9" "9" \
  "$(FWF_UT_MODE=deep FWF_TEMPLATE=user-testing FWF_UT_APP_URL=http://localhost:3939 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; echo \$FWF_PAIRS")"
assert_eq "default mode keeps FWF_PAIRS=3" "3" \
  "$(FWF_TEMPLATE=user-testing FWF_UT_APP_URL=http://localhost:3939 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; echo \$FWF_PAIRS")"
# explicit FWF_PAIRS still wins over the mode preset
assert_eq "explicit FWF_PAIRS overrides deep mode" "6" \
  "$(FWF_UT_MODE=deep FWF_PAIRS=6 FWF_TEMPLATE=user-testing FWF_UT_APP_URL=http://localhost:3939 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; echo \$FWF_PAIRS")"
# wrap-around guidance present for runs where FWF_PAIRS > 9
assert_contains "wrap-around guidance in library" "$ILIB" "WRAP AROUND"
# count-aware captain/researcher prompts: __UT_PERSONA_COUNT__ / __UT_PERSONA_PANES__
# render to the live roster so they read right for both a quick gate and a deep sweep
CAPQ="$(UTE 'fwf_render "$(fwf_tmpl_path captain)" ""')"
assert_contains "captain reads 3 personas (quick)"  "$CAPQ" "just 3 source-blind"
assert_contains "captain lists the persona panes"   "$CAPQ" "impl1, impl2, impl3"
DEEPR() { FWF_UT_MODE=deep FWF_TEMPLATE=user-testing FWF_UT_APP_URL=http://localhost:3939 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }
assert_contains "captain reads 9 personas (deep)"   "$(DEEPR 'fwf_render "$(fwf_tmpl_path captain)" ""')" "just 9 source-blind"
assert_contains "captain lists impl9 in deep sweep" "$(DEEPR 'fwf_render "$(fwf_tmpl_path captain)" ""')" "impl9"
assert_contains "researcher reads 9 streams (deep)" "$(DEEPR 'fwf_render "$(fwf_tmpl_path pm)" ""')" "9 streams"

# --------------------------------------------------------------------------
# e2e lock (#65): liveness-aware acquire/release, shared by every role (not
# just the conductor). No real processes are killed here — a "dead" holder is
# simulated with a PID number no OS actually hands out, and a "live" holder is
# simulated by stamping OUR OWN pid (so kill -0 on it is trivially true for as
# long as this test script runs) — hermetic, no real tmux/gh/kill touched.
section "e2e lock (#65): liveness-aware acquire/release shared across every role"
E2ERUN="$TMP/e2e65"
cat > "$TMP/e2e-lock-drive.sh" <<'EOSCRIPT'
set -uo pipefail
source "$ROOT_PATH/lib.sh"
case "$1" in
  symmetry)
    fwf_e2e_lock_acquire testrole && echo ACQUIRED
    [ -f "$E2E_LOCK/owner" ] && echo STAMPED
    grep -q '^role=testrole$' "$E2E_LOCK/owner" && echo ROLEOK
    fwf_e2e_lock_release
    [ -d "$E2E_LOCK" ] && echo STILLTHERE || echo RELEASED
    ;;
  dead)
    # pre-stamp with a PID no OS hands out (way past any real pid_max) + an old timestamp
    mkdir -p "$E2E_LOCK"
    printf 'role=zombie\npid=999999999\nhost=%s\nworktree=/nowhere\nacquired=%s\n' \
      "$(hostname)" "$(( $(date +%s) - 9999 ))" > "$E2E_LOCK/owner"
    rc=0; fwf_e2e_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    grep -q '^role=impl9$' "$E2E_LOCK/owner" 2>/dev/null && echo NEWOWNER
    ;;
  live)
    # pre-stamp with OUR OWN pid (this very process — alive for the whole call)
    # and a timestamp already past the (deliberately tiny, for a fast test) stale backstop
    mkdir -p "$E2E_LOCK"
    printf 'role=selfheld\npid=%s\nhost=%s\nworktree=%s\nacquired=%s\n' \
      "$$" "$(hostname)" "$PWD" "$(( $(date +%s) - 9999 ))" > "$E2E_LOCK/owner"
    rc=0; fwf_e2e_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    ;;
esac
EOSCRIPT

SYM_OUT="$(FWF_RUN_DIR="$E2ERUN/sym" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/e2e-lock-drive.sh" symmetry)"
assert_contains "acquire succeeds and returns 0"        "$SYM_OUT" "ACQUIRED"
assert_contains "acquire writes a holder-identity stamp" "$SYM_OUT" "STAMPED"
assert_contains "stamp carries the caller's role label"  "$SYM_OUT" "ROLEOK"
assert_contains "release removes the lock dir"           "$SYM_OUT" "RELEASED"
case "$SYM_OUT" in *STILLTHERE*) bad "release must remove the lock dir";; esac

DEAD_OUT="$(FWF_RUN_DIR="$E2ERUN/dead" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/e2e-lock-drive.sh" dead)"
assert_contains "dead-PID holder is named and broken"    "$DEAD_OUT" "breaking it"
assert_contains "dead-PID lock is re-acquired, not deadlocked" "$DEAD_OUT" "RC=0"
assert_contains "the new stamp overwrites the dead one"  "$DEAD_OUT" "NEWOWNER"

LIVE_OUT="$(FWF_RUN_DIR="$E2ERUN/live" FWF_E2E_LOCK_STALE_SECS=1 FWF_E2E_LOCK_TIMEOUT=2 FWF_E2E_LOCK_POLL=1 \
  FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/e2e-lock-drive.sh" live)"
assert_contains "a blocked wait names the current holder" "$LIVE_OUT" "waiting on the e2e lock (held by selfheld)"
assert_contains "acquire times out rather than hanging"   "$LIVE_OUT" "timed out"
assert_contains "acquire returns non-zero on timeout"     "$LIVE_OUT" "RC=1"
case "$LIVE_OUT" in *"breaking it"*) bad "a LIVE same-host holder must never be broken, even past the age backstop";; *) ok "live holder not broken, even past the age backstop";; esac

# --------------------------------------------------------------------------
# per-role gate single-flight lock (#123 AC1/AC2/AC5): a role that relaunches
# the gate while its OWN prior run is still in flight must NOT stack a second
# — it skips this tick instead. Non-blocking (unlike the e2e lock above): a
# "live" holder here means "skip and report", never "wait". Same hermetic
# simulation style as the e2e lock test — no real gate process is spawned.
section "gate single-flight lock (#123): per-role guard against self-relaunch pileup"
GATERUN="$TMP/gate123"
cat > "$TMP/gate-lock-drive.sh" <<'EOSCRIPT'
set -uo pipefail
source "$ROOT_PATH/lib.sh"
case "$1" in
  symmetry)
    fwf_gate_lock_acquire testrole && echo ACQUIRED
    [ -f "$(fwf_gate_lock_dir testrole)/owner" ] && echo STAMPED
    grep -q '^role=testrole$' "$(fwf_gate_lock_dir testrole)/owner" && echo ROLEOK
    fwf_gate_lock_release testrole
    [ -d "$(fwf_gate_lock_dir testrole)" ] && echo STILLTHERE || echo RELEASED
    ;;
  dead)
    mkdir -p "$(fwf_gate_lock_dir impl9)"
    printf 'role=impl9\npid=999999999\nhost=%s\nacquired=%s\n' \
      "$(hostname)" "$(( $(date +%s) - 9999 ))" > "$(fwf_gate_lock_dir impl9)/owner"
    rc=0; fwf_gate_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    grep -q "^pid=$$" "$(fwf_gate_lock_dir impl9)/owner" 2>/dev/null && echo NEWOWNER
    ;;
  live-in-flight)
    # AC1: a live same-host holder (this process's own pid) mid-run — a
    # second tick must SKIP, never stack a concurrent gate.
    mkdir -p "$(fwf_gate_lock_dir impl9)"
    printf 'role=impl9\npid=%s\nhost=%s\nacquired=%s\n' \
      "$$" "$(hostname)" "$(date +%s)" > "$(fwf_gate_lock_dir impl9)/owner"
    rc=0; fwf_gate_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    ;;
  live-wedged)
    # AC2b: a live same-host holder, but past the max-run ceiling — treated
    # as wedged and reaped (never permanently wedges the role).
    mkdir -p "$(fwf_gate_lock_dir impl9)"
    printf 'role=impl9\npid=%s\nhost=%s\nacquired=%s\n' \
      "$$" "$(hostname)" "$(( $(date +%s) - 9999 ))" > "$(fwf_gate_lock_dir impl9)/owner"
    rc=0; fwf_gate_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    ;;
  indeterminate)
    # AC2a: fail-closed — a stamp with no parseable host/pid must skip, not launch.
    mkdir -p "$(fwf_gate_lock_dir impl9)"
    printf 'garbage\n' > "$(fwf_gate_lock_dir impl9)/owner"
    rc=0; fwf_gate_lock_acquire impl9 2>&1 || rc=$?
    echo "RC=$rc"
    ;;
  race-contestant)
    # QA adversarial check (issue #119): the prior tests simulate an
    # already-in-flight lock sequentially (mkdir it first, THEN call
    # acquire) — that exercises the liveness-check branch but never the
    # mkdir-itself race two ticks firing at THE SAME INSTANT would hit.
    # This contestant races a sibling process for the SAME never-before-held
    # role, holding the lock briefly if it wins, so a real double-mkdir race
    # is exercised, not just simulated post-hoc state.
    rc=0; fwf_gate_lock_acquire raceRole 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
      echo "WON pid=$$"
      sleep 0.3
      fwf_gate_lock_release raceRole
    else
      echo "LOST pid=$$ rc=$rc"
    fi
    ;;
esac
EOSCRIPT

GSYM_OUT="$(FWF_RUN_DIR="$GATERUN/sym" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" symmetry)"
assert_contains "acquire succeeds and returns 0"        "$GSYM_OUT" "ACQUIRED"
assert_contains "acquire writes a holder-identity stamp" "$GSYM_OUT" "STAMPED"
assert_contains "stamp carries the caller's role label"  "$GSYM_OUT" "ROLEOK"
assert_contains "release removes the lock dir"           "$GSYM_OUT" "RELEASED"
case "$GSYM_OUT" in *STILLTHERE*) bad "release must remove the lock dir";; esac

GDEAD_OUT="$(FWF_RUN_DIR="$GATERUN/dead" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" dead)"
assert_contains "dead-PID holder is named an anomaly and reaped" "$GDEAD_OUT" "ANOMALY"
assert_contains "dead-PID lock is re-acquired, not permanently wedged" "$GDEAD_OUT" "RC=0"
assert_contains "the new stamp overwrites the dead one"  "$GDEAD_OUT" "NEWOWNER"

section "QA adversarial check (#119): a REAL simultaneous race for a never-before-held lock is still atomic (not just the sequential simulated states above)"
RACERUN="$TMP/gate123-race"
FWF_RUN_DIR="$RACERUN" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" race-contestant > "$TMP/race-a.out" 2>&1 &
RACE_A_PID=$!
FWF_RUN_DIR="$RACERUN" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" race-contestant > "$TMP/race-b.out" 2>&1 &
RACE_B_PID=$!
wait "$RACE_A_PID"; wait "$RACE_B_PID"
RACE_COMBINED="$(cat "$TMP/race-a.out" "$TMP/race-b.out")"
RACE_WON_COUNT="$(printf '%s\n' "$RACE_COMBINED" | grep -c '^WON ')"
RACE_LOST_COUNT="$(printf '%s\n' "$RACE_COMBINED" | grep -c '^LOST ')"
assert_eq "exactly one contestant wins a truly simultaneous race" "1" "$RACE_WON_COUNT"
assert_eq "exactly one contestant loses (skips, never stacks)"    "1" "$RACE_LOST_COUNT"

section "gate single-flight lock AC1: a live in-flight gate is never double-launched"
GLIVE_OUT="$(FWF_RUN_DIR="$GATERUN/live" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" live-in-flight)"
assert_contains "second tick reports the prior gate still in flight" "$GLIVE_OUT" "already in flight"
assert_contains "second tick skips rather than launching (RC=1)"     "$GLIVE_OUT" "RC=1"
case "$GLIVE_OUT" in *ANOMALY*) bad "a healthy in-flight gate must not be reaped as an anomaly";; *) ok "healthy in-flight gate left alone (not reaped)";; esac

section "gate single-flight lock AC2b: a wedged (past-ceiling) live holder is reaped, not a permanent block"
GWEDGE_OUT="$(FWF_RUN_DIR="$GATERUN/wedge" FWF_GATE_LOCK_MAX_RUN_SECS=1 FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" live-wedged)"
assert_contains "past-ceiling holder is flagged as an anomaly" "$GWEDGE_OUT" "ANOMALY"
assert_contains "past-ceiling holder is reaped, not wedged forever (RC=0)" "$GWEDGE_OUT" "RC=0"
assert_contains "reap names the max-run ceiling reason" "$GWEDGE_OUT" "max-run ceiling"

section "gate single-flight lock AC2a: indeterminate liveness fails CLOSED (skip, never stack)"
GIND_OUT="$(FWF_RUN_DIR="$GATERUN/ind" FWF_PROFILE=example ROOT_PATH="$ROOT" bash "$TMP/gate-lock-drive.sh" indeterminate)"
assert_contains "indeterminate state is refused rather than launched (RC=1)" "$GIND_OUT" "RC=1"
assert_contains "fail-closed reasoning is logged" "$GIND_OUT" "failing closed"

# --------------------------------------------------------------------------
# fwf gate hermeticity (#123 AC3/AC4): two overlapping e2e-class runs from
# DIFFERENT roles must not mutually stall on a shared fixed resource — RED
# against today's unwrapped/direct invocation (both would collide), GREEN
# once routed through `fwf gate --e2e` (the existing issue #65 floor-wide
# lock serializes them instead of letting them collide). The shared
# resource is a fixed marker FILE, not a real socket, so this stays
# hermetic/portable like the rest of the suite — same "everyone touches the
# one fixed thing" shape a fixed TCP port has, without opening real sockets.
section "fwf gate hermeticity (#123 AC3/AC4): overlapping e2e-class runs on a shared fixed resource"
FIXEDRUN="$TMP/fixedport123"
mkdir -p "$FIXEDRUN"
FIXED_MARKER="$FIXEDRUN/held"

cat > "$TMP/fixed-resource-harness.sh" <<'EOSCRIPT'
set -uo pipefail
marker="$1"; hold="$2"; wait_budget="$3"
deadline=$(( $(date +%s) + wait_budget ))
while [ -e "$marker" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT waiting for the fixed resource"; exit 1; }
  sleep 0.2
done
: > "$marker"
sleep "$hold"
rm -f "$marker"
echo "DONE"
EOSCRIPT

# RED (today, unwrapped): both invocations touch the SAME fixed marker
# directly with no coordination. The second's wait budget (2s) is
# deliberately shorter than the first's hold (4s), so it deterministically
# times out rather than getting a fair turn — exactly the "collide on the
# fixed resource" failure mode a real fixed-port harness hits.
rm -f "$FIXED_MARKER"
bash "$TMP/fixed-resource-harness.sh" "$FIXED_MARKER" 4 10   > "$TMP/red-a.out" 2>&1 & RED_A_PID=$!
sleep 0.5
bash "$TMP/fixed-resource-harness.sh" "$FIXED_MARKER" 4 2 > "$TMP/red-b.out" 2>&1 & RED_B_PID=$!
wait "$RED_A_PID"; RED_A_RC=$?
wait "$RED_B_PID"; RED_B_RC=$?
assert_eq "RED (unwrapped): first invocation completes" "0" "$RED_A_RC"
[ "$RED_B_RC" != 0 ] && ok "RED (unwrapped): second invocation fails rather than silently succeeding" \
  || bad "RED (unwrapped): second invocation should have failed on the shared fixed resource"
assert_contains "RED (unwrapped): second invocation times out on the shared fixed resource" "$(cat "$TMP/red-b.out")" "TIMEOUT"

# GREEN (through fwf gate --e2e): the SAME two invocations (different roles),
# each routed through the shared guarded launcher — the floor-wide e2e lock
# (issue #65) serializes them, so the second waits for the first to finish
# instead of colliding on the still-held resource. Both complete.
rm -f "$FIXED_MARKER"
GATEHRUN="$TMP/gate-hermetic"
run_gated() { # $1=role $2=hold $3=wait_budget $4=outfile
  FWF_RUN_DIR="$GATEHRUN" FWF_PROFILE=example FWF_E2E_LOCK_POLL=1 FWF_E2E_LOCK_TIMEOUT=15 \
    "$ROOT/fwf-gate.sh" "$1" --e2e -- bash "$TMP/fixed-resource-harness.sh" "$FIXED_MARKER" "$2" "$3" > "$4" 2>&1
}
run_gated hermetic-a 4 10  "$TMP/green-a.out" & GREEN_A_PID=$!
sleep 0.5
run_gated hermetic-b 4 2 "$TMP/green-b.out" & GREEN_B_PID=$!
wait "$GREEN_A_PID"; GREEN_A_RC=$?
wait "$GREEN_B_PID"; GREEN_B_RC=$?
assert_eq "GREEN (through fwf gate --e2e): first invocation completes"      "0" "$GREEN_A_RC"
assert_eq "GREEN (through fwf gate --e2e): second invocation ALSO completes (no longer times out)" "0" "$GREEN_B_RC"
assert_contains "GREEN: second invocation's own output shows it actually ran, not skipped" "$(cat "$TMP/green-b.out")" "DONE"

# --------------------------------------------------------------------------
# fwf pr-review-state (#82): the shared-account qa<->impl handshake. Every
# role authenticates as one GitHub user, so the formal review-decision API is
# permanently empty here (#81's deadlock) — qa signals via a plain QA-* comment
# instead. Drives the REAL helper (never a decoy grep) with stubbed
# prs_comments/prs_meta fixtures, pinning: column-0-only sentinels, last-wins,
# the busy-loop guard, amend/rebase robustness, and the self-trigger guard.
PRS="$ROOT/fwf-pr-review-state.sh"
prs_state() { # $1=comments-json  $2=state  $3=lastCommitAt
  FWF_PROFILE=example bash -c "
    source '$PRS'
    prs_comments() { printf '%s' '$1'; }
    prs_meta() { printf '%s' '{\"state\":\"$2\",\"lastCommitAt\":\"$3\"}'; }
    main 84"
}

section "pr-review-state (#82): plain QA-CHANGES-REQUESTED comment is recognized (RED on the old empty-review-decision behavior)"
assert_eq "no IMPL-ADDRESSED yet, newer than last push -> CHANGES_REQUESTED + repro branch" \
  "CHANGES_REQUESTED qa1/repro-84" \
  "$(prs_state '[{"body":"QA-CHANGES-REQUESTED: #84\n\nsee qa1/repro-84","createdAt":"2026-07-10T16:00:00Z"}]' OPEN 2026-07-10T15:00:00Z)"

section "pr-review-state (#82): busy-loop guard — impl's IMPL-ADDRESSED idles the NEXT cycle instead of re-fixing"
assert_eq "IMPL-ADDRESSED newer than the QA-CHANGES-REQUESTED comment -> AWAITING_REVIEW" \
  "AWAITING_REVIEW" \
  "$(prs_state '[{"body":"QA-CHANGES-REQUESTED: #84\n\nsee qa1/repro-84","createdAt":"2026-07-10T16:00:00Z"},{"body":"IMPL-ADDRESSED: #84 abc123","createdAt":"2026-07-10T16:05:00Z"}]' OPEN 2026-07-10T16:04:00Z)"

section "pr-review-state (#82): amend/rebase robustness — committedDate predating the push must not misread a real response as unanswered"
assert_eq "IMPL-ADDRESSED comment (not the amended commit's committedDate) is the primary addressed signal" \
  "AWAITING_REVIEW" \
  "$(prs_state '[{"body":"QA-CHANGES-REQUESTED: #84","createdAt":"2026-07-10T16:00:00Z"},{"body":"IMPL-ADDRESSED: #84 def456","createdAt":"2026-07-10T16:10:00Z"}]' OPEN 2026-07-10T15:30:00Z)"

section "pr-review-state (#82): self-trigger guard — a QA-* string not at column 0 never counts"
assert_eq "IMPL-ADDRESSED comment quoting QA-CHANGES-REQUESTED mid-line stays AWAITING_REVIEW" \
  "AWAITING_REVIEW" \
  "$(prs_state '[{"body":"IMPL-ADDRESSED: #84 abc\n\nsaw your QA-CHANGES-REQUESTED and fixed it","createdAt":"2026-07-10T16:00:00Z"}]' OPEN 2026-07-10T15:00:00Z)"

section "pr-review-state (#82): last-sentinel-wins + merged/closed"
assert_eq "a later QA-APPROVED supersedes an earlier QA-CHANGES-REQUESTED" \
  "APPROVED" \
  "$(prs_state '[{"body":"QA-CHANGES-REQUESTED: #84","createdAt":"2026-07-10T16:00:00Z"},{"body":"IMPL-ADDRESSED: #84 abc","createdAt":"2026-07-10T16:05:00Z"},{"body":"QA-APPROVED: #84","createdAt":"2026-07-10T16:10:00Z"}]' OPEN 2026-07-10T16:04:00Z)"
assert_eq "a merged PR resolves to APPROVED regardless of thread contents" \
  "APPROVED" "$(prs_state '[]' MERGED 2026-07-10T15:00:00Z)"

section "pr-review-state (#82): no request / bad input"
assert_eq "no QA-* sentinel at all -> AWAITING_REVIEW" "AWAITING_REVIEW" "$(prs_state '[]' OPEN 2026-07-10T15:00:00Z)"
assert_eq "non-numeric PR arg -> NONE" "NONE" "$(FWF_PROFILE=example bash -c "source '$PRS'; main abc")"

# --------------------------------------------------------------------------
# fwf flag-captain (#113): a persisted, tracker-native "needs-captain" flag
# any role raises on an issue/PR, that the captain's per-tick sweep picks up
# reliably (the 2026-07-14 impl1 incident this closes). Local-backend tests
# drive the REAL helper end-to-end over a real fwf-issues.sh store (identical
# code path to production); gh-backend tests override the gh_ boundary only.
FC="$ROOT/fwf-flag-captain.sh"
FCRUN="$TMP/flagcaptain-local"
FCISS() { FWF_RUN_DIR="$FCRUN" FWF_PROFILE=example "$ROOT/fwf-issues.sh" "$@"; }
FCL()   { FWF_RUN_DIR="$FCRUN" FWF_PROFILE=example FWF_ISSUES=local "$FC" "$@"; }

section "fwf flag-captain (#113): local backend — raise, sweep, clear round-trip"
FCISS create --title "Base missing provenance primitive" >/dev/null
RAISE_OUT="$(FCL 1 --role impl1 --reason "blocked: base missing #104 provenance primitive")"
assert_contains "raise confirms" "$RAISE_OUT" "flagged: NEEDS-CAPTAIN [impl1] blocked: base missing #104 provenance primitive"
assert_contains "raise applies the label" "$(FCISS list --label needs-captain)" "LI-1"
SWEEP1="$(FCL sweep)"
assert_contains "sweep shows the issue"  "$SWEEP1" "LI-1"
assert_contains "sweep shows the role"   "$SWEEP1" "[impl1]"
assert_contains "sweep shows the reason" "$SWEEP1" "blocked: base missing #104 provenance primitive"

section "fwf flag-captain (#113): multiple raisers append, never overwrite"
FCL 1 --role qa1 --reason "also seeing this on review" >/dev/null
SWEEP2="$(FCL sweep)"
assert_contains "first raiser's row survives a second raise" "$SWEEP2" "[impl1]"
assert_contains "second raiser's row is appended"            "$SWEEP2" "[qa1]"
assert_eq "two active rows for LI-1, not a dedup to one" "2" "$(printf '%s\n' "$SWEEP2" | grep -c '^LI-1'"$(printf '\t')")"

section "fwf flag-captain (#113): clear ends the flag; a bare re-raise after clear is active again"
CLEAR_OUT="$(FCL 1 --clear --note "unblocked, rebased onto staging")"
assert_contains "clear confirms" "$CLEAR_OUT" "needs-captain cleared"
case "$(FCISS list --label needs-captain)" in *LI-1*) bad "clear removes the label" "still listed";; *) ok "clear removes the label";; esac
assert_eq "cleared item has no open flags" "no needs-captain flags open" "$(FCL sweep)"
assert_contains "clear is recorded as a comment" "$(FCISS view 1 --comments)" "NEEDS-CAPTAIN-CLEARED: unblocked, rebased onto staging"
FCL 1 --role impl1 --reason "flaked again on the same base" >/dev/null
POSTCLEAR="$(FCL sweep)"
assert_contains "a raise AFTER a clear is active again" "$POSTCLEAR" "flaked again on the same base"
case "$POSTCLEAR" in *"blocked: base missing #104"*) bad "the pre-clear reason must not resurrect" "$POSTCLEAR";; *) ok "the pre-clear reason stays inactive (only post-clear raises count)";; esac

section "fwf flag-captain (#113): a labeled item never silently drops a missing role/reason"
FCISS create --title "Silent stub" >/dev/null
FCISS edit 2 --add-label needs-captain >/dev/null   # label with zero NEEDS-CAPTAIN: comments
assert_contains "bare label with no comment still surfaces" "$(FCL sweep)" "no reason given"
FCISS comment 2 --body "NEEDS-CAPTAIN: unattributed reason, no role tag" >/dev/null
assert_contains "a NEEDS-CAPTAIN: line with no [role] tag surfaces as role unstated" "$(FCL sweep)" "role unstated"

section "fwf flag-captain (#113): usage errors"
RC=0; FCL 3 --role impl1 2>/dev/null || RC=$?
[ "$RC" -ne 0 ] && ok "raise without --reason fails closed" || bad "raise without --reason should fail"
RC=0; FCL 3 --reason "x" 2>/dev/null || RC=$?
[ "$RC" -ne 0 ] && ok "raise without --role fails closed" || bad "raise without --role should fail"

section "fwf flag-captain (#113): gh backend — label pre-provisioning (AC7) and PR-vs-issue routing"
FCG() { # $1... args; overrides gh_ to log calls instead of hitting the network
  # arg0 below is deliberately NOT "$FC" — fwf-flag-captain.sh's own
  # "if BASH_SOURCE[0] = 0" direct-execution guard would otherwise fire
  # DURING the `source` (BASH_SOURCE[0] and $0 both equal $FC's path),
  # running the real (network-hitting) main() before gh_/gh_kind are
  # stubbed below. A harmless name here keeps this test hermetic.
  FWF_PROFILE=example bash -c "
    source '$FC'
    gh_kind() { [ \"\$1\" = 9 ] && echo pr || echo issue; }
    gh_() { printf '%s\n' \"gh \$*\" >> '$TMP/gh-calls.log'; }
    main \"\$@\"
  " fcg-test-harness "$@"
}
rm -f "$TMP/gh-calls.log"
FCG 5 --role gv --reason "spec won't converge, needs a human call" >/dev/null
GHLOG="$(cat "$TMP/gh-calls.log")"
assert_contains "gh raise ensures the label exists first" "$GHLOG" "gh label create needs-captain"
assert_contains "gh raise adds the label to the issue"    "$GHLOG" "gh issue edit 5 --add-label needs-captain"
assert_contains "gh raise posts the NEEDS-CAPTAIN comment" "$GHLOG" "gh issue comment 5 --body NEEDS-CAPTAIN: [gv] spec won't converge, needs a human call"
LABEL_LINE="$(printf '%s\n' "$GHLOG" | grep -n "label create" | head -1 | cut -d: -f1)"
ADDLABEL_LINE="$(printf '%s\n' "$GHLOG" | grep -n "add-label" | head -1 | cut -d: -f1)"
[ "$LABEL_LINE" -lt "$ADDLABEL_LINE" ] && ok "label create-if-absent runs BEFORE add-label (AC7 order)" || bad "label must be ensured before it's applied"
rm -f "$TMP/gh-calls.log"
FCG 9 --role qa2 --reason "PR needs a rebase call" >/dev/null
assert_contains "PR number routes through 'gh pr', not 'gh issue'" "$(cat "$TMP/gh-calls.log")" "gh pr edit 9 --add-label needs-captain"

# --------------------------------------------------------------------------
# fwf usage aggregator (#95, Ticket A of #70): per-role token/$ usage summed
# from FAKE Claude Code project dirs — never touches the real
# ~/.claude/projects (FWF_CLAUDE_PROJECTS_DIR override) or the real run dir
# (FWF_RUN_DIR override).
UD="$ROOT/fwf-usage-data.sh"
UT="$TMP/usage"; mkdir -p "$UT/wt" "$UT/claude-projects"
cat > "$ROOT/profiles/.__usage.sh" <<EOF
FWF_REPO="$UT/repo"; WT_PREFIX="ut"; WT_BASE="$UT/wt"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
EOF
# impl1's cwd -> project-dir slug, replicating fwf_role_cwd's wt_dir() shape
# ($WT_BASE/$WT_PREFIX-impl1) and Claude Code's own slugification (every '/'
# and '.' -> '-' — confirmed against this repo's own ~/.claude/projects/*).
UCWD="$UT/wt/ut-impl1"
USLUG="${UCWD//\//-}"; USLUG="${USLUG//./-}"
UPROJ="$UT/claude-projects/$USLUG"
usage_run() { FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 "$UD" 2>&1; }
usage_role() { usage_run | jq -c '.roles[] | select(.role=="impl1")'; }

section "fwf usage (#95): missing project dir -> UNKNOWN, never \$0/blank"
assert_eq "no dir yet -> state unknown" "unknown" "$(usage_role | jq -r '.state')"
assert_eq "unknown -> cost_usd is null, not 0" "null" "$(usage_role | jq -c '.cost_usd')"

section "fwf usage (#95): sum-across-all-files (compaction: multiple session files)"
mkdir -p "$UPROJ"
printf '%s\n%s\n%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":10,"output_tokens":20}}}' \
  '{"type":"user","message":{}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":30,"output_tokens":40}}}' \
  > "$UPROJ/sessA.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}' \
  > "$UPROJ/sessB.jsonl"
R1="$(usage_role)"
assert_eq "state is fresh once readable" "fresh" "$(printf '%s' "$R1" | jq -r '.state')"
assert_eq "input summed across BOTH files (not just newest)" "310" "$(printf '%s' "$R1" | jq -r '.tokens.input')"
assert_eq "cache_creation summed"  "50" "$(printf '%s' "$R1" | jq -r '.tokens.cache_creation')"
assert_eq "cache_read summed"      "40" "$(printf '%s' "$R1" | jq -r '.tokens.cache_read')"
assert_eq "output summed"          "65" "$(printf '%s' "$R1" | jq -r '.tokens.output')"
assert_eq "newest-file-only counting would under-report (RED if it did)" "310" \
  "$(printf '%s' "$R1" | jq -r '.tokens.input')"   # 310 only reachable by summing BOTH files; sessB alone is 10

section "fwf usage (#95): idempotent — re-running yields the same total (no double-count)"
R2="$(usage_role)"
assert_eq "re-run: same input total"          "$(printf '%s' "$R1" | jq -r '.tokens.input')" "$(printf '%s' "$R2" | jq -r '.tokens.input')"
assert_eq "re-run: same output total"         "$(printf '%s' "$R1" | jq -r '.tokens.output')" "$(printf '%s' "$R2" | jq -r '.tokens.output')"

section "fwf usage (#95): efficiency — an already-summed file is not fully re-read (byte-offset cache)"
# In-place, SAME-LENGTH poison of the already-cached prefix (100/200 -> 999,
# same digit count so the file's byte length — and thus the cached offset —
# doesn't shift). If the aggregator ever re-summed from byte 0 instead of the
# cached offset, this poisoned prefix would inflate the total; if it truly
# only reads new bytes, poisoning already-read history has NO effect.
OLDINPUT="$(printf '%s' "$R1" | jq -r '.tokens.input')"
content="$(cat "$UPROJ/sessA.jsonl")"
content="${content//:100,/:999,}"
content="${content//:200,/:999,}"
printf '%s\n' "$content" > "$UPROJ/sessA.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' >> "$UPROJ/sessA.jsonl"
R3="$(usage_role)"
assert_eq "only the NEW appended line's tokens are added (poisoned history had zero effect)" \
  "$((OLDINPUT + 7))" "$(printf '%s' "$R3" | jq -r '.tokens.input')"
CACHEFILE="$UT/run/state/.__usage/usage-cache/impl1.json"
assert_eq "cached offset for sessA equals its new (grown) size" "$(wc -c <"$UPROJ/sessA.jsonl" | tr -d ' ')" \
  "$(jq -r '.files["sessA.jsonl"]' "$CACHEFILE")"

section "fwf usage (#95): model/\$ mapping"
assert_eq "known model -> expected \$ from the price table (310 in @ \$2.00/MTok + 50 cache-write @ \$2.50 + 40 cache-read @ \$0.20 + 65 out @ \$10.00, /1e6)" \
  "0.001403" "$(printf '%s' "$R1" | jq -r '.cost_usd')"
UD2CWD="$UT/wt/ut-impl2"; USLUG2="${UD2CWD//\//-}"; USLUG2="${USLUG2//./-}"
UNKNOWN_MODEL_PROJ="$UT/claude-projects/$USLUG2"
mkdir -p "$UNKNOWN_MODEL_PROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-totally-unknown","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$UNKNOWN_MODEL_PROJ/s.jsonl"
UNKMODEL="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run2" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=2 "$UD" | jq -c '.roles[] | select(.role=="impl2")')"
assert_eq "unpriced model -> cost_usd is null, never a wrong \$0" "null" "$(printf '%s' "$UNKMODEL" | jq -c '.cost_usd')"
assert_eq "unpriced model's tokens are still shown (not hidden)" "100" "$(printf '%s' "$UNKMODEL" | jq -r '.tokens.input')"

section "fwf usage (#95): proxy caveat is present in the payload"
assert_contains "caveat names this as an estimate, not real account usage" "$(usage_run)" "not your account's actual rolling-window usage"

section "fwf usage (#95): unreadable after a good read -> STALE with last-good numbers, not frozen/blank"
rm -rf "$UPROJ"
R4="$(usage_role)"
assert_eq "dir removed -> state stale (not unknown — we HAD a good read)" "stale" "$(printf '%s' "$R4" | jq -r '.state')"
assert_eq "stale keeps the last-good totals" "317" "$(printf '%s' "$R4" | jq -r '.tokens.input')"

section "fwf usage (#95): CLI wiring — 'fwf usage' dispatches to fwf-usage.sh and renders the report"
CLIOUT="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 "$ROOT/fwf" usage 2>&1)"
assert_contains "help mentions the usage command" "$("$ROOT/fwf" help)" "Per-role token usage"
assert_contains "prints the profile"      "$CLIOUT" "profile .__usage"
assert_contains "prints the impl1 row"    "$CLIOUT" "impl1"
assert_contains "prints a TOTAL row"      "$CLIOUT" "TOTAL"
assert_contains "prints the proxy caveat" "$CLIOUT" "not your account's actual rolling-window usage"
assert_contains "STALE role renders the warning treatment, not a bare number" "$CLIOUT" "STALE"
case "$CLIOUT" in *'$0.0000'*) bad "no role should render a false \$0.0000";; *) ok "no false \$0.0000 anywhere in the report";; esac
STRAY="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" "$ROOT/fwf" usage bogus 2>&1)" && bad "usage rejects a stray argument" || ok "usage rejects a stray argument"
assert_contains "stray-argument error is clear" "$STRAY" "unknown argument"

section "fwf usage (#96/#108): budget-enforcement ARMED/NOT ARMED surface (GV-signoff residual-risk fix) + this-run-vs-cumulative"
NOBUDGET="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 "$ROOT/fwf" usage 2>&1)"
assert_contains "no budget configured -> NOT ARMED" "$NOBUDGET" "budget enforcement: NOT ARMED"
assert_contains "no budget -> hold state none" "$NOBUDGET" "hold state: none"

UNARMED="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$ROOT/fwf" usage 2>&1)"
assert_contains "budget set but writer not running -> NOT ARMED (visibly, not silently, off)" "$UNARMED" "budget enforcement: NOT ARMED"
assert_contains "unarmed message tells the operator how to fix it" "$UNARMED" "fwf up"

UNARMEDUSD="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 FWF_BUDGET_USD=5 "$ROOT/fwf" usage 2>&1)"
assert_contains "--budget-usd set but writer not running -> NOT ARMED" "$UNARMEDUSD" "budget enforcement: NOT ARMED"
assert_contains "unarmed \$ message names FWF_BUDGET_USD" "$UNARMEDUSD" "FWF_BUDGET_USD=5"

env FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_start"
ARMED="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$ROOT/fwf" usage 2>&1)"
assert_contains "writer running for this profile -> ARMED (unchanged wording, back-compat)" "$ARMED" "budget enforcement: ARMED (ceiling 1000 tokens)"
assert_contains "this-run-vs-cumulative line appears once a baseline exists" "$ARMED" "this run:"
assert_contains "this-run line names cumulative too" "$ARMED" "cumulative:"

# Stop the background writer before hand-editing the hold file — otherwise its
# next tick (real usage data from these fixtures) races the manual overwrite
# below and can clobber it before "fwf usage" ever reads it.
env FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_stop"
printf 'HOLD — 1200 tokens spent this run (of 1200 cumulative; includes cache-read), budget is 1000 — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold\n' > "$UT/run/BUDGET_HOLD"
HELDOUT="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$ROOT/fwf" usage 2>&1)"
assert_contains "usage report surfaces the current hold state verbatim" "$HELDOUT" "hold state: HOLD — 1200 tokens spent this run"

CLEAROUT="$(FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 "$ROOT/fwf" usage --clear-hold 2>&1)"
assert_contains "--clear-hold confirms" "$CLEAROUT" "cleared"
[ -f "$UT/run/BUDGET_HOLD" ] && bad "--clear-hold removes the hold file" || ok "--clear-hold removes the hold file"

env FWF_PROFILE=.__usage FWF_RUN_DIR="$UT/run" FWF_CLAUDE_PROJECTS_DIR="$UT/claude-projects" FWF_PAIRS=1 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_stop"

rm -f "$ROOT/profiles/.__usage.sh"

# --------------------------------------------------------------------------
section "token-budget unit disambiguation (issue #108, AC3): both ceilings set -> rejected at source time"
env FWF_TOKEN_BUDGET=1000 FWF_BUDGET_USD=5 FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 \
  && bad "FWF_TOKEN_BUDGET + FWF_BUDGET_USD both set rejected" || ok "FWF_TOKEN_BUDGET + FWF_BUDGET_USD both set rejected"

section "fwf --help / help (#108 AC10): documents --budget-usd, the poll-interval guarantee, and the price-table coupling"
HELPTXT="$("$ROOT/fwf" help)"
assert_contains "--help documents --budget-usd" "$HELPTXT" "budget-usd"
assert_contains "--help states raw --token-budget counts cache-read" "$HELPTXT" "cache-read tokens"
assert_contains "--help states the poll-interval (not instant) guarantee" "$HELPTXT" "FWF_BUDGET_CHECK_INTERVAL"
assert_contains "--help names the price-table coupling for \$ enforcement" "$HELPTXT" "price table"

section "fwf-respawn.sh (issue #108 AC7): never touches the token-budget arming path — a respawn cannot reset the baseline"
case "$(cat "$ROOT/fwf-respawn.sh")" in
  *fwf_budget_writer_start*|*fwf_budget_baseline*) bad "fwf-respawn.sh must not call the budget-arming path" ;;
  *) ok "fwf-respawn.sh never calls fwf_budget_writer_start/fwf_budget_baseline_* (same-run recovery, not a new run)" ;;
esac

section "fwf-down.sh (issue #108 AC5): a full teardown clears the run-start baseline; --floor-only preserves it"
FD108ENV="FWF_PROFILE=example FWF_SESSION=fwf-selftest-108-$$ FWF_MIN_FREE_GB=0"
FD108RUN="$TMP/run108down"; mkdir -p "$FD108RUN/state/example"
FD108BASE="$FD108RUN/state/example/budget-baseline.json"

printf '{"tokens_total":100,"cost_usd":1}' > "$FD108BASE"
env $FD108ENV FWF_RUN_DIR="$FD108RUN" "$ROOT/fwf-down.sh" --floor-only >/dev/null 2>&1
[ -f "$FD108BASE" ] && ok "AC5: --floor-only down preserves the baseline (same run)" \
  || bad "AC5: --floor-only down preserves the baseline (same run)"

env $FD108ENV FWF_RUN_DIR="$FD108RUN" "$ROOT/fwf-down.sh" >/dev/null 2>&1
[ -f "$FD108BASE" ] && bad "AC5: a full 'fwf down' must clear the baseline (next full 'fwf up' gets a fresh one)" \
  || ok "AC5: a full 'fwf down' clears the baseline"

# --------------------------------------------------------------------------
section "fwf-budget-check.sh (#96, Ticket B of #70; #108 delta+\$ enforcement): the WRITER — hermetic, isolated fixture"
BC="$ROOT/fwf-budget-check.sh"
BT="$TMP/budget"; mkdir -p "$BT/wt" "$BT/claude-projects"
cat > "$ROOT/profiles/.__budget.sh" <<EOF
FWF_REPO="$BT/repo"; WT_PREFIX="bt"; WT_BASE="$BT/wt"
STAGING_BRANCH=staging; INTEGRATION_BRANCH=integration; DEFAULT_BRANCH=main
GATE_CMD=true; BUILD_CMD=true; E2E_CMD=true; E2E_SETUP_CMD=""; DEV_UI_HINT=""
EOF
BCWD="$BT/wt/bt-impl1"; BSLUG="${BCWD//\//-}"; BSLUG="${BSLUG//./-}"
BPROJ="$BT/claude-projects/$BSLUG"
budget_run() { # $1=FWF_TOKEN_BUDGET (may be empty) $2=extra env (may be empty)
  env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" \
    FWF_PAIRS=1 FWF_TOKEN_BUDGET="${1:-}" ${2:-} "$BC"
}
hold_file() { cat "$BT/run/BUDGET_HOLD" 2>/dev/null || true; }
# A budget is only ever enforced against a run-start baseline (#108) — this
# snapshots one (usually at 0, matching a fresh `fwf up`) into a given run
# dir, mirroring what fwf_budget_writer_start does on a genuinely fresh arm.
baseline_ensure() { # $1=FWF_RUN_DIR
  env FWF_PROFILE=.__budget FWF_RUN_DIR="$1" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 \
    bash -c "source '$ROOT/lib.sh'; fwf_budget_baseline_ensure"
}
baseline_file() { echo "$1/state/.__budget/budget-baseline.json"; }

section "fwf-budget-check.sh: bootstrap — a role that has NEVER produced usage is 0 tokens, not a hold"
baseline_ensure "$BT/run"
budget_run 1000
[ -z "$(hold_file)" ] && ok "no hold at t=0 (unknown-with-no-prior-data is not a fail-closed trigger)" \
  || bad "no hold at t=0" "$(hold_file)"

section "fwf-budget-check.sh: over budget -> HOLD (delta since baseline; #108 AC1/AC9)"
mkdir -p "$BPROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":600,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}}}' > "$BPROJ/s1.jsonl"
budget_run 1000
assert_contains "HOLD written when this-run delta >= budget" "$(hold_file)" "HOLD"
assert_contains "HOLD names the lift command" "$(hold_file)" "fwf usage --clear-hold"
assert_contains "HOLD names this-run spend distinctly from cumulative" "$(hold_file)" "this run"
case "$(hold_file)" in HOLD\ *) ok "AC9: first-line token is byte-identical 'HOLD '";; *) bad "AC9: first-line token" "$(hold_file)";; esac

section "fwf-budget-check.sh: WARN at threshold, below budget — does not pause"
# Fresh run dir + a smaller total than the HOLD test above, so this lands in
# the WARN band (>=80% of budget, <100%) without also tripping HOLD.
rm -rf "$BT/run3" "$BPROJ"
baseline_ensure "$BT/run3"
mkdir -p "$BPROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":450,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":400}}}' > "$BPROJ/s1.jsonl"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run3" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$BC"
WARNHOLD="$(cat "$BT/run3/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "WARN written at >=80% and <100% of budget" "$WARNHOLD" "WARN"
case "$WARNHOLD" in *HOLD*) bad "WARN must not also say HOLD";; *) ok "WARN is textually distinct from HOLD";; esac
case "$WARNHOLD" in WARN\ *) ok "AC9: first-line token is byte-identical 'WARN '";; *) bad "AC9: first-line token" "$WARNHOLD";; esac

section "fwf-budget-check.sh: unlimited (no budget configured) clears any stale hold"
mkdir -p "$BT/run4"; printf 'HOLD — stale leftover\n' > "$BT/run4/BUDGET_HOLD"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run4" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET="" "$BC"
[ -f "$BT/run4/BUDGET_HOLD" ] && bad "unlimited clears a stale hold" || ok "unlimited clears a stale hold"

section "fwf-budget-check.sh: a role whose reader broke (stale, not unknown) fails CLOSED, distinct from a real HOLD"
mkdir -p "$BT/run5/state/.__budget/usage-cache"
jq -n '{files:{}, last_success_epoch:1000000000, totals:{input:100,cache_creation:0,cache_read:0,output:100}, model:"claude-sonnet-5"}' \
  > "$BT/run5/state/.__budget/usage-cache/impl1.json"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run5" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects-missing" FWF_PAIRS=1 FWF_TOKEN_BUDGET=100000000 "$BC"
FAILCLOSED="$(cat "$BT/run5/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "fail-closed UNKNOWN written when a role's reader broke" "$FAILCLOSED" "UNKNOWN"
assert_contains "fail-closed message says FAIL-CLOSED"                    "$FAILCLOSED" "FAIL-CLOSED"
assert_contains "fail-closed message says NOT over budget (never confused with a real HOLD)" "$FAILCLOSED" "NOT over budget"
assert_contains "fail-closed message names the broken role"               "$FAILCLOSED" "impl1"
case "$FAILCLOSED" in UNKNOWN\ *) ok "AC9: first-line token is byte-identical 'UNKNOWN '";; *) bad "AC9: first-line token" "$FAILCLOSED";; esac

section "fwf-budget-check.sh: dispatches via the fwf CLI"
CLIRC=0
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run6" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 "$ROOT/fwf" budget-check >/dev/null 2>&1 || CLIRC=$?
[ "$CLIRC" = 0 ] && ok "'fwf budget-check' dispatches and exits 0 with no budget configured" \
  || bad "'fwf budget-check' dispatches and exits 0" "exit $CLIRC"

section "fwf-budget-check.sh (#108 AC8): missing baseline -> UNKNOWN, never 0 and never a silent HOLD/no-hold"
rm -rf "$BT/run7" "$BPROJ"; mkdir -p "$BPROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100000000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$BPROJ/s1.jsonl"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run7" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$BC"
MISSING="$(cat "$BT/run7/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "no baseline yet -> UNKNOWN (fail-closed), even with a huge cumulative total" "$MISSING" "UNKNOWN"
assert_contains "missing-baseline message is distinct/actionable" "$MISSING" "baseline"

section "fwf-budget-check.sh (#108 AC8): corrupt baseline (non-numeric field) -> UNKNOWN"
rm -rf "$BT/run8"; mkdir -p "$BT/run8/state/.__budget"
printf '%s\n' '{"tokens_total":"oops","cost_usd":0}' > "$(baseline_file "$BT/run8")"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run8" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$BC"
CORRUPT="$(cat "$BT/run8/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "corrupt baseline (non-numeric field) -> UNKNOWN" "$CORRUPT" "UNKNOWN"

section "fwf-budget-check.sh (#108 AC8): current usage below the recorded baseline -> UNKNOWN, never clamped to 'no spend'"
rm -rf "$BT/run9"; mkdir -p "$BT/run9/state/.__budget"
printf '%s\n' '{"tokens_total":200000000000,"cost_usd":99999}' > "$(baseline_file "$BT/run9")"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run9" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 "$BC"
BELOW="$(cat "$BT/run9/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "current < baseline (raw-token path) -> UNKNOWN, not silently 'no spend'" "$BELOW" "UNKNOWN"
rm -rf "$BT/run9b"; mkdir -p "$BT/run9b/state/.__budget"
printf '%s\n' '{"tokens_total":0,"cost_usd":300000}' > "$(baseline_file "$BT/run9b")"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run9b" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_BUDGET_USD=5 "$BC"
BELOWUSD="$(cat "$BT/run9b/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "current < baseline (\$ path) -> UNKNOWN, not silently 'no spend'" "$BELOWUSD" "UNKNOWN"

section "fwf-budget-check.sh (#108): --budget-usd over budget -> HOLD, formatted in \$ (cache-read priced at its true low rate)"
rm -rf "$BT/run10" "$BPROJ"; baseline_ensure "$BT/run10"; mkdir -p "$BPROJ"
# sonnet-5: \$2.00/MTok input -> 3,000,000 input tokens = \$6.00, over a \$5 ceiling.
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$BPROJ/s1.jsonl"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run10" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_BUDGET_USD=5 "$BC"
USDHOLD="$(cat "$BT/run10/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "\$ HOLD fires once this-run spend crosses the \$ ceiling" "$USDHOLD" "HOLD"
assert_contains "\$ HOLD is formatted in dollars" "$USDHOLD" "\$6.0000"
assert_contains "\$ HOLD names the \$ lift command" "$USDHOLD" "FWF_BUDGET_USD"

section "fwf-budget-check.sh (#108 AC1): a profile with BILLIONS of prior cumulative tokens does NOT instantly HOLD once re-armed"
rm -rf "$BT/run11" "$BPROJ"; mkdir -p "$BPROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000000000,"output_tokens":100000000}}}' > "$BPROJ/s1.jsonl"
baseline_ensure "$BT/run11"   # snapshots the huge cumulative as the baseline
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run11" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_BUDGET_USD=5 "$BC"
[ -z "$(cat "$BT/run11/BUDGET_HOLD" 2>/dev/null || true)" ] \
  && ok "AC1: billions of prior tokens + a fresh baseline -> no instant HOLD with --budget-usd 5" \
  || bad "AC1: no instant HOLD" "$(cat "$BT/run11/BUDGET_HOLD")"
# ...but NEW spend since that baseline still HOLDs, same \$6-over-\$5 fixture as above.
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' >> "$BPROJ/s1.jsonl"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run11" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_BUDGET_USD=5 "$BC"
AC1HOLD="$(cat "$BT/run11/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "AC1: new spend since the baseline still triggers HOLD" "$AC1HOLD" "HOLD"
assert_contains "AC1: HOLD names the small this-run figure, not the huge cumulative one" "$AC1HOLD" "\$6.0000 spent this run"

section "fwf-budget-check.sh (#108 AC2): a role with an unpriced model fails CLOSED for --budget-usd, never a silent \$0"
rm -rf "$BT/run12"; baseline_ensure "$BT/run12"
UNPRICEDCWD="$BT/wt/bt-impl2"; UNPRICEDSLUG="${UNPRICEDCWD//\//-}"; UNPRICEDSLUG="${UNPRICEDSLUG//./-}"
UNPRICEDPROJ="$BT/claude-projects/$UNPRICEDSLUG"; mkdir -p "$UNPRICEDPROJ"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-totally-unknown","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$UNPRICEDPROJ/s.jsonl"
FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run12" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=2 FWF_BUDGET_USD=5 "$BC"
UNPRICED="$(cat "$BT/run12/BUDGET_HOLD" 2>/dev/null || true)"
assert_contains "unpriced model -> UNKNOWN (fail-closed), never a silent \$0" "$UNPRICED" "UNKNOWN"
assert_contains "unpriced-model message names the price table" "$UNPRICED" "price table"
rm -rf "$UNPRICEDPROJ"

section "fwf-budget-check.sh / fwf_budget_writer_stop (#108 AC5/AC7): stopping the writer preserves the baseline — only an explicit clear resets it"
rm -rf "$BT/run13" "$BPROJ"; mkdir -p "$BPROJ"
env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run13" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_start"
BEFORE="$(cat "$(baseline_file "$BT/run13")")"
env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run13" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_stop"
[ -f "$(baseline_file "$BT/run13")" ] && ok "fwf_budget_writer_stop (floor-down equivalent) leaves the baseline file in place" \
  || bad "fwf_budget_writer_stop must not delete the baseline"
# new usage arrives between the stop and a floor-only re-up...
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":9999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$BPROJ/s1.jsonl"
# ...but re-arming (a floor-only `fwf up` equivalent) must NOT re-snapshot.
env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run13" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 FWF_TOKEN_BUDGET=1000 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_start"
AFTER="$(cat "$(baseline_file "$BT/run13")")"
assert_eq "AC5/AC7: re-arming after a stop does not overwrite an existing baseline, even with fresh usage sitting in between" "$BEFORE" "$AFTER"
env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run13" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_writer_stop"
# explicit clear (the full-teardown path) DOES reset it.
env FWF_PROFILE=.__budget FWF_RUN_DIR="$BT/run13" FWF_CLAUDE_PROJECTS_DIR="$BT/claude-projects" FWF_PAIRS=1 \
  bash -c "source '$ROOT/lib.sh'; fwf_budget_baseline_clear"
[ -f "$(baseline_file "$BT/run13")" ] && bad "fwf_budget_baseline_clear must remove the baseline" \
  || ok "fwf_budget_baseline_clear (full-teardown path) resets the baseline for the next full 'fwf up'"

rm -f "$ROOT/profiles/.__budget.sh"

section "BUDGET CHECK step-0 (issue #96): every REAL role-loop template carries it (composed/rendered, not a naive per-file grep)"
# Every template dir under templates/ EXCEPT _local-issues/ (an addendum
# fragment composed onto a base template's already-checked prompt — it has no
# loop of its own, so it is correctly excluded, not missing coverage).
for tdir in templates/*/; do
  t="$(basename "$tdir")"
  [ "$t" = "_local-issues" ] && continue
  for tmplfile in "$tdir"*.tmpl; do
    [ -e "$tmplfile" ] || continue
    role="$(basename "$tmplfile" .tmpl)"
    rendered="$(FWF_PROFILE=example FWF_TEMPLATE="$t" bash -c "source '$ROOT/lib.sh'; fwf_render '$tmplfile' 1" 2>/dev/null || true)"
    case "$rendered" in
      *"STOP CHECK"*)
        case "$rendered" in
          *"BUDGET CHECK"*) ok "$t/$role: BUDGET CHECK present (composed/rendered)";;
          *) bad "$t/$role: BUDGET CHECK present (composed/rendered)" "template has a loop (STOP CHECK) but no BUDGET CHECK";;
        esac
        ;;
      *) : ;;  # no STOP CHECK -> not a looped role prompt (nothing to require here)
    esac
  done
done
# The _local-issues addenda are one-line fragments with no loop of their own —
# confirm they do NOT independently need the check (they compose onto a base
# .tmpl that already has it, verified above).
for f in templates/_local-issues/*.tmpl; do
  [ -e "$f" ] || continue
  case "$(cat "$f")" in
    *"STOP CHECK"*) bad "_local-issues/$(basename "$f"): addenda should have no loop of their own" ;;
    *) ok "_local-issues/$(basename "$f"): correctly has no independent loop (composes onto a base that's already covered)" ;;
  esac
done

# --------------------------------------------------------------------------
# branch reconcile (#114): stop the swarm building on a stale base. Real git
# fixtures — a bare "origin.git", a "seed" repo that authors commits and
# pushes them to origin, and a "drive" repo (a separate clone) that stands in
# for the fwf-self checkout the classifier/reconcile helper actually runs
# from. Every scenario gets its own fixture trio so ancestry states never leak
# across tests. Never touches the real repo/network/gh.
section "branch reconcile (#114): classifier (BEHIND/AHEAD/EQUAL/DIVERGED/SUSPECT) + FF-or-halt"

rec_setup() { # $1=label -> creates $TMP/rec114-<label>/{origin.git,seed,drive}, all 3 branches synced at one commit
  local label="$1"
  local base="$TMP/rec114-$label"
  REC_ORIGIN="$base/origin.git"; REC_SEED="$base/seed"; REC_DRIVE="$base/drive"; REC_RUN="$base/run"
  mkdir -p "$REC_ORIGIN" "$REC_SEED" "$REC_DRIVE"
  ( cd "$REC_ORIGIN" && git init -q --bare )
  ( cd "$REC_SEED" && git init -q && git symbolic-ref HEAD refs/heads/main \
    && git config user.email t@t.co && git config user.name t \
    && echo a > f && git add -A && git commit -qm c1 \
    && git remote add origin "$REC_ORIGIN" \
    && git push -q origin main && git push -q origin main:staging && git push -q origin main:integration )
  ( cd "$REC_DRIVE" && git init -q && git config user.email t@t.co && git config user.name t \
    && git remote add origin "$REC_ORIGIN" && git fetch -q origin )
}
rec_advance() { # $1=branch to push a new commit onto (from the seed repo)
  ( cd "$REC_SEED" && git checkout -q main && echo "$RANDOM$RANDOM" >> f && git commit -qam "advance $1" \
    && git push -q origin "main:$1" )
}
rec_sha() { git -C "$REC_ORIGIN" rev-parse "refs/heads/$1"; } # authoritative: read the tip straight off origin
rec_fork() { # $1=branch $2=base-sha -> a NEW commit forking off base-sha (independent of any later main advances), pushed to $1
  ( cd "$REC_SEED" && git checkout -q "$2" && echo "$RANDOM$RANDOM" >> f && git commit -qam "fork $1 from $2" \
    && git push -q origin "HEAD:$1" )
}
rec_run() { FWF_REPO="$REC_DRIVE" FWF_RUN_DIR="$REC_RUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; $1"; }

# --- classifier: BEHIND -------------------------------------------------
rec_setup behind
rec_advance main   # main gets a commit staging/integration don't have -> staging is a strict ancestor of main
CLS="$(rec_run 'fwf_reconcile_classify staging main')"
assert_contains "BEHIND: classifier names the state" "$CLS" "BEHIND"
assert_contains "BEHIND: reports the branch sha"     "$CLS" "$(rec_sha staging)"
assert_contains "BEHIND: reports the main sha"       "$CLS" "$(rec_sha main)"

# --- classifier: AHEAD (the false-positive guard, AC3) -------------------
rec_setup ahead
rec_advance integration   # integration carries a promoted-but-unreleased commit main doesn't have yet
CLS="$(rec_run 'fwf_reconcile_classify integration main')"
assert_contains "AHEAD: a legitimately-leading branch is reported normal, not diverged" "$CLS" "AHEAD"

# --- classifier: EQUAL (clean no-op) --------------------------------------
rec_setup equal
CLS="$(rec_run 'fwf_reconcile_classify staging main')"
assert_contains "EQUAL: freshly-synced branches classify as EQUAL" "$CLS" "EQUAL"

# --- classifier: DIVERGED --------------------------------------------------
rec_setup diverged
DIV_BASE="$(rec_sha main)"       # common ancestor before either side moves
rec_advance main                  # main moves forward from the common ancestor...
rec_fork staging "$DIV_BASE"      # ...and staging forks independently FROM THAT SAME ancestor -> neither is an ancestor of the other
CLS="$(rec_run 'fwf_reconcile_classify staging main')"
assert_contains "DIVERGED: two independently-moved branches classify as DIVERGED" "$CLS" "DIVERGED"

# --- classifier: SUSPECT (fail-closed on fetch failure, AC6) ---------------
rec_setup suspect
rm -rf "$REC_ORIGIN"   # origin vanishes -> fetch fails
CLS="$(rec_run 'fwf_reconcile_classify staging main')"
assert_contains "SUSPECT: an unfetchable origin fails CLOSED, never silently proceeds" "$CLS" "SUSPECT"

# --- fwf_reconcile_branch: BEHIND -> actually reconciles (AC1) -------------
rec_setup reconcile-behind
rec_advance main
OLD_SHA="$(rec_sha staging)"; NEW_SHA="$(rec_sha main)"
rc=0; LINE="$(rec_run 'fwf_reconcile_branch staging main')" || rc=$?
assert_eq   "BEHIND reconcile: rc 0 (safe to proceed)" "0" "$rc"
assert_contains "BEHIND reconcile: reports reconciled + old->new SHAs" "$LINE" "reconciled staging $OLD_SHA -> $NEW_SHA"
POST="$(rec_run 'fwf_reconcile_classify staging main')"
assert_contains "BEHIND reconcile: staging == main on origin afterward" "$POST" "EQUAL"

# --- fwf_reconcile_branch: DIVERGED -> halts, never mutates (AC2) ---------
rec_setup reconcile-diverged
RD_BASE="$(rec_sha main)"
rec_advance main
rec_fork staging "$RD_BASE"
PRE_STAGING_SHA="$(rec_sha staging)"
rc=0; LINE="$(rec_run 'fwf_reconcile_branch staging main')" || rc=$?
assert_eq   "DIVERGED reconcile: rc 1 (do not build on this base)" "1" "$rc"
assert_contains "DIVERGED reconcile: reports halted-diverged with both SHAs" "$LINE" "halted-diverged staging $PRE_STAGING_SHA $(rec_sha main)"
POST_SHA="$(rec_run 'fwf_reconcile_classify staging main' | awk '{print $2}')"
assert_eq   "DIVERGED reconcile: staging ref on origin is untouched (no auto merge/rebase/force)" "$PRE_STAGING_SHA" "$POST_SHA"

# --- fwf_reconcile_branch: AHEAD -> zero mutation, zero halt (AC3) --------
rec_setup reconcile-ahead
rec_advance integration
PRE_SHA="$(rec_sha integration)"
rc=0; LINE="$(rec_run 'fwf_reconcile_branch integration main')" || rc=$?
assert_eq   "AHEAD reconcile: rc 0, never treated as unsafe"    "0" "$rc"
assert_contains "AHEAD reconcile: reports normal-ahead, no mutation/alarm" "$LINE" "normal-ahead integration"
POST_SHA="$(rec_run 'fwf_reconcile_classify integration main' | awk '{print $2}')"
assert_eq   "AHEAD reconcile: ref never moved" "$PRE_SHA" "$POST_SHA"

# --- fwf_reconcile_branch: idempotent on an already-synced branch (AC7) ---
rec_setup reconcile-idempotent
rc=0; LINE="$(rec_run 'fwf_reconcile_branch staging main')" || rc=$?
assert_eq   "idempotent: rc 0 on an already-synced branch" "0" "$rc"
assert_contains "idempotent: reports clean no-op, no spurious mutation" "$LINE" "clean no-op staging"
rc=0; LINE2="$(rec_run 'fwf_reconcile_branch staging main')" || rc=$?
assert_eq   "idempotent: second run is still a clean no-op" "0" "$rc"
assert_contains "idempotent: second run reports the same clean no-op" "$LINE2" "clean no-op staging"

# --- fwf-reconcile.sh CLI: both branches, non-zero exit iff any is unsafe --
rec_setup cli-mixed
rec_advance main; rec_advance main           # main advances twice from the common base -> staging (still at base) is BEHIND by 2
rec_advance integration                      # integration then advances PAST that (a descendant of the new main tip) -> AHEAD (safe, never a false alarm)
CLI_OUT="$(FWF_REPO="$REC_DRIVE" FWF_RUN_DIR="$REC_RUN" FWF_PROFILE=example \
  "$ROOT/fwf-reconcile.sh" --branch staging --branch integration --against main 2>&1)"; rc=$?
assert_eq   "CLI: exits 0 when every branch ends up safe (BEHIND auto-FF'd, AHEAD normal)" "0" "$rc"
assert_contains "CLI: reports the staging reconcile" "$CLI_OUT" "reconciled staging"
assert_contains "CLI: reports the integration normal-ahead" "$CLI_OUT" "normal-ahead integration"

rec_setup cli-halts
CH_BASE="$(rec_sha main)"
rec_advance main
rec_fork staging "$CH_BASE"   # staging forks independently from the common base -> DIVERGED from main
CLI_RC=0; CLI_OUT2="$(FWF_REPO="$REC_DRIVE" FWF_RUN_DIR="$REC_RUN" FWF_PROFILE=example \
  "$ROOT/fwf-reconcile.sh" --branch staging --branch integration --against main 2>&1)" || CLI_RC=$?
assert_eq   "CLI: exits non-zero when any branch is unsafe (halted-diverged)" "1" "$CLI_RC"
assert_contains "CLI: names the diverged branch" "$CLI_OUT2" "halted-diverged staging"

# --- flap detection (#114 AC9): repeated consecutive reconciles surface as an anomaly ---
rec_setup flap
rec_advance main
rec_run 'fwf_reconcile_branch staging main' >/dev/null   # 1st consecutive reconcile
rec_advance main
FLAP_LINE="$(rec_run 'fwf_reconcile_branch staging main')"   # 2nd consecutive reconcile -> anomaly
assert_contains "flap: 2 consecutive reconciles of the same branch trip an anomaly" "$FLAP_LINE" "ANOMALY"
rec_run 'fwf_reconcile_branch staging main' >/dev/null   # clean no-op (already synced) -> resets the streak
rec_advance main
NOFLAP_LINE="$(rec_run 'fwf_reconcile_branch staging main')"
case "$NOFLAP_LINE" in
  *ANOMALY*) bad "flap: a reset streak must not immediately re-trip the anomaly" ;;
  *) ok "flap: streak correctly reset by the intervening clean no-op" ;;
esac

# --- both backends (#114 AC10): classification is pure git, so FWF_ISSUES
# (gh vs the local issue-tracking store) never changes its outcome ----------
rec_setup backend
rec_advance main
GH_CLS="$(FWF_ISSUES=gh    rec_run 'fwf_reconcile_classify staging main')"
LOCAL_CLS="$(FWF_ISSUES=local rec_run 'fwf_reconcile_classify staging main')"
assert_eq "both backends: classification is identical regardless of FWF_ISSUES" "$GH_CLS" "$LOCAL_CLS"

# --- concurrency (#114 AC8): the CAS-loser aborts cleanly, never a blind
# overwrite or a partial/interleaved move. "Writer 1" observes a BEHIND
# classification (capturing staging's then-current SHA as its lease, and
# main's THEN tip as its intended target). Before writer 1 acts, main
# advances AGAIN and "writer 2" wins the race first via the real
# fwf_reconcile_branch path, reconciling staging to the NEWER tip. Writer 1's
# late CAS push (stale lease AND a now-superseded target) must be rejected,
# leaving the branch at exactly writer 2's SHA -- no double move, no
# interleave. Drives the actual production primitive (fwf_reconcile_cas_push,
# the same one fwf_reconcile_branch's BEHIND case calls), not a
# re-implementation. (Deliberately does NOT reuse writer 2's target as writer
# 1's push value -- pushing an already-current SHA can short-circuit as a
# no-op regardless of the lease, which would test nothing.)
rec_setup race
rec_advance main
RACE_CLS="$(rec_run 'fwf_reconcile_classify staging main')"
read -r _ RACE_STALE_LEASE RACE_STALE_TARGET <<<"$RACE_CLS"   # writer 1's observed (soon-to-be-stale) lease + target
rec_advance main                                               # main moves again, unbeknownst to writer 1
rec_run 'fwf_reconcile_branch staging main' >/dev/null         # writer 2 (fresh classify) wins the race for real
WINNER_SHA="$(rec_sha staging)"
assert_eq "race: writer 2 (the real winner) reconciled staging to main's CURRENT tip" "$(rec_sha main)" "$WINNER_SHA"
race_rc=0; rec_run "fwf_reconcile_cas_push staging '$RACE_STALE_LEASE' '$RACE_STALE_TARGET'" || race_rc=$?
assert_eq   "race: writer 1's late CAS push (stale lease) is rejected"       "1" "$race_rc"
assert_eq   "race: no partial/double move -- branch still at writer 2's SHA" "$WINNER_SHA" "$(rec_sha staging)"

# --- captain-tick guard is wired at the template level (#114 AC4/AC5) ------
# Every REAL captain template that owns a RELEASE ENGINEERING job (promotes
# to __DEFAULT__ and assigns tickets) must carry the STALE-BASE GUARD
# directive in its composed/rendered prompt -- same discipline as the
# BUDGET CHECK check above, so a future prompt refactor can't silently drop
# this guard with nothing to catch it.
for t in dev dev-sre refactor; do
  rendered="$(FWF_PROFILE=example FWF_TEMPLATE="$t" bash -c "source '$ROOT/lib.sh'; fwf_render '$ROOT/templates/$t/captain.tmpl' ''" 2>/dev/null || true)"
  assert_contains "$t/captain: STALE-BASE GUARD present (composed/rendered)" "$rendered" "STALE-BASE GUARD"
  assert_contains "$t/captain: names the fwf reconcile command"              "$rendered" "fwf reconcile"
done

# --------------------------------------------------------------------------
section "cargo target isolation (issue #151)"
# fwf_cargo_isolate must guarantee a build in a worktree writes ONLY to that
# worktree's own target — the fix for the shared-target false-GREEN. Each case
# runs in its own subshell (the `unset` must not leak) inside a fresh git
# fixture, and prints "<CARGO_TARGET_DIR|UNSET>|<target-state>|<rc>|<wrapper>".
ci_run() { # $1 = setup snippet (runs with $wt=worktree, $shared=out-of-tree dir)
  FWF_PROFILE=example bash -c '
    source "'"$ROOT"'/lib.sh" 2>/dev/null
    wt="$(mktemp -d "${TMPDIR:-/tmp}/fwf-ci.XXXXXX")"; cd "$wt" && git init -q
    shared="$(mktemp -d "${TMPDIR:-/tmp}/fwf-shared.XXXXXX")"
    '"$1"'
    fwf_cargo_isolate; rc=$?
    ts=none; [ -L target ] && ts=symlink; { [ -d target ] && [ ! -L target ]; } && ts=dir
    printf "%s|%s|%s|%s" "${CARGO_TARGET_DIR:-UNSET}" "$ts" "$rc" "${RUSTC_WRAPPER:-UNSET}"
    rm -rf "$wt" "$shared"
  '
}
ci_f() { printf '%s' "$2" | cut -d'|' -f"$1"; }

# A. shared ambient CARGO_TARGET_DIR (outside the worktree) is dropped.
R="$(ci_run 'export CARGO_TARGET_DIR="$shared"')"
assert_eq "shared ambient CARGO_TARGET_DIR is dropped" "UNSET" "$(ci_f 1 "$R")"
assert_eq "  ...and isolate succeeds"                  "0"     "$(ci_f 3 "$R")"

# B. a private CARGO_TARGET_DIR already inside the worktree is kept.
R="$(ci_run 'mkdir -p "$wt/target"; export CARGO_TARGET_DIR="$wt/target"')"
assert_not_contains "in-worktree CARGO_TARGET_DIR is kept" "$(ci_f 1 "$R")" "UNSET"

# C. a legacy shared-target symlink (pointing out of tree) is removed.
R="$(ci_run 'ln -s "$shared" target')"
assert_eq "shared target symlink removed" "none" "$(ci_f 2 "$R")"
assert_eq "  ...and isolate succeeds"     "0"    "$(ci_f 3 "$R")"

# D. an in-worktree symlink is harmless and left alone.
R="$(ci_run 'mkdir -p "$wt/sub"; ln -s "$wt/sub" target')"
assert_eq "in-worktree target symlink kept" "symlink" "$(ci_f 2 "$R")"

# E. healthy case: nothing set, nothing to repair — a clean no-op.
R="$(ci_run ':')"
assert_eq "healthy no-op leaves CARGO_TARGET_DIR unset" "UNSET" "$(ci_f 1 "$R")"
assert_eq "healthy no-op creates no target"             "none"  "$(ci_f 2 "$R")"
assert_eq "healthy no-op succeeds"                      "0"     "$(ci_f 3 "$R")"

# F. sccache (RUSTC_WRAPPER) is content-addressed and shared-safe — never touched.
R="$(ci_run 'export RUSTC_WRAPPER=sccache; export CARGO_TARGET_DIR="$shared"')"
assert_eq "sccache RUSTC_WRAPPER preserved"        "sccache" "$(ci_f 4 "$R")"
assert_eq "  ...while shared target dir is dropped" "UNSET"  "$(ci_f 1 "$R")"

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
section "fwf gate does not leak its own profile resolution (issue #175)"
# fwf-gate.sh resolves a profile for its lock paths. That resolution must NOT
# reach the wrapped command: test/run.sh (the real GATE_CMD here) builds its own
# fixtures, and an inherited FWF_REPO/FWF_PROFILE overrides them — 41 tests went
# RED on every gate cycle. Assert the wrapped command sees the CALLER's env.
F175RUN="$TMP/run175"; mkdir -p "$F175RUN/state/example"
F175REPORT="$TMP/f175-env.txt"
cat > "$TMP/f175-probe.sh" <<'F175EOF'
#!/usr/bin/env bash
# Report what the wrapped command actually inherited. "<unset>" is the pass
# state for a caller that had nothing set — an empty value is NOT the same.
printf 'PROFILE=%s
' "${FWF_PROFILE-<unset>}"
printf 'PAIRS=%s
'   "${FWF_PAIRS-<unset>}"
printf 'REPO=%s
'    "${FWF_REPO-<unset>}"
F175EOF
chmod +x "$TMP/f175-probe.sh"

# (a) caller with a CLEAN env -> wrapped command must see nothing set.
env -u FWF_REPO -u FWF_PROFILE -u FWF_PAIRS FWF_RUN_DIR="$F175RUN" FWF_MIN_FREE_GB=0 \
    "$ROOT/fwf-gate.sh" f175a -- "$TMP/f175-probe.sh" > "$F175REPORT" 2>/dev/null
assert_contains "clean caller: no FWF_PROFILE leaks to wrapped cmd" "$(cat "$F175REPORT")" "PROFILE=<unset>"
assert_contains "clean caller: no FWF_PAIRS leaks to wrapped cmd"   "$(cat "$F175REPORT")" "PAIRS=<unset>"
assert_contains "clean caller: no FWF_REPO leaks to wrapped cmd"    "$(cat "$F175REPORT")" "REPO=<unset>"

# (b) caller that DID set them -> its own values survive verbatim. The restore
#     must not BLANK a var the caller legitimately owned, which is the opposite
#     failure from the leak. Values must be resolvable: the gate has to load a
#     real profile to build its lock paths, so an unresolvable FWF_PROFILE makes
#     it exit before ever reaching the wrapped command (correct behaviour, but
#     it tests nothing). `example` is the tracked profile every checkout has.
env FWF_PROFILE=example FWF_PAIRS=7 FWF_REPO="$ROOT" FWF_RUN_DIR="$F175RUN" FWF_MIN_FREE_GB=0 \
    "$ROOT/fwf-gate.sh" f175b -- "$TMP/f175-probe.sh" > "$F175REPORT" 2>/dev/null
assert_contains "caller's own FWF_PROFILE is preserved" "$(cat "$F175REPORT")" "PROFILE=example"
assert_contains "caller's own FWF_PAIRS is preserved"   "$(cat "$F175REPORT")" "PAIRS=7"
assert_contains "caller's own FWF_REPO is preserved"    "$(cat "$F175REPORT")" "REPO=$ROOT"

# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# reconcile ENFORCEMENT (#179): the classifier was always sound; what was
# missing is a call site OBLIGED to act on its verdict. These four cases are
# deliberately SEPARATE -- they bite different paths with different
# consequences, and collapsing any two lets a faithful reproduction of the
# original bug pass. Reuses the #114 rec_* git fixtures above.
section "reconcile enforcement (#179): obliged call sites on both release paths"

CI_YML="$(cat "$ROOT/.github/workflows/ci.yml")"
REL_YML="$(cat "$ROOT/.github/workflows/release.yml")"

# --- AC1: untagged direct-to-main push -> reconcile EXECUTES --------------
# RED before #179: the reconcile step lived only in release.yml, which is
# `on: push: tags`, so an untagged hotfix push never ran it at all.
assert_contains "AC1: ci.yml fires on push to main" "$CI_YML" "branches: [main]"
assert_contains "AC1: ci.yml has a reconcile job" "$CI_YML" "reconcile:"
assert_contains "AC1: the reconcile job actually invokes reconcile" "$CI_YML" "./fwf reconcile-guard"
assert_contains "AC1: reconcile job is scoped to push-to-main only" "$CI_YML" \
  "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
assert_contains "AC1: reconcile job fetches full ancestry (a shallow tip misclassifies)" "$CI_YML" "fetch-depth: 0"
# The trap this AC cannot catch on its own -- hence AC3. Asserted against
# EXECUTABLE lines only: ci.yml's comments deliberately quote the anti-pattern
# to warn implementers off it, and a naive grep over the whole file matches
# that warning and calls it the bug.
CI_CODE="$(grep -v '^[[:space:]]*#' "$ROOT/.github/workflows/ci.yml")"
assert_not_contains "AC1: ci.yml does NOT swallow the verdict into a warning (Hole 2 on the new path)" \
  "$CI_CODE" './fwf reconcile || echo "::warning'

# --- AC2: tagged release + genuine divergence -> publish PREVENTED --------
# Wiring: every publishing job hangs off the pre-publish check.
assert_contains "AC2: release.yml has a pre-publish preflight job" "$REL_YML" "preflight:"
assert_contains "AC2: preflight runs the non-mutating check" "$REL_YML" "./fwf reconcile --check"
assert_contains "AC2: artifact build is gated on preflight" "$REL_YML" "needs: preflight"
assert_contains "AC2: publish is gated on preflight" "$REL_YML" "needs: [preflight, dash-binaries]"

# Behaviour: DIVERGED must fail the check, and the refusal must be ROUTED --
# naming the branch, what it diverged against, and the resolving command. A
# refusal that strands the operator with no next step is what produced the
# out-of-band workarounds this ticket exists to stop.
rec_setup check-diverged
rec_advance main
PRE_STAGING_SHA="$(rec_sha staging)"
rec_fork staging "$(rec_sha staging)"
PRE_STAGING_SHA="$(rec_sha staging)"
rc=0; LINE="$(rec_run 'fwf_reconcile_check_branch staging main')" || rc=$?
assert_eq       "AC2: DIVERGED -> check exits non-zero (publish is blocked)" "1" "$rc"
assert_contains "AC2: refusal names the branch"            "$LINE" "check-diverged staging"
assert_contains "AC2: refusal names the resolving command" "$LINE" "fwf reconcile --branch staging --against main"
assert_contains "AC2: refusal says a human decides, not a rerun" "$LINE" "needs a human decision"
POST_SHA="$(rec_run 'fwf_reconcile_classify staging main' | awk '{print $2}')"
assert_eq "AC2: --check NEVER mutates the ref (safe to run pre-publish)" "$PRE_STAGING_SHA" "$POST_SHA"

# BEHIND is staleness, NOT divergence: blocking a release for it would be
# wrong, and the post-publish reconcile fast-forwards it anyway.
rec_setup check-behind
rec_advance main
rc=0; LINE="$(rec_run 'fwf_reconcile_check_branch staging main')" || rc=$?
assert_eq       "AC2: BEHIND -> check exits 0 (staleness must not block a release)" "0" "$rc"
assert_contains "AC2: BEHIND check reports ok, not a divergence" "$LINE" "check-ok staging"
POST_SHA="$(rec_run 'fwf_reconcile_classify staging main' | awk '{print $2}')"
assert_eq "AC2: --check does not fast-forward a BEHIND branch either" "$(rec_sha staging)" "$POST_SHA"

# --- AC3/AC4: durable, blocking, IDEMPOTENT artifact on the untagged path --
# A stub `gh` stands in for GitHub: it logs every subcommand and remembers the
# one issue it "created", so the guard's find->create/edit path is exercised
# for real. Injected per-process via $FWF_GH -- never by mutating PATH, which
# would race a parallel suite (the #175 lesson).
guard_stub() { # $1=dir
  mkdir -p "$1"
  GH_LOG="$1/calls.log"; GH_STATE="$1/issues.json"
  : > "$GH_LOG"; printf '[]\n' > "$GH_STATE"
  cat > "$1/gh" <<STUB
#!/usr/bin/env bash
# stub gh: logs calls, keeps one fake issue in \$GH_STATE
log="$GH_LOG"; state="$GH_STATE"
echo "\$1 \$2" >> "\$log"
case "\$1 \$2" in
  "issue list")
    # emit the marker line only while a fake issue is open
    if grep -q OPEN "\$state" 2>/dev/null; then echo 4242; fi ;;
  "issue create")
    cat > /dev/null           # consume --body-file -
    echo OPEN > "\$state"
    echo "https://example.invalid/issues/4242" ;;
  "issue edit")   cat > /dev/null ;;
  "issue close")  echo CLOSED > "\$state" ;;
  "issue comment") : ;;
esac
exit 0
STUB
  chmod +x "$1/gh"
}
# count how many times a subcommand appears in the stub's call log
gh_calls() { grep -c "^$1\$" "$GH_LOG" 2>/dev/null | tr -d ' '; }

# AC3: divergence on an untagged push -> exit non-zero AND one durable artifact
rec_setup guard-diverged
rec_advance main
rec_fork staging "$(rec_sha staging)"
GUARD_DIR="$TMP/rec179-guard"; guard_stub "$GUARD_DIR"
guard_run() {
  FWF_REPO="$REC_DRIVE" FWF_RUN_DIR="$REC_RUN" FWF_PROFILE=example \
  FWF_GH="$GUARD_DIR/gh" bash "$ROOT/fwf-reconcile-guard.sh" --branch staging 2>&1
}
rc=0; OUT="$(guard_run)" || rc=$?
assert_eq       "AC3: divergence -> guard exits non-zero (the check goes red)" "1" "$rc"
assert_contains "AC3: guard reports it filed a durable artifact" "$OUT" "filing durable artifact"
assert_eq       "AC3: exactly one issue was filed" "1" "$(gh_calls 'issue create')"
assert_contains "AC3: guard surfaces the reconcile verdict itself" "$OUT" "halted-diverged staging"

# AC4: a SECOND push while still diverged -> NO second artifact.
# ci.yml fires on every push to main; ten pushes under one divergence must
# produce one issue, not ten, or the signal becomes the noise it replaced.
rc=0; OUT2="$(guard_run)" || rc=$?
assert_eq       "AC4: still diverged -> guard still exits non-zero" "1" "$rc"
assert_eq       "AC4: NO second issue is filed" "1" "$(gh_calls 'issue create')"
assert_eq       "AC4: the existing artifact is edited in place instead" "1" "$(gh_calls 'issue edit')"
assert_contains "AC4: guard says so out loud" "$OUT2" "no duplicate filed"

# ...and the artifact closes itself once the divergence is resolved, so the
# next divergence gets a fresh one rather than reopening a stale thread.
rec_setup guard-clean
GUARD_CLEAN="$TMP/rec179-guard-clean"; guard_stub "$GUARD_CLEAN"
printf 'OPEN\n' > "$GUARD_CLEAN/issues.json"    # pretend an artifact is already open
guard_run_clean() {
  FWF_REPO="$REC_DRIVE" FWF_RUN_DIR="$REC_RUN" FWF_PROFILE=example \
  FWF_GH="$GUARD_CLEAN/gh" bash "$ROOT/fwf-reconcile-guard.sh" --branch staging 2>&1
}
rc=0; OUT3="$(guard_run_clean)" || rc=$?
GH_LOG="$GUARD_CLEAN/calls.log"
assert_eq       "AC3: clean verdict -> guard exits 0" "0" "$rc"
assert_contains "AC3: clean verdict closes the open artifact" "$OUT3" "closing artifact"
assert_eq       "AC3: the artifact was actually closed" "1" "$(gh_calls 'issue close')"
assert_eq       "AC3: a clean run files nothing" "0" "$(gh_calls 'issue create')"

# --------------------------------------------------------------------------
section "the suite's own exit gate cannot be shadowed by an append (#242)"
# f03d78f (#179) appended a section BELOW the terminal `[ "$FAIL" -eq 0 ]`.
# A bash script's status is that of its LAST executed command, so the gate
# stopped reflecting $FAIL and 1121-passed/2-failed runs shipped as green.
# This asserts the structural property that made that possible is gone.
_gate_tail="$(grep -vE '^\s*(#|$)' "$ROOT/test/run.sh" | tail -1)"
assert_eq "the last executable line of test/run.sh is an explicit exit" \
  "exit \"\$_rc\"" "$_gate_tail"
assert_eq "no bare [ \"\$FAIL\" -eq 0 ] survives as the gate" "0" \
  "$(grep -cE '^\[ "\$FAIL" -eq 0 \]$' "$ROOT/test/run.sh")"

# --------------------------------------------------------------------------
# THE PASS/FAIL GATE. It MUST stay last, and it MUST exit explicitly.
#
# Do NOT append a section below this block. A bare `[ "$FAIL" -eq 0 ]` as the
# final statement is silently shadowed by anything appended after it, because
# the script's exit status is that of the last command it runs -- that is
# exactly how #242 happened, and how two real failures shipped green. An
# explicit `exit` cannot be shadowed by an append, only preceded by one, and
# the section above fails loudly if someone tries.
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
_rc=0; [ "$FAIL" -eq 0 ] || _rc=1
exit "$_rc"
