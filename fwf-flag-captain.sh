#!/usr/bin/env bash
# fwf-flag-captain.sh — issue #113: a persisted, tracker-native "needs-captain"
# flag any role (impl/qa/pm/gv) can raise on an issue or PR, that the
# captain's per-tick sweep (captain.tmpl) picks up reliably every tick instead
# of depending on the captain happening to read the right pane/comment (the
# 2026-07-14 impl1 incident this closes).
#
# WHY A SEPARATE SCRIPT (not a captain.tmpl `gh issue`/`fwf issues` line):
# fwf_render's local-issues rewrite only retargets the literal substring
# `gh issue ` (lib.sh) — a template line that instead calls `fwf flag-captain`
# passes through UNCHANGED in both backends, so ONE command in the templates
# works identically in gh-issues and local-issues mode (AC5) with this script
# doing the FWF_ISSUES branching, not the template.
#
# Carrier: the "needs-captain" label (FWF_NEEDS_CAPTAIN_LABEL) + a comment:
#   NEEDS-CAPTAIN: [<role>] <reason>       raise (first line, column 0)
#   NEEDS-CAPTAIN-CLEARED: <note-or-empty> clear (first line, column 0)
# Multiple raises APPEND (never overwrite, per the edge case in #113) — a
# clear only affects flags raised BEFORE it; a raise after a clear is active
# again. The sweep's jq filter (SWEEP_FILTER below) implements this once.
#
# Usage:
#   fwf flag-captain <n> --role <role> --reason "<text>"   raise (or re-raise)
#   fwf flag-captain <n> --clear [--note "<text>"]         clear
#   fwf flag-captain sweep                                  list every open flag
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

die() { echo "fwf flag-captain: $*" >&2; exit 1; }

NEEDS_CAPTAIN_LABEL="${NEEDS_CAPTAIN_LABEL:-needs-captain}"

# --- gh backend --------------------------------------------------------------
# cd into the repo so gh's {owner}/{repo} api placeholders resolve correctly;
# a plain function (not a subshell alias) so tests can override it wholesale.
gh_() { if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh "$@" ); else gh "$@"; fi; }

# GitHub shares ONE number sequence across issues and PRs, and `gh issue`/
# `gh pr` each fail on the other kind's number — detect which one N is via the
# unified /issues API (PRs come back with a non-null .pull_request there).
gh_kind() { # $1=num -> "issue"|"pr"
  local pr
  pr="$(gh_ api "repos/{owner}/{repo}/issues/$1" --jq '.pull_request // empty' 2>/dev/null || true)"
  [ -n "$pr" ] && echo pr || echo issue
}
gh_ensure_label() {
  # --force makes this create-or-update, never erroring on an existing label
  # (confirmed via `gh label create --help`) — safe to call on every raise so
  # a raise against a repo that never ran `fwf provision` (or predates this
  # feature) can never no-op on a missing label (AC7).
  gh_ label create "$NEEDS_CAPTAIN_LABEL" \
    --description "Something needs the captain's attention — see the NEEDS-CAPTAIN: comment" \
    --color D93F0B --force >/dev/null 2>&1 || true
}
gh_raise() { # $1=num $2=role $3=reason
  local kind; kind="$(gh_kind "$1")"
  gh_ensure_label
  gh_ "$kind" edit "$1" --add-label "$NEEDS_CAPTAIN_LABEL"
  gh_ "$kind" comment "$1" --body "NEEDS-CAPTAIN: [$2] $3"
}
gh_clear() { # $1=num $2=note (may be empty)
  local kind; kind="$(gh_kind "$1")"
  gh_ "$kind" edit "$1" --remove-label "$NEEDS_CAPTAIN_LABEL" 2>/dev/null || true
  [ -n "$2" ] && gh_ "$kind" comment "$1" --body "NEEDS-CAPTAIN-CLEARED: $2"
}
# -> a single JSON array of {number,createdAt,comments:[{body,createdAt}]},
# open issues AND open PRs unioned (both carry the same label independently).
# #291: two defects fixed here, both required.
# (a) FAIL-CLOSED: a genuine `gh` read failure used to fall back to '[]' --
# indistinguishable from "no flags open" to the caller, so the sweep silently
# under-reported. Every read below is checked explicitly and this function
# returns 1 (prints nothing on stdout) on any failure, so a caller that
# actually checks $? gets UNKNOWN, never a confident empty list.
# (b) ARG_MAX: a flagged item's `comments` carries every comment BODY on the
# thread verbatim, so one item with a long thread (an un-gate rationale, a
# triage write-up) can push the combined payload past ARG_MAX when passed as
# --argjson on the command line -- jq then exits 126 and (before fix (a))
# that got swallowed as "no flags". Route the payload through files
# (--slurpfile) instead of argv, and (c) drop every comment that isn't an
# actual NEEDS-CAPTAIN(-CLEARED) marker before it ever reaches jq's argv --
# the sweep only ever needs the marker lines, not the rest of the thread.
gh_flagged_items() {
  local issues prs ddir
  issues="$(gh_ issue list --state open --label "$NEEDS_CAPTAIN_LABEL" --json number,createdAt,comments)" \
    || { echo "fwf flag-captain: gh issue list failed (read is UNKNOWN, not empty)" >&2; return 1; }
  prs="$(gh_ pr list --state open --label "$NEEDS_CAPTAIN_LABEL" --json number,createdAt,comments)" \
    || { echo "fwf flag-captain: gh pr list failed (read is UNKNOWN, not empty)" >&2; return 1; }
  ddir="$(mktemp -d)" || { echo "fwf flag-captain: mktemp failed" >&2; return 1; }
  trap 'rm -rf "$ddir"' RETURN
  printf '%s' "$issues" > "$ddir/issues.json"
  printf '%s' "$prs"    > "$ddir/prs.json"
  jq -c -n --slurpfile a "$ddir/issues.json" --slurpfile b "$ddir/prs.json" '
    def only_markers: .comments = [(.comments // [])[] | select((.body // "") | test("^NEEDS-CAPTAIN(-CLEARED)?:"))];
    ($a[0] + $b[0]) | map(only_markers)
  ' || { echo "fwf flag-captain: jq combine failed" >&2; return 1; }
}
gh_id() { printf '#%s' "$1"; }

# --- local backend (fwf-issues.sh) -------------------------------------------
# Local mode has no PR concept (templates/_local-issues/qa.tmpl uses
# READY-FOR-REVIEW/CHANGES-REQUESTED comments in its place) — "flag N" is
# always a local issue there.
local_raise() { # $1=num $2=role $3=reason
  "$DIR/fwf-issues.sh" edit "$1" --add-label "$NEEDS_CAPTAIN_LABEL" >/dev/null
  "$DIR/fwf-issues.sh" comment "$1" --body "NEEDS-CAPTAIN: [$2] $3" >/dev/null
}
local_clear() { # $1=num $2=note (may be empty)
  "$DIR/fwf-issues.sh" edit "$1" --remove-label "$NEEDS_CAPTAIN_LABEL" >/dev/null 2>&1 || true
  [ -n "$2" ] && "$DIR/fwf-issues.sh" comment "$1" --body "NEEDS-CAPTAIN-CLEARED: $2" >/dev/null
}
local_flagged_items() {
  "$DIR/fwf-issues.sh" list --state open --label "$NEEDS_CAPTAIN_LABEL" --json number,createdAt,comments
}
local_id() { printf 'LI-%s' "$1"; }

# --- shared sweep logic (one jq filter, driven by a backend-neutral array) ---
# Rules encoded here (see file header + issue #113 edge cases):
#  - a NEEDS-CAPTAIN-CLEARED: comment resets what counts as "active" for that
#    item — only NEEDS-CAPTAIN: comments AFTER the latest clear are active;
#  - multiple active raises on one item each surface as their OWN row (append,
#    never overwrite);
#  - a labeled item with zero active NEEDS-CAPTAIN: comments still surfaces
#    (never silently dropped) as "role unstated" / "no reason given";
#  - a NEEDS-CAPTAIN: line with no "[role]" tag surfaces as "role unstated"
#    (never inferred from the comment author — every role shares one account).
# Column-0-only match (^, not a mid-line/quoted occurrence) is the same
# self-trigger guard fwf-pr-review-state.sh uses for its QA-*/IMPL-* markers.
read -r -d '' SWEEP_FILTER <<'JQ' || true
def human_age($secs):
  if $secs < 60 then "\($secs|floor)s"
  elif $secs < 3600 then "\(($secs/60)|floor)m"
  elif $secs < 86400 then "\(($secs/3600)|floor)h\((($secs%3600)/60)|floor)m"
  else "\(($secs/86400)|floor)d\((($secs%86400)/3600)|floor)h"
  end;
def sweep_rows($now):
  . as $it
  # Index-based (not timestamp-string-based) ordering: the local backend's
  # createdAt has only 1s resolution, so a clear and the very next raise can
  # land in the SAME second — comparing createdAt strings would then mis-order
  # them. $c is already in true append order (fwf-issues.sh serializes comment
  # appends through one store lock), so array position is a reliable clock.
  | ($it.comments // [] | to_entries) as $ce
  | ([$ce[] | select((.value.body // "") | test("^NEEDS-CAPTAIN-CLEARED:"))] | last | .key) as $clearedIdx
  | ([$ce[] | select((.value.body // "") | test("^NEEDS-CAPTAIN:")) | select($clearedIdx == null or .key > $clearedIdx) | .value]) as $active
  | if ($active | length) == 0 then
      { number: $it.number, role: "role unstated", reason: "no reason given", at: $it.createdAt }
    else
      $active[] | (.body | capture("^NEEDS-CAPTAIN: *(\\[(?<role>[^\\]]*)\\])? *(?<reason>.*)$")) as $m
      | { number: $it.number,
          role: (if ($m.role // "") == "" then "role unstated" else $m.role end),
          reason: (if ($m.reason // "") == "" then "no reason given" else $m.reason end),
          at: .createdAt }
    end
  | . + { age: human_age($now - (.at | fromdateiso8601)) };
[.[] | sweep_rows($now)] | sort_by(.number, .at)
JQ

cmd_sweep() {
  local items now rows n id_fn
  # #291 AC(a)/(d), operator follow-up: the failure must also be visible on
  # STDOUT, not stderr alone. Returning 1 with an EMPTY stdout is still
  # "an empty sweep" to anyone reading the output -- the exact shape this
  # ticket exists to kill -- and it made the AC(a)/(d) assertion vacuous
  # (#275 (a5) correctly refuses to pass on an empty haystack). Print the
  # UNKNOWN marker on both streams; still return 1.
  _sweep_unknown() { # $1=detail
    echo "UNKNOWN: sweep could not be completed -- $1 (this is NOT an empty sweep)"
    echo "fwf flag-captain: $1 (UNKNOWN, not empty)" >&2
    return 1
  }
  now="$(date -u +%s)"
  # #291 AC(a): a read/parse failure anywhere in this chain must exit
  # non-zero and say so on stderr -- NEVER fall through to "no needs-captain
  # flags open", which is indistinguishable from a genuinely empty sweep.
  if [ "$FWF_ISSUES" = "local" ]; then
    items="$(local_flagged_items)" \
      || { _sweep_unknown "could not enumerate local flags"; return 1; }
    id_fn=local_id
  else
    items="$(gh_flagged_items)" \
      || { _sweep_unknown "could not enumerate flags"; return 1; }
    id_fn=gh_id
  fi
  rows="$(jq -c --argjson now "$now" "$SWEEP_FILTER" <<<"$items")" \
    || { _sweep_unknown "sweep filter failed"; return 1; }
  n="$(jq 'length' <<<"$rows")" \
    || { _sweep_unknown "sweep count failed"; return 1; }
  if [ "$n" = 0 ]; then echo "no needs-captain flags open"; return 0; fi
  jq -r '.[] | "\(.number)\t[\(.role)]\t\(.reason)\t\(.age)"' <<<"$rows" | \
  while IFS=$'\t' read -r num role reason age; do
    printf '%s\t%s\t%s\t%s\n' "$("$id_fn" "$num")" "$role" "$reason" "$age"
  done
}

cmd_raise() { # $1=num, rest = --role R --reason TEXT
  local n="$1"; shift
  local role="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)   role="$2"; shift 2;;
      --reason) reason="$2"; shift 2;;
      *) die "unknown flag '$1' (usage: fwf flag-captain <n> --role R --reason TEXT)";;
    esac
  done
  [ -n "$role" ]   || die "--role is required"
  [ -n "$reason" ] || die "--reason is required"
  if [ "$FWF_ISSUES" = "local" ]; then local_raise "$n" "$role" "$reason"; echo "$(local_id "$n") flagged: NEEDS-CAPTAIN [$role] $reason"
  else gh_raise "$n" "$role" "$reason"; echo "$(gh_id "$n") flagged: NEEDS-CAPTAIN [$role] $reason"
  fi
}

cmd_clear() { # $1=num, rest = [--note TEXT]
  local n="$1"; shift
  local note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) note="$2"; shift 2;;
      *) die "unknown flag '$1' (usage: fwf flag-captain <n> --clear [--note TEXT])";;
    esac
  done
  if [ "$FWF_ISSUES" = "local" ]; then local_clear "$n" "$note"; echo "$(local_id "$n") needs-captain cleared"
  else gh_clear "$n" "$note"; echo "$(gh_id "$n") needs-captain cleared"
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    sweep) shift; cmd_sweep "$@";;
    ''|*[!0-9]*) die "usage: fwf flag-captain <n> --role R --reason TEXT | fwf flag-captain <n> --clear [--note TEXT] | fwf flag-captain sweep";;
    *)
      local n="$1"; shift
      if [ "${1:-}" = "--clear" ]; then shift; cmd_clear "$n" "$@"
      else cmd_raise "$n" "$@"
      fi
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
