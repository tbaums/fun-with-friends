#!/usr/bin/env bash
# fwf-ungate.sh — issue #213: `fwf ungate <n> [<n>...]` as one verb for the
# four-step ritual the operator has been hand-rolling — comment, un-label,
# cache-bust, verify. RESCOPED 2026-08-29: ergonomics only. #191 (the
# cryptographic-signature design this ticket originally specified against)
# was declined `not_planned` on 2026-08-27 — every seat runs on the owner's
# own account, so a signature scheme defends against a party that does not
# exist here. NO signing, key custody, or trust-anchor work lives here or
# ever should; if that ever changes, #191's own reopen condition fires and
# the signing design comes back on its own ticket.
#
# `fwf authz` is UNCHANGED and remains the sole authorization oracle. This
# script only automates POSTING the same anchored sentinel a human already
# posts by hand or via `fwf dash` approve (fwf-dash-act.sh) — both call the
# shared fwf_ungate_comment_body() in lib.sh so the two paths can never drift
# in the one thing that actually matters: the #218-anchored sentinel format.
#
# Security property: PROVENANCE, not prevention (see the issue body's §3).
# The comment records how it was invoked — board keypress, this CLI, or the
# concierge proxy relaying for the operator — so a mistake is reviewable, not
# prevented. There is no key here; recording is the honest property.
#
# Usage:
#   fwf ungate <n> [<n>...] [--via cli|concierge-proxy]
#   fwf ungate --audit
#
# Exit: 0 iff every issue's un-gate (or already-clear no-op) succeeded.
# Non-zero if ANY issue failed. A failure on one issue never aborts or rolls
# back the others — each is independent and reported on its own line.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf ungate <n> [<n>...] [--via cli|concierge-proxy]   |   fwf ungate --audit" >&2; }

# --- dual-backend read/write, same shape as fwf-claim.sh/fwf-dash-act.sh ----
_issue_read() { # rest = <n> --json <field> --jq <expr>
  if [ "${FWF_ISSUES:-}" = "local" ]; then "$DIR/fwf-issues.sh" view "$@"
  else gh issue view "$@"; fi
}
_issue_comment() { # $1=n $2=body
  if [ "${FWF_ISSUES:-}" = "local" ]; then "$DIR/fwf-issues.sh" comment "$1" --body "$2"
  else gh issue comment "$1" --body "$2"; fi
}
_issue_remove_label() { # $1=n
  if [ "${FWF_ISSUES:-}" = "local" ]; then "$DIR/fwf-issues.sh" edit "$1" --remove-label "$WIP_LABEL"
  else gh issue edit "$1" --remove-label "$WIP_LABEL"; fi
}
# A FRESH read of every comment body, never through a caching layer -- the
# documented "gh write silently no-ops when stdout is redirected" trap means
# the write's own exit code cannot be trusted, and `gh issue view` can serve
# a stale REST-cache snapshot that never observes a write that genuinely
# landed a moment ago. `gh api` (paginated) is the same live path fwf-authz.sh
# itself reads through.
_comments_fresh() { # $1=n
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$1" --json comments --jq '.comments[].body' 2>/dev/null
  else
    gh api "repos/$(fwf_repo_slug)/issues/$1/comments" --paginate --jq '.[].body' 2>/dev/null
  fi
}
# NOTE: never `| grep -q` here under `set -o pipefail` — grep -q exits the
# instant it finds a match, and if the upstream producer is still writing
# when grep closes its read end, the producer gets SIGPIPE (rc 141), which
# pipefail then reports as the WHOLE pipeline's exit status, overriding
# grep's own success. Capture to a variable first and match without a pipe.
_has_label() { # $1=n $2=label -> rc 0 if present
  local labels
  labels="$(_issue_read "$1" --json labels --jq '.labels[].name' 2>/dev/null)"
  case $'\n'"$labels"$'\n' in *$'\n'"$2"$'\n'*) return 0;; *) return 1;; esac
}

# --- per-issue result accounting (AC 4: partial failure never aborts) ------
FAILED=0
ok_line()   { printf '  #%s: %s\n' "$1" "$2"; }
fail_line() { printf '  #%s: FAILED — %s\n' "$1" "$2" >&2; FAILED=1; }

ungate_one() { # $1=n $2=invocation description $3=provenance-tag (for the "already ungated" message only)
  local n="$1" desc="$2"
  case "$n" in ''|*[!0-9]*) fail_line "$n" "not a valid issue number"; return; esac

  local state
  state="$(_issue_read "$n" --json state --jq '.state' 2>/dev/null)"
  if [ -z "$state" ]; then
    fail_line "$n" "could not read this issue (nonexistent, or the read failed) — refusing rather than guessing"
    return
  fi
  if [ "$state" = "CLOSED" ]; then
    fail_line "$n" "issue is CLOSED — un-gating a closed issue authorizes nothing and is almost certainly a typo"
    return
  fi

  # AC 5: idempotent. No product-wip -> nothing to do; never posts a second
  # sentinel comment for an issue that is already clear.
  if ! _has_label "$n" "$WIP_LABEL"; then
    ok_line "$n" "already clear (no $WIP_LABEL) — no-op"
    return
  fi

  # Comment BEFORE un-gating (same ordering as fwf dash's approve, and for
  # the same reason): the signal of record must exist the instant the label
  # comes off, never the other way around.
  local body
  body="$(fwf_ungate_comment_body "$n" "$desc")"
  if ! _issue_comment "$n" "$body" >/dev/null 2>&1; then
    fail_line "$n" "the comment write failed — the label was NOT touched (a half-posted un-gate is worse than none)"
    return
  fi
  # Verify the write actually landed, by re-reading fresh -- never trust the
  # write's own exit code alone (the redirected-stdout no-op trap). Captured
  # to a variable, not piped into `grep -q` (same SIGPIPE/pipefail trap
  # _has_label's comment above documents).
  local fresh_bodies
  fresh_bodies="$(_comments_fresh "$n")"
  case "$fresh_bodies" in
    *"**$OPERATOR_UNGATE_SENTINEL #$n**"*) : ;;
    *)
      fail_line "$n" "the comment write reported success but did not actually land (re-read came back without it) — the label was NOT touched"
      return ;;
  esac

  if ! _issue_remove_label "$n" >/dev/null 2>&1; then
    fail_line "$n" "the sentinel comment landed, but removing $WIP_LABEL failed — the signal of record exists and the gate is still on; retry is safe (AC 5 is idempotent)"
    return
  fi
  if _has_label "$n" "$WIP_LABEL"; then
    fail_line "$n" "the sentinel comment landed, but $WIP_LABEL is still present after the removal call — retry is safe"
    return
  fi

  # Write-through cache-bust (issue #167): gh backend only, same as dash's
  # approve -- the local store has no REST cache to bust.
  [ "${FWF_ISSUES:-}" = "local" ] || "$DIR/fwf-ghcache.sh" invalidate issue "$n" >/dev/null 2>&1 || true

  local verdict_out rc
  verdict_out="$("$DIR/fwf-authz.sh" "$n" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then
    ok_line "$n" "un-gated — $(printf '%s' "$verdict_out" | head -1)"
  else
    fail_line "$n" "posted and un-labeled, but fwf authz did not report AUTHORIZED afterward (rc=$rc): $(printf '%s' "$verdict_out" | head -1)"
  fi
}

do_audit() {
  local nums n body createdAt tag
  # AC/Assumption 3: reads the un-gate comments themselves, never a separate
  # local log, so it works from any checkout and cannot drift from the
  # signals of record. `in:comments` is GitHub's own full-text search
  # qualifier; --state all so a since-closed issue's history is not lost.
  nums="$(gh issue list --state all --search "\"$OPERATOR_UNGATE_SENTINEL\" in:comments" --json number --jq '.[].number' 2>/dev/null)"
  if [ -z "$nums" ]; then
    echo "fwf ungate --audit: no un-gates found (or the search failed — see 'gh issue list' directly to distinguish)" >&2
    return 0
  fi
  printf '%-8s %-24s %s\n' "ISSUE" "TIMESTAMP" "VIA"
  for n in $nums; do
    gh issue view "$n" --json comments --jq \
      '.comments[] | select(.body | startswith("**'"$OPERATOR_UNGATE_SENTINEL"' #'"$n"'**")) | "\(.createdAt)\t\(.body)"' 2>/dev/null \
    | while IFS=$'\t' read -r createdAt body; do
        [ -n "$createdAt" ] || continue
        case "$body" in
          *"via fwf dash"*)        tag="board (fwf dash approve)";;
          *"via fwf ungate (cli)"*) tag="fwf ungate (cli)";;
          *"via fwf ungate (concierge-proxy)"*) tag="fwf ungate (concierge-proxy)";;
          *)                       tag="unrecognized — $(printf '%s' "$body" | cut -c1-60)";;
        esac
        printf '%-8s %-24s %s\n' "#$n" "$createdAt" "$tag"
      done
  done
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0;;
    "") usage; exit 1;;
    --audit) do_audit; exit $?;;
  esac

  local via="cli" nums=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --via)
        [ $# -ge 2 ] || { usage; exit 1; }
        case "$2" in
          cli|concierge-proxy) via="$2";;
          *) echo "fwf ungate: --via must be 'cli' or 'concierge-proxy'" >&2; exit 1;;
        esac
        shift 2;;
      *[!0-9]*|"") echo "fwf ungate: '$1' is not a valid issue number" >&2; exit 1;;
      *) nums+=("$1"); shift;;
    esac
  done
  [ "${#nums[@]}" -gt 0 ] || { usage; exit 1; }

  local desc="authorized via fwf ungate (${via}): the human operator un-gated this from the command line"
  echo "fwf ungate: processing ${#nums[@]} issue(s)…"
  local n
  for n in "${nums[@]}"; do
    ungate_one "$n" "$desc"
  done
  exit "$FAILED"
}
main "$@"
