#!/usr/bin/env bash
# fwf-ghcache.sh — shared, single-flight, REST+ETag read cache for `gh` (#57 sibling).
#
# WHY: the factory's coordination bus is the GitHub API. Ten agents each polling
# `gh issue list` / `gh pr list` (which use GraphQL — a 5,000-point/hr bucket with
# tight secondary limits) drain the budget in minutes, stalling the whole floor.
#
# WHAT this does:
#   1. SINGLE-FLIGHT + TTL: N identical polls within a TTL window collapse to ONE
#      upstream fetch (a shared cache all panes + the dash read). This is the
#      load-bearing win and is always 100% correct (it caches gh's own output).
#   2. REST + ETag: the canonical `issue list` / `pr list` shapes are served from
#      ONE per-topic REST fetch (the CORE bucket — separate from GraphQL) with an
#      `If-None-Match` conditional request, so an unchanged poll returns 304 and
#      costs nothing. All list variants (per-label, per-base, projections) filter
#      that one canonical snapshot locally.
#   3. SAFE FALLBACK: anything not provably REST-equivalent (--search, comments,
#      unmapped --json fields) falls back to the single-flight stdout cache (still
#      collapsed, refreshed via real gh). Refresh failures pass through to real gh.
#      The caller is NEVER broken.
#
# Entry: fwf-ghcache.sh serve <issue|pr> <list|view> [gh-args…]
# Env  : FWF_REAL_GH (real gh path), FWF_GHCACHE_DIR (cache root),
#        FWF_GHCACHE_REPO (owner/name) or FWF_REPO (git dir to derive it),
#        FWF_GHCACHE_TTL (seconds, default 60), FWF_GHCACHE_OFF=1 to bypass.
set -u

TTL="${FWF_GHCACHE_TTL:-60}"
LOCK_STALE=45           # break a lock held longer than this (a crashed refresher)
LOCK_WAIT=8             # seconds to wait for another pane's in-flight refresh

# --- real gh (never the shim) ----------------------------------------------
real_gh() {
  if [ -n "${FWF_REAL_GH:-}" ]; then "$FWF_REAL_GH" "$@"; return $?; fi
  command gh "$@"
}

now() { date +%s; }
file_age() { # seconds since $1 was modified; 999999 (==stale) if unknowable.
  # GNU form FIRST: BSD `stat -f` means --file-system on GNU and *succeeds* with
  # junk, so `-f %m || -c %Y` never reaches the GNU fallback on Linux (#57).
  local m; m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) echo 999999;; *) echo $(( $(now) - m ));; esac
}
fresh() { [ -f "$1" ] && [ "$(file_age "$1")" -lt "${2:-$TTL}" ]; }

# owner/name — from env, else parsed from the repo's origin remote (no API call).
repo_slug() {
  if [ -n "${FWF_GHCACHE_REPO:-}" ]; then printf '%s' "$FWF_GHCACHE_REPO"; return; fi
  local url
  url="$(git -C "${FWF_REPO:-.}" config --get remote.origin.url 2>/dev/null)"
  url="${url%.git}"; url="${url#git@github.com:}"; url="${url#https://github.com/}"; url="${url#ssh://git@github.com/}"
  printf '%s' "$url"
}

SLUG="$(repo_slug)"
# Give every real-gh call (the tier-1 fallback for view/--search) an explicit
# repo, so it resolves from ANY cwd — the dash runs outside the target repo, where
# bare `gh issue view N` would otherwise fail "could not resolve to an issue".
[ -n "$SLUG" ] && export GH_REPO="$SLUG"
ROOT="${FWF_GHCACHE_DIR:-${FWF_RUN:-$HOME/.fun-with-friends}/ghcache}/${SLUG//\//__}"
mkdir -p "$ROOT/locks" "$ROOT/stdout" "$ROOT/reviews" 2>/dev/null

# --- single-flight lock (mkdir is atomic; break stale) ----------------------
lock() { # $1=name -> 0 once held
  local d="$ROOT/locks/$1.lock" waited=0
  while ! mkdir "$d" 2>/dev/null; do
    if [ "$(file_age "$d")" -gt "$LOCK_STALE" ]; then rm -rf "$d" 2>/dev/null; continue; fi
    [ "$waited" -ge "$LOCK_WAIT" ] && return 1
    sleep 1; waited=$((waited+1))
  done
  return 0
}
unlock() { rm -rf "$ROOT/locks/$1.lock" 2>/dev/null; }

# --- canonical REST snapshot per topic, ETag-conditional --------------------
# issues live at /issues (which also returns PRs — filtered out); prs at /pulls.
refresh_canonical() { # $1=issue|pr  -> populates $ROOT/<topic>s.json
  local topic="$1" path json etag tsf hdr body status newetag
  case "$topic" in
    issue) path="issues"; json="$ROOT/issues.json"; etag="$ROOT/issues.etag"; tsf="$ROOT/issues.ts";;
    pr)    path="pulls";  json="$ROOT/prs.json";    etag="$ROOT/prs.etag";    tsf="$ROOT/prs.ts";;
    *) return 1;;
  esac
  fresh "$tsf" "$TTL" && [ -f "$json" ] && return 0
  if ! lock "canon-$topic"; then
    # Another pane is already fetching. Wait for ITS fresh REST snapshot rather
    # than firing our own (GraphQL) fallback — this is what kills the cold-start
    # thundering herd so N concurrent first-polls collapse to ONE upstream fetch.
    local w=0; while [ "$w" -lt 12 ]; do { fresh "$tsf" "$TTL" && [ -f "$json" ]; } && return 0; sleep 1; w=$((w+1)); done
    [ -f "$json" ] && return 0 || return 1
  fi
  if fresh "$tsf" "$TTL" && [ -f "$json" ]; then unlock "canon-$topic"; return 0; fi

  # Page 1 with a conditional ETag — the OPEN set only (the hot path). A change
  # to the open set (new/closed issue) shifts page 1, so its ETag is a faithful
  # "did anything change" signal; 304 => unchanged => keep the cache for free.
  local et=""; [ -f "$etag" ] && et="$(cat "$etag")"
  hdr="$(real_gh api -i "/repos/$SLUG/$path?state=open&per_page=100&page=1" \
          ${et:+-H "If-None-Match: $et"} 2>/dev/null)" || { unlock "canon-$topic"; return 1; }
  status="$(printf '%s' "$hdr" | awk 'toupper($1) ~ /^HTTP/ {print $2; exit}')"
  if [ "$status" = "304" ] && [ -f "$json" ]; then touch "$tsf"; unlock "canon-$topic"; return 0; fi
  if [ "$status" != "200" ]; then unlock "canon-$topic"; return 1; fi
  newetag="$(printf '%s' "$hdr" | awk 'BEGIN{IGNORECASE=1} /^etag:/{sub(/^[Ee][Tt][Aa][Gg]: /,""); gsub(/\r/,""); print; exit}')"
  local acc body page=2
  acc="$(printf '%s' "$hdr" | awk 'f{print} /^\r?$/{f=1}')"
  # Paginate while the last page was full (rare for a factory backlog; capped).
  while [ "$(printf '%s' "$acc" | jq 'length' 2>/dev/null || echo 0)" -ge $((100*(page-1))) ] && [ "$page" -le 8 ]; do
    body="$(real_gh api "/repos/$SLUG/$path?state=open&per_page=100&page=$page" 2>/dev/null)" || break
    [ "$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ] || break
    acc="$(printf '%s\n%s' "$acc" "$body" | jq -cs 'add')" || break
    page=$((page+1))
  done
  # Drop PRs from the issues endpoint; order created-desc to match gh's default.
  local filt='.'; [ "$topic" = "issue" ] && filt='[.[] | select(has("pull_request")|not)]'
  printf '%s' "$acc" | jq -c "$filt | sort_by(.created_at) | reverse" > "$json.tmp" 2>/dev/null || { unlock "canon-$topic"; return 1; }
  mv "$json.tmp" "$json"; [ -n "$newetag" ] && printf '%s' "$newetag" > "$etag"; touch "$tsf"
  unlock "canon-$topic"; return 0
}

# reviewDecision needs per-PR reviews (REST, TTL-cached). Matches gh's value:
# any latest-per-user CHANGES_REQUESTED -> CHANGES_REQUESTED; else any APPROVED ->
# APPROVED; else REVIEW_REQUIRED.
ensure_reviews() { # $1=pr number -> writes $ROOT/reviews/<n>.decision
  local n="$1"; local f="$ROOT/reviews/$n.json" tsf="$ROOT/reviews/$n.ts" dec="$ROOT/reviews/$n.decision"
  if ! fresh "$tsf" "$TTL"; then
    if lock "rev-$n"; then
      if ! fresh "$tsf" "$TTL"; then
        if real_gh api "/repos/$SLUG/pulls/$n/reviews?per_page=100" > "$f.tmp" 2>/dev/null; then
          mv "$f.tmp" "$f"; touch "$tsf"
          jq -r '
            [ .[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED") ]
            | group_by(.user.login) | map(max_by(.submitted_at // "")) | map(.state)
            | if any(.=="CHANGES_REQUESTED") then "CHANGES_REQUESTED"
              elif any(.=="APPROVED") then "APPROVED" else "" end
          ' "$f" 2>/dev/null > "$dec" || echo "" > "$dec"
        fi
      fi
      unlock "rev-$n"
    fi
  fi
  [ -f "$dec" ] && cat "$dec" || echo ""
}

# --- gh --json field shapes (REST object -> gh JSON superset) ----------------
ISSUE_SHAPE='{
  number, title, body: (.body // ""), state: (.state|ascii_upcase), url: .html_url,
  createdAt: .created_at, updatedAt: .updated_at, closedAt: .closed_at,
  author: (if .user then {login: .user.login} else null end),
  labels: [ .labels[]? | {id: .node_id, name: .name, description: (.description // ""), color: .color} ],
  assignees: [ .assignees[]? | {login: .login} ]
}'
PR_SHAPE='{
  number, title, body: (.body // ""),
  state: (if .merged_at then "MERGED" else (.state|ascii_upcase) end),
  isDraft: .draft, headRefName: .head.ref, headRefOid: .head.sha, baseRefName: .base.ref,
  url: .html_url, createdAt: .created_at, updatedAt: .updated_at, mergedAt: .merged_at, closedAt: .closed_at,
  author: (if .user then {login: .user.login} else null end)
}'
ISSUE_FIELDS="number title body state url createdAt updatedAt closedAt author labels assignees"
PR_FIELDS="number title body state isDraft headRefName headRefOid baseRefName url createdAt updatedAt mergedAt closedAt author reviewDecision"

in_set() { local x="$1"; shift; case " $* " in *" $x "*) return 0;; esac; return 1; }

# Parse a `list` invocation's flags into P_* globals (a delimited string + `read`
# would collapse our empty fields, since tab is IFS-whitespace). Returns 1 on any
# flag we don't model, so the caller falls back to the safe stdout cache.
parse_list() { # $@=args
  P_STATE=""; P_LABEL=""; P_BASE=""; P_LIMIT=""; P_JSON=""; P_JQ=""; P_SEARCH=""
  local a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --state) P_STATE="$2"; shift 2;;
      --state=*) P_STATE="${a#--state=}"; shift;;
      --label) P_LABEL="$2"; shift 2;;
      --label=*) P_LABEL="${a#--label=}"; shift;;
      --base) P_BASE="$2"; shift 2;;
      --base=*) P_BASE="${a#--base=}"; shift;;
      --limit|-L) P_LIMIT="$2"; shift 2;;
      --limit=*) P_LIMIT="${a#--limit=}"; shift;;
      --json) P_JSON="$2"; shift 2;;
      --json=*) P_JSON="${a#--json=}"; shift;;
      --jq|-q) P_JQ="$2"; shift 2;;
      --jq=*) P_JQ="${a#--jq=}"; shift;;
      --search|-S) P_SEARCH="$2"; shift 2;;
      --search=*) P_SEARCH="${a#--search=}"; shift;;
      *) return 1;;   # an unknown flag -> don't risk it, fall back
    esac
  done
  return 0
}

reshape_list() { # $1=topic ; rest=args  -> stdout (gh-equivalent) or return 1 to fall back
  local topic="$1"; shift
  parse_list "$@" || return 1
  local st="$P_STATE" lbl="$P_LABEL" base="$P_BASE" lim="$P_LIMIT" json="$P_JSON" jq="$P_JQ" search="$P_SEARCH" shape fields
  [ -n "$search" ] && return 1            # search syntax -> fall back (correctness)
  [ -z "$json" ] && return 1              # bare table output -> fall back
  case "$topic" in
    issue) shape="$ISSUE_SHAPE"; fields="$ISSUE_FIELDS";;
    pr)    shape="$PR_SHAPE";    fields="$PR_FIELDS";;
  esac
  local need_reviews=0 f
  for f in ${json//,/ }; do
    in_set "$f" $fields || return 1       # an unmapped field -> fall back
    [ "$f" = "reviewDecision" ] && need_reviews=1
  done
  refresh_canonical "$topic" || return 1
  local src; case "$topic" in issue) src="$ROOT/issues.json";; pr) src="$ROOT/prs.json";; esac
  [ -f "$src" ] || return 1

  # The canonical store IS the open set; only open queries are served from it
  # (closed/merged/all fall back to the safe stdout cache).
  case "$(printf '%s' "${st:-open}" | tr A-Z a-z)" in
    open|"") ;;
    *) return 1;;
  esac
  local stsel='.'
  [ -z "$lim" ] && lim=30   # gh issue/pr list default page size
  local lblsel='.'; [ -n "$lbl" ] && lblsel="select([.labels[]?.name] | index(\"$lbl\"))"
  local basesel='.'; [ -n "$base" ] && basesel="select(.base.ref==\"$base\")"

  # Build the gh-shaped array (filter -> shape -> project requested fields).
  # gh sorts TOP-LEVEL keys alphabetically (nested objects keep gh's struct order);
  # build the projection in sorted order and emit compact (jq -c, not -cS).
  local proj; proj="$(printf '{'; local first=1 ff; for ff in $(printf '%s\n' ${json//,/ } | sort); do [ $first = 1 ] || printf ','; printf '%s: .%s' "$ff" "$ff"; first=0; done; printf '}')"
  local arr
  arr="$(jq -c "[ .[] | $stsel | $lblsel | $basesel ]" "$src" 2>/dev/null)" || return 1

  # Inject reviewDecision per PR if requested (REST reviews, cached).
  if [ "$need_reviews" = 1 ]; then
    local nums n dec out="[]"
    nums="$(printf '%s' "$arr" | jq -r '.[].number' 2>/dev/null)"
    local enriched="[]"
    for n in $nums; do
      dec="$(ensure_reviews "$n")"
      enriched="$(printf '%s' "$arr" | jq -c --argjson keep "$(printf '%s' "$enriched")" --arg n "$n" --arg d "$dec" \
        '($keep) as $k | [ .[] | select(.number==($n|tonumber)) | . + {reviewDecision:$d} ] as $cur | $k + $cur' 2>/dev/null)" || return 1
    done
    arr="$enriched"
    shape="$(printf '%s + {reviewDecision: (.reviewDecision // null)}' "$PR_SHAPE")"
  fi

  local out
  out="$(printf '%s' "$arr" | jq -c "[ .[] | $shape ] | [ .[] | $proj ]" 2>/dev/null)" || return 1
  [ -n "$lim" ] && out="$(printf '%s' "$out" | jq -c ".[0:$lim]" 2>/dev/null)"
  if [ -n "$jq" ]; then printf '%s' "$out" | jq -r "$jq" 2>/dev/null || return 1
  else printf '%s' "$out" | jq -c '.' 2>/dev/null || return 1; fi   # compact; top-level already alpha-ordered
}

# --- tier-1: single-flight stdout cache (caches real gh output) -------------
tier1() { # $@ = full gh argv (e.g. issue list --search …)
  local key; key="$(printf '%s\037' "$SLUG" "$@" | shasum -a 256 2>/dev/null | cut -c1-32)"
  [ -z "$key" ] && { real_gh "$@"; return $?; }
  local out="$ROOT/stdout/$key.out"
  if fresh "$out" "$TTL"; then cat "$out"; return 0; fi
  if lock "s-$key"; then
    if ! fresh "$out" "$TTL"; then
      if real_gh "$@" > "$out.tmp" 2>/dev/null; then mv "$out.tmp" "$out"; else rm -f "$out.tmp"; unlock "s-$key"; [ -f "$out" ] && { cat "$out"; return 0; }; real_gh "$@"; return $?; fi
    fi
    unlock "s-$key"; cat "$out"; return 0
  fi
  [ -f "$out" ] && { cat "$out"; return 0; }   # someone else refreshing; serve stale
  real_gh "$@"
}

# --- entry ------------------------------------------------------------------
[ "${1:-}" = serve ] && shift     # drop the 'serve' subcommand verb
[ "${FWF_GHCACHE_OFF:-0}" = 1 ] && { real_gh "$@"; exit $?; }
case "${1:-} ${2:-}" in
  "issue list"|"pr list")
    topic="$1"; shift 2
    reshape_list "$topic" "$@" && exit 0
    tier1 "$topic" list "$@"; exit $?
    ;;
  "issue view"|"pr view")
    topic="$1"; shift 2
    tier1 "$topic" view "$@"; exit $?
    ;;
  *) real_gh "$@"; exit $?;;
esac
