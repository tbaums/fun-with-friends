#!/usr/bin/env bash
# fwf usage — CLI report over fwf-usage-data.sh's per-role token/$ aggregate
# (issue #95, Ticket A of #70). Read-only: this never pauses a factory or
# writes any hold/sentinel (enforcement is Ticket B, #96).
#
# Usage: fwf usage [--profile NAME]     (--profile is handled by the fwf
#                                         dispatcher's engine() — see #69)
#
# Prints a per-role table (state, model, tokens by kind, $ estimate) plus a
# factory total and the proxy-vs-real-account-usage caveat.
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

main() {
  [ $# -eq 0 ] || { echo "fwf usage: unknown argument '$1' (usage takes no flags of its own — --profile is handled before dispatch)" >&2; exit 1; }
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
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
