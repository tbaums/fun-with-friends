#!/usr/bin/env bash
# Repo profile: transom (Rust workspace). Sourced after config.sh by lib.sh.
# To target a different repo, copy this file to profiles/<name>.sh, adjust the
# commands, and launch with FWF_PROFILE=<name>.

FWF_REPO="${FWF_REPO:-$HOME/transom}"   # the application repo (source of truth)
WT_PREFIX="${FWF_WT_PREFIX:-tx}"        # worktrees named ${WT_PREFIX}-impl1, -qa1, -pm, -conductor
BASE_BRANCH="${FWF_BASE_BRANCH:-integration}"   # PRs target this; QA merges here
DEFAULT_BRANCH="${FWF_DEFAULT_BRANCH:-main}"    # conductor promotes integration -> here

# Commands run inside a worktree ---------------------------------------------
GATE_CMD='cargo test --workspace && cargo check -p frontend --target wasm32-unknown-unknown'
E2E_CMD='cd tests/e2e && npx playwright test'
BUILD_CMD='cargo build -q -p server -p worker'
E2E_SETUP_CMD='cd tests/e2e && npm install'     # run once in the conductor tree at provision

# Live-UI hint shown to implementers (__DATA__ -> that tree's dev-data dir).
DEV_UI_HINT='TRANSOM_DEV_DATA=__DATA__ ./scripts/dev.sh   (dev ports 3939/8081, one UI at a time)'

# Isolated per-worktree dev data (transom seeds a throwaway synthetic git repo).
data_dir()  { echo "$HOME/transom-dev-data-$1"; }                              # $1 = role tag
seed_data() { "$FWF_REPO/scripts/seed-dev.sh" "$1" >/dev/null 2>&1 || true; }  # $1 = data dir
