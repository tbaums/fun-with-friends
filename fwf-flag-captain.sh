#!/usr/bin/env bash
# fwf-flag-captain.sh — issue #113: a persisted, queryable "needs-captain"
# signal any role can raise on an issue or PR, that the captain sweeps every
# tick, instead of an ephemeral pane line the captain might never read (the
# 2026-07-14 impl1 incident this closes).
#
# Carrier: the "$NEEDS_CAPTAIN_LABEL" label (config.sh; default
# "needs-captain") plus a self-declared `NEEDS-CAPTAIN: [<role>] <reason>`
# comment — self-declared because every role on this shared account
# authenticates as the SAME GitHub user, so the comment author carries no
# role information (mirrors the qa/impl QA-*/IMPL-* convention).
#
# Uniform across BOTH issue-tracker backends so a raiser never branches on
# mode: issues route through the local store when FWF_ISSUES=local, through
# `gh issue` otherwise; PRs ALWAYS route through `gh pr` (PRs live on GitHub
# in both modes — only the issue tracker itself is swappable).
#
# Usage:
#   fwf flag-captain <n> --role <role> --reason "<text>" [--pr]   raise
#   fwf flag-captain <n> --clear [--note "<text>"] [--pr]         clear
#   fwf flag-captain --sweep                                      list every
#     open issue/PR carrying the label, across both trackers, one line each:
#     "#<n> [issue|pr] role=<role> age=<Ns/m/h/d> reason=<text>"
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

LABEL="$NEEDS_CAPTAIN_LABEL"
die() { echo "fwf flag-captain: $*" >&2; exit 1; }

# Create-if-absent (AC7): a raise must never no-op on a missing label, even
# against a repo provisioned before this issue shipped (fwf-provision.sh also
# provisions it at setup — belt and suspenders). No-op for the local tracker,
# whose labels are free-form strings with nothing to register.
ensure_label() {
  [ "$FWF_ISSUES" = "gh" ] || return 0
  gh label create "$LABEL" --description "An agent needs the captain's attention on this item — cleared once the captain has acted" --color D93F0B --force >/dev/null 2>&1 || true
}

_fwf_iso_to_epoch() { # $1 = ISO8601 UTC, e.g. 2026-07-15T18:25:56Z
  date -u -d "$1" +%s 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}
_fwf_age_str() { # $1 = epoch seconds in the past
  local now secs; now="$(date -u +%s)"; secs=$(( now - $1 )); [ "$secs" -ge 0 ] || secs=0
  if   [ "$secs" -lt 60 ];    then printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ];  then printf '%dm' $(( secs/60 ))
  elif [ "$secs" -lt 86400 ]; then printf '%dh' $(( secs/3600 ))
  else                             printf '%dd' $(( secs/86400 ))
  fi
}

# Parse the FIRST line of a NEEDS-CAPTAIN comment body into role=/reason=.
# Edge cases (issue #113): no [role] tag -> "role unstated"; not a
# NEEDS-CAPTAIN line at all -> rc 1 (caller falls back to "no reason given").
_fwf_parse_needs_captain_line() { # $1 = comment body
  local line="${1%%$'\n'*}" role reason
  case "$line" in
    "NEEDS-CAPTAIN: ["*"]"*)
      role="${line#NEEDS-CAPTAIN: [}"; role="${role%%]*}"
      reason="${line#*] }"
      printf 'role=%s\nreason=%s\n' "$role" "$reason"
      ;;
    NEEDS-CAPTAIN:*)
      reason="${line#NEEDS-CAPTAIN: }"
      printf 'role=unstated\nreason=%s\n' "$reason"
      ;;
    *) return 1;;
  esac
}

raise() { # $1=n $2=is_pr(0/1) $3=role $4=reason
  local n="$1" is_pr="$2" role="$3" reason="$4"
  [ -n "$role" ]   || die "raise: --role is required"
  [ -n "$reason" ] || die "raise: --reason is required"
  local line="NEEDS-CAPTAIN: [$role] $reason"
  if [ "$is_pr" = 1 ]; then
    ensure_label
    gh pr edit "$n" --add-label "$LABEL"
    gh pr comment "$n" --body "$line"
  elif [ "$FWF_ISSUES" = "local" ]; then
    "$DIR/fwf-issues.sh" edit "$n" --add-label "$LABEL" >/dev/null
    "$DIR/fwf-issues.sh" comment "$n" --body "$line" >/dev/null
  else
    ensure_label
    gh issue edit "$n" --add-label "$LABEL"
    gh issue comment "$n" --body "$line"
  fi
  echo "flag-captain: raised on #$n ($line)"
}

clear_flag() { # $1=n $2=is_pr(0/1) $3=note (may be empty)
  local n="$1" is_pr="$2" note="$3"
  if [ "$is_pr" = 1 ]; then
    gh pr edit "$n" --remove-label "$LABEL"
    [ -n "$note" ] && gh pr comment "$n" --body "$note"
  elif [ "$FWF_ISSUES" = "local" ]; then
    "$DIR/fwf-issues.sh" edit "$n" --remove-label "$LABEL" >/dev/null
    [ -n "$note" ] && "$DIR/fwf-issues.sh" comment "$n" --body "$note" >/dev/null
  else
    gh issue edit "$n" --remove-label "$LABEL"
    [ -n "$note" ] && gh issue comment "$n" --body "$note"
  fi
  echo "flag-captain: cleared on #$n"
}

# Emit one sweep line for item $1 (number), $2 (issue|pr), given its comments
# as a JSON array [{"body":...,"createdAt":...}] on stdin (newest-last is NOT
# assumed — we sort by createdAt ourselves) and its own createdAt as $3 (the
# "no NEEDS-CAPTAIN comment at all" fallback anchor).
_emit_sweep_row() { # $1=n $2=type $3=item_created_at
  local n="$1" type="$2" item_created="$3" comments latest_body latest_created parsed role reason age_epoch
  comments="$(cat)"
  latest_body="$(printf '%s' "$comments" | jq -r '[.[] | select(.body | startswith("NEEDS-CAPTAIN:"))] | sort_by(.createdAt) | last | .body // empty' 2>/dev/null)"
  latest_created="$(printf '%s' "$comments" | jq -r '[.[] | select(.body | startswith("NEEDS-CAPTAIN:"))] | sort_by(.createdAt) | last | .createdAt // empty' 2>/dev/null)"
  if [ -n "$latest_body" ] && parsed="$(_fwf_parse_needs_captain_line "$latest_body")"; then
    role="$(printf '%s' "$parsed" | sed -n 's/^role=//p')"
    reason="$(printf '%s' "$parsed" | sed -n 's/^reason=//p')"
    age_epoch="$(_fwf_iso_to_epoch "$latest_created")"
  else
    role="unstated"; reason="no reason given"
    age_epoch="$(_fwf_iso_to_epoch "$item_created")"
  fi
  [ -n "$age_epoch" ] || age_epoch="$(date -u +%s)"
  printf '#%s [%s] role=%s age=%s reason=%s\n' "$n" "$type" "$role" "$(_fwf_age_str "$age_epoch")" "$reason"
}

sweep() {
  local n created comments any=0
  if [ "$FWF_ISSUES" = "local" ]; then
    while IFS=$'\t' read -r n created; do
      [ -n "$n" ] || continue
      any=1
      comments="$("$DIR/fwf-issues.sh" view "$n" --json comments --jq '.' 2>/dev/null)"
      printf '%s' "$comments" | _emit_sweep_row "$n" issue "$created"
    done < <("$DIR/fwf-issues.sh" list --state open --label "$LABEL" --json number,createdAt --jq '.[] | "\(.number)\t\(.createdAt)"' 2>/dev/null)
  else
    while IFS=$'\t' read -r n created; do
      [ -n "$n" ] || continue
      any=1
      comments="$(gh issue view "$n" --json comments --jq '.comments' 2>/dev/null)"
      printf '%s' "$comments" | _emit_sweep_row "$n" issue "$created"
    done < <(gh issue list --state open --label "$LABEL" --json number,createdAt --jq '.[] | "\(.number)\t\(.createdAt)"' 2>/dev/null)
  fi
  # PRs always live on GitHub, regardless of tracker backend.
  while IFS=$'\t' read -r n created; do
    [ -n "$n" ] || continue
    any=1
    comments="$(gh pr view "$n" --json comments --jq '.comments' 2>/dev/null)"
    printf '%s' "$comments" | _emit_sweep_row "$n" pr "$created"
  done < <(gh pr list --state open --label "$LABEL" --json number,createdAt --jq '.[] | "\(.number)\t\(.createdAt)"' 2>/dev/null)
  [ "$any" = 1 ] || echo "flag-captain: nothing flagged"
}

# --- dispatch ----------------------------------------------------------------
main() {
  [ $# -gt 0 ] || die "usage: fwf flag-captain <n> --role R --reason TEXT [--pr] | <n> --clear [--note TEXT] [--pr] | --sweep"

  if [ "$1" = "--sweep" ]; then sweep; return 0; fi

  local n="$1"; shift
  case "$n" in ''|*[!0-9]*) die "need an issue/PR number (got '$n')";; esac

  local is_pr=0 role="" reason="" do_clear=0 note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)     is_pr=1; shift;;
      --role)   role="$2"; shift 2;;
      --reason) reason="$2"; shift 2;;
      --clear)  do_clear=1; shift;;
      --note)   note="$2"; shift 2;;
      *) die "unknown flag '$1'";;
    esac
  done

  if [ "$do_clear" = 1 ]; then
    clear_flag "$n" "$is_pr" "$note"
  else
    raise "$n" "$is_pr" "$role" "$reason"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
