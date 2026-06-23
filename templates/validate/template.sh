#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: validation factory — falsify a posited business+product idea down
# a GO/KILL/PIVOT funnel (market reality → solution → business), short-circuit on
# any gate that finds no viability, preserve state for an evidence-gated override.
#
# Config DEFAULTS for this template. lib.sh sources this AFTER the profile, and
# only ${VAR:-default} patterns apply — so env/CLI/profile settings still win.
#
# Three stance-diverse analyst/red-team pairs give the funnel parallel attack
# angles at each gate (Gate 1: incumbents / demand / timing) while the
# adjudicator and captain serialize the convergent judgment.
FWF_PAIRS="${FWF_PAIRS:-3}"

# Visual identity: a validation floor should LOOK like one (analysts attacking a
# claim, a red team, a verdict-writer), not a code floor.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-ANALYST}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-REDTEAM}"
FWF_DISPLAY_CONDUCTOR="${FWF_DISPLAY_CONDUCTOR:-JUDGE}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-FRAMER}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-falsify → dossier sections}"
FWF_DESC_QA="${FWF_DESC_QA:-red-teams + merges sections}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-gate verdicts: GO/KILL/PIVOT}"
FWF_DESC_PM="${FWF_DESC_PM:-idea → falsifiable hypothesis}"
