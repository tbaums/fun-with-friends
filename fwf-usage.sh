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

_fwf_usage_budget_line() { # $1=usage-data JSON (for the this-run-vs-cumulative line)
  local data="$1"
  if [ -z "${FWF_TOKEN_BUDGET:-}" ] && [ -z "${FWF_BUDGET_USD:-}" ]; then
    printf 'budget enforcement: NOT ARMED (no FWF_TOKEN_BUDGET/FWF_BUDGET_USD configured — unlimited)\n'
  elif fwf_budget_writer_running; then
    if [ -n "${FWF_BUDGET_USD:-}" ]; then
      printf 'budget enforcement: ARMED (ceiling $%.4f USD)\n' "$FWF_BUDGET_USD"
    else
      printf 'budget enforcement: ARMED (ceiling %s tokens)\n' "$FWF_TOKEN_BUDGET"
    fi
  elif [ -n "${FWF_BUDGET_USD:-}" ]; then
    printf 'budget enforcement: NOT ARMED — FWF_BUDGET_USD=%s is set, but the writer is not running for this profile (re-run '"'"'fwf up'"'"' to arm it)\n' "$FWF_BUDGET_USD"
  else
    printf 'budget enforcement: NOT ARMED — FWF_TOKEN_BUDGET=%s is set, but the writer is not running for this profile (re-run '"'"'fwf up'"'"' to arm it)\n' "$FWF_TOKEN_BUDGET"
  fi

  # this-run vs cumulative (issue #108): only shown once a baseline exists
  # (i.e. armed at least once by a full `fwf up`) — before that there's
  # nothing yet to diff against. Both figures always named as $/tokens so the
  # unit — and that tokens include cache-read — is never left implicit.
  local baseline
  if baseline="$(fwf_budget_baseline_read)"; then
    local baseline_tokens baseline_cost total_tokens cost_usd delta_tokens delta_cost
    baseline_tokens="${baseline%%$'\t'*}"
    baseline_cost="${baseline#*$'\t'}"
    total_tokens="$(printf '%s' "$data" | jq -r '[.total.tokens.input, .total.tokens.cache_creation, .total.tokens.cache_read, .total.tokens.output] | add')"
    cost_usd="$(printf '%s' "$data" | jq -r '.total.cost_usd')"
    delta_tokens=$(( total_tokens - baseline_tokens )); [ "$delta_tokens" -lt 0 ] && delta_tokens=0
    delta_cost="$(jq -rn --argjson c "$cost_usd" --argjson b "$baseline_cost" '(($c - $b) as $d | if $d < 0 then 0 else $d end)')"
    printf 'this run: %s tokens (est. $%.4f) since fwf up — cumulative: %s tokens (est. $%.4f)\n' \
      "$delta_tokens" "$delta_cost" "$total_tokens" "$cost_usd"
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
  _fwf_usage_budget_line "$data"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
