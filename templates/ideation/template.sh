#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: ideation factory — parallel divergence, hardened critique, curated convergence
#
# Config DEFAULTS for this template. lib.sh sources this AFTER the profile, and
# only ${VAR:-default} patterns apply — so env/CLI/profile settings still win.
#
# Generation is the genuinely parallel phase of ideation (independent
# generators avoid anchoring on each other), so the floor keeps three pairs.
# Generators iterate faster than coders; critics and the synthesizer follow.
FWF_PAIRS="${FWF_PAIRS:-3}"

# Visual identity (issue #31): an ideation floor should LOOK like one.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-GEN}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-CRITIC}"
FWF_DISPLAY_CONDUCTOR="${FWF_DISPLAY_CONDUCTOR:-SYNTH}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-FRAMER}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-diverge → idea briefs}"
FWF_DESC_QA="${FWF_DESC_QA:-critiques+merges briefs}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-portfolio synthesis}"
FWF_DESC_PM="${FWF_DESC_PM:-fuzzy goals → challenge frames}"
