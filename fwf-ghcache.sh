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
#      that one canonical snapshot locally. `issue/pr view --json …` (+ `comments`)
#      is likewise served from a per-resource REST+ETag fetch (#58), and the
#      three enumerated `--search` patterns (is:open ± label filters) filter the
#      same canonical open-set snapshot list uses. `pr diff --name-only` is
#      served from a paginated `/pulls/{n}/files` REST fetch (#58).
#   3. SAFE FALLBACK: anything not provably REST-equivalent (an unrecognized
#      --search string, an unmapped --json field, a non-open state, any other
#      view/diff flag) falls back to the single-flight stdout cache (still
#      collapsed, refreshed via real gh). Refresh failures pass through to real gh.
#      The caller is NEVER broken.
#
# Entry: fwf-ghcache.sh serve <issue|pr> <list|view> [gh-args…]
#        fwf-ghcache.sh serve pr diff [gh-args…]
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
# `view`-only field, layered on top of the list fields above (list has no
# equivalent — gh's list schema doesn't expose it). REST has no equivalent of
# GraphQL's isMinimized/minimizedReason/reactionGroups/viewerDidAuthor for a
# comment (those are GraphQL-only concepts), so they default to the common
# case (unminimized, not-the-viewer) rather than being omitted.
COMMENT_SHAPE='{
  id: (.id|tostring),
  author: (if .user then {login: .user.login} else null end),
  authorAssociation: (.author_association // "NONE"),
  body: (.body // ""),
  createdAt: .created_at,
  includesCreatedEdit: (.created_at != .updated_at),
  isMinimized: false,
  minimizedReason: "",
  reactionGroups: [],
  url: .html_url,
  viewerDidAuthor: false
}'

in_set() { local x="$1"; shift; case " $* " in *" $x "*) return 0;; esac; return 1; }

# Recognized --search vocabulary ONLY (#58): is:open, is:closed, label:<x>,
# -label:<x> — the exact token grammar the templates emit (mirrors
# fwf-issues.sh:parse_search). FAILS CLOSED on anything else (author:, sort:,
# a date qualifier, free text, "#123", …): an unrecognized token means we do
# not actually know what GitHub's search would return, so guessing risks
# feeding a role the WRONG issue/PR set — worse than spending a GraphQL call.
# Sets SR_STATE/SR_LABELS/SR_NOTLABELS on success (return 0).
parse_search_tokens() {
  SR_STATE="open"; SR_LABELS=""; SR_NOTLABELS=""
  local tok
  for tok in $1; do
    case "$tok" in
      is:open)   SR_STATE="open";;
      is:closed) SR_STATE="closed";;
      -label:*)  SR_NOTLABELS="$SR_NOTLABELS ${tok#-label:}";;
      label:*)   SR_LABELS="$SR_LABELS ${tok#label:}";;
      *)         return 1;;
    esac
  done
  return 0
}

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
  SR_LABELS=""; SR_NOTLABELS=""
  if [ -n "$search" ]; then
    # Only `issue list --search "…"` uses the recognized vocabulary in the
    # templates today (`pr list --search` is always --state merged, which the
    # open-only canonical snapshot can't serve anyway — falls through below).
    [ "$topic" = "issue" ] || return 1
    parse_search_tokens "$search" || return 1
    [ "$SR_STATE" = "open" ] || return 1   # canonical snapshot models the open set only
    st="open"
  fi
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
  local lblsel='.' ll; for ll in $lbl $SR_LABELS; do lblsel="$lblsel | select([.labels[]?.name] | index(\"$ll\"))"; done
  local notsel='.' nl; for nl in $SR_NOTLABELS; do notsel="$notsel | select([.labels[]?.name] | index(\"$nl\") | not)"; done
  local basesel='.'; [ -n "$base" ] && basesel="select(.base.ref==\"$base\")"

  # Build the gh-shaped array (filter -> shape -> project requested fields).
  # gh sorts TOP-LEVEL keys alphabetically (nested objects keep gh's struct order);
  # build the projection in sorted order and emit compact (jq -c, not -cS).
  local proj; proj="$(printf '{'; local first=1 ff; for ff in $(printf '%s\n' ${json//,/ } | sort); do [ $first = 1 ] || printf ','; printf '%s: .%s' "$ff" "$ff"; first=0; done; printf '}')"
  local arr
  arr="$(jq -c "[ .[] | $stsel | $lblsel | $notsel | $basesel ]" "$src" 2>/dev/null)" || return 1

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

# --- per-resource REST + ETag (issue/pr view) --------------------------------
# Keyed by <topic>-<n>, separate from the list-level issues.etag/prs.etag
# (#58 GV item 4: per-resource ETags must not collide with the list ETags).
mkdir -p "$ROOT/views" 2>/dev/null
ensure_view_resource() { # $1=topic(issue|pr) $2=number -> $ROOT/views/$1-$2.json
  local topic="$1" n="$2" path json etag tsf hdr status newetag body
  case "$topic" in issue) path="issues";; pr) path="pulls";; *) return 1;; esac
  json="$ROOT/views/$topic-$n.json"; etag="$ROOT/views/$topic-$n.etag"; tsf="$ROOT/views/$topic-$n.ts"
  fresh "$tsf" "$TTL" && [ -f "$json" ] && return 0
  if ! lock "view-$topic-$n"; then
    local w=0; while [ "$w" -lt 12 ]; do { fresh "$tsf" "$TTL" && [ -f "$json" ]; } && return 0; sleep 1; w=$((w+1)); done
    [ -f "$json" ] && return 0 || return 1
  fi
  if fresh "$tsf" "$TTL" && [ -f "$json" ]; then unlock "view-$topic-$n"; return 0; fi
  local et=""; [ -f "$etag" ] && et="$(cat "$etag")"
  hdr="$(real_gh api -i "/repos/$SLUG/$path/$n" ${et:+-H "If-None-Match: $et"} 2>/dev/null)" || { unlock "view-$topic-$n"; return 1; }
  status="$(printf '%s' "$hdr" | awk 'toupper($1) ~ /^HTTP/ {print $2; exit}')"
  # 404 (or any non-200/304): don't crash, don't guess — fall through to real
  # gh so the caller sees gh's own error, never a wrong-but-well-formed result.
  if [ "$status" = "304" ] && [ -f "$json" ]; then touch "$tsf"; unlock "view-$topic-$n"; return 0; fi
  if [ "$status" != "200" ]; then unlock "view-$topic-$n"; return 1; fi
  newetag="$(printf '%s' "$hdr" | awk 'BEGIN{IGNORECASE=1} /^etag:/{sub(/^[Ee][Tt][Aa][Gg]: /,""); gsub(/\r/,""); print; exit}')"
  body="$(printf '%s' "$hdr" | awk 'f{print} /^\r?$/{f=1}')"
  printf '%s' "$body" | jq -c '.' > "$json.tmp" 2>/dev/null && [ -s "$json.tmp" ] || { rm -f "$json.tmp"; unlock "view-$topic-$n"; return 1; }
  mv "$json.tmp" "$json"; [ -n "$newetag" ] && printf '%s' "$newetag" > "$etag"; touch "$tsf"
  unlock "view-$topic-$n"; return 0
}

# Issue AND PR comments both live at /issues/$n/comments (a PR is an issue in
# GitHub's data model) — keyed by number alone, not topic, matching that.
ensure_view_comments() { # $1=number -> $ROOT/views/$1-comments.json
  local n="$1" json etag tsf hdr status newetag acc page body cnt
  json="$ROOT/views/$n-comments.json"; etag="$ROOT/views/$n-comments.etag"; tsf="$ROOT/views/$n-comments.ts"
  fresh "$tsf" "$TTL" && [ -f "$json" ] && return 0
  if ! lock "view-comments-$n"; then
    local w=0; while [ "$w" -lt 12 ]; do { fresh "$tsf" "$TTL" && [ -f "$json" ]; } && return 0; sleep 1; w=$((w+1)); done
    [ -f "$json" ] && return 0 || return 1
  fi
  if fresh "$tsf" "$TTL" && [ -f "$json" ]; then unlock "view-comments-$n"; return 0; fi
  local et=""; [ -f "$etag" ] && et="$(cat "$etag")"
  hdr="$(real_gh api -i "/repos/$SLUG/issues/$n/comments?per_page=100&page=1" ${et:+-H "If-None-Match: $et"} 2>/dev/null)" || { unlock "view-comments-$n"; return 1; }
  status="$(printf '%s' "$hdr" | awk 'toupper($1) ~ /^HTTP/ {print $2; exit}')"
  if [ "$status" = "304" ] && [ -f "$json" ]; then touch "$tsf"; unlock "view-comments-$n"; return 0; fi
  if [ "$status" != "200" ]; then unlock "view-comments-$n"; return 1; fi
  newetag="$(printf '%s' "$hdr" | awk 'BEGIN{IGNORECASE=1} /^etag:/{sub(/^[Ee][Tt][Aa][Gg]: /,""); gsub(/\r/,""); print; exit}')"
  acc="$(printf '%s' "$hdr" | awk 'f{print} /^\r?$/{f=1}')"
  page=2
  while [ "$(printf '%s' "$acc" | jq 'length' 2>/dev/null || echo 0)" -ge $((100*(page-1))) ] && [ "$page" -le 10 ]; do
    body="$(real_gh api "/repos/$SLUG/issues/$n/comments?per_page=100&page=$page" 2>/dev/null)" || break
    cnt="$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo 0)"
    [ "$cnt" -gt 0 ] || break
    acc="$(printf '%s\n%s' "$acc" "$body" | jq -cs 'add')" || break
    page=$((page+1))
  done
  printf '%s' "$acc" | jq -c '.' > "$json.tmp" 2>/dev/null || { unlock "view-comments-$n"; return 1; }
  mv "$json.tmp" "$json"; [ -n "$newetag" ] && printf '%s' "$newetag" > "$etag"; touch "$tsf"
  unlock "view-comments-$n"; return 0
}

# `issue/pr view --json …` REST reshape. Cache-key correctness (#58 GV item
# 3): the base resource and its comments are cached in SEPARATE files, keyed
# by resource identity alone — never by the requested --json field set. The
# shape+field-projection below is recomputed live on every call from whatever
# raw files exist, so a `--json comments` call always fetches comments first
# if they aren't cached yet; it can never be served a stale comment-less body
# left over from an earlier comment-less call of the same #N.
reshape_view() { # $1=topic ; rest=args -> stdout (gh-equivalent) or return 1 to fall back
  local topic="$1"; shift
  local num="" jsonf="" jqf="" a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --json) jsonf="$2"; shift 2;;
      --json=*) jsonf="${a#--json=}"; shift;;
      --jq|-q) jqf="$2"; shift 2;;
      --jq=*) jqf="${a#--jq=}"; shift;;
      -*) return 1;;                          # any other flag (--comments, --web, …) -> fall back
      *) [ -z "$num" ] && num="$a" || return 1; shift;;
    esac
  done
  [ -n "$num" ] || return 1
  case "$num" in *[!0-9]*) return 1;; esac     # not a bare number (e.g. a URL) -> fall back
  [ -n "$jsonf" ] || return 1                  # no --json -> table/text output, fall back

  local shape fields
  case "$topic" in
    issue) shape="$ISSUE_SHAPE"; fields="$ISSUE_FIELDS comments";;
    pr)    shape="$PR_SHAPE";    fields="$PR_FIELDS comments";;
    *) return 1;;
  esac
  local need_comments=0 need_reviews=0 f
  for f in ${jsonf//,/ }; do
    in_set "$f" $fields || return 1            # an unmapped field -> fall back
    [ "$f" = "comments" ] && need_comments=1
    [ "$f" = "reviewDecision" ] && need_reviews=1
  done

  ensure_view_resource "$topic" "$num" || return 1
  local rf="$ROOT/views/$topic-$num.json"
  [ -f "$rf" ] || return 1
  local obj; obj="$(jq -c "$shape" "$rf" 2>/dev/null)" || return 1

  if [ "$need_reviews" = 1 ]; then
    local dec; dec="$(ensure_reviews "$num")"
    obj="$(printf '%s' "$obj" | jq -c --arg d "$dec" '. + {reviewDecision: $d}' 2>/dev/null)" || return 1
  fi
  if [ "$need_comments" = 1 ]; then
    ensure_view_comments "$num" || return 1
    local cf="$ROOT/views/$num-comments.json"
    [ -f "$cf" ] || return 1
    local carr; carr="$(jq -c "[ .[] | $COMMENT_SHAPE ]" "$cf" 2>/dev/null)" || return 1
    obj="$(printf '%s' "$obj" | jq -c --argjson c "$carr" '. + {comments: $c}' 2>/dev/null)" || return 1
  fi

  local proj; proj="$(printf '{'; local first=1 ff; for ff in $(printf '%s\n' ${jsonf//,/ } | sort); do [ $first = 1 ] || printf ','; printf '%s: .%s' "$ff" "$ff"; first=0; done; printf '}')"
  local out; out="$(printf '%s' "$obj" | jq -c "$proj" 2>/dev/null)" || return 1
  if [ -n "$jqf" ]; then printf '%s' "$out" | jq -r "$jqf" 2>/dev/null || return 1
  else printf '%s' "$out" | jq -c '.' 2>/dev/null || return 1; fi
}

# `pr diff --name-only` — REST /pulls/$n/files, following ALL pages (#58 GV
# item 5: a truncated file list makes a role wrongly conclude a file was
# untouched, so 30/page is followed to the end, not just page 1).
reshape_pr_files_fetch() { # $1=pr number -> stdout: one filename per line
  local n="$1" acc="[]" page=1 body cnt
  while :; do
    body="$(real_gh api "/repos/$SLUG/pulls/$n/files?per_page=30&page=$page" 2>/dev/null)" || return 1
    cnt="$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo -1)"
    [ "$cnt" -ge 0 ] || return 1
    acc="$(printf '%s\n%s' "$acc" "$body" | jq -cs 'add' 2>/dev/null)" || return 1
    [ "$cnt" -lt 30 ] && break
    page=$((page+1))
    [ "$page" -gt 100 ] && break   # hard cap (3000 files, GitHub's own PR file limit)
  done
  printf '%s' "$acc" | jq -r '.[].filename' 2>/dev/null
}

reshape_pr_diff() { # rest=args (after 'pr diff') -> stdout or return 1 to fall back
  local n="" nameonly=0 a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --name-only) nameonly=1; shift;;
      -*) return 1;;                # any other diff flag (--patch, --color, …) -> fall back
      *) [ -z "$n" ] && n="$a" || return 1; shift;;
    esac
  done
  [ "$nameonly" = 1 ] || return 1    # only --name-only is modeled; the real diff stays on real gh
  [ -n "$n" ] || return 1
  case "$n" in *[!0-9]*) return 1;; esac

  local out="$ROOT/views/pr-$n-files.out" tsf="$ROOT/views/pr-$n-files.ts"
  if fresh "$tsf" "$TTL" && [ -f "$out" ]; then cat "$out"; return 0; fi
  if lock "diff-files-$n"; then
    if ! fresh "$tsf" "$TTL"; then
      if reshape_pr_files_fetch "$n" > "$out.tmp" 2>/dev/null; then mv "$out.tmp" "$out"; touch "$tsf"
      else rm -f "$out.tmp"; unlock "diff-files-$n"; [ -f "$out" ] && { cat "$out"; return 0; }; return 1; fi
    fi
    unlock "diff-files-$n"; cat "$out"; return 0
  fi
  [ -f "$out" ] && { cat "$out"; return 0; }
  return 1
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
    reshape_view "$topic" "$@" && exit 0
    tier1 "$topic" view "$@"; exit $?
    ;;
  "pr diff")
    shift 2
    reshape_pr_diff "$@" && exit 0
    tier1 pr diff "$@"; exit $?
    ;;
  *) real_gh "$@"; exit $?;;
esac
