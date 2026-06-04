#!/usr/bin/env bash
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

# PM drafts wear this label; implementers skip any issue carrying it until you remove it.
WIP_LABEL="${FWF_WIP_LABEL:-product-wip}"
# How long fwf-up / fwf-respawn wait for claude to boot in a pane before sending a prompt.
FWF_BOOT_TIMEOUT="${FWF_BOOT_TIMEOUT:-45}"

# Where worktrees live, and run-state (the e2e lock).
WT_BASE="${FWF_WT_BASE:-$HOME}"
FWF_RUN="${FWF_RUN_DIR:-$HOME/.fun-with-friends}"
E2E_LOCK="$FWF_RUN/e2e.lock"
STOP_FILE="$FWF_RUN/STOP"   # fwf-stop.sh creates this; agents that notice it commit WIP, cancel their loop, and idle

# Colors. ONE hue per implementer/QA pair (the implementer matches its QA, by request).
# PM and conductor get their own distinct colors.
pair_color() { case "$1" in 1) echo colour203;; 2) echo colour78;; 3) echo colour45;; esac; }
PM_COLOR="${FWF_PM_COLOR:-colour213}"
CONDUCTOR_COLOR="${FWF_CONDUCTOR_COLOR:-colour220}"
