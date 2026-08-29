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
# shellcheck source=fwf-usage-data.sh
source "$DIR/fwf-usage-data.sh"   # sourced, not executed -- reuses its price
                                   # table + fwf_usage_model_drift_live (#289 e)

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

  # Subscription brake (issue #149) — independent of the token/$ line above;
  # both can be armed at once, sharing the same writer/sentinel.
  if [ -z "${FWF_SESSION_PCT_PARK:-}" ] && [ -z "${FWF_WEEKLY_PCT_PARK:-}" ]; then
    printf 'subscription brake: NOT ARMED (no --session-pct/--weekly-pct configured)\n'
  elif fwf_budget_writer_running; then
    printf 'subscription brake: ARMED (session park %s%%%s, weekly park %s%%%s)\n' \
      "${FWF_SESSION_PCT_PARK:-none}" "${FWF_SESSION_PCT_PARK:+/resume ${FWF_SESSION_PCT_RESUME}%}" \
      "${FWF_WEEKLY_PCT_PARK:-none}" "${FWF_WEEKLY_PCT_PARK:+/resume ${FWF_WEEKLY_PCT_RESUME}%}"
  else
    printf 'subscription brake: NOT ARMED — --session-pct/--weekly-pct is set, but the writer is not running for this profile (re-run '"'"'fwf up'"'"' to arm it)\n'
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

# issue #211 AC (f): "readers returning unknown" has two halves that must
# BOTH be reported, because a transient failure is over by the time anyone
# checks -- a point-in-time probe alone almost always comes back clean on
# exactly the incident this ticket exists to prevent.
#   (i)  LIVE PROBE — query the converted readers for every role RIGHT NOW.
#   (ii) RECENT UNKNOWNS — the bounded append log (lib.sh's
#        fwf_log_unknown_read), written only by the failure path, so the
#        common (all-healthy) case costs this report nothing beyond the read.
_fwf_unknown_reads_section() {
  printf '\ncollapsing-read diagnostics (issue #211):\n'
  local role bad_ticks="" rc
  for role in $(fwf_all_roles); do
    if ! fwf_tick_read "$role" >/dev/null; then
      bad_ticks="$bad_ticks $role"
    fi
  done
  if [ -n "$bad_ticks" ]; then
    printf '  live probe: tick read is UNTRUSTED right now for:%s\n' "$bad_ticks"
  else
    printf '  live probe: all roles'"'"' tick reads are trustworthy right now\n'
  fi

  local log; log="$(fwf_unknown_log_path)"
  if [ -s "$log" ]; then
    printf '  recent unknowns (last %s, timestamp / reader / reason):\n' "$FWF_UNKNOWN_LOG_MAX_LINES"
    tail -n 20 "$log" | sed 's/^/    /'
    printf '  (fwf usage --clear-unknown-log to clear)\n'
  else
    printf '  recent unknowns: none logged\n'
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
    --clear-unknown-log)
      rm -f "$(fwf_unknown_log_path)"
      echo "fwf usage: cleared $(fwf_unknown_log_path)"
      exit 0
      ;;
    *) echo "fwf usage: unknown argument '$1' (expected no arguments, --clear-hold, or --clear-unknown-log)" >&2; exit 1;;
  esac
  command -v jq >/dev/null 2>&1 || { echo "fwf usage: jq is required" >&2; exit 1; }
  local data
  data="$(usage_data)"

  printf 'fwf usage — profile %s\n\n' "$PROFILE"
  printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
    ROLE STATE MODEL INPUT CACHE-W CACHE-R OUTPUT 'EST-$'

  local role state age model tin twrite tread tout cost price_state
  while IFS=$'\t' read -r role state age model tin twrite tread tout cost price_state; do
    printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
      "$role" \
      "$(_fwf_usage_fmt_state "$state" "$age")" \
      "$([ "$model" = "null" ] && echo '-' || echo "$model")" \
      "$(_fwf_usage_fmt_tokens "$tin")" \
      "$(_fwf_usage_fmt_tokens "$twrite")" \
      "$(_fwf_usage_fmt_tokens "$tread")" \
      "$(_fwf_usage_fmt_tokens "$tout")" \
      "$(_fwf_usage_fmt_cost "$cost")$([ "$price_state" = "stale" ] && echo ' ⚠stale-price' || true)"
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
     (.cost_usd // "null"), (.price_state // "null")] | @tsv')

  printf '\n'
  printf '%-12s %-22s %-20s %10s %10s %10s %10s %10s\n' \
    TOTAL '' '' \
    "$(printf '%s' "$data" | jq -r '.total.tokens.input')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.cache_creation')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.cache_read')" \
    "$(printf '%s' "$data" | jq -r '.total.tokens.output')" \
    "$(printf '$%.4f' "$(printf '%s' "$data" | jq -r '.total.cost_usd')")$(printf '%s' "$data" | jq -r 'if .total.partial then " ⚠PARTIAL" else "" end')"

  # issue #289 (b1)/(b2): name what was excluded and its MAGNITUDE, not just
  # a bool -- "partial" alone reads as a rounding caveat; the excluded-token
  # percentage is what tells an operator the reported figure could be less
  # than half the truth.
  if [ "$(printf '%s' "$data" | jq -r '.total.partial')" = "true" ]; then
    local unpriced_seats stale_seats excl_pct
    unpriced_seats="$(printf '%s' "$data" | jq -r '.total.unpriced_seats | join(", ")')"
    stale_seats="$(printf '%s' "$data" | jq -r '.total.stale_priced_seats | join(", ")')"
    excl_pct="$(printf '%s' "$data" | jq -r '.total.excluded_tokens_pct')"
    printf '\n⚠ TOTAL is PARTIAL — excluded seats hold %.1f%% of all factory tokens, priced at $0 above:\n' "$excl_pct"
    [ -n "$unpriced_seats" ] && printf '  unpriced (no price-table row): %s\n' "$unpriced_seats"
    [ -n "$stale_seats" ] && printf '  stale-priced (past valid_until, still counted above at the OLD rate): %s\n' "$stale_seats"
  fi

  printf '\n%s\n' "$(printf '%s' "$data" | jq -r '"note: " + .caveat')"

  printf '\n'
  _fwf_usage_budget_line "$data"
  _fwf_usage_drift_section "$data"
  _fwf_unknown_reads_section
}

# issue #289 (e): surface price-table drift on the display path -- checking
# BOTH the reported (live transcripts, retrospective) and declared
# (FWF_MODEL*/menu, prospective) sources; see fwf_usage_model_drift_live's
# own header for why neither alone is sufficient.
_fwf_usage_drift_section() { # $1=usage-data JSON
  local data="$1" out rc=0
  out="$(fwf_usage_model_drift_live "$data")" || rc=$?
  printf '\nprice-table drift check (issue #289):\n'
  if [ "$rc" = 0 ]; then
    printf '  clean — every reported and declared model has a price-table row\n'
  else
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
