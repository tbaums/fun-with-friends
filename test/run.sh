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

section "floor lifecycle flags (issue #6) — no live tmux needed"
# Isolated session names guarantee we never touch a real factory.
# FWF_MIN_FREE_GB=0 disables the disk-pressure guard so these flag-logic
# tests don't depend on the runner's free disk.
FU_ENV="FWF_PROFILE=example FWF_SESSION=fwf-selftest-$$ FWF_MIN_FREE_GB=0"
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

section "floor-lifecycle event log (issue #85): fwf_floor_event / fwf_floor_idle_state"
# Pure file I/O (lib.sh) — no tmux/gh needed for the read/write primitives.
F85RUN="$TMP/run85"; mkdir -p "$F85RUN"
F85ENV="FWF_RUN_DIR=$F85RUN FWF_PROFILE=example"
assert_eq "no log yet -> floor_idle inactive" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_idle_state" | cut -f1)"
# (b) floor-down is appended with actor/reason/ts/epoch and survives a re-read
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain 'queue empty; nothing in flight'"
F85LOG="$F85RUN/state/example/floor-events.log"
[ -f "$F85LOG" ] && ok "floor-events.log created" || bad "floor-events.log created"
F85LAST="$(tail -n1 "$F85LOG")"
assert_contains "floor-down line names the actor" "$F85LAST" "captain"
assert_contains "floor-down line carries the reason" "$F85LAST" "queue empty; nothing in flight"
case "$F85LAST" in *"floor-down"*) ok "last line is floor-down";; *) bad "last line is floor-down" "$F85LAST";; esac
F85EPOCH="$(printf '%s' "$F85LAST" | cut -f2)"
case "$F85EPOCH" in ''|*[!0-9]*) bad "epoch field is numeric" "$F85EPOCH";; *) ok "epoch field is numeric";; esac
F85TS="$(printf '%s' "$F85LAST" | cut -f1)"
case "$F85TS" in [0-9][0-9][0-9][0-9]-*T*Z) ok "ts field is ISO-8601 UTC";; *) bad "ts field is ISO-8601 UTC" "$F85TS";; esac
# (a) fwf_floor_idle_state now reports active, carrying the same reason
F85IDLE="$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_idle_state")"
assert_eq "floor_idle_state active after floor-down" "true" "$(printf '%s' "$F85IDLE" | cut -f1)"
assert_contains "floor_idle_state carries the reason" "$F85IDLE" "queue empty; nothing in flight"
# (b-up-paths / idempotency) floor-up clears it; repeated transitions stay coherent
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-up '' ''"
assert_eq "floor-up clears floor_idle" "false" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_idle_state" | cut -f1)"
env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain r2; fwf_floor_event floor-up '' ''; fwf_floor_event floor-down captain r3"
assert_eq "repeated down/up/down stays coherent (last event wins)" "true" \
  "$(env $F85ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_idle_state" | cut -f1)"
# (bound) capped at the last 200 lines; the dash still reads the correct last event
F85CAPRUN="$TMP/run85cap"; mkdir -p "$F85CAPRUN/state/example"
F85CAPLOG="$F85CAPRUN/state/example/floor-events.log"
i=1; while [ "$i" -le 205 ]; do printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$i" >> "$F85CAPLOG"; i=$((i+1)); done
env FWF_RUN_DIR="$F85CAPRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_floor_event floor-down captain capped"
assert_eq "log capped at 200 lines" "200" "$(wc -l < "$F85CAPLOG" | tr -d ' ')"
assert_eq "dash still reads the correct (capped) last event" "true" \
  "$(env FWF_RUN_DIR="$F85CAPRUN" FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_floor_idle_state" | cut -f1)"

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
  env FWF_PROFILE=example FWF_RUN_DIR="$F85ARUN" FWF_SESSION="$F85ASESS" FWF_MIN_FREE_GB=0 \
      FWF_REPO="$F85REPO" FWF_WT_BASE="$F85AWT" FWF_CLAUDE_CMD="$F85CLAUDE" FWF_PAIRS=1 \
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
      "$ROOT/fwf-up.sh" >/dev/null 2>&1
  assert_contains "a full 'fwf up' appends floor-up" "$(tail -n1 "$F85BLOG")" "floor-up"
  tmux kill-session -t "${F85BSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F85BSESS}-build" 2>/dev/null

  # --- a floor-role fwf-respawn.sh (pm) -- captain is excluded (never torn ---
  # down by --floor-only, so respawning it is not an "IDLE cleared" signal).
  F85CWT="$TMP/wt85c"; mkdir -p "$F85CWT/ex-captain" "$F85CWT/ex-pm"
  F85CRUN="$TMP/run85c"; mkdir -p "$F85CRUN/state/example"
  F85CLOG="$F85CRUN/state/example/floor-events.log"
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85CLOG"
  F85CSESS="fwf-selftest-85c-$$"
  tmux new-session -d -s "${F85CSESS}-coord" -c "$F85CWT/ex-captain"
  tmux set -p -t "${F85CSESS}-coord" @l "CAPTAIN"
  env FWF_PROFILE=example FWF_RUN_DIR="$F85CRUN" FWF_SESSION="$F85CSESS" \
      FWF_WT_BASE="$F85CWT" FWF_CLAUDE_CMD="$F85CLAUDE" \
      "$ROOT/fwf-respawn.sh" pm >/dev/null 2>&1
  assert_contains "fwf-respawn.sh of a floor role (pm) appends floor-up" "$(tail -n1 "$F85CLOG")" "floor-up"
  # respawning the CAPTAIN itself must NOT append floor-up — it was never the
  # thing --floor-only tore down, so its respawn says nothing about the floor.
  printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tqueue empty; nothing in flight\n' > "$F85CLOG"
  env FWF_PROFILE=example FWF_RUN_DIR="$F85CRUN" FWF_SESSION="$F85CSESS" \
      FWF_WT_BASE="$F85CWT" FWF_CLAUDE_CMD="$F85CLAUDE" \
      "$ROOT/fwf-respawn.sh" captain >/dev/null 2>&1
  case "$(tail -n1 "$F85CLOG")" in
    *floor-up*) bad "respawning the captain must not clear floor_idle";;
    *) ok "respawning the captain must not clear floor_idle";;
  esac
  tmux kill-session -t "${F85CSESS}-coord" 2>/dev/null
  tmux kill-session -t "${F85CSESS}-build" 2>/dev/null
else
  printf '  skip real-tmux floor-lifecycle wiring tests (tmux not installed)\n'
fi

section "floor-down cooldown guard (issue #88): fwf_floor_last_up_epoch / fwf_floor_cooldown_remaining"
# Pure file I/O (lib.sh) — no tmux needed for the read-only cooldown math.
F88RUN="$TMP/run88lib"; mkdir -p "$F88RUN/state/example"
F88ENV="FWF_RUN_DIR=$F88RUN FWF_PROFILE=example"
F88LIBLOG="$F88RUN/state/example/floor-events.log"
# no log at all -> no prior up on record -> cooldown never blocks
assert_eq "no log -> no last-up epoch" "" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_last_up_epoch")"
assert_eq "no log -> cooldown remaining 0" "0" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_cooldown_remaining")"
# a log that has only ever seen floor-down (never a floor-up) -> still unguarded
printf '2026-01-01T00:00:00Z\t0\tfloor-down\tcaptain\tfirst ever down\n' > "$F88LIBLOG"
assert_eq "floor-down-only log -> no last-up epoch" "" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_last_up_epoch")"
assert_eq "floor-down-only log -> cooldown remaining 0" "0" "$(env $F88ENV bash -c "source '$ROOT/lib.sh'; fwf_floor_cooldown_remaining")"
# a recent floor-up -> remaining cooldown is positive and bounded by FWF_FLOOR_COOLDOWN
NOW="$(date +%s)"
printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$NOW" > "$F88LIBLOG"
REM="$(env $F88ENV FWF_FLOOR_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_floor_cooldown_remaining")"
case "$REM" in ''|*[!0-9]*) bad "recent floor-up -> remaining is numeric" "$REM";; *) ok "recent floor-up -> remaining is numeric";; esac
[ "$REM" -gt 0 ] && [ "$REM" -le 100 ] && ok "recent floor-up -> 0 < remaining <= cooldown" || bad "recent floor-up -> 0 < remaining <= cooldown" "$REM"
# an old floor-up (past the cooldown window) -> remaining is 0
OLD=$(( NOW - 1000 ))
printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$OLD" > "$F88LIBLOG"
assert_eq "elapsed floor-up -> cooldown remaining 0" "0" "$(env $F88ENV FWF_FLOOR_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_floor_cooldown_remaining")"
# the LAST floor-up wins, not the first, when there are several in the log
{
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$OLD"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-down\tcaptain\tr\n' "$OLD"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$NOW"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-down\tcaptain\tr2\n' "$NOW"
} > "$F88LIBLOG"
REM2="$(env $F88ENV FWF_FLOOR_COOLDOWN=100 bash -c "source '$ROOT/lib.sh'; fwf_floor_cooldown_remaining")"
[ "$REM2" -gt 0 ] && [ "$REM2" -le 100 ] && ok "cooldown keys off the LAST floor-up, not the first" || bad "cooldown keys off the LAST floor-up, not the first" "$REM2"
# bogus FWF_FLOOR_COOLDOWN is rejected at source time, same style as FWF_PAIRS
env $F88ENV FWF_FLOOR_COOLDOWN=banana bash -c "source '$ROOT/lib.sh'" >/dev/null 2>&1 && bad "FWF_FLOOR_COOLDOWN=banana rejected" || ok "FWF_FLOOR_COOLDOWN=banana rejected"

section "captain.tmpl (issue #88): dwell + deterministic cooldown are both stated"
CAPRENDER="$(FWF_PROFILE=example bash -c "source '$ROOT/lib.sh'; fwf_render \"\$(fwf_tmpl_path captain)\" ''")"
assert_contains "captain prompt mentions the dwell" "$CAPRENDER" "dwell"
assert_contains "captain prompt names FWF_FLOOR_COOLDOWN" "$CAPRENDER" "FWF_FLOOR_COOLDOWN"
assert_contains "captain prompt calls the cooldown deterministic" "$CAPRENDER" "DETERMINISTIC"
assert_contains "captain prompt mentions --force" "$CAPRENDER" "--force"

if command -v tmux >/dev/null 2>&1; then
  section "fwf-down.sh --floor-only cooldown guard (issue #88): real tmux"
  F88TRUN="$TMP/run88tmux"; mkdir -p "$F88TRUN/state/example"
  F88TLOG="$F88TRUN/state/example/floor-events.log"
  F88SESS="fwf-selftest-88-$$"
  F88ENVT="FWF_PROFILE=example FWF_RUN_DIR=$F88TRUN FWF_SESSION=$F88SESS FWF_FLOOR_COOLDOWN=300"

  # --- refused within cooldown: sessions/panes must stay up, exit nonzero ----
  tmux new-session -d -s "${F88SESS}-coord" -c "$TMP"
  tmux set -p -t "${F88SESS}-coord" @l "CAPTAIN"
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  RECENT_UP="$(date +%s)"
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$RECENT_UP" > "$F88TLOG"
  REFUSED="$(env $F88ENVT "$ROOT/fwf-down.sh" --floor-only 2>&1)" && bad "cooldown refuses too-soon floor-only down" || ok "cooldown refuses too-soon floor-only down"
  assert_contains "refusal names the remaining cooldown" "$REFUSED" "remaining"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && ok "build session stays up when refused" || bad "build session stays up when refused"
  tmux has-session -t "${F88SESS}-coord" 2>/dev/null && ok "coord session stays up when refused" || bad "coord session stays up when refused"
  assert_contains "log unchanged (no floor-down appended) when refused" "$(tail -n1 "$F88TLOG")" "floor-up"

  # --- --force overrides the cooldown and actually tears down -----------------
  env $F88ENVT "$ROOT/fwf-down.sh" --floor-only --force >/dev/null 2>&1 && ok "--force overrides cooldown" || bad "--force overrides cooldown"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "--force actually tears down the build session" || ok "--force actually tears down the build session"
  assert_contains "--force still logs floor-down" "$(tail -n1 "$F88TLOG")" "floor-down"

  # --- cooldown elapsed -> tears down normally without --force ----------------
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  OLD_UP=$(( $(date +%s) - 1000 ))
  printf '2026-01-01T00:00:00Z\t%s\tfloor-up\t\t\n' "$OLD_UP" > "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --floor-only >/dev/null 2>&1 && ok "elapsed cooldown allows floor-only down" || bad "elapsed cooldown allows floor-only down"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "elapsed-cooldown down actually tears down" || ok "elapsed-cooldown down actually tears down"

  # --- no prior floor-up on record (first-ever down) -> allowed ---------------
  tmux new-session -d -s "${F88SESS}-build" -c "$TMP"
  rm -f "$F88TLOG"
  env $F88ENVT "$ROOT/fwf-down.sh" --floor-only >/dev/null 2>&1 && ok "no prior floor-up on record allows down" || bad "no prior floor-up on record allows down"
  tmux has-session -t "${F88SESS}-build" 2>/dev/null && bad "no-record down actually tears down" || ok "no-record down actually tears down"

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

section "dash act: role controls + validation"
assert_contains "respawn wraps fwf-respawn.sh" "$(act respawn impl2)" "fwf-respawn.sh impl2"
assert_contains "stop wraps fwf-stop.sh"       "$(act stop)" "fwf-stop.sh"
act approve >/dev/null 2>&1 && bad "approve without id rejected" || ok "approve without id rejected"
act comment 40 >/dev/null 2>&1 && bad "empty comment rejected" || ok "empty comment rejected"
act bogus-verb >/dev/null 2>&1 && bad "unknown verb rejected" || ok "unknown verb rejected"

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
