#!/usr/bin/env bash
# fwf-merge.sh — issue #136 (prevention layer): squash-merges a PR with the
# crafted history card ALWAYS included, replacing the multi-line printf
# construction templates/dev/qa.tmpl and templates/refactor/qa.tmpl used to
# spell out inline. A helper nobody's workflow invokes fixes nothing (#136's
# own framing) -- this is that helper, wired into both qa.tmpls in the same
# change, so the shared-account direct/manual merge path this floor actually
# uses is the ONE code path that produces the crafted body, not prose an
# agent has to transcribe correctly (the exact class of bug #189 shipped 16
# times: <n> vs <num> on one line, easy to misread, easy to get away with
# once).
#
# Usage: fwf merge <num> [--target <branch>]
#   <num>          the PR number to squash-merge.
#   --target       branch to merge into (default: the profile's STAGING_BRANCH).
#
# Composes the body itself (issue #189's --pr resolution + issue #135's
# fail-open fold + credit + fwf-Provenance), then calls
#   gh pr merge <num> --squash --delete-branch --subject <pr-title> --body <that>
# Fails loudly and merges NOTHING if the context fold itself refuses (issue
# #106's guard) -- never falls back to a thinner or default body just to get
# the merge to happen; a caller that hits this should investigate the
# refusal, not bypass this helper.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf merge <num> [--target <branch>]" >&2; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 1 ;; esac
shift
target="${STAGING_BRANCH:-staging}"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:-}"; [ -n "$target" ] || { usage; exit 1; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

title="$(gh pr view "$num" --json title --jq '.title' 2>/dev/null)"
[ -n "$title" ] || { echo "fwf merge: could not read PR #$num's title (bad number, or gh unreachable)" >&2; exit 1; }

linked="$(_fwf_pr_ctx_pr_linked_issues "$num")"
[ -n "$linked" ] || {
  echo "fwf merge: PR #$num has no resolvable linked issue ('Closes #n' in its body) -- refusing to merge with no issue to close" >&2
  exit 1
}
issue_num="$(printf '%s\n' "$linked" | head -1)"
if [ "$(printf '%s\n' "$linked" | wc -l)" -gt 1 ]; then
  echo "fwf merge: PR #$num closes multiple issues ($(printf '%s' "$linked" | tr '\n' ' ' | sed 's/ $//')) -- picked the lowest, #$issue_num" >&2
fi

ctx="$(fwf_context_block "$issue_num" | fwf_pr_body_guard)" || {
  echo "fwf merge: context fold refused (issue #106 guard, see above) -- not merging with a hollow or leaky body" >&2
  exit 1
}

credit="$(fwf_credit_block)"
provenance="$(fwf_provenance_block)"

body="$(printf 'Closes #%s.\n\n%s\n\n%s\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n%s' \
  "$issue_num" "$ctx" "$credit" "$provenance")"

exec gh pr merge "$num" --squash --delete-branch --subject "$title" --body "$body"
