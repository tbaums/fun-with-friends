#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: dev factory + a dedicated PROD OPS / SRE pane (docs/captain-split.md)
#
# Inherits every dev prompt it doesn't override (FWF_TEMPLATE_BASE) and adds a
# fourth coordination pane: the SRE, which owns the prod-ops loop so the
# captain does ZERO ops actions (the one-writer contract from issue #4).
# Run this variant only when the trigger conditions in docs/captain-split.md
# hold: a live prod service + recurring ops work + a degraded captain loop.
FWF_TEMPLATE_BASE="dev"
FWF_EXTRA_ROLES="${FWF_EXTRA_ROLES:-sre:coord:2m:colour208}"
