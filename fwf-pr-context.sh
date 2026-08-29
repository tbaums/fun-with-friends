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
# Usage:
#   fwf pr-context --issue <n> [<n> ...]   fold the given ISSUE(s) directly
#   fwf pr-context --pr <num>              resolve <num>'s linked issue(s)
#                                           (its own body's "Closes #n"),
#                                           then fold THAT
#   fwf pr-context <n> [<n> ...]           legacy bare form: same as --issue,
#                                           except refuses (issue #189 AC a)
#                                           if any <n> resolves to a PR
#                                           instead of an issue -- the
#                                           confusion that shipped 16 hollow
#                                           squash-merge commit cards.
# Prints the sanitized, multi-ticket "## Context & rationale" block (see
# lib/pr_context.sh: fwf_context_block) to stdout.
#
# WHY TWO FLAGS INSTEAD OF ONE SMARTER FORM (issue #189): the command's own
# name reads as "context of the PR", so supplying a PR number is the natural
# misreading -- `--pr` satisfies that instinct correctly instead of fighting
# it, while `--issue` stays for the (equally common) call site that already
# has the issue number in hand. The bare form is kept for backward
# compatibility (existing muscle memory / any un-migrated call site) but is
# no longer silent about the one confusion that actually shipped bugs.
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

usage() {
  echo "usage: fwf pr-context --issue <n> [<n> ...]  |  fwf pr-context --pr <num>  |  fwf pr-context <n> [<n> ...]" >&2
}

[ $# -gt 0 ] || { usage; exit 1; }

case "$1" in
  --issue)
    shift
    [ $# -gt 0 ] || { usage; exit 1; }
    fwf_context_block "$@" | fwf_pr_body_guard
    ;;
  --pr)
    shift
    [ $# -eq 1 ] || { usage; exit 1; }
    pr_num="$1"
    linked="$(_fwf_pr_ctx_pr_linked_issues "$pr_num")"
    [ -n "$linked" ] || {
      echo "fwf pr-context: PR #$pr_num has no resolvable linked issue (no 'Closes #n' found in its body) -- refusing rather than folding the PR's own body" >&2
      exit 1
    }
    issue_num="$(printf '%s\n' "$linked" | head -1)"
    if [ "$(printf '%s\n' "$linked" | wc -l)" -gt 1 ]; then
      echo "fwf pr-context: PR #$pr_num closes multiple issues ($(printf '%s' "$linked" | tr '\n' ' ' | sed 's/ $//')) -- picked the lowest, #$issue_num" >&2
    fi
    fwf_context_block "$issue_num" | fwf_pr_body_guard
    ;;
  -h|--help)
    usage; exit 0
    ;;
  *)
    for n in "$@"; do
      [ "$(_fwf_pr_ctx_kind "$n")" = pr ] && {
        echo "fwf pr-context: #$n is a PULL REQUEST, not an issue (issue #189) -- pass '--pr $n' to fold its linked issue, or '--issue <n>' with the actual issue number" >&2
        exit 1
      }
    done
    fwf_context_block "$@" | fwf_pr_body_guard
    ;;
esac
