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

FWF_REPO="${FWF_REPO:-$HOME/your-repo}"     # the application repo (source of truth)
WT_PREFIX="${FWF_WT_PREFIX:-ex}"            # worktrees: ${WT_PREFIX}-impl1, -qa1, -pm, -conductor
# Where worktrees live. Leave unset to use $HOME; point it at a workspace dir to
# keep eight worktrees out of your home directory (what `fwf init` does).
WT_BASE="${FWF_WT_BASE:-$HOME/.fun-with-friends/workspaces/example}"

STAGING_BRANCH="${FWF_STAGING_BRANCH:-staging}"             # impl PRs target this; QA fast-gates + merges here
INTEGRATION_BRANCH="${FWF_INTEGRATION_BRANCH:-integration}" # conductor e2e-promotes here (your release source)
DEFAULT_BRANCH="${FWF_DEFAULT_BRANCH:-main}"                # released by you; the swarm never touches it

# Commands run inside a worktree ---------------------------------------------
GATE_CMD='make test'              # fast gate QA runs before merging to staging (tests + typecheck/lint)
BUILD_CMD='true'                  # warm-build per worktree at provision (use 'true' if none)
E2E_CMD='true'                    # full e2e the conductor runs before promoting to integration ('true' = none)
E2E_SETUP_CMD=''                  # one-time e2e dep install in the conductor tree (e.g. 'npx playwright install')

# Live-dev hint shown to implementers. Use __DATA__ for this tree's dev-data dir
# (only meaningful if you define data_dir() below).
DEV_UI_HINT='make dev'

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
