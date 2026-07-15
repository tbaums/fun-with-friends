#!/usr/bin/env bash
# fwf budget-check — the token-budget WRITER (issue #96, Ticket B of #70's
# discovery; see docs/proposals/70-token-usage-budget.md). Evaluates aggregate
# usage (via fwf-usage-data.sh, Ticket A / #95) against either a raw-token
# ceiling ($FWF_TOKEN_BUDGET, back-compat) or an estimated-$ ceiling
# ($FWF_BUDGET_USD, issue #108 — the human-intuitive default: the price table
# already prices cache-read at its true low rate, so a $ budget is already
# correctly cache-read-weighted with no down-weight factor to invent) and
# writes/clears $BUDGET_HOLD_FILE. This is the ONLY process that ever writes
# that sentinel — every role only ever READS it, at its existing step-0
# self-check (see the BUDGET CHECK step in the templates). Read-only against
# the network: makes NO metered calls itself, only reads the local *.jsonl
# transcripts fwf-usage-data.sh already reads.
#
# Enforcement is against the DELTA since this run's baseline (issue #108) —
# $BUDGET_BASELINE_FILE, written once per genuinely fresh `fwf up` by
# fwf_budget_baseline_ensure (lib.sh) — not the lifetime cumulative total, so
# a profile whose worktree paths were reused from an earlier run doesn't
# inherit billions of prior tokens as if they were spent just now.
#
# Usage: fwf-budget-check.sh          (one evaluation, then exits)
#        fwf-budget-check.sh --loop   (re-evaluates every $FWF_BUDGET_CHECK_INTERVAL
#                                       seconds until killed — used by fwf_budget_writer_start)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

_fwf_budget_evaluate_once() {
  command -v jq >/dev/null 2>&1 || return 0

  # No budget configured: never write/touch the sentinel, and clear any hold
  # left over from a PRIOR run that DID have one configured (e.g. the operator
  # unset it) — enforcement being off must mean truly off, not "stuck held".
  if [ -z "${FWF_TOKEN_BUDGET:-}" ] && [ -z "${FWF_BUDGET_USD:-}" ]; then
    rm -f "$BUDGET_HOLD_FILE"
    return 0
  fi

  local usage_json
  usage_json="$("$DIR/fwf-usage-data.sh" 2>/dev/null || echo '')"
  if [ -z "$usage_json" ] || ! printf '%s' "$usage_json" | jq -e . >/dev/null 2>&1; then
    # Could not even run the aggregator — fail CLOSED. Textually distinct from
    # the over-budget HOLD message below (INCIDENT_PROTOCOL: an operator must
    # never confuse "reader broke" with "I blew my budget").
    printf 'UNKNOWN — FAIL-CLOSED: could not read usage (fwf-usage-data.sh failed), NOT over budget — lift: fwf usage --clear-hold\n' > "$BUDGET_HOLD_FILE"
    return 0
  fi

  # A role whose reader broke AFTER previously working (fwf-usage-data.sh's
  # own "stale" state — see its header comment: stale means a prior good read
  # exists but THIS poll couldn't refresh it) means the total can no longer be
  # certified — fail closed for the whole factory rather than risk silently
  # under-counting ongoing spend. A role that has simply never produced usage
  # yet ("unknown", no prior successful read — the normal state right after
  # `fwf up`, before any role has completed a billed turn) is NOT evidence of
  # a broken reader and must not itself trigger a hold — it contributes 0.
  local broken_roles
  broken_roles="$(printf '%s' "$usage_json" | jq -r '[.roles[] | select(.state=="stale") | .role] | join(", ")')"
  if [ -n "$broken_roles" ]; then
    printf 'UNKNOWN — FAIL-CLOSED: could not read usage for: %s (reader error), NOT over budget — lift: fwf usage --clear-hold\n' "$broken_roles" > "$BUDGET_HOLD_FILE"
    return 0
  fi

  # issue #108 AC8: the baseline is as load-bearing as the aggregator itself
  # — current-minus-baseline is undefined without it. Missing/unparseable ->
  # UNKNOWN, NEVER baseline=0 (reintroduces the instant-HOLD bug this issue
  # fixes) and NEVER baseline=current (silently disables the budget).
  local baseline baseline_tokens baseline_cost
  if ! baseline="$(fwf_budget_baseline_read)"; then
    printf 'UNKNOWN — FAIL-CLOSED: no run-start baseline yet (budget-baseline.json missing/unreadable) — this run'"'"'s spend cannot be computed, NOT over budget — lift: fwf usage --clear-hold\n' > "$BUDGET_HOLD_FILE"
    return 0
  fi
  baseline_tokens="${baseline%%$'\t'*}"
  baseline_cost="${baseline#*$'\t'}"

  local total_tokens cost_usd delta_tokens
  total_tokens="$(printf '%s' "$usage_json" | jq -r \
    '[.total.tokens.input, .total.tokens.cache_creation, .total.tokens.cache_read, .total.tokens.output] | add')"
  cost_usd="$(printf '%s' "$usage_json" | jq -r '.total.cost_usd')"
  delta_tokens=$(( total_tokens - baseline_tokens ))

  if [ -n "${FWF_BUDGET_USD:-}" ]; then
    # issue #108 AC2: an unknown model must still fail closed, never silently
    # price it at $0. A role with real data (fresh/stale-but-not-broken — the
    # stale-broken case already returned above) whose model isn't in the
    # price table yields a null cost_usd; that's distinct from "unknown, no
    # data yet" (state=="unknown"), which legitimately contributes 0.
    local unpriced
    unpriced="$(printf '%s' "$usage_json" | jq -r \
      '[.roles[] | select(.state != "unknown") | select(.cost_usd == null) | .role] | join(", ")')"
    if [ -n "$unpriced" ]; then
      printf 'UNKNOWN — FAIL-CLOSED: could not price model for: %s (model missing from the price table), NOT over budget — lift: fwf usage --clear-hold\n' "$unpriced" > "$BUDGET_HOLD_FILE"
      return 0
    fi

    # AC8: current < baseline (mid-run transcript rotation/prune) -> UNKNOWN,
    # never "no spend" — a negative delta is not a clamp-to-zero, it's a sign
    # the read can no longer be trusted this poll.
    local below_baseline
    below_baseline="$(jq -rn --argjson c "$cost_usd" --argjson b "$baseline_cost" '$c < $b')"
    if [ "$below_baseline" = true ]; then
      printf 'UNKNOWN — FAIL-CLOSED: usage read (%s) is below this run'"'"'s baseline (%s) — likely a transcript rotation/prune, NOT over budget — lift: fwf usage --clear-hold\n' "$cost_usd" "$baseline_cost" > "$BUDGET_HOLD_FILE"
      return 0
    fi

    local delta_cost warn_usd over warn_over
    delta_cost="$(jq -rn --argjson c "$cost_usd" --argjson b "$baseline_cost" '$c - $b')"
    warn_usd="$(jq -rn --argjson budget "$FWF_BUDGET_USD" --argjson pct "$FWF_TOKEN_BUDGET_WARN_PCT" '$budget * $pct / 100')"
    over="$(jq -rn --argjson d "$delta_cost" --argjson b "$FWF_BUDGET_USD" '$d >= $b')"
    warn_over="$(jq -rn --argjson d "$delta_cost" --argjson w "$warn_usd" '$d >= $w')"

    if [ "$over" = true ]; then
      printf 'HOLD — $%.4f spent this run (of $%.4f cumulative), budget is $%.4f — lift: raise FWF_BUDGET_USD or fwf usage --clear-hold\n' \
        "$delta_cost" "$cost_usd" "$FWF_BUDGET_USD" > "$BUDGET_HOLD_FILE"
    elif [ "$warn_over" = true ]; then
      printf 'WARN — $%.4f spent this run (of $%.4f cumulative), budget is $%.4f (%s%% warn threshold) — not paused\n' \
        "$delta_cost" "$cost_usd" "$FWF_BUDGET_USD" "$FWF_TOKEN_BUDGET_WARN_PCT" > "$BUDGET_HOLD_FILE"
    else
      rm -f "$BUDGET_HOLD_FILE"
    fi
    return 0
  fi

  # Raw-token ceiling (back-compat) — same AC8 negative-delta guard as the $ path.
  if [ "$delta_tokens" -lt 0 ]; then
    printf 'UNKNOWN — FAIL-CLOSED: usage read (%s tokens) is below this run'"'"'s baseline (%s tokens) — likely a transcript rotation/prune, NOT over budget — lift: fwf usage --clear-hold\n' "$total_tokens" "$baseline_tokens" > "$BUDGET_HOLD_FILE"
    return 0
  fi

  local warn_tokens
  warn_tokens=$(( FWF_TOKEN_BUDGET * FWF_TOKEN_BUDGET_WARN_PCT / 100 ))

  if [ "$delta_tokens" -ge "$FWF_TOKEN_BUDGET" ]; then
    printf 'HOLD — %s tokens spent this run (of %s cumulative; includes cache-read), budget is %s — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold\n' \
      "$delta_tokens" "$total_tokens" "$FWF_TOKEN_BUDGET" > "$BUDGET_HOLD_FILE"
  elif [ "$delta_tokens" -ge "$warn_tokens" ]; then
    printf 'WARN — %s tokens spent this run (of %s cumulative; includes cache-read), budget is %s (%s%% warn threshold) — not paused\n' \
      "$delta_tokens" "$total_tokens" "$FWF_TOKEN_BUDGET" "$FWF_TOKEN_BUDGET_WARN_PCT" > "$BUDGET_HOLD_FILE"
  else
    rm -f "$BUDGET_HOLD_FILE"
  fi
}

main() {
  case "${1:-}" in
    --loop)
      while true; do
        _fwf_budget_evaluate_once
        sleep "$FWF_BUDGET_CHECK_INTERVAL"
      done
      ;;
    "") _fwf_budget_evaluate_once ;;
    *) echo "fwf-budget-check.sh: unknown argument '$1'" >&2; exit 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
