#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars here are consumed by other sourced scripts
# fun-with-friends — a generic, repo-agnostic multi-agent dev swarm.
# Generic defaults only. Repo-specific commands live in profiles/<name>.sh.
# Every value is overridable by the matching FWF_* env var.

FWF_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Implementer/QA pair ids (each id = one implementer + its paired QA reviewer).
PAIRS=(1 2 3)

# tmux session + cadence
SESSION="${FWF_SESSION:-friends}"
QA_LOOP_INTERVAL="${FWF_QA_INTERVAL:-1m}"          # how often each QA loop re-checks
CONDUCTOR_INTERVAL="${FWF_CONDUCTOR_INTERVAL:-2m}" # how often the conductor e2e+promotes
PM_INTERVAL="${FWF_PM_INTERVAL:-5m}"               # how often the PM loop reviews its draft issues
IMPL_INTERVAL="${FWF_IMPL_INTERVAL:-2m}"           # implementers loop too, so they advance after each handoff (no idle-waiting)
CLAUDE_CMD="${FWF_CLAUDE_CMD:-claude --dangerously-skip-permissions}"
# Environment prepended to each claude launch. CLAUDE_CODE_FORCE_SYNC_OUTPUT=1
# makes terminal redraws atomic (helps avoid dropped/garbled input under tmux).
# Add CLAUDE_CODE_NO_FLICKER=1 for alt-screen isolation (changes scrollback), or
# set FWF_CLAUDE_ENV="" to disable.
FWF_CLAUDE_ENV="${FWF_CLAUDE_ENV:-CLAUDE_CODE_FORCE_SYNC_OUTPUT=1}"
[ -n "$FWF_CLAUDE_ENV" ] && CLAUDE_CMD="env $FWF_CLAUDE_ENV $CLAUDE_CMD"

# PM drafts wear this label; implementers skip any issue carrying it until you remove it.
WIP_LABEL="${FWF_WIP_LABEL:-product-wip}"
# Release-freeze hold: the PM applies this to tickets that should wait for a future release,
# so the queue drains to a clean integration cutoff before you release. Implementers skip it too.
HOLD_LABEL="${FWF_HOLD_LABEL:-release-hold}"
# How long fwf-up / fwf-respawn wait for claude to boot in a pane before sending a prompt.
FWF_BOOT_TIMEOUT="${FWF_BOOT_TIMEOUT:-45}"

# Where worktrees live, and run-state (the e2e lock).
# WT_BASE defaults to $HOME for backward-compat, but a generated profile (from
# `fwf init <url>`) overrides it to that repo's workspace dir so eight worktrees
# don't pile up in your home directory.
WT_BASE="${FWF_WT_BASE:-$HOME}"
FWF_RUN="${FWF_RUN_DIR:-$HOME/.fun-with-friends}"
# Per-repo workspaces live here: each `fwf init/start <url>` clones into
# $FWF_WORKSPACE_BASE/<name>/repo and puts that profile's worktrees alongside.
FWF_WORKSPACE_BASE="${FWF_WORKSPACE_BASE:-$FWF_RUN/workspaces}"
E2E_LOCK="$FWF_RUN/e2e.lock"
STOP_FILE="$FWF_RUN/STOP"   # fwf-stop.sh creates this; agents that notice it commit WIP, cancel their loop, and idle

# Per-worktree dev data. Default to no-ops so a profile for a repo with no dev
# data can omit them entirely; a profile may override these to seed an
# isolated data dir per tree. data_dir echoes nothing by default (so a
# __DATA__ placeholder in DEV_UI_HINT collapses to empty).
data_dir()  { :; }          # $1 = role tag; echo a path if the repo needs isolated dev data
seed_data() { :; }          # $1 = data dir; seed it if the repo needs it

# Colors. ONE hue per implementer/QA pair (the implementer matches its QA, by request).
# PM and conductor get their own distinct colors.
pair_color() { case "$1" in 1) echo colour203;; 2) echo colour78;; 3) echo colour45;; esac; }
PM_COLOR="${FWF_PM_COLOR:-colour213}"
CONDUCTOR_COLOR="${FWF_CONDUCTOR_COLOR:-colour220}"
