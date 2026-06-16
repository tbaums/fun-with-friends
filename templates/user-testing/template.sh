#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: user-testing factory (issue #42) — whacky, unscripted, SOURCE-BLIND
# personas drive the product like real humans (not like an LLM writing tests); a
# researcher dedupes their diaries into a ranked findings report; the human talks
# to the captain, who grades the trial against ground truth and gates which
# findings graduate to real tickets.
#
# Shape: 3 personas + 1 researcher + captain. Realized by REPURPOSING stock slots
# (the proven ideation/refactor grain) so the engine barely moves:
#   personas   = impl1..3  (display PERSONA, default Sonnet — cheap + impulsive,
#                arguably more user-like). STRUCTURALLY source-blind:
#                FWF_NO_WORKTREE_ROLES gives them NO checkout of the target — only
#                a browser (playwright) against the profile's UT_APP_URL plus a
#                throwaway scratch dir for a persistent browser context + evidence.
#   researcher = pm        (display RESEARCHER, default Opus — synthesis quality).
#   captain    = captain   (the human talks here; grades + gates findings).
#   qa / conductor / gv are SUPPRESSED — a user-test has no gate pipeline. Their
#   (unused) prompts are inherited from dev so role validation still passes.
#
# Trials run ONLY against an isolated scratch/UAT instance — fwf refuses a
# prod-looking UT_APP_URL (a human can override one launch with
# FWF_UT_ALLOW_TARGET=1). Designed for the default `gh` issue backend, so the
# researcher can read the target's tracker for cross-referencing AFTER sessions.
FWF_TEMPLATE_BASE="dev"
FWF_PAIRS="${FWF_PAIRS:-3}"                                   # 3 personas
FWF_SUPPRESS_ROLES="${FWF_SUPPRESS_ROLES:-qa conductor gv}"   # no gate pipeline
FWF_NO_WORKTREE_ROLES="${FWF_NO_WORKTREE_ROLES:-impl}"        # personas are source-blind

# Visual identity (issue #31): a user-testing floor should LOOK like one.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-PERSONA}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-RESEARCHER}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-source-blind user · browser only}"
FWF_DESC_PM="${FWF_DESC_PM:-dedupes diaries → ranked findings}"

# Default models — per-role FWF_MODEL_* overrides still win. Personas on Sonnet
# (cheap, impulsive, more user-like); researcher on Opus (synthesis quality).
FWF_MODEL_IMPL="${FWF_MODEL_IMPL:-sonnet}"
FWF_MODEL_PM="${FWF_MODEL_PM:-opus}"
