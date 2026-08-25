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

# Token/$ ceiling check (issues #96/#108). Emits "STATUS\tMESSAGE" on stdout,
# STATUS in OK|WARN|HOLD|UNKNOWN — never writes $BUDGET_HOLD_FILE itself
# anymore; the orchestrator below composes this with the subscription check
# (issue #149) so the two guards can't clobber each other's verdict.
_fwf_token_budget_evaluate() {
  # No budget configured: OK, nothing to say. The orchestrator is responsible
  # for clearing any stale hold when NEITHER guard is armed.
  if [ -z "${FWF_TOKEN_BUDGET:-}" ] && [ -z "${FWF_BUDGET_USD:-}" ]; then
    printf 'OK\t\n'
    return 0
  fi

  local usage_json
  usage_json="$("$DIR/fwf-usage-data.sh" 2>/dev/null || echo '')"
  if [ -z "$usage_json" ] || ! printf '%s' "$usage_json" | jq -e . >/dev/null 2>&1; then
    # Could not even run the aggregator — fail CLOSED. Textually distinct from
    # the over-budget HOLD message below (INCIDENT_PROTOCOL: an operator must
    # never confuse "reader broke" with "I blew my budget").
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: could not read usage (fwf-usage-data.sh failed), NOT over budget — lift: fwf usage --clear-hold\n'
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
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: could not read usage for: %s (reader error), NOT over budget — lift: fwf usage --clear-hold\n' "$broken_roles"
    return 0
  fi

  # issue #108 AC8: the baseline is as load-bearing as the aggregator itself
  # — current-minus-baseline is undefined without it. Missing/unparseable ->
  # UNKNOWN, NEVER baseline=0 (reintroduces the instant-HOLD bug this issue
  # fixes) and NEVER baseline=current (silently disables the budget).
  local baseline baseline_tokens baseline_cost
  if ! baseline="$(fwf_budget_baseline_read)"; then
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: no run-start baseline yet (budget-baseline.json missing/unreadable) — this run'"'"'s spend cannot be computed, NOT over budget — lift: fwf usage --clear-hold\n'
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
      printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: could not price model for: %s (model missing from the price table), NOT over budget — lift: fwf usage --clear-hold\n' "$unpriced"
      return 0
    fi

    # AC8: current < baseline (mid-run transcript rotation/prune) -> UNKNOWN,
    # never "no spend" — a negative delta is not a clamp-to-zero, it's a sign
    # the read can no longer be trusted this poll.
    local below_baseline
    below_baseline="$(jq -rn --argjson c "$cost_usd" --argjson b "$baseline_cost" '$c < $b')"
    if [ "$below_baseline" = true ]; then
      printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: usage read (%s) is below this run'"'"'s baseline (%s) — likely a transcript rotation/prune, NOT over budget — lift: fwf usage --clear-hold\n' "$cost_usd" "$baseline_cost"
      return 0
    fi

    local delta_cost warn_usd over warn_over
    delta_cost="$(jq -rn --argjson c "$cost_usd" --argjson b "$baseline_cost" '$c - $b')"
    warn_usd="$(jq -rn --argjson budget "$FWF_BUDGET_USD" --argjson pct "$FWF_TOKEN_BUDGET_WARN_PCT" '$budget * $pct / 100')"
    over="$(jq -rn --argjson d "$delta_cost" --argjson b "$FWF_BUDGET_USD" '$d >= $b')"
    warn_over="$(jq -rn --argjson d "$delta_cost" --argjson w "$warn_usd" '$d >= $w')"

    if [ "$over" = true ]; then
      printf 'HOLD\t'
      printf 'HOLD — $%.4f spent this run (of $%.4f cumulative), budget is $%.4f — lift: raise FWF_BUDGET_USD or fwf usage --clear-hold\n' \
        "$delta_cost" "$cost_usd" "$FWF_BUDGET_USD"
    elif [ "$warn_over" = true ]; then
      printf 'WARN\t'
      printf 'WARN — $%.4f spent this run (of $%.4f cumulative), budget is $%.4f (%s%% warn threshold) — not paused\n' \
        "$delta_cost" "$cost_usd" "$FWF_BUDGET_USD" "$FWF_TOKEN_BUDGET_WARN_PCT"
    else
      printf 'OK\t\n'
    fi
    return 0
  fi

  # Raw-token ceiling (back-compat) — same AC8 negative-delta guard as the $ path.
  if [ "$delta_tokens" -lt 0 ]; then
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: usage read (%s tokens) is below this run'"'"'s baseline (%s tokens) — likely a transcript rotation/prune, NOT over budget — lift: fwf usage --clear-hold\n' "$total_tokens" "$baseline_tokens"
    return 0
  fi

  local warn_tokens
  warn_tokens=$(( FWF_TOKEN_BUDGET * FWF_TOKEN_BUDGET_WARN_PCT / 100 ))

  if [ "$delta_tokens" -ge "$FWF_TOKEN_BUDGET" ]; then
    printf 'HOLD\t'
    printf 'HOLD — %s tokens spent this run (of %s cumulative; includes cache-read), budget is %s — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold\n' \
      "$delta_tokens" "$total_tokens" "$FWF_TOKEN_BUDGET"
  elif [ "$delta_tokens" -ge "$warn_tokens" ]; then
    printf 'WARN\t'
    printf 'WARN — %s tokens spent this run (of %s cumulative; includes cache-read), budget is %s (%s%% warn threshold) — not paused\n' \
      "$delta_tokens" "$total_tokens" "$FWF_TOKEN_BUDGET" "$FWF_TOKEN_BUDGET_WARN_PCT"
  else
    printf 'OK\t\n'
  fi
}

# Subscription-usage brake (issue #149). Same "STATUS\tMESSAGE" contract as
# _fwf_token_budget_evaluate. Fail-closed on every one of the four blind
# shapes named in the ticket's AC3 (missing/empty/unparseable/malformed-
# schema — all folded into fwf_subscription_usage_read's reasons) and on a
# stale signal; resumes only on a FRESH sub-RESUME reading (never a timer).
_fwf_subscription_budget_evaluate() {
  # Not armed: OK, and drop any parked-state left over from a prior armed run
  # (opting out must mean truly off, not "stuck held" — same posture as the
  # token/$ guard above).
  if [ -z "${FWF_SESSION_PCT_PARK:-}" ] && [ -z "${FWF_WEEKLY_PCT_PARK:-}" ]; then
    rm -f "$SUBSCRIPTION_PARKED_FILE"
    printf 'OK\t\n'
    return 0
  fi

  local raw
  if ! raw="$(fwf_subscription_usage_read)"; then
    touch "$SUBSCRIPTION_PARKED_FILE" 2>/dev/null || true
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: subscription usage signal %s (%s) — NOT necessarily over your subscription limit, just unreadable — lift: fwf usage --clear-hold\n' \
      "$raw" "$SUBSCRIPTION_USAGE_FILE"
    return 0
  fi

  local session_pct weekly_pct as_of_epoch now age
  session_pct="$(printf '%s' "$raw" | cut -f1)"
  weekly_pct="$(printf '%s' "$raw" | cut -f2)"
  as_of_epoch="$(printf '%s' "$raw" | cut -f3)"
  now="$(date +%s)"
  age=$(( now - as_of_epoch ))
  if [ "$age" -gt "$FWF_SUBSCRIPTION_STALE_SECS" ]; then
    touch "$SUBSCRIPTION_PARKED_FILE" 2>/dev/null || true
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: subscription usage signal is %ds old (stale bound %ds) — helper may be wedged, NOT necessarily over budget — lift: fwf usage --clear-hold\n' \
      "$age" "$FWF_SUBSCRIPTION_STALE_SECS"
    return 0
  fi
  # A negative age means the signal is timestamped in the future relative to
  # this box — clock skew or a bad `as_of`, either way not trustworthy.
  if [ "$age" -lt 0 ]; then
    touch "$SUBSCRIPTION_PARKED_FILE" 2>/dev/null || true
    printf 'UNKNOWN\tUNKNOWN — FAIL-CLOSED: subscription usage signal is timestamped %ds in the future (clock skew?) — lift: fwf usage --clear-hold\n' "$(( -age ))"
    return 0
  fi

  # Monotonic-within-window sanity: substitute the ratcheted effective value.
  session_pct="$(fwf_subscription_monotonic_apply session "$session_pct")"
  weekly_pct="$(fwf_subscription_monotonic_apply weekly "$weekly_pct")"

  local was_parked=0
  [ -f "$SUBSCRIPTION_PARKED_FILE" ] && was_parked=1

  local breach=""
  if [ -n "${FWF_SESSION_PCT_PARK:-}" ]; then
    if [ "$was_parked" = 1 ]; then
      if [ "$(awk -v a="$session_pct" -v b="$FWF_SESSION_PCT_RESUME" 'BEGIN{print (a<b)?1:0}')" != 1 ]; then
        breach="session ${session_pct}% (>= resume threshold ${FWF_SESSION_PCT_RESUME}%)"
      fi
    else
      if [ "$(awk -v a="$session_pct" -v b="$FWF_SESSION_PCT_PARK" 'BEGIN{print (a>=b)?1:0}')" = 1 ]; then
        breach="session ${session_pct}% >= park threshold ${FWF_SESSION_PCT_PARK}%"
      fi
    fi
  fi
  if [ -z "$breach" ] && [ -n "${FWF_WEEKLY_PCT_PARK:-}" ]; then
    if [ "$was_parked" = 1 ]; then
      if [ "$(awk -v a="$weekly_pct" -v b="$FWF_WEEKLY_PCT_RESUME" 'BEGIN{print (a<b)?1:0}')" != 1 ]; then
        breach="weekly ${weekly_pct}% (>= resume threshold ${FWF_WEEKLY_PCT_RESUME}%)"
      fi
    else
      if [ "$(awk -v a="$weekly_pct" -v b="$FWF_WEEKLY_PCT_PARK" 'BEGIN{print (a>=b)?1:0}')" = 1 ]; then
        breach="weekly ${weekly_pct}% >= park threshold ${FWF_WEEKLY_PCT_PARK}%"
      fi
    fi
  fi

  if [ -n "$breach" ]; then
    touch "$SUBSCRIPTION_PARKED_FILE" 2>/dev/null || true
    printf 'HOLD\tHOLD — subscription %s (signal %ds old) — lift: fwf usage --clear-hold (or wait for a fresh sub-resume-threshold reading)\n' "$breach" "$age"
  else
    rm -f "$SUBSCRIPTION_PARKED_FILE"
    printf 'OK\t\n'
  fi
}

# Orchestrator: composes both guards into the ONE sentinel every role reads.
# Severity HOLD/UNKNOWN (both PAUSE per the templates' "starts with HOLD or
# UNKNOWN" check) > WARN > OK. Never lets one guard's OK clear a hold the
# OTHER guard still wants — the file is written from the combined verdict,
# not from whichever guard ran last.
_fwf_budget_evaluate_once() {
  command -v jq >/dev/null 2>&1 || return 0

  local tok_line sub_line tok_status tok_msg sub_status sub_msg
  tok_line="$(_fwf_token_budget_evaluate)"
  tok_status="${tok_line%%$'\t'*}"; tok_msg="${tok_line#*$'\t'}"
  sub_line="$(_fwf_subscription_budget_evaluate)"
  sub_status="${sub_line%%$'\t'*}"; sub_msg="${sub_line#*$'\t'}"

  _fwf_budget_sev() { case "$1" in UNKNOWN) echo 3;; HOLD) echo 2;; WARN) echo 1;; *) echo 0;; esac; }
  local tok_sev sub_sev
  tok_sev="$(_fwf_budget_sev "$tok_status")"
  sub_sev="$(_fwf_budget_sev "$sub_status")"

  if [ "$tok_sev" = 0 ] && [ "$sub_sev" = 0 ]; then
    rm -f "$BUDGET_HOLD_FILE"
  elif [ "$tok_sev" -ge "$sub_sev" ] && [ "$tok_sev" -gt 0 ]; then
    if [ "$sub_sev" -gt 0 ]; then
      printf '%s (subscription ALSO flagged: %s)\n' "$tok_msg" "$sub_msg" > "$BUDGET_HOLD_FILE"
    else
      printf '%s\n' "$tok_msg" > "$BUDGET_HOLD_FILE"
    fi
  else
    if [ "$tok_sev" -gt 0 ]; then
      printf '%s (token/$ budget ALSO flagged: %s)\n' "$sub_msg" "$tok_msg" > "$BUDGET_HOLD_FILE"
    else
      printf '%s\n' "$sub_msg" > "$BUDGET_HOLD_FILE"
    fi
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
