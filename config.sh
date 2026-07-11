#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars here are consumed by other sourced scripts
# fun-with-friends — a generic, repo-agnostic multi-agent dev swarm.
# Generic defaults only. Repo-specific commands live in profiles/<name>.sh.
# Every value is overridable by the matching FWF_* env var.

FWF_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Which factory template the agents run — a directory under templates/ holding
# the six role prompts (and an optional template.sh of config defaults).
# CLI: fwf up --template NAME. DELIBERATELY not defaulted here (issue #30):
# profiles persist it with FWF_TEMPLATE="${FWF_TEMPLATE:-ideation}", which only
# works if nothing pre-fills the var before the profile loads — lib.sh applies
# the final fallback (dev) after profile sourcing.

# How many implementer/QA pairs the floor runs (each id = one implementer + its
# paired QA reviewer). DELIBERATELY not defaulted here: profiles and templates
# get to set their own default, so lib.sh applies the final fallback (3) only
# after both load. CLI: fwf up --pairs N.

# Per-role model overrides (claude CLI --model). Empty = the CLI's default.
# FWF_MODEL is the floor-wide default; FWF_MODEL_<ROLE> beats it for that role.
# CLI: fwf up --model M --impl-model M --qa-model M --pm-model M --gv-model M
#      --captain-model M --conductor-model M
FWF_MODEL="${FWF_MODEL:-}"
FWF_MODEL_IMPL="${FWF_MODEL_IMPL:-}"
FWF_MODEL_QA="${FWF_MODEL_QA:-}"
FWF_MODEL_PM="${FWF_MODEL_PM:-}"
FWF_MODEL_GV="${FWF_MODEL_GV:-}"
FWF_MODEL_CAPTAIN="${FWF_MODEL_CAPTAIN:-}"
FWF_MODEL_CONDUCTOR="${FWF_MODEL_CONDUCTOR:-}"

# Issue-tracker backend: "gh" (the target repo's GitHub issues — the default)
# or "local" (a markdown store under $FWF_RUN/issues/<profile>, OUTSIDE any
# repo, driven by `fwf issues` — for repos whose issues/labels you don't
# control). CLI: fwf up --issues local. DELIBERATELY not defaulted here (same
# #30 ordering trap as FWF_TEMPLATE): lib.sh defaults it to gh after the
# profile AND template load, so both can persist it with the ${VAR:-} idiom.

# The model menu `fwf suggest` recommends from — "id:traits" entries separated
# by " | ". Edit as models evolve; it is advisory text, not validation.
FWF_MODEL_MENU="${FWF_MODEL_MENU:-claude-opus-4-8:strongest reasoning, highest cost — synthesis, strategy, judgment seats | claude-sonnet-4-6:strong all-round default — building, reviewing, planning | claude-haiku-4-5-20251001:fast and cheap — mechanical, high-volume, rubric-scored seats}"

# tmux sessions + cadence. The factory runs as TWO sessions: a COORDINATION
# session (pm · gv · captain) the human attaches to and talks to the captain in,
# and an IMPLEMENTATION session (impl1-3 · qa1-3 · conductor) that builds. They
# coordinate through the issue tracker + git, never across panes. FWF_SESSION is
# the shared base name; each session derives from it (overridable individually).
# Session names derive in lib.sh AFTER the template resolves (issue #31): the
# dev template keeps the classic ${SESSION}-coord/-build, every other template
# gets its name embedded (friends-ideation-coord/-build) so `tmux ls` always
# says which factory design is live. FWF_SESSION/FWF_COORD_SESSION/
# FWF_BUILD_SESSION still override.
QA_LOOP_INTERVAL="${FWF_QA_INTERVAL:-1m}"          # how often each QA loop re-checks
CONDUCTOR_INTERVAL="${FWF_CONDUCTOR_INTERVAL:-2m}" # how often the conductor e2e+promotes
PM_INTERVAL="${FWF_PM_INTERVAL:-5m}"               # how often the PM loop reviews its draft issues
GV_INTERVAL="${FWF_GV_INTERVAL:-3m}"               # how often the Grand Vizier reviews gated drafts + captain plans
CAPTAIN_INTERVAL="${FWF_CAPTAIN_INTERVAL:-2m}"     # captain loop tick — surfaces pending human decisions every tick (also takes human input live)
IMPL_INTERVAL="${FWF_IMPL_INTERVAL:-2m}"           # implementers loop too, so they advance after each handoff (no idle-waiting)
CLAUDE_CMD="${FWF_CLAUDE_CMD:-claude --dangerously-skip-permissions}"
# The bare claude binary (first token), captured BEFORE the `env` wrappers below
# and in lib.sh mangle the first token — doctor and preflights probe this.
FWF_CLAUDE_BIN="${CLAUDE_CMD%% *}"
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
# Discovery / exploration: the deliverable is a written PROPOSAL (investigation + a
# build-or-no-go recommendation), NOT feature code. An implementer that claims a
# discovery ticket produces docs/proposals/<num>-<slug>.md instead of a code change;
# a proposal that recommends building spawns a NEW build ticket through the normal flow.
# This is the path for GV-signed-as-SCOPED (not "build it") tickets, so they no longer
# stall in product-wip limbo with no role to produce them.
DISCOVERY_LABEL="${FWF_DISCOVERY_LABEL:-discovery}"
# How long fwf-up / fwf-respawn wait for claude to boot in a pane before sending a prompt.
FWF_BOOT_TIMEOUT="${FWF_BOOT_TIMEOUT:-45}"

# Where worktrees live, and run-state (the e2e lock).
# WT_BASE defaults to $HOME for backward-compat, but a generated profile (from
# `fwf init <url>`) overrides it to that repo's workspace dir so ten worktrees
# don't pile up in your home directory.
WT_BASE="${FWF_WT_BASE:-$HOME}"
FWF_RUN="${FWF_RUN_DIR:-$HOME/.fun-with-friends}"
# Per-repo workspaces live here: each `fwf init/start <url>` clones into
# $FWF_WORKSPACE_BASE/<name>/repo and puts that profile's worktrees alongside.
FWF_WORKSPACE_BASE="${FWF_WORKSPACE_BASE:-$FWF_RUN/workspaces}"
E2E_LOCK="$FWF_RUN/e2e.lock"
STOP_FILE="$FWF_RUN/STOP"   # fwf-stop.sh creates this; agents that notice it commit WIP, cancel their loop, and idle

# Hard token-budget enforcement (issue #96, Ticket B of #70's discovery — see
# docs/proposals/70-token-usage-budget.md). Unset/empty = unlimited, the
# default — enforcement is opt-in. CLI: fwf up --token-budget N.
FWF_TOKEN_BUDGET="${FWF_TOKEN_BUDGET:-}"
FWF_TOKEN_BUDGET_WARN_PCT="${FWF_TOKEN_BUDGET_WARN_PCT:-80}"
# How often the `fwf budget-check` WRITER re-evaluates (see fwf-budget-check.sh).
FWF_BUDGET_CHECK_INTERVAL="${FWF_BUDGET_CHECK_INTERVAL:-60}"
# The sentinel every role's step-0 HONORER check reads (mirrors STOP_FILE's
# pattern exactly). Carries a one-line state: "HOLD <reason>" / "WARN <reason>"
# / absent = clear. Written ONLY by the WRITER (fwf-budget-check.sh) — every
# other role only ever reads it.
BUDGET_HOLD_FILE="$FWF_RUN/BUDGET_HOLD"

# Per-worktree dev data. Default to no-ops so a profile for a repo with no dev
# data can omit them entirely; a profile may override these to seed an
# isolated data dir per tree. data_dir echoes nothing by default (so a
# __DATA__ placeholder in DEV_UI_HINT collapses to empty).
data_dir()  { :; }          # $1 = role tag; echo a path if the repo needs isolated dev data
seed_data() { :; }          # $1 = data dir; seed it if the repo needs it

# Colors. ONE hue per implementer/QA pair (the implementer matches its QA, by
# request); the palette cycles so any --pairs count gets a color. PM and
# conductor get their own distinct colors.
pair_color() { case "$(( ($1 - 1) % 6 + 1 ))" in 1) echo colour203;; 2) echo colour78;; 3) echo colour45;; 4) echo colour214;; 5) echo colour135;; 6) echo colour87;; esac; }
PM_COLOR="${FWF_PM_COLOR:-colour213}"
CONDUCTOR_COLOR="${FWF_CONDUCTOR_COLOR:-colour220}"
GV_COLOR="${FWF_GV_COLOR:-colour129}"            # Grand Vizier — distinct purple
CAPTAIN_COLOR="${FWF_CAPTAIN_COLOR:-colour33}"   # Captain — commanding blue
