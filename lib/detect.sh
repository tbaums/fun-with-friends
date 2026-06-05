#!/usr/bin/env bash
# Ecosystem detection. Given a repo directory, propose the four commands the
# swarm needs: a fast GATE (QA runs it), a BUILD (warm each worktree), an E2E
# suite (the conductor runs it), and a DEV command (shown to implementers).
#
# fwf_detect <repo_dir> populates these globals (any may be empty):
#   DETECT_KIND   human label, e.g. "Rust", "Node (pnpm)", "unknown"
#   DETECT_GATE   fast test/typecheck gate
#   DETECT_BUILD  warm-build command
#   DETECT_E2E    end-to-end suite ("" when none found)
#   DETECT_DEV    live-dev command ("" when none found)
#
# Detection is best-effort: `fwf init` always shows the result for review before
# anything runs, so a wrong guess on an unusual repo costs an edit, not a misfire.
# Deliberately 3.2-clean: no associative arrays, no ${var^^}, no mapfile.

# True if $1 is a readable file under the repo root being detected.
_d_has() { [ -f "$_D_ROOT/$1" ]; }

# Echo a package.json script body for key $1 ("" if absent). Prefers node for
# correctness; falls back to a tolerant grep when node is unavailable.
_d_npm_script() { # $1 = script name
  local key="$1"
  if command -v node >/dev/null 2>&1; then
    node -e '
      try {
        const p = require(process.argv[1]);
        const s = (p.scripts || {})[process.argv[2]];
        if (s) process.stdout.write(String(s));
      } catch (e) {}
    ' "$_D_ROOT/package.json" "$key" 2>/dev/null
  else
    # crude fallback: a "key": "value" line inside the file
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_D_ROOT/package.json" 2>/dev/null \
      | head -1 | sed -E "s/\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/"
  fi
}

# True if package.json declares dependency (any kind) matching regex $1.
_d_npm_dep() { # $1 = extended-regex dependency name
  if command -v node >/dev/null 2>&1; then
    node -e '
      try {
        const p = require(process.argv[1]);
        const all = Object.assign({}, p.dependencies, p.devDependencies, p.peerDependencies);
        const re = new RegExp(process.argv[2]);
        process.exit(Object.keys(all).some(k => re.test(k)) ? 0 : 1);
      } catch (e) { process.exit(1); }
    ' "$_D_ROOT/package.json" "$1" 2>/dev/null
  else
    grep -qE "\"$1" "$_D_ROOT/package.json" 2>/dev/null
  fi
}

# Pick the JS package manager from the lockfile present.
_d_node_pm() {
  if   _d_has pnpm-lock.yaml;  then echo pnpm
  elif _d_has yarn.lock;       then echo yarn
  elif _d_has bun.lockb;       then echo bun
  else echo npm
  fi
}

# Build "<pm> run <script>" / "<pm> test" idioms for the chosen manager.
_d_run() { # $1=pm  $2=script
  case "$1" in
    npm)  echo "npm run $2";;
    pnpm) echo "pnpm $2";;
    yarn) echo "yarn $2";;
    bun)  echo "bun run $2";;
  esac
}
_d_test() { # $1=pm
  case "$1" in
    npm)  echo "npm test";;
    pnpm) echo "pnpm test";;
    yarn) echo "yarn test";;
    bun)  echo "bun test";;
  esac
}
_d_x() { # $1=pm  -> the "run a bin from node_modules" prefix
  case "$1" in
    npm)  echo "npx";;
    pnpm) echo "pnpm exec";;
    yarn) echo "yarn";;
    bun)  echo "bunx";;
  esac
}

_detect_node() {
  local pm gate build e2e dev x
  pm="$(_d_node_pm)"; x="$(_d_x "$pm")"
  DETECT_KIND="Node ($pm)"

  # gate: test (+ typecheck, then lint, if those scripts exist)
  gate="$(_d_test "$pm")"
  [ -n "$(_d_npm_script typecheck)" ] && gate="$gate && $(_d_run "$pm" typecheck)"
  [ -n "$(_d_npm_script lint)" ]      && gate="$gate && $(_d_run "$pm" lint)"
  DETECT_GATE="$gate"

  # build: only if a build script exists
  [ -n "$(_d_npm_script build)" ] && build="$(_d_run "$pm" build)"
  DETECT_BUILD="$build"

  # e2e: prefer an explicit e2e script, else infer from the test runner dep
  if   [ -n "$(_d_npm_script 'test:e2e')" ]; then e2e="$(_d_run "$pm" test:e2e)"
  elif [ -n "$(_d_npm_script e2e)" ];        then e2e="$(_d_run "$pm" e2e)"
  elif _d_npm_dep '@playwright/test|^playwright'; then e2e="$x playwright test"
  elif _d_npm_dep '^cypress';                     then e2e="$x cypress run"
  fi
  DETECT_E2E="$e2e"

  # dev: dev script, else start
  if   [ -n "$(_d_npm_script dev)" ];   then dev="$(_d_run "$pm" dev)"
  elif [ -n "$(_d_npm_script start)" ]; then dev="$(_d_run "$pm" start)"
  fi
  DETECT_DEV="$dev"
}

_detect_rust() {
  local ws=""
  grep -q '^\[workspace\]' "$_D_ROOT/Cargo.toml" 2>/dev/null && ws=" --workspace"
  DETECT_KIND="Rust"
  DETECT_GATE="cargo test$ws"
  DETECT_BUILD="cargo build$ws"
  DETECT_E2E=""     # cargo has no standard e2e lane
  DETECT_DEV=""
}

_detect_go() {
  DETECT_KIND="Go"
  DETECT_GATE="go test ./..."
  DETECT_BUILD="go build ./..."
  DETECT_E2E=""
  DETECT_DEV=""
}

_detect_python() {
  local runner="pytest"
  if   _d_has uv.lock;       then runner="uv run pytest";    DETECT_KIND="Python (uv)"
  elif _d_has poetry.lock;   then runner="poetry run pytest"; DETECT_KIND="Python (poetry)"
  elif grep -q '\[tool.poetry\]' "$_D_ROOT/pyproject.toml" 2>/dev/null; then
       runner="poetry run pytest"; DETECT_KIND="Python (poetry)"
  else DETECT_KIND="Python"
  fi
  DETECT_GATE="$runner"
  DETECT_BUILD=""
  DETECT_E2E=""
  DETECT_DEV=""
}

# Main entry point.
fwf_detect() { # $1 = repo dir
  _D_ROOT="$1"
  DETECT_KIND="unknown"; DETECT_GATE=""; DETECT_BUILD=""; DETECT_E2E=""; DETECT_DEV=""

  if   _d_has Cargo.toml;     then _detect_rust
  elif _d_has package.json;   then _detect_node
  elif _d_has go.mod;         then _detect_go
  elif _d_has pyproject.toml || _d_has setup.py || _d_has requirements.txt; then _detect_python
  fi
}

# Pretty one-screen summary of the current DETECT_* values.
fwf_detect_summary() {
  printf '  ecosystem : %s\n' "$DETECT_KIND"
  printf '  gate      : %s\n' "${DETECT_GATE:-<none — fill in>}"
  printf '  build     : %s\n' "${DETECT_BUILD:-<none>}"
  printf '  e2e       : %s\n' "${DETECT_E2E:-<none — conductor will promote without e2e>}"
  printf '  dev       : %s\n' "${DETECT_DEV:-<none>}"
}
