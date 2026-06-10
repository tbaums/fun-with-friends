#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: behavior-preserving refactoring factory — survey in parallel, edit serially, verify hard
#
# Config DEFAULTS for this template. lib.sh sources this AFTER the profile, and
# only ${VAR:-default} patterns apply — so env/CLI/profile settings still win.
#
# Editing is the least parallelizable part of refactoring (refactors collide on
# shared files; see docs/refactor-factory.md), so this floor defaults to two
# impl/qa pairs instead of three — throughput comes from sequencing, not width.
FWF_PAIRS="${FWF_PAIRS:-2}"
