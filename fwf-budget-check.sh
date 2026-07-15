#!/usr/bin/env bash
# fwf budget-check — the token-budget WRITER (issue #96, Ticket B of #70's
# discovery; see docs/proposals/70-token-usage-budget.md). Evaluates aggregate
# token usage (via fwf-usage-data.sh, Ticket A / #95) against
# $FWF_TOKEN_BUDGET and writes/clears $BUDGET_HOLD_FILE. This is the ONLY
# process that ever writes that sentinel — every role only ever READS it, at
# its existing step-0 self-check (see the BUDGET CHECK step in the templates).
# Read-only against the network: makes NO metered calls itself, only reads
# the local *.jsonl transcripts fwf-usage-data.sh already reads.
#
# issue #108: the enforced total excludes cache_read (cheap-per-token but
# volume-dominant — see the comment at its computation below) and is measured
# SINCE THIS RUN's baseline (captured once at fwf_budget_writer_start, see
# lib.sh), not the worktrees' lifetime-cumulative total.
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
  if [ -z "${FWF_TOKEN_BUDGET:-}" ]; then
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

  # The ceiling formula (issue #108): input + cache_creation + output.
  # cache_read is DELIBERATELY excluded — it's billed at a fraction of the
  # input rate (Anthropic's fixed 0.1x-0.2x multiplier) but dominates raw
  # counts by 2-3 orders of magnitude on a long-lived agent run (every turn
  # re-reads a large cached context), so counting it 1:1 makes an intuitive
  # ceiling like 1000000 trip before any real work happens. cache_read still
  # costs money — it just isn't a meaningful unit for a human-set ceiling; see
  # `fwf usage` for the full (cache-read-inclusive) breakdown and $ estimate.
  local raw_total baseline_total total_tokens warn_tokens
  raw_total="$(printf '%s' "$usage_json" | jq -r \
    '[.total.tokens.input, .total.tokens.cache_creation, .total.tokens.output] | add')"
  baseline_total=0
  if [ -f "$FWF_BUDGET_BASELINE_FILE" ]; then
    baseline_total="$(jq -r '[.input, .cache_creation, .output] | add' "$FWF_BUDGET_BASELINE_FILE" 2>/dev/null || echo 0)"
    case "$baseline_total" in ''|*[!0-9]*) baseline_total=0;; esac
  fi
  # THIS RUN's spend = current cumulative minus the run-start baseline
  # (issue #108) — never the worktrees' lifetime-cumulative total, which
  # would otherwise inherit a prior run's history after `fwf down --purge` +
  # re-`provision` reuses the same worktree paths. Clamped at 0 as a guard
  # against a baseline captured AFTER some of this run's spend (never
  # negative "spend").
  total_tokens=$(( raw_total - baseline_total ))
  [ "$total_tokens" -lt 0 ] && total_tokens=0
  warn_tokens=$(( FWF_TOKEN_BUDGET * FWF_TOKEN_BUDGET_WARN_PCT / 100 ))

  if [ "$total_tokens" -ge "$FWF_TOKEN_BUDGET" ]; then
    printf 'HOLD — %s tokens spent this run (excl. cache-read), budget is %s — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold\n' \
      "$total_tokens" "$FWF_TOKEN_BUDGET" > "$BUDGET_HOLD_FILE"
  elif [ "$total_tokens" -ge "$warn_tokens" ]; then
    printf 'WARN — %s tokens spent this run (excl. cache-read), budget is %s (%s%% warn threshold) — not paused\n' \
      "$total_tokens" "$FWF_TOKEN_BUDGET" "$FWF_TOKEN_BUDGET_WARN_PCT" > "$BUDGET_HOLD_FILE"
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
