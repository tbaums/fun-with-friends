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
