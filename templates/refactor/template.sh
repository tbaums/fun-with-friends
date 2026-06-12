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

# Visual identity (issue #31): a refactoring floor should LOOK like one.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-REFAC}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-VERIF}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-PLANNER}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-behavior-preserving moves}"
FWF_DESC_QA="${FWF_DESC_QA:-behavior-contract review of}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-e2e behavior backstop}"
FWF_DESC_PM="${FWF_DESC_PM:-debt survey → refactor items}"
