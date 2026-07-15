#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: skill-runner (Phase 1, archetype B) — spins up with a (skill,
# target) pair and drives a found DEFECT to a filed, reviewer-ready REPORT in
# one pass: contract-load the standard → gather+feasibility-check the repro →
# build the report → standard-gate it → receiver-edit + sanitize → verify
# facts/side-effects → deliver to the target surface. See this dir's
# README.md for the full 9-failure-mode → stage map and the PRE-REGISTERED
# eval protocol (issue #117, Phase 1: archetype B only).
#
# Config DEFAULTS for this template. lib.sh sources this AFTER the profile,
# and only ${VAR:-default} patterns apply — so env/CLI/profile settings win.
#
# Built ON the `validate` template: same PM-drafts/GV-gates-the-frame,
# floor-produces/QA-attacks-and-merges, conductor-adjudicates-and-promotes,
# captain-presents-to-human skeleton — reframed from "kill an idea" to "drive
# one (skill,target) run to a filable defect report". Declares the base so
# lineage is explicit and any un-overridden role falls back to validate
# rather than erroring (none are expected to — all six are overridden below).
FWF_TEMPLATE_BASE="validate"

# A single (skill,target) run is one pipeline pass, not a parallel funnel —
# Phase 1 has no stance-diverse pairs. Pin to 1 regardless of profile default.
FWF_PAIRS="1"

# Visual identity: a skill-runner floor should look like a report line, not a
# code floor or a validation funnel.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-BUILDER}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-RECEIVER}"
FWF_DISPLAY_CONDUCTOR="${FWF_DISPLAY_CONDUCTOR:-DELIVERY}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-CONTRACT}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-gather+build → grounded report}"
FWF_DESC_QA="${FWF_DESC_QA:-receiver-edit + sanitize + merge}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-verify + deliver + checklist score}"
FWF_DESC_PM="${FWF_DESC_PM:-loads standard → derives checklist}"

# Judgment-heavy seats (checklist derivation, standard-gate, checklist
# scoring) want the strong model; per-role FWF_MODEL_* overrides still win.
FWF_MODEL_PM="${FWF_MODEL_PM:-opus}"
FWF_MODEL_GV="${FWF_MODEL_GV:-opus}"
FWF_MODEL_CONDUCTOR="${FWF_MODEL_CONDUCTOR:-opus}"
