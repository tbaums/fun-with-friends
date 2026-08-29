#!/usr/bin/env bash
# shellcheck disable=SC2034  # profile vars are consumed by lib.sh and the engine scripts
# fun-with-friends profile: EXAMPLE / template.
#
# `fwf init <git-url>` writes one of these for you automatically (detecting the
# commands). This hand-written copy documents every knob so you can author one
# by hand or tune a generated one. Sourced after config.sh by lib.sh.
#
# To target a repo manually: copy this to profiles/<name>.sh, fill in the values,
# and launch with `fwf --profile <name> up`. Every value is overridable by the
# matching FWF_* env var.
#
# Alternative (issue #188): a profile can instead live IN the target repo, at
# $FWF_REPO/.fwf/<name>.sh, so it's versioned and reviewed there instead of as
# untracked local state here. It runs through a sandboxed import (only a
# fixed allowlist of values comes back; two authorization-critical names are
# refused outright) — see docs/repo-profiles.md for the trust model and the
# resolution order (explicit path > in-tree > auto-detected).

FWF_REPO="${FWF_REPO:-$HOME/your-repo}"     # the application repo (source of truth)
WT_PREFIX="${FWF_WT_PREFIX:-ex}"            # worktrees: ${WT_PREFIX}-impl1, -qa1, -pm, -conductor
# Where worktrees live. Leave unset to use $HOME; point it at a workspace dir to
# keep eight worktrees out of your home directory (what `fwf init` does).
WT_BASE="${FWF_WT_BASE:-$HOME/.fun-with-friends/workspaces/example}"

STAGING_BRANCH="${FWF_STAGING_BRANCH:-staging}"             # impl PRs target this; QA fast-gates + merges here
INTEGRATION_BRANCH="${FWF_INTEGRATION_BRANCH:-integration}" # conductor e2e-promotes here (your release source)
DEFAULT_BRANCH="${FWF_DEFAULT_BRANCH:-main}"                # released by you; the swarm never touches it

# Commands run inside a worktree ---------------------------------------------
# Cargo note (issue #151): the engine guarantees each worktree's gate/build uses
# its OWN target dir — do NOT point CARGO_TARGET_DIR at a shared path here. A
# shared cargo output dir is a false-GREEN mechanism: cargo keys artifacts by
# crate name+version (not content), so sibling worktrees clobber each other's
# rlibs and a gate can pass on code that is not on its branch. For cross-worktree
# cache SPEED without that hazard, use sccache (content-addressed) instead —
# e.g. `export RUSTC_WRAPPER=sccache` — which the engine leaves untouched.
GATE_CMD='make test'              # fast gate QA runs before merging to staging (tests + typecheck/lint)
BUILD_CMD='true'                  # warm-build per worktree at provision (use 'true' if none)
E2E_CMD='true'                    # full e2e the conductor runs before promoting to integration ('true' = none)
# TIP (issue #385): if your E2E_CMD is the same suite ci.yml already runs on the
# same SHA, point it at scripts/conductor-e2e.sh instead. That consults ci.yml's
# verdict for the exact tip SHA first and only re-runs locally when there is no
# definitive green -- measured: promotion cycles were 17-53min (avg ~36) against
# a designed 2min cadence, and 3 of 7 verdicts came back STALE because staging
# moved during the run. Fail-safe: anything other than a definitive green falls
# through to the full local run.
E2E_SETUP_CMD=''                  # one-time e2e dep install in the conductor tree (e.g. 'npx playwright install')
# Reap-scoping warning (issue #65): fwf runs N parallel worktrees on ONE box.
# If E2E_CMD's harness does its own "reap stale processes" pass at startup
# (many Playwright/Cypress globalSetups do, matching on fixed ports or a
# relative path), that reap MUST scope any pkill/port-kill to the invoking
# worktree's own path/identity — otherwise it can kill a SIBLING worktree's
# healthy, in-flight e2e server just because it happens to share the same
# fixed port. This bit implementers and conductor both (see the shared e2e
# lock, __LOCK__, in config.sh) — the lock only serializes fwf-known e2e
# runs, it can't protect against a harness reaping a process it doesn't know
# is a different worktree's.

# Flake-vs-broken discrimination (issue #227), OPTIONAL: a failing GATE_CMD
# run means one of two very different things — "broken" or "flaky" — and
# `fwf gate` cannot tell them apart from a bare pass/fail without help. When
# GATE_CASE_EXTRACTOR is declared, `fwf gate` reads the wrapped command's
# captured STDOUT through it and expects "PASS <case-id>" / "FAIL <case-id>"
# lines back (one per test case; the rest of the line, spaces included, is
# the case-id) — from THAT it reports, on every FAILING case, whether it
# also failed at the merge-base commit and how often it has failed in
# recent runs (across branches and on this one), so a red case reads as
# either a real regression or a known flake, not just "red". Leave unset
# for suite-level reporting instead (same discrimination, one case named
# "SUITE" standing in for the whole gate command) — every profile gets this
# for free with zero configuration; per-case is strictly more precise where
# GATE_CMD's own output has a stable, parseable pass/fail convention. The
# reference extractor for fwf's OWN "  ok   <label>" / "  FAIL <label>"
# test/run.sh convention (what a profile gating THIS repo would declare):
#   GATE_CASE_EXTRACTOR="awk '/^  ok   / { print \"PASS \" substr(\$0,8) } /^  FAIL / { print \"FAIL \" substr(\$0,8) }'"
# A passing run's output is completely unaffected either way — the report
# only ever appears alongside a FAILING case.



# Live-dev hint shown to implementers. Use __DATA__ for this tree's dev-data dir
# (only meaningful if you define data_dir() below).
DEV_UI_HINT='make dev'

# user-testing template (issue #42) ONLY: the running app URL the source-blind
# personas drive with a browser (rendered into their prompts as __UT_APP_URL__).
# MUST be an isolated scratch/UAT instance — fwf refuses a prod-looking host
# (loopback, *.local/*.test, or a host containing uat/staging/test/scratch/
# sandbox/dev pass; a human can override one launch with FWF_UT_ALLOW_TARGET=1).
# Unused by every other template. Leave unset unless you run `--template user-testing`.
UT_APP_URL="${FWF_UT_APP_URL:-}"
# Per-persona app instances (recommended — avoids shared-backend bleed between
# personas, trial one's #1 false-signal source). UT_APP_URL_<id> overrides the
# shared URL for persona <id>; each is guarded the same way. Leave unset to share.
#   UT_APP_URL_1="http://localhost:3941"
#   UT_APP_URL_2="http://localhost:3942"
#   UT_APP_URL_3="http://localhost:3943"
# Browser engine the personas' Playwright MCP drives (default firefox — the
# trial-validated default). See docs/user-testing.md to wire it.
UT_BROWSER="${FWF_UT_BROWSER:-firefox}"

# Optional: factory design, issue backend, floor sizing, per-role models.
# CLI flags (fwf up --template T --issues B --pairs N --impl-model M …) and
# env vars beat these profile defaults — keep the ${VAR:-default} shape.
# FWF_TEMPLATE="${FWF_TEMPLATE:-ideation}"     # factory design (default dev; see fwf templates)
# FWF_ISSUES="${FWF_ISSUES:-local}"            # issue backend (default gh; local = md store + no-push guard)
# FWF_PAIRS="${FWF_PAIRS:-2}"                  # implementer/QA pairs (default 3)
# FWF_MODEL="${FWF_MODEL:-}"                   # model for EVERY agent (claude --model)
# FWF_MODEL_IMPL="${FWF_MODEL_IMPL:-sonnet}"   # per-role override; also FWF_MODEL_QA,
#                                              # _PM, _GV, _CAPTAIN, _CONDUCTOR

# Optional: isolated per-worktree dev data. The no-op defaults in config.sh apply
# unless you override these. Define them if each worktree needs its own seeded
# data so parallel implementers don't collide on shared state.
# data_dir()  { echo "$HOME/example-dev-data-$1"; }                 # $1 = role tag
# seed_data() { "$FWF_REPO/scripts/seed-dev.sh" "$1" >/dev/null 2>&1 || true; }  # $1 = data dir
