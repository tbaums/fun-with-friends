#!/usr/bin/env bash
# fwf usage — CLI report over fwf-usage-data.sh's per-role token/$ aggregate
# (issue #95, Ticket A of #70), plus the #96 (Ticket B) budget-enforcement
# surface: an ARMED/NOT ARMED line (so a budget set mid-run without a re-`up`
# is visibly, not silently, off — the GV-signoff residual-risk fix) and
# --clear-hold to lift a BUDGET_HOLD by hand.
#
# Usage: fwf usage [--profile NAME]     (--profile is handled by the fwf
#                                         dispatcher's engine() — see #69)
#        fwf usage --clear-hold         Remove $BUDGET_HOLD_FILE (operator
#                                        override — the writer will re-write
#                                        it next tick if still over budget).
#
# Prints a per-role table (state, model, tokens by kind, $ estimate), a
# factory total, the current budget-enforcement status, and the
# proxy-vs-real-account-usage caveat. Reporting itself is read-only; it never
# writes the hold sentinel except when --clear-hold is explicitly passed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage_data() { "$DIR/fwf-usage-data.sh"; }

_fwf_usage_fmt_tokens() { # $1=n (may be the string "null")
  [ "$1" = "null" ] && { printf -- '-'; return 0; }
  printf '%s' "$1"
}

_fwf_usage_fmt_cost() { # $1=cost_usd (number or null)
  if [ "$1" = "null" ]; then printf -- '-'
  else printf '$%.4f' "$1"
  fi
}

_fwf_usage_fmt_state() { # $1=state $2=age_secs
  case "$1" in
    fresh)   printf 'fresh';;
    stale)   printf '⚠ STALE (%ds ago)' "$2";;
    unknown) printf '⚠ UNKNOWN';;
    *)       printf '%s' "$1";;
  esac
}

# NOTE (issue #108): the ARMED/NOT ARMED line stays a plain ceiling summary —
# it must keep matching dash's independent Rust reimplementation (data.rs
# `armed_status_line()`, whose own header comment claims parity "exactly").
# The this-run / excl.-cache-read breakdown lives in the hold-state line
# instead, which BOTH surfaces already render verbatim from $BUDGET_HOLD_FILE
# (the single thing fwf-budget-check.sh writes) — so it appears there for
# free, with no risk of the two surfaces drifting apart.
_fwf_usage_budget_line() {
  if [ -z "${FWF_TOKEN_BUDGET:-}" ]; then
    printf 'budget enforcement: NOT ARMED (no FWF_TOKEN_BUDGET configured — unlimited)\n'
  elif fwf_budget_writer_running; then
    printf 'budget enforcement: ARMED (ceiling %s tokens)\n' "$FWF_TOKEN_BUDGET"
  else
    printf 'budget enforcement: NOT ARMED — FWF_TOKEN_BUDGET=%s is set, but the writer is not running for this profile (re-run '"'"'fwf up'"'"' to arm it)\n' "$FWF_TOKEN_BUDGET"
  fi
  if [ -f "$BUDGET_HOLD_FILE" ]; then
    printf 'hold state: %s\n' "$(head -1 "$BUDGET_HOLD_FILE")"
  else
    printf 'hold state: none\n'
  fi
}

main() {
  case "${1:-}" in
    "") ;;
    --clear-hold)
      rm -f "$BUDGET_HOLD_FILE"
      echo "fwf usage: cleared $BUDGET_HOLD_FILE (the writer will re-write it next tick if still over budget)"
      exit 0
      ;;
    *) echo "fwf usage: unknown argument '$1' (expected no arguments, or --clear-hold)" >&2; exit 1;;
  esac
  command -v jq >/dev/null 2>&1 || { echo "fwf usage: jq is required" >&2; exit 1; }
  local data
  data="$(usage_data)"

  printf 'fwf usage — profile %s\n\n' "$PROFILE"
  printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
    ROLE STATE MODEL INPUT CACHE-W CACHE-R OUTPUT 'EST-$'

  local role state age model tin twrite tread tout cost
  while IFS=$'\t' read -r role state age model tin twrite tread tout cost; do
    printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
      "$role" \
      "$(_fwf_usage_fmt_state "$state" "$age")" \
      "$([ "$model" = "null" ] && echo '-' || echo "$model")" \
      "$(_fwf_usage_fmt_tokens "$tin")" \
      "$(_fwf_usage_fmt_tokens "$twrite")" \
      "$(_fwf_usage_fmt_tokens "$tread")" \
      "$(_fwf_usage_fmt_tokens "$tout")" \
      "$(_fwf_usage_fmt_cost "$cost")"
  done < <(printf '%s' "$data" | jq -r '.roles[] |
    # UNKNOWN never had a real read, so its 0-valued token fields would
    # otherwise render as "confirmed zero usage" — show "-" instead, same
    # as the cost/model columns already do for this state.
    (if .state == "unknown" then null else .tokens.input end) as $tin |
    (if .state == "unknown" then null else .tokens.cache_creation end) as $twrite |
    (if .state == "unknown" then null else .tokens.cache_read end) as $tread |
    (if .state == "unknown" then null else .tokens.output end) as $tout |
    [.role, .state, (.age_secs // 0), (.model // "null"),
     ($tin // "null"), ($twrite // "null"), ($tread // "null"), ($tout // "null"),
     (.cost_usd // "null")] | @tsv')

  printf '\n'
  printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
    TOTAL '' '' \
    "$(printf '%s' "$data" | jq -r '.total.tokens.input')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.cache_creation')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.cache_read')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.output')" \
    "$(printf '$%.4f' "$(printf '%s' "$data" | jq -r '.total.cost_usd')")"

  printf '\n%s\n' "$(printf '%s' "$data" | jq -r '"note: " + .caveat')"

  printf '\n'
  _fwf_usage_budget_line
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
