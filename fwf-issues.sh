#!/usr/bin/env bash
# fwf issues — the LOCAL issue tracker (issue #26): a gh-issue-shaped CLI over
# a plain-markdown store OUTSIDE any repo, so the factory can run against
# repos whose GitHub issues/labels you don't control (--issues local).
#
# Store: $FWF_RUN/issues/<profile>/{open,closed}/<N>-<slug>.md
#   - ONE self-contained markdown file per issue — open it and read the whole
#     discussion; grep it; paste it into a PR description
#   - status IS the directory (open/ closed/); everything finer is labels
#   - file shape: "# LI-N: title" · "labels:"/"created:" header lines · body ·
#     appended "## comment <timestamp>" sections
#   - mutations serialize through one store lock, so comment APPENDS are
#     ordered — the factory's atomic CLAIM mutex works (first CLAIM in the
#     file wins). Hand-editing the files is fine; parsing is lenient.
#
# Subcommands (deliberately gh-shaped — rendered prompts substitute
# `gh issue` -> `fwf --profile P issues` and keep working verbatim):
#   create --title T [--body B] [--label L]...
#   list   [--state open|closed|all] [--label L] [--search "is:open -label:x words"]
#          [--json fields [--jq EXPR]]
#   view N [--comments] [--json fields [--jq EXPR]]
#   edit N [--title T] [--body B] [--add-label L] [--remove-label L]
#   comment N --body B
#   close N [--comment C]   |   reopen N
#   export [N...]           # dump issues incl. comments as markdown (default: all)
#   help
#
# JSON fields: number,title,state,createdAt,body,labels,comments
# (labels as [{"name":…}], comments as [{"body":…,"createdAt":…}] — the shapes
# the factory prompts' --jq expressions expect). --jq needs the jq binary.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

STORE="$FWF_ISSUES_DIR"
die() { echo "fwf issues: $*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One store-wide lock serializes mutations (creation, appends, edits, moves).
# Contention is a handful of agents commenting occasionally — simplicity wins.
with_lock() {
  local lock="$STORE/.lock" tries=0
  mkdir -p "$STORE"
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries+1)); [ "$tries" -gt 200 ] && die "store lock stuck at $lock — remove it if no other fwf issues process is running"
    sleep 0.05
  done
  local rc=0
  "$@" || rc=$?   # || so a failing op can't (via set -e) skip the unlock below
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# Locate an issue file by number, echoing its path. State is the directory.
issue_file() { # $1=num
  local f
  for f in "$STORE/open/$1-"*.md "$STORE/closed/$1-"*.md; do
    [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
require_issue() {
  case "${1:-}" in ''|*[!0-9]*) die "need an issue number (got '${1:-}')";; esac
  issue_file "$1" >/dev/null || die "no local issue $1 (store: $STORE)"
}
state_of()  { case "$(issue_file "$1")" in */open/*) echo open;; *) echo closed;; esac; }
title_of()  { head -1 "$(issue_file "$1")" | sed "s/^# LI-$1: //"; }
created_of(){ sed -n 's/^created: //p' "$(issue_file "$1")" | head -1; }
# issue #211: a genuinely label-less issue and a FAILED read of the issue
# file both used to produce identical empty output here, so a caller could
# not tell "this issue has no labels" from "I could not read this issue" --
# the read-modify-write callers below (_rewrite_header_locked's __KEEP__
# path) would then silently REWRITE the file with every label dropped,
# including product-wip, on nothing more than a transient read glitch. Now
# echoes labels unchanged (an existing bare `labels_of N` caller sees no
# difference), but returns non-zero when the file itself could not be
# located/read -- distinct from a real empty label list, which returns 0.
labels_of() {
  local f raw out
  if ! f="$(issue_file "$1")"; then
    fwf_log_unknown_read labels_of "issue=$1 file not found" || true
    return 1
  fi
  if ! raw="$(sed -n 's/^labels: //p' "$f" 2>/dev/null | head -1)"; then
    fwf_log_unknown_read labels_of "issue=$1 file unreadable" || true
    return 1
  fi
  [ -n "$raw" ] || return 0
  out="$(printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')" || true
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
has_label() { labels_of "$1" | grep -qx -- "$2"; }
slugify()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-40; }
# Body = everything after the header block, before the first comment marker.
body_of() {
  awk 'NR==1 {next}
       /^labels: /  && !past_header {next}
       /^created: / && !past_header {next}
       /^$/ && !past_header {past_header=1; next}
       /^## comment / {exit}
       {past_header=1; print}' "$(issue_file "$1")"
}
# Comments as \001-separated records: "<ts>\n<body lines…>" each. Octal \001
# (not \x01) — hex escapes aren't POSIX awk and BSD awk ignores them.
comments_tsv() {
  awk '/^## comment /{ inc=1; ts=$3; printf "\001%s\n", ts; next }
       inc { print }' "$(issue_file "$1")"
}

next_num() {
  local n
  n="$(cat "$STORE/seq" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s\n' "$n" > "$STORE/seq"
  printf '%s\n' "$n"
}

# --- JSON emission (no jq needed to PRODUCE; --jq needs the jq binary) -------
json_escape() { # stdin -> JSON string contents (no surrounding quotes)
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); if (NR>1) printf "\\n"; print}'
}
json_issue() { # $1=num $2=csv-fields -> one JSON object
  local n="$1" fields="$2" out="" f first=1 sep l larr carr
  for f in $(printf '%s' "$fields" | tr ',' ' '); do
    [ "$first" = 1 ] && sep="" || sep=","
    first=0
    case "$f" in
      number)    out="$out$sep\"number\":$n";;
      title)     out="$out$sep\"title\":\"$(title_of "$n" | json_escape)\"";;
      state)     out="$out$sep\"state\":\"$(state_of "$n" | tr '[:lower:]' '[:upper:]')\"";;
      createdAt) out="$out$sep\"createdAt\":\"$(created_of "$n" | json_escape)\"";;
      body)      out="$out$sep\"body\":\"$(body_of "$n" | json_escape)\"";;
      labels)
        larr=""
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          [ -n "$larr" ] && larr="$larr,"
          larr="$larr{\"name\":\"$(printf '%s' "$l" | json_escape)\"}"
        done <<EOF
$(labels_of "$n")
EOF
        out="$out$sep\"labels\":[$larr]";;
      comments)
        carr="$(comments_tsv "$n" | awk 'BEGIN{RS="\001"} NR>1 {
          nl = index($0, "\n"); ts = substr($0, 1, nl-1); body = substr($0, nl+1)
          sub(/^\n+/, "", body); sub(/\n+$/, "", body)
          gsub(/\\/,"\\\\",body); gsub(/"/,"\\\"",body); gsub(/\t/,"\\t",body); gsub(/\r/,"\\r",body); gsub(/\n/,"\\n",body)
          if (out != "") out = out ","
          out = out "{\"createdAt\":\"" ts "\",\"body\":\"" body "\"}"
        } END { printf "%s", out }')"
        out="$out$sep\"comments\":[$carr]";;
      *) die "unsupported --json field '$f' (have: number,title,state,createdAt,body,labels,comments)";;
    esac
  done
  printf '{%s}' "$out"
}
maybe_jq() { # $1=jq-expr-or-empty; stdin=json
  if [ -n "$1" ]; then
    command -v jq >/dev/null 2>&1 || die "--jq needs the jq binary (brew/apt install jq)"
    jq -r "$1"
  else
    cat
  fi
}

# --- subcommands ---------------------------------------------------------------
_create_locked() { # title body labels(comma-joined)
  local n
  n="$(next_num)"
  mkdir -p "$STORE/open"
  {
    printf '# LI-%s: %s\n' "$n" "$1"
    [ -n "$3" ] && printf 'labels: %s\n' "$3"
    printf 'created: %s\n\n' "$(now)"
    printf '%s\n' "$2"
  } > "$STORE/open/$n-$(slugify "$1").md"
  echo "LI-$n created: $STORE/open/$n-$(slugify "$1").md"
}
cmd_create() {
  local title="" body="" labels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2;;
      --body)  body="$2"; shift 2;;
      --label) labels="${labels:+$labels, }$2"; shift 2;;
      *) die "create: unknown flag '$1'";;
    esac
  done
  [ -n "$title" ] || die "create: --title is required"
  with_lock _create_locked "$title" "$body" "$labels"
}

_comment_locked() { # num body
  printf '\n## comment %s\n\n%s\n' "$(now)" "$2" >> "$(issue_file "$1")"
  echo "LI-$1 commented"
}
cmd_comment() {
  local n="$1"; shift; require_issue "$n"
  local body=""
  while [ $# -gt 0 ]; do case "$1" in --body) body="$2"; shift 2;; *) die "comment: unknown flag '$1'";; esac; done
  [ -n "$body" ] || die "comment: --body is required"
  with_lock _comment_locked "$n" "$body"
}

# Header rewrites preserve everything below the header block.
# issue #211: both rewrite functions rebuild the ENTIRE issue file from a
# handful of reads (title/labels/created/body) -- a failed read that
# silently fell back to empty (the old shape) would REWRITE the file with
# that field dropped. `labels` is the highest-consequence instance named by
# the ticket: a collapsed labels_of drops product-wip on rewrite, which is a
# collapsed read un-gating a ticket. So every read that feeds a rewrite here
# is EXPLICITLY status-checked (`if ! x="$(...)"`, never a bare assignment --
# a bare `x="$(cmd)"` does NOT reliably trigger `set -e` on `cmd`'s failure
# in bash, a separate, well-known gotcha from the `local x="$(cmd)"` masking
# trap) and a failure REFUSES the rewrite entirely rather than writing a
# partially-fabricated file.
_rewrite_header_locked() { # num newtitle-or-empty newlabels-or-KEEP
  local n="$1" f title labels created tmp
  if ! f="$(issue_file "$n")"; then
    echo "fwf issues: refusing to rewrite issue $n's header -- could not locate its file" >&2
    return 1
  fi
  if ! title="${2:-$(title_of "$n")}"; then
    echo "fwf issues: refusing to rewrite issue $n's header -- could not read its current title" >&2
    return 1
  fi
  if [ "$3" = "__KEEP__" ]; then
    if ! labels="$(labels_of "$n" | paste -sd, - 2>/dev/null | sed 's/,/, /g')"; then
      echo "fwf issues: refusing to rewrite issue $n's header -- could not read its current labels, refusing to silently drop them" >&2
      return 1
    fi
  else
    labels="$3"
  fi
  if ! created="$(created_of "$n")"; then
    echo "fwf issues: refusing to rewrite issue $n's header -- could not read its created timestamp" >&2
    return 1
  fi
  tmp="$f.tmp.$$"
  {
    printf '# LI-%s: %s\n' "$n" "$title"
    [ -n "$labels" ] && printf 'labels: %s\n' "$labels"
    printf 'created: %s\n\n' "$created"
    body_of "$n"
    awk '/^## comment /{found=1} found{print}' "$f" | sed '1s/^/\n/'
  } > "$tmp"
  mv "$tmp" "$f"
}
_set_body_locked() { # num body
  local n="$1" f title labels created tmp
  if ! f="$(issue_file "$n")"; then
    echo "fwf issues: refusing to rewrite issue $n's body -- could not locate its file" >&2
    return 1
  fi
  if ! title="$(title_of "$n")"; then
    echo "fwf issues: refusing to rewrite issue $n's body -- could not read its current title" >&2
    return 1
  fi
  if ! labels="$(labels_of "$n" | paste -sd, - 2>/dev/null | sed 's/,/, /g')"; then
    echo "fwf issues: refusing to rewrite issue $n's body -- could not read its current labels, refusing to silently drop them" >&2
    return 1
  fi
  if ! created="$(created_of "$n")"; then
    echo "fwf issues: refusing to rewrite issue $n's body -- could not read its created timestamp" >&2
    return 1
  fi
  tmp="$f.tmp.$$"
  {
    printf '# LI-%s: %s\n' "$n" "$title"
    [ -n "$labels" ] && printf 'labels: %s\n' "$labels"
    printf 'created: %s\n\n' "$created"
    printf '%s\n' "$2"
    awk '/^## comment /{found=1} found{print}' "$f" | sed '1s/^/\n/'
  } > "$tmp"
  mv "$tmp" "$f"
}
cmd_edit() {
  local n="$1"; shift; require_issue "$n"
  local labels
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) with_lock _rewrite_header_locked "$n" "$2" "__KEEP__"; shift 2;;
      --body)  with_lock _set_body_locked "$n" "$2"; shift 2;;
      --add-label)
        if ! has_label "$n" "$2"; then
          labels="$(labels_of "$n" | paste -sd, - 2>/dev/null | sed 's/,/, /g')"
          with_lock _rewrite_header_locked "$n" "" "${labels:+$labels, }$2"
        fi
        shift 2;;
      --remove-label)
        # `|| true`: removing the LAST label leaves grep with no matches (exit
        # 1), which pipefail would otherwise turn into a silent set -e death.
        labels="$(labels_of "$n" | grep -vx -- "$2" | paste -sd, - 2>/dev/null | sed 's/,/, /g' || true)"
        with_lock _rewrite_header_locked "$n" "" "$labels"
        shift 2;;
      *) die "edit: unknown flag '$1'";;
    esac
  done
  echo "LI-$n edited"
}

_move_locked() { # num dest-state
  local f; f="$(issue_file "$1")"
  mkdir -p "$STORE/$2"
  mv "$f" "$STORE/$2/$(basename "$f")"
}
cmd_close() {
  local n="$1"; shift; require_issue "$n"
  [ "${1:-}" = "--comment" ] && { with_lock _comment_locked "$n" "$2" >/dev/null; shift 2; }
  [ "$(state_of "$n")" = "closed" ] || with_lock _move_locked "$n" closed
  echo "LI-$n closed"
}
cmd_reopen() {
  require_issue "$1"
  [ "$(state_of "$1")" = "open" ] || with_lock _move_locked "$1" open
  echo "LI-$1 reopened"
}

# Filters: state, positive/negative labels, free words (substring across the
# whole file). Populated by both --flags and gh-style --search tokens.
F_STATE="open"; F_LABELS=""; F_NOTLABELS=""; F_WORDS=""
parse_search() { # is:open is:closed label:x -label:y words…
  local tok
  for tok in $1; do
    case "$tok" in
      is:open)   F_STATE=open;;
      is:closed) F_STATE=closed;;
      is:*)      ;;
      label:*)   F_LABELS="$F_LABELS ${tok#label:}";;
      -label:*)  F_NOTLABELS="$F_NOTLABELS ${tok#-label:}";;
      *)         F_WORDS="$F_WORDS $tok";;
    esac
  done
}
matches() { # $1=num
  local n="$1" l w
  case "$F_STATE" in
    all) ;;
    *) [ "$(state_of "$n")" = "$F_STATE" ] || return 1;;
  esac
  for l in $F_LABELS;    do has_label "$n" "$l" || return 1; done
  for l in $F_NOTLABELS; do has_label "$n" "$l" && return 1; done
  for w in $F_WORDS;     do grep -qi -- "$w" "$(issue_file "$n")" || return 1; done
  return 0
}
all_nums() { # every issue number in the store, ascending
  local f
  # trailing `true`: an unmatched glob leaves the loop's last [ -e ] false,
  # and under pipefail that status would leak through sort and kill callers.
  { for f in "$STORE"/open/[0-9]*-*.md "$STORE"/closed/[0-9]*-*.md; do
      [ -e "$f" ] && basename "$f" | sed 's/-.*//'
    done; true; } | sort -n
}

cmd_list() {
  local jsonf="" jqexpr="" n first=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)  F_STATE="$2"; shift 2;;
      --label)  F_LABELS="$F_LABELS $2"; shift 2;;
      --search) parse_search "$2"; shift 2;;
      --json)   jsonf="$2"; shift 2;;
      --jq)     jqexpr="$2"; shift 2;;
      --limit)  shift 2;;   # accepted for gh compatibility; the store is small
      *) die "list: unknown flag '$1'";;
    esac
  done
  {
    [ -n "$jsonf" ] && printf '['
    for n in $(all_nums); do
      matches "$n" || continue
      if [ -n "$jsonf" ]; then
        [ "$first" = 1 ] || printf ','
        first=0
        json_issue "$n" "$jsonf"
      else
        printf 'LI-%s\t%s\t[%s]\t%s\n' "$n" "$(title_of "$n")" "$(labels_of "$n" | paste -sd, - 2>/dev/null)" "$(state_of "$n")"
      fi
    done
    [ -n "$jsonf" ] && printf ']\n'
  } | maybe_jq "$jqexpr"
}

cmd_view() {
  local n="$1"; shift; require_issue "$n"
  local with_comments=0 jsonf="" jqexpr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --comments) with_comments=1; shift;;
      --json)     jsonf="$2"; shift 2;;
      --jq)       jqexpr="$2"; shift 2;;
      *) die "view: unknown flag '$1'";;
    esac
  done
  if [ -n "$jsonf" ]; then
    json_issue "$n" "$jsonf" | maybe_jq "$jqexpr"; echo
    return 0
  fi
  if [ "$with_comments" = 1 ]; then
    cat "$(issue_file "$n")"
  else
    # header + body only
    printf '# LI-%s: %s\nlabels: %s\ncreated: %s · state: %s\n\n' \
      "$n" "$(title_of "$n")" "$(labels_of "$n" | paste -sd, - 2>/dev/null)" "$(created_of "$n")" "$(state_of "$n")"
    body_of "$n"
  fi
}

cmd_export() {
  local nums="$*" n
  [ -n "$nums" ] || nums="$(all_nums)"
  [ -n "$nums" ] || { echo "(no local issues in $STORE)"; return 0; }
  for n in $nums; do
    require_issue "$n"
    printf '<!-- state: %s -->\n' "$(state_of "$n")"
    cat "$(issue_file "$n")"
    printf '\n---\n\n'
  done
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  create)  cmd_create "$@";;
  list)    cmd_list "$@";;
  view)    cmd_view "$@";;
  edit)    cmd_edit "$@";;
  comment) cmd_comment "$@";;
  close)   cmd_close "$@";;
  reopen)  cmd_reopen "$@";;
  export)  cmd_export "$@";;
  help|-h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//';;
  *) die "unknown subcommand '$cmd' (try 'fwf issues help')";;
esac
