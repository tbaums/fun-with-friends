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
_FWF_PRICE_TABLE='{
  "claude-opus-4-8":  {"input":5.00,  "output":25.00, "cache_write":6.25, "cache_read":0.50},
  "claude-sonnet-5":  {"input":2.00,  "output":10.00, "cache_write":2.50, "cache_read":0.20},
  "claude-haiku-4-5": {"input":1.00,  "output":5.00,  "cache_write":1.25, "cache_read":0.10},
  "claude-fable-5":   {"input":10.00, "output":50.00, "cache_write":12.50,"cache_read":1.00}
}'

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
  local state="$1" role="$2" age="$3" model="$4" totals="$5" cost
  cost="$(jq -nc --argjson t "$totals" --arg m "$model" --argjson prices "$_FWF_PRICE_TABLE" '
    ($prices[$m] // null) as $p |
    if $p == null then null else
      (($t.input // 0) * $p.input
       + ($t.cache_creation // 0) * $p.cache_write
       + ($t.cache_read // 0) * $p.cache_read
       + ($t.output // 0) * $p.output) / 1000000
    end')"
  jq -nc --arg state "$state" --arg role "$role" --argjson age "$age" \
    --arg model "$model" --argjson tokens "$totals" --argjson cost "$cost" '
    {role:$role, state:$state, age_secs:$age,
     model:(if $model=="" then null else $model end),
     tokens:$tokens, cost_usd:$cost}'
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

jq -nc --argjson roles "$roles_json" --argjson stale_secs "$FWF_USAGE_STALE_SECS" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
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
     cost_usd: ($roles | map(.cost_usd // 0) | add // 0)
   }}'
fi
