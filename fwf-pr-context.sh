#!/usr/bin/env bash
# fwf-pr-context.sh — issue #106: CLI entrypoint an implementer/QA agent calls
# at ACTUAL PR-creation/squash-merge time to fold sanitized ticket context into
# the body.
#
# WHY A CLI, NOT A __CONTEXT__ TEMPLATE PLACEHOLDER: __PROVENANCE__/__CREDIT__
# resolve once, at template-RENDER time (fwf_render, in lib.sh) — before any
# issue is even claimed — because a git sha / model map is the same for every
# PR out of a given pane. The folded ticket context is NOT: it depends on
# which issue number(s) THIS SPECIFIC PR closes, which isn't known until the
# agent has already picked an issue. So templates instead embed a literal
# `$(fwf pr-context <num>)` command substitution for the agent to run for real
# when it composes its `gh pr create`/`gh pr merge` command — the same pattern
# templates already use for `$(printf '...')` in the QA squash-merge body.
#
# Usage: fwf pr-context <issue-num> [<issue-num> ...]
# Prints the sanitized, multi-ticket "## Context & rationale" block (see
# lib/pr_context.sh: fwf_context_block) to stdout, one ticket per issue
# number given, ordered.
#
# FAIL-CLOSED (PM item 2 — the runtime guard, not just the CI fixture test):
# the actual rendered output is re-scanned by fwf_pr_body_guard immediately
# before it is printed. If any fwf-internal token survived the sanitizer,
# NOTHING is printed to stdout, the offending line(s) go to stderr, and this
# exits 1 — a caller must not embed empty/partial output into a public PR
# body without investigating first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

[ $# -gt 0 ] || { echo "usage: fwf pr-context <issue-num> [<issue-num> ...]" >&2; exit 1; }
fwf_context_block "$@" | fwf_pr_body_guard
