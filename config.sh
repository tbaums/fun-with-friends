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
# issue #289 (a4): claude-sonnet-4-6 was offered here but has no price-table
# entry (fwf-usage-data.sh) and is not a model this project's roles actually
# run — replaced with claude-sonnet-5, the model every impl/qa/conductor
# seat on this factory is really running today and the only sonnet tier that
# IS priced. Do not re-add an entry here without a matching price-table row
# (or a documented (a3) exception) — an unpriceable menu entry re-arms this
# same defect for the next operator who picks it.
FWF_MODEL_MENU="${FWF_MODEL_MENU:-claude-opus-4-8:strongest reasoning, highest cost — synthesis, strategy, judgment seats | claude-sonnet-5:strong all-round default — building, reviewing, planning | claude-haiku-4-5-20251001:fast and cheap — mechanical, high-volume, rubric-scored seats}"

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
# Output style for every seat (issue #187): panes talk to each other through
# the issue tracker + git, not their own narration, so Claude Code's default
# prose is pure token cost here. Concise is the floor-wide default; fwf_claude_cmd
# passes it via --settings. Set FWF_OUTPUT_STYLE="" (explicitly empty, not just
# unset) to opt back out — a plain ${VAR:-} default would treat "" the same as
# unset and silently re-apply Concise, so this uses ${VAR-} instead.
FWF_OUTPUT_STYLE="${FWF_OUTPUT_STYLE-Concise}"

# PM drafts wear this label; implementers skip any issue carrying it until you remove it.
WIP_LABEL="${FWF_WIP_LABEL:-product-wip}"
# Operator un-gate sentinel (issue #150): the POSITIVE, attributable, mechanically
# checkable authorization signal. `fwf dash` approve — a HUMAN keypress on the
# board — is the only path that emits it (into the issue thread as a comment);
# `fwf authz <issue>` verifies it. It exists because label-absence alone is
# unattributable (every role shares one account), which is the gap a role once
# filled with fabricated pane/ghost text — inventing a human confirmation and
# reverting approved work. A durable comment is the signal of record precisely
# because it survives a wrongful re-gate, unlike the mutable label state.
OPERATOR_UNGATE_SENTINEL="${FWF_OPERATOR_UNGATE_SENTINEL:-OPERATOR-UNGATE}"
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
# A parked idea the human recorded for later, distinct from DISCOVERY_LABEL
# above (a scoped investigation ticket whose deliverable is a proposal doc).
# Previously a bare literal ("idea") repeated in five templates with no
# config var at all -- issue #255's "half-templated, half-hardcoded" defect,
# named so a future edit does not re-conflate it with DISCOVERY_LABEL again.
IDEA_LABEL="${FWF_IDEA_LABEL:-idea}"
# Meta/coordination marker (issue #255): a living document (the dependency
# graph, the release audit) the PM posts to every cycle, not buildable work.
TRACKING_LABEL="${FWF_TRACKING_LABEL:-tracking}"
# Coordination-lane idle-backfill (issue #169): a doc-only/chunkable coordination
# item (PM) or a from-scratch discovery proposal (GV, alongside DISCOVERY_LABEL,
# only during a floor-down sustained pass) still being drafted via checkpointed
# issue COMMENTS -- never a branch or file, since PM/GV are read-only roles that
# never touch branches or PRs. Present = still being drafted, implementers skip
# it; the coordination role removes it once a final "COORD-DRAFT: READY" comment
# hands the fully-drafted content to an implementer's normal claim-and-build
# cycle. See docs/coordination-idle-backfill.md.
COORD_LABEL="${FWF_COORD_LABEL:-coordination-only}"
# Survey exclusion set (issue #255): what an implementer's / captain's / pm's
# `gh issue list` survey excludes. Single-sourced here so a rename, or adding
# a new exclusion, is a ONE-PLACE edit instead of N template edits in two
# different styles (which is how #161 -- a TRACKING issue with none of the
# other exclusion labels -- ended up claimable: `tracking` was never added
# anywhere). Two sets, not one, and the split is DELIBERATE, not duplication:
# implementers must never see (and so never claim) a parked "idea"; the PM's
# own role prompt instructs it to SEE "idea" issues and skip them by hand,
# which requires the PM's survey to include them. Same label, opposite
# correct treatment. fwf_render (lib.sh) picks the set by role and expands
# both the -label: flags AND the matching human-readable eligibility prose
# from it, so the two can never independently drift the way the six-times,
# two-styles version did.
SURVEY_EXCLUDE_IMPL="${FWF_SURVEY_EXCLUDE_IMPL:-$WIP_LABEL $HOLD_LABEL $IDEA_LABEL $TRACKING_LABEL $COORD_LABEL}"
SURVEY_EXCLUDE_COORD="${FWF_SURVEY_EXCLUDE_COORD:-$WIP_LABEL $HOLD_LABEL $TRACKING_LABEL}"
# needs-captain flag (issue #113): any role raises this on an issue/PR via
# `fwf flag-captain` when something needs the captain's decision; the captain
# sweeps it every tick so a raised flag can't go unseen (the pane-line
# incident this closes). Carrier is a label + a NEEDS-CAPTAIN: comment — see
# fwf-flag-captain.sh and docs/needs-captain.md.
NEEDS_CAPTAIN_LABEL="${FWF_NEEDS_CAPTAIN_LABEL:-needs-captain}"
# Operator→captain channel (issue #192): `fwf operator-decision <n> <text>`
# writes an attributable artifact (an issue/PR comment) delivering a human
# decision when the board keypress isn't available; `--floor` posts to this
# configured coordination issue instead of naming one. Empty by default —
# --floor refuses (rather than guessing a destination) until a profile sets
# it. See fwf-operator-decision.sh and docs/operator-decision.md.
FLOOR_ISSUE="${FWF_FLOOR_ISSUE:-}"
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
# issue #494: the FIFO ticket queue for e2e-lane waiters -- a SIBLING dir of
# E2E_LOCK (never nested under it), so an `rm -rf "$E2E_LOCK"` from anywhere
# else can never take the queue down with it, matching the same reasoning
# already applied to per-lane dirs above.
E2E_QUEUE="$FWF_RUN/e2e.queue"
# Resource-keyed e2e leases (issue #205): the contended resource is the
# concrete port + data dir, not "e2e" abstractly. Up to FWF_E2E_MAX_LANES
# leases are held at once, each on port FWF_E2E_PORT_BASE+(lane-1) and a
# freshly-generated data dir under FWF_E2E_DATA_BASE — see lib.sh's
# fwf_e2e_lock_acquire. Ships at MAX_LANES=1 (a strict no-op: identical
# behavior to the single global lock this replaces, AC d/i) until a consumer
# (transom) reads FWF_E2E_PORT/FWF_E2E_DATA_DIR and the cap is deliberately
# raised in a separate, observable step.
FWF_E2E_MAX_LANES="${FWF_E2E_MAX_LANES:-1}"
FWF_E2E_PORT_BASE="${FWF_E2E_PORT_BASE:-3940}"
FWF_E2E_DATA_BASE="${FWF_E2E_DATA_BASE:-$FWF_RUN/e2e-data}"
# Floor-wide cargo build concurrency bound (issue #138 piece C): a SEMAPHORE
# (not a mutex like E2E_LOCK above) — up to this many roles may hold a build
# slot at once via fwf_cargo_build_slot_acquire; the (N+1)th waits. N~1-2
# keeps concurrent full cargo builds from CPU/IO-thrashing each other.
FWF_CARGO_BUILD_CONCURRENCY="${FWF_CARGO_BUILD_CONCURRENCY:-2}"
CARGO_BUILD_LOCK="$FWF_RUN/cargo-build.lock"

# --- memory-admission control (issue #156) -----------------------------------
# The build-serialization mechanism #156's discovery chose (strategy b): gate
# every heavy build's START on MEASURED ground-truth free RAM minus the summed
# live reservations, holding only a sub-second decision mutex for the atomic
# measure+reserve — NEVER a lock across the multi-GB build. That structurally
# avoids the failed prototype's fatal orphan-hole (no lock is held across the
# build, so nothing auto-releases into an orphan) and never blocks a waiting
# #123 gate for 25min while it holds its per-role lock. See lib.sh's
# fwf_mem_admit and docs/proposals/156-build-serialization.md.
#
# OPT-IN: default OFF (issue #286 — v0.32.1 flipped this to 1 without the
# criterion-3 calibration the reserves below still need, and the fixed
# inequality it enforces is UNSATISFIABLE on a CI runner / small box: with the
# shipped FWF_MEM_RESERVE_BUILD_GB=6 and FWF_MEM_ADMIT_FLOOR_GB=8 below, a
# second --cargo-build holder needs >=20 GiB free, which no small box has —
# every gate then waits the full FWF_MEM_ADMIT_TIMEOUT and exits EX_SKIPPED,
# not flakily but every time. Reverted to 0, restoring the exact configuration
# measured green on both CI platforms at v0.32.0). With admission OFF, the
# existing cargo-build SEMAPHORE (FWF_CARGO_BUILD_CONCURRENCY, fwf-gate.sh)
# stays the sole throttle, unchanged. The route back to ON is shadow-log (log
# the admission decision, admit unconditionally) on real boxes under real
# load, THEN a single-runner canary, THEN fleet-wide — never a second blind
# flip of this default. See docs/proposals/156-build-serialization.md and
# issue #286.
FWF_MEM_ADMIT_ENABLE="${FWF_MEM_ADMIT_ENABLE:-0}"
MEM_ADMIT="$FWF_RUN/mem-admit.lock"
FWF_MEM_ADMIT_TIMEOUT="${FWF_MEM_ADMIT_TIMEOUT:-900}"        # bounded wait; < the 1800s gate max-run ceiling (hole #2/#3)
FWF_MEM_ADMIT_POLL="${FWF_MEM_ADMIT_POLL:-5}"                # seconds between admission attempts
FWF_MEM_ADMIT_STALE_SECS="${FWF_MEM_ADMIT_STALE_SECS:-1800}" # ~30m backstop for an indeterminate (cross-host/unparseable) reservation
FWF_MEM_ADMIT_REPORT_SECS="${FWF_MEM_ADMIT_REPORT_SECS:-30}" # how often the "queued on RAM" line prints (mirrors the e2e lock cadence)
FWF_MEM_ADMIT_DECISION_STALE_SECS="${FWF_MEM_ADMIT_DECISION_STALE_SECS:-60}" # backstop for the sub-second decision mutex itself
# Free-RAM floor to hold back for the OS + resident consumers the mechanism
# CANNOT bound (rust-analyzer, proc-macro servers, editors). PROVISIONAL.
FWF_MEM_ADMIT_FLOOR_GB="${FWF_MEM_ADMIT_FLOOR_GB:-8}"
# Measured PEAK RSS to reserve per op-class. PROVISIONAL PLACEHOLDERS — these
# are the exact numbers criterion (3) says MUST be measured on the real
# multi-agent box before this is trusted. Reserving the link-PEAK (not current
# usage) bounds a spike that lands minutes into a build.
FWF_MEM_RESERVE_FAST_GB="${FWF_MEM_RESERVE_FAST_GB:-2}"   # cargo check / fast gate
FWF_MEM_RESERVE_BUILD_GB="${FWF_MEM_RESERVE_BUILD_GB:-6}" # full cargo build+test (rustc link peak)
FWF_MEM_RESERVE_E2E_GB="${FWF_MEM_RESERVE_E2E_GB:-6}"     # cargo build + playwright chromium+webkit

# Kill-safe gate process-group ownership (issue #156 hole #1). fwf-gate.sh makes
# itself a process-group LEADER so a kill takes cargo down WITH the release —
# never orphaning a multi-GB build that a second gate then stacks on. Default ON
# where perl is present; set 0 to disable (debugging on a box without perl).
FWF_GATE_PGLEADER_ENABLE="${FWF_GATE_PGLEADER_ENABLE:-1}"

STOP_FILE="$FWF_RUN/STOP"   # fwf-stop.sh creates this; agents that notice it commit WIP, cancel their loop, and idle

# Hard token-budget enforcement (issue #96, Ticket B of #70's discovery — see
# docs/proposals/70-token-usage-budget.md). Unset/empty = unlimited, the
# default — enforcement is opt-in. CLI: fwf up --token-budget N.
FWF_TOKEN_BUDGET="${FWF_TOKEN_BUDGET:-}"
# Estimated-$ ceiling (issue #108) — the human-intuitive alternative to raw
# tokens: the price table (fwf-usage-data.sh) already prices cache-read at its
# true low rate, so a $ budget is already correctly cache-read-weighted with
# no down-weight factor to invent. CLI: fwf up --budget-usd N. Mutually
# exclusive with FWF_TOKEN_BUDGET (validated in lib.sh — both set is an error,
# never a silent pick-one).
FWF_BUDGET_USD="${FWF_BUDGET_USD:-}"
FWF_TOKEN_BUDGET_WARN_PCT="${FWF_TOKEN_BUDGET_WARN_PCT:-80}"
# How often the `fwf budget-check` WRITER re-evaluates (see fwf-budget-check.sh).
# Enforcement is poll-based: a HOLD fires within one interval of crossing the
# cap, not at the instant it's crossed — see fwf --help.
FWF_BUDGET_CHECK_INTERVAL="${FWF_BUDGET_CHECK_INTERVAL:-60}"
# The sentinel every role's step-0 HONORER check reads (mirrors STOP_FILE's
# pattern exactly). Carries a one-line state: "HOLD <reason>" / "WARN <reason>"
# / absent = clear. Written ONLY by the WRITER (fwf-budget-check.sh) — every
# other role only ever reads it.
BUDGET_HOLD_FILE="$FWF_RUN/BUDGET_HOLD"

# Subscription-usage brake (issue #149): fwf's token/$ guards above are blind
# to the Claude subscription's OWN usage meters (the rolling 5h session window
# and the weekly allowance) — the thing that actually stops a Max-plan
# operator. fwf does not (and cannot, from inside this environment) read those
# meters itself; it consumes a STRUCTURED signal an operator-run helper writes
# — deliberately never OCR, see docs/subscription-budget.md. Unset/empty
# (both PARK vars absent) = not armed, the default — this feature does
# nothing unless explicitly configured. CLI: fwf up --session-pct
# PARK[/RESUME] / --weekly-pct PARK[/RESUME].
SUBSCRIPTION_USAGE_FILE="$FWF_RUN/subscription-usage.json"
FWF_SESSION_PCT_PARK="${FWF_SESSION_PCT_PARK:-}"
FWF_SESSION_PCT_RESUME="${FWF_SESSION_PCT_RESUME:-}"
FWF_WEEKLY_PCT_PARK="${FWF_WEEKLY_PCT_PARK:-}"
FWF_WEEKLY_PCT_RESUME="${FWF_WEEKLY_PCT_RESUME:-}"
# A signal older than this (vs. its own `as_of`) is stale -> fail-closed park,
# never read as current. 15min default: long enough that the helper's own
# poll interval doesn't self-trigger staleness, short enough that a genuinely
# wedged helper is caught well within one 5h session window.
FWF_SUBSCRIPTION_STALE_SECS="${FWF_SUBSCRIPTION_STALE_SECS:-900}"
# Default hysteresis gap (percentage points) below PARK when RESUME is
# omitted from --session-pct/--weekly-pct — resume never equals park (that's
# a timer with extra steps; a reading sitting exactly at the line would flap).
FWF_SUBSCRIPTION_RESUME_GAP="${FWF_SUBSCRIPTION_RESUME_GAP:-15}"
# Ratchet state (issue #149 AC: "monotonic-within-window sanity") + whether
# subscription enforcement specifically is the reason the floor is parked
# right now (distinct from BUDGET_HOLD_FILE, which composes with the
# token/$ guard) — both written only by fwf-budget-check.sh.
SUBSCRIPTION_MONOTONIC_FILE="$FWF_RUN/subscription-monotonic.json"
SUBSCRIPTION_PARKED_FILE="$FWF_RUN/subscription-parked"

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
