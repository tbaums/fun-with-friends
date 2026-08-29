#!/usr/bin/env bash
# fwf usage data provider (issue #95, Ticket A of #70's discovery) — per-role
# token/$ usage aggregated from each role's own Claude Code session
# transcripts. Sibling of fwf-dash-data.sh: bash gathers + shapes JSON, the
# dash Usage tab (or `fwf usage`) renders it. READ-ONLY — this never pauses a
# factory or writes any hold/sentinel (that's Ticket B, #96).
#
# Source: Claude Code appends every turn to
#   ~/.claude/projects/<slugified-cwd>/<session-uuid>.jsonl
# where the slug is the role's pane cwd with every '/' and '.' replaced by
# '-' (verified against this very repo's own project dirs — see
# docs/proposals/70-token-usage-budget.md). Each `"type":"assistant"` line
# carries `message.usage` (token counts) + `message.model`.
#
# A session ROTATES to a new <uuid>.jsonl on compaction/restart — summing
# only the newest file would silently drop everything spent before the last
# compaction. So every file under a role's project dir is summed, with a
# per-file byte-offset + running-sum cache (state below) so a re-poll only
# reads NEW bytes, not the whole history again.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# Overridable for tests; real usage always wants the actual Claude Code dir.
FWF_CLAUDE_PROJECTS_DIR="${FWF_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
# "STALE" = the last successful read for a role is older than this. Roughly
# 2x a typical dash poll interval; overridable for tests/tuning.
FWF_USAGE_STALE_SECS="${FWF_USAGE_STALE_SECS:-180}"
FWF_USAGE_CACHE_DIR="$FWF_STATE_DIR/usage-cache"
mkdir -p "$FWF_USAGE_CACHE_DIR" 2>/dev/null || true

_fwf_usage_now() { date -u +%s; }

# cwd -> Claude Code's project-directory slug: every '/' and '.' -> '-'
# (confirmed against this repo's own ~/.claude/projects/* entries).
_fwf_usage_slug() {
  local s="$1"
  s="${s//\//-}"
  s="${s//./-}"
  printf '%s' "$s"
}

# --- price table (issue #95; a MAINTENANCE BURDEN, not a blocker — dated
# 2026-06-24 per docs/proposals/70-token-usage-budget.md, incl. sonnet-5's
# intro pricing thru 2026-08-31. WILL go stale as pricing/models change; an
# unknown model yields null cost (never a silent/wrong $0 — see the
# UNREADABLE philosophy below), not a crash. $/MTok; cache-write is the 5m-
# breakpoint rate; cache-read is Anthropic's fixed 0.1x-of-input multiplier.
# "valid_until" (issue #289 (f), YYYY-MM-DD or null=no known expiry): a row
# past this date is PRICED but STALE — see _fwf_usage_price_state below.
#
# issue #289 (a): claude-opus-5 (what pm/gv/captain actually run) is
# DELIBERATELY ABSENT. (a1)/(a3): a guessed rate replaces a visible gap with
# an invisible wrong number, which is worse than the gap — inferring it from
# claude-opus-4-8's row is explicitly out of scope. Add a row here, dated and
# sourced (a2), the moment a published rate exists; until then (b) below is
# what keeps the TOTAL honest about the omission.
_FWF_PRICE_TABLE='{
  "claude-opus-4-8":  {"input":5.00,  "output":25.00, "cache_write":6.25, "cache_read":0.50, "valid_until":null},
  "claude-sonnet-5":  {"input":2.00,  "output":10.00, "cache_write":2.50, "cache_read":0.20, "valid_until":"2026-08-31"},
  "claude-haiku-4-5": {"input":1.00,  "output":5.00,  "cache_write":1.25, "cache_read":0.10, "valid_until":null},
  "claude-fable-5":   {"input":10.00, "output":50.00, "cache_write":12.50,"cache_read":1.00, "valid_until":null}
}'

# issue #289 (f2): the clock is INJECTABLE, never bare `date +%s` inline in
# the check itself -- a date-driven check tested against the real clock is
# green today and red on the expiry date for reasons no diff explains.
# FWF_USAGE_NOW_EPOCH overrides for tests; production leaves it unset.
_fwf_usage_now_epoch_for_pricing() { printf '%s' "${FWF_USAGE_NOW_EPOCH:-$(date -u +%s)}"; }

# issue #289 (f0)/(f): classify model $1 against the price table using now-
# epoch $2 (defaults to _fwf_usage_now_epoch_for_pricing). Three states,
# deliberately distinct (f0: "different states, and both must reach the
# TOTAL's partial marker" — collapsing them would lose that distinction):
#   priced    — a row exists and valid_until (if any) has not passed.
#   stale     — a row exists but valid_until has passed.
#   unpriced  — no row at all (includes an unknown/未priced model).
_fwf_usage_price_state() { # $1=model $2=now_epoch(optional)
  local model="$1" now="${2:-$(_fwf_usage_now_epoch_for_pricing)}" until_date until_epoch
  until_date="$(printf '%s' "$_FWF_PRICE_TABLE" | jq -r --arg m "$model" '.[$m].valid_until // empty' 2>/dev/null || true)"
  [ -z "$until_date" ] && {
    printf '%s' "$_FWF_PRICE_TABLE" | jq -e --arg m "$model" 'has($m)' >/dev/null 2>&1 \
      && { printf 'priced'; return 0; } || { printf 'unpriced'; return 0; }
  }
  until_epoch="$(date -u -d "${until_date}T23:59:59Z" +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${until_date}T23:59:59Z" +%s 2>/dev/null || echo "")"
  if [ -z "$until_epoch" ] || [ "$now" -le "$until_epoch" ]; then printf 'priced'
  else printf 'stale'
  fi
}

# Sum new complete "type":"assistant" lines from file $1 since cached byte
# offset $2. Only counts lines the file has already terminated with a
# newline — a trailing partial line (still mid-write) is deferred to the
# next poll rather than risking a truncated-JSON parse. A file shrinking
# below the cached offset (truncated/replaced) resets to a full re-sum from
# zero — never trusts a stale offset past a shrink.
#
# Emits ONE combined JSON object on stdout — the token/model delta PLUS the
# new byte offset — rather than also setting a variable: this function's
# result is always captured via command substitution ($(...)), which forks a
# subshell, so any plain variable it set would vanish with that subshell and
# never reach the caller. Folding new_offset into the emitted JSON is what
# actually survives the round trip.
_fwf_usage_sum_file_since() { # $1=file $2=start_offset
  local file="$1" start="${2:-0}" size chunk
  size="$(wc -c <"$file" 2>/dev/null | tr -d ' ')"; size="${size:-0}"
  [ "$start" -gt "$size" ] && start=0
  if [ "$start" -ge "$size" ]; then
    jq -nc --argjson o "$start" '{new_offset:$o}'; return 0
  fi
  if [ "$(tail -c1 "$file" 2>/dev/null | wc -l | tr -d ' ')" != "1" ]; then
    jq -nc --argjson o "$start" '{new_offset:$o}'; return 0   # mid-write — defer
  fi
  chunk="$(tail -c "+$((start + 1))" "$file" 2>/dev/null || true)"
  [ -z "$chunk" ] && { jq -nc --argjson o "$size" '{new_offset:$o}'; return 0; }
  printf '%s\n' "$chunk" \
    | jq -R 'fromjson? // empty' \
    | jq -sc --argjson o "$size" '[.[] | select(.type=="assistant") | .message] |
        {input:          (map(.usage.input_tokens // 0) | add // 0),
         cache_creation: (map(.usage.cache_creation_input_tokens // 0) | add // 0),
         cache_read:     (map(.usage.cache_read_input_tokens // 0) | add // 0),
         output:         (map(.usage.output_tokens // 0) | add // 0),
         model:          (map(.model) | last // null),
         new_offset:     $o}'
}

# Aggregate one role's usage. Reads/writes this role's cache file (running
# per-file offsets + sums, so a re-poll only reads new bytes) and its
# last-success stamp (so a read failure can still report STALE with the
# last-good numbers instead of silently freezing or going straight to
# UNKNOWN). Emits one role object on stdout.
_fwf_usage_role() { # $1=role
  local role="$1" cwd slug projdir cache now
  cwd="$(fwf_role_cwd "$role" 2>/dev/null || true)"
  cache="$FWF_USAGE_CACHE_DIR/$role.json"
  now="$(_fwf_usage_now)"
  [ -f "$cache" ] || echo '{"files":{},"last_success_epoch":null,"totals":{"input":0,"cache_creation":0,"cache_read":0,"output":0},"model":null}' > "$cache"

  if [ -z "$cwd" ]; then
    _fwf_usage_emit_unknown "$role"; return 0
  fi
  slug="$(_fwf_usage_slug "$cwd")"
  projdir="$FWF_CLAUDE_PROJECTS_DIR/$slug"
  if [ ! -d "$projdir" ]; then
    _fwf_usage_emit_from_cache_or_unknown "$role" "$cache" "$now"; return 0
  fi

  local state totals model f base off delta d_off new_model ok=1
  state="$(cat "$cache")"
  totals="$(printf '%s' "$state" | jq -c '.totals')"
  model="$(printf '%s' "$state" | jq -r '.model // "null"')"
  [ "$model" = "null" ] && model=""
  for f in "$projdir"/*.jsonl; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    off="$(printf '%s' "$state" | jq -r --arg f "$base" '.files[$f] // 0')"
    if ! delta="$(_fwf_usage_sum_file_since "$f" "$off")"; then ok=0; continue; fi
    d_off="$(printf '%s' "$delta" | jq -r '.new_offset')"
    totals="$(jq -nc --argjson a "$totals" --argjson b "$delta" \
      '{input:(($a.input//0)+($b.input//0)), cache_creation:(($a.cache_creation//0)+($b.cache_creation//0)),
        cache_read:(($a.cache_read//0)+($b.cache_read//0)), output:(($a.output//0)+($b.output//0))}')"
    new_model="$(printf '%s' "$delta" | jq -r '.model // empty')"
    [ -n "$new_model" ] && model="$new_model"
    state="$(printf '%s' "$state" | jq -c --arg f "$base" --argjson o "$d_off" '.files[$f]=$o')"
  done

  if [ "$ok" = 1 ]; then
    state="$(printf '%s' "$state" | jq -c --argjson t "$totals" --arg m "$model" --argjson now "$now" \
      '.totals=$t | .model=($m|if .=="" then null else . end) | .last_success_epoch=$now')"
    printf '%s' "$state" > "$cache"
    _fwf_usage_emit fresh "$role" 0 "$model" "$totals"
  else
    _fwf_usage_emit_from_cache_or_unknown "$role" "$cache" "$now"
  fi
}

_fwf_usage_emit_unknown() { # $1=role
  jq -nc --arg role "$1" '{role:$role, state:"unknown", age_secs:null, model:null,
    tokens:{input:0,cache_creation:0,cache_read:0,output:0}, cost_usd:null}'
}

_fwf_usage_emit_from_cache_or_unknown() { # $1=role $2=cache_file $3=now
  local role="$1" cache="$2" now="$3" last model totals age
  last="$(jq -r '.last_success_epoch // empty' "$cache" 2>/dev/null || true)"
  if [ -z "$last" ]; then _fwf_usage_emit_unknown "$role"; return 0; fi
  model="$(jq -r '.model // empty' "$cache")"
  totals="$(jq -c '.totals' "$cache")"
  age=$((now - last))
  _fwf_usage_emit stale "$role" "$age" "$model" "$totals"
}

_fwf_usage_emit() { # $1=state $2=role $3=age_secs $4=model(may be empty) $5=totals-json
  local state="$1" role="$2" age="$3" model="$4" totals="$5" cost price_state="unpriced"
  if [ -n "$model" ]; then price_state="$(_fwf_usage_price_state "$model")"; fi
  # issue #289 (f1): a STALE price still degrades the report, it does not
  # gate anything -- compute the best-available number (the expired rate)
  # rather than dropping it to null like a genuinely unpriced model. The
  # row's price_state is what tells a reader (and the TOTAL's partial
  # marker) that this number is stale, not the presence/absence of a number.
  if [ "$price_state" != "unpriced" ]; then
    cost="$(jq -nc --argjson t "$totals" --arg m "$model" --argjson prices "$_FWF_PRICE_TABLE" '
      $prices[$m] as $p |
      (($t.input // 0) * $p.input
       + ($t.cache_creation // 0) * $p.cache_write
       + ($t.cache_read // 0) * $p.cache_read
       + ($t.output // 0) * $p.output) / 1000000')"
  else
    cost=null
  fi
  jq -nc --arg state "$state" --arg role "$role" --argjson age "$age" \
    --arg model "$model" --argjson tokens "$totals" --argjson cost "$cost" --arg price_state "$price_state" '
    {role:$role, state:$state, age_secs:$age,
     model:(if $model=="" then null else $model end),
     tokens:$tokens, cost_usd:$cost,
     price_state:(if $model=="" then null else $price_state end)}'
}

# issue #289 (e): price-table drift check against BOTH sources -- $1=
# newline-separated REPORTED models (retrospective: what a seat's own
# transcript actually emits; sees only models a seat has run at least once),
# $2=newline-separated DECLARED models (prospective: FWF_MODEL/_ROLE and
# every FWF_MODEL_MENU entry; sees a configured-but-never-run model the
# reported half cannot). Neither subsumes the other -- see the ticket for
# why (a menu entry nobody picked yet, or a model set at `fwf up` for a seat
# that has not produced a transcript yet, are each invisible to one source).
# (e2): the asymmetry is deliberate -- ONLY offered/reported-but-unpriced is
# a defect; a priced-but-unoffered table row (claude-fable-5 today) is fine,
# the table may legitimately carry models nobody currently runs.
# Prints one line per drift instance; returns 1 if any found, 0 if clean.
fwf_usage_model_drift() { # $1=reported-models(newline) $2=declared-models(newline)
  local reported="$1" declared="$2" m rc=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s' "$_FWF_PRICE_TABLE" | jq -e --arg m "$m" 'has($m)' >/dev/null 2>&1 \
      || { echo "REPORTED model NOT priced: $m"; rc=1; }
  done <<<"$reported"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s' "$_FWF_PRICE_TABLE" | jq -e --arg m "$m" 'has($m)' >/dev/null 2>&1 \
      || { echo "DECLARED model NOT priced: $m"; rc=1; }
  done <<<"$declared"
  return $rc
}

# Convenience wrapper over the REAL live state: reported = every non-unknown
# role's model from an already-fetched usage-data JSON; declared = this
# box's FWF_MODEL/_IMPL/_QA/_PM/_GV/_CAPTAIN/_CONDUCTOR + every
# FWF_MODEL_MENU entry.
fwf_usage_model_drift_live() { # $1=usage-data-json
  local data="$1" reported declared
  reported="$(printf '%s' "$data" | jq -r '.roles[] | select(.state != "unknown") | .model // empty')"
  declared="$(
    { printf '%s\n' "${FWF_MODEL:-}" "${FWF_MODEL_IMPL:-}" "${FWF_MODEL_QA:-}" "${FWF_MODEL_PM:-}" \
        "${FWF_MODEL_GV:-}" "${FWF_MODEL_CAPTAIN:-}" "${FWF_MODEL_CONDUCTOR:-}"
      printf '%s' "${FWF_MODEL_MENU:-}" | tr '|' '\n' | cut -d: -f1 | sed 's/^ *//;s/ *$//'
    } | sort -u
  )"
  fwf_usage_model_drift "$reported" "$declared"
}

# Main body: emit the whole-factory usage roll-up. Guarded so this file can also
# be SOURCED (e.g. by fwf-supervise.sh, #165) purely to reuse _fwf_usage_role for
# per-role token sampling, without triggering an all-roles poll + JSON dump.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
command -v jq >/dev/null 2>&1 || { echo '{"error":"jq is required for fwf usage"}'; exit 1; }

roles_json="[]"
for role in $(fwf_all_roles); do
  r="$(_fwf_usage_role "$role")"
  roles_json="$(jq -nc --argjson arr "$roles_json" --argjson r "$r" '$arr + [$r]')"
done

# issue #289 (b): the per-row null (unpriced) is correct and untouched above
# -- the defect was ONLY here, at the aggregate, where `// 0` laundered every
# unpriced/stale-priced row into a silent, indistinguishable zero. Fixed by
# naming what was excluded (b1) and its magnitude (b2) rather than changing
# what the summed number itself means (it was already, and remains, "sum of
# what could be priced" -- the bug was that nothing said so).
jq -nc --argjson roles "$roles_json" --argjson stale_secs "$FWF_USAGE_STALE_SECS" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($roles | map(select(.state != "unknown" and .price_state == "unpriced")) | map("\(.role) (\(.model))")) as $unpriced_seats |
  ($roles | map(select(.state != "unknown" and .price_state == "stale")) | map("\(.role) (\(.model))")) as $stale_priced_seats |
  ($roles | map((.tokens.input//0)+(.tokens.cache_creation//0)+(.tokens.cache_read//0)+(.tokens.output//0)) | add // 0) as $grand_tokens |
  ($roles | map(select(.state != "unknown" and .price_state != "priced")) |
    map((.tokens.input//0)+(.tokens.cache_creation//0)+(.tokens.cache_read//0)+(.tokens.output//0)) | add // 0) as $excluded_tokens |
  {generated_at: $generated_at,
   stale_secs: $stale_secs,
   caveat: "estimated $ equivalent — not your account'\''s actual rolling-window usage",
   roles: $roles,
   total: {
     tokens: {
       input:          ($roles | map(.tokens.input // 0) | add // 0),
       cache_creation: ($roles | map(.tokens.cache_creation // 0) | add // 0),
       cache_read:     ($roles | map(.tokens.cache_read // 0) | add // 0),
       output:         ($roles | map(.tokens.output // 0) | add // 0)
     },
     # (b) sum of rows that HAD a price (priced or stale-priced) -- an
     # unpriced row still contributes 0 here, same arithmetic as before the
     # fix; what changed is that "partial" + the two seat lists below now
     # say so instead of leaving this number looking complete.
     cost_usd: ($roles | map(.cost_usd // 0) | add // 0),
     partial: (($unpriced_seats | length) > 0 or ($stale_priced_seats | length) > 0),
     unpriced_seats: $unpriced_seats,
     stale_priced_seats: $stale_priced_seats,
     # (b2): magnitude, not just a bool -- what fraction of ALL factory
     # tokens (grand total across every role, priced or not) is held by
     # seats this cost_usd figure does NOT reflect. 0 when nothing is
     # excluded or there is no usage yet.
     excluded_tokens_pct: (if $grand_tokens > 0 then (($excluded_tokens / $grand_tokens) * 100) else 0 end)
   }}'
fi
