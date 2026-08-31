#!/usr/bin/env bash
# fwf-claim.sh — issue #243: a fail-FAST authorization checkpoint at
# INTENT-FORMATION time, split out of #207 (which keeps the enforcement
# checkpoint — merge/promote/release, refused repository-side). This is the
# ergonomic half: today an implementer discovers a HELD issue is not
# authorized only at merge, after the work is already done — the most
# expensive possible moment to learn it, and exactly the pressure that
# produced the forged CAPTAIN-NOTICE incident this ticket exists to relieve.
#
# THIS IS NOT A SECURITY CONTROL. An agent can simply not run `fwf claim`.
# Its value is making the authorized path the EASY path and surfacing a
# hold before the effort is spent — #207's repository-side refusal is what
# makes the hold BINDING. Stated here AND on the success path (AC h): the
# terminal is where a reader draws the "was this authorized?" conclusion,
# not the docs.
#
# Usage: fwf claim <issue-number> [role]
#   On success: prints the prerequisite scan (if any), the ergonomic-not-
#   control statement, and creates the claim artifact -- an empty commit
#   `claim #<n>: <title>` (the definition pinned by this ticket, AC i0/i2:
#   NO branch management here, matching #177's own live worktree-branch
#   contention concern -- the caller is assumed to already be on the
#   right branch).
#
#   issue #462: when [role] is given, this ALSO performs the atomic
#   claim-race adjudication that used to live as PROSE in the implementer
#   template ("post a CLAIM comment, then re-check you won"). Two seats
#   racing inside the loop-latency window used to both comply with that
#   prose perfectly and both proceed -- a test cannot exercise prose, and
#   nothing enforced it. With [role], this script itself posts "CLAIM
#   <role>", busts the ghcache read of the issue thread (a compare-and-set
#   against a stale cached snapshot is not a compare-and-set, #462 AC 4),
#   and refuses -- posting a STAND-DOWN comment so the loser is TOLD, not
#   silent (#462 AC 2) -- unless its own claim is the FIRST LIVE one on
#   the thread (liveness via the SAME fwf_claim_liveness_blocks signal
#   fwf-claim-liveness.sh already uses, so an old abandoned claim never
#   blocks a fresh one). [role] omitted preserves the pre-#462 behavior
#   exactly (the caller is assumed to have already posted its own CLAIM
#   comment and re-checked it won) -- this script is an ergonomic
#   checkpoint, not a control, and remains skippable either way.
#
# Exit codes: 0 = claimed (AUTHORIZED or NOT-GATED, INDETERMINATE warns but
#   still proceeds). 1 = REFUSED (HELD, INVALID, a lost claim race, or a
#   usage error).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# Same dual-backend shape as fwf-dash-data.sh's di_read: FWF_ISSUES=local
# routes to the local store (fwf-issues.sh), else real gh -- a claim run
# against the local test/dev issue store must never shell out to gh.
_issue_read() { # $1=issue-number ; rest = --json <field> --jq <expr>
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$@"
  else
    gh issue view "$@"
  fi
}

usage() { echo "usage: fwf claim <issue-number> [role]   # fail-fast authorization + claim-race checkpoint (issues #243, #462) -- NOT a security control, see 'fwf claim --help'" >&2; }

# issue #243 AC (h): the ergonomic-not-control statement, verbatim, on
# BOTH --help and the success path -- the terminal is where a reader
# concludes an authorization check was passed, not the docs.
ERGONOMIC_NOTICE="fwf claim is an ERGONOMIC checkpoint, not a security control: it can simply be skipped. #207's repository-side refusal at merge/promote/release is what actually binds authorization -- this only surfaces a hold before effort is spent on it."

case "${1:-}" in
  -h|--help|help)
    usage
    echo "$ERGONOMIC_NOTICE" >&2
    exit 0
    ;;
esac

num="${1:-}"
case "$num" in ''|*[!0-9]*) usage; exit 1;; esac
role="${2:-}"
case "$role" in *[!A-Za-z0-9_-]*) echo "fwf claim: invalid role '$role' (letters/digits/-/_ only)" >&2; exit 1;; esac

# --- refusal event log, durable across ticks (issue #243 AC f) --------------
# EVENT-SOURCED, never recomputed per render: fwf-dash-data.sh reading this
# costs a file read, not a fresh `fwf authz` (and hence a fresh comment-
# thread read) per candidate issue per refresh -- issue #239 already
# measured that exact per-render cost as the dash's dominant term, and a
# second one here would double it before #239 even finished measuring the
# first. Durable (a real file under $FWF_STATE_DIR, not in-process state
# that resets every tick -- the #238 N=3-counter trap) so a refusal
# recorded on tick N is still visible on tick N+1.
CLAIM_REFUSAL_LOG="$FWF_STATE_DIR/claim-refusals.log"
_record_refusal() { # $1=issue-number $2=verdict
  mkdir -p "$(dirname "$CLAIM_REFUSAL_LOG")" 2>/dev/null
  printf 'ts=%s issue=%s verdict=%s\n' "$(date +%s)" "$1" "$2" >> "$CLAIM_REFUSAL_LOG" 2>/dev/null
  # Bounded, same rolling-window shape as #227/#239's own logs -- a count
  # of recent refusals, never an unbounded file nobody prunes.
  if [ -f "$CLAIM_REFUSAL_LOG" ]; then
    tail -n "${FWF_CLAIM_REFUSAL_LOG_MAX:-500}" "$CLAIM_REFUSAL_LOG" > "$CLAIM_REFUSAL_LOG.tmp.$$" 2>/dev/null \
      && mv "$CLAIM_REFUSAL_LOG.tmp.$$" "$CLAIM_REFUSAL_LOG" || rm -f "$CLAIM_REFUSAL_LOG.tmp.$$"
  fi
}

refuse() { # $1=verdict-line $2=cause-class(policy|infrastructure|race)
  echo "fwf claim #$num: REFUSED — $2 cause" >&2
  echo "  $1" >&2
  echo "  next: fwf authz $num" >&2
  # AC (h): the ergonomic-not-control statement belongs on EVERY path a
  # reader might stop at, including refusal -- silence here would read as
  # "this is where the real control lives", the exact misreading (h) exists
  # to prevent.
  echo "$ERGONOMIC_NOTICE" >&2
  _record_refusal "$num" "$2"
  exit 1
}

# --- issue #462: atomic claim-race adjudication -----------------------------
# Only engaged when a [role] arg is given (see usage note above). Three
# steps, all CODE (the whole point: the template's old "post a comment,
# then re-check you won" was PROSE -- both racing seats could comply with
# it perfectly and both still proceed, since nothing there ever refused).
#
# 1. Post "CLAIM <role>" ourselves (folding what used to be a separate,
#    earlier `gh issue comment` call the agent ran by hand into this one
#    tool call -- one fewer place for the two steps to drift apart).
# 2. Bust the ghcache view of this issue's comment thread (AC 4: a
#    compare-and-set against a snapshot up to TTL=60s stale is not a
#    compare-and-set -- reuses the SAME write-through primitive
#    fwf-dash-act.sh's operator-approve path already calls). Skipped for
#    the local test/dev issue store, which has no cache to bust.
# 3. Re-read the thread and find the FIRST LIVE "CLAIM <role>" comment,
#    reusing fwf_claim_liveness_blocks (lib.sh) -- the SAME liveness
#    signal fwf-claim-liveness.sh, the conductor's build-plane guard and
#    fwf-scale.sh already use, so this 4th call site can never disagree
#    with the other three about who currently holds a claim. An old,
#    abandoned claim is skipped (not live), so it never blocks a fresh
#    attempt -- only a genuinely CONCURRENT claim can beat us.
_claim_comments_tsv() { # $1=issue-number -> "createdAt\trole" per CLAIM comment, in order
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" view "$1" --json comments --jq \
      '(.comments // []) | map(select(.body | test("^CLAIM [A-Za-z0-9_-]+$"))) | .[] | "\(.createdAt)\t\(.body | sub("^CLAIM ";""))"'
  else
    gh issue view "$1" --json comments --jq \
      '(.comments // []) | map(select(.body | test("^CLAIM [A-Za-z0-9_-]+$"))) | .[] | "\(.createdAt)\t\(.body | sub("^CLAIM ";""))"'
  fi
}

# -> the role of the first LIVE claim comment on stdout, rc 0. Empty
# stdout + rc 0 means no CLAIM comment exists at all. rc 1 = the thread
# could not be read (infrastructure failure, not "no claims") -- callers
# must not treat that the same as "no claims found".
_first_live_claim_role() { # $1=issue-number
  local data now created body claimant epoch age
  data="$(_claim_comments_tsv "$1")" || return 1
  [ -z "$data" ] && return 0
  now="$(date -u +%s)"
  while IFS=$'\t' read -r created body; do
    [ -z "$body" ] && continue
    claimant="$body"
    epoch="$(fwf_iso_to_epoch "$created" 2>/dev/null || true)"
    case "$epoch" in ''|*[!0-9]*) epoch="$now";; esac
    age=$(( now - epoch )); [ "$age" -ge 0 ] || age=0
    if fwf_claim_liveness_blocks "$claimant" "$age"; then
      printf '%s' "$claimant"
      return 0
    fi
  done <<<"$data"
  return 0
}

_post_issue_comment() { # $1=issue-number $2=body
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    "$DIR/fwf-issues.sh" comment "$1" --body "$2" >/dev/null 2>&1
  else
    gh issue comment "$1" --body "$2" >/dev/null 2>&1
  fi
}

_adjudicate_claim_race() { # $1=issue-number $2=role
  local n="$1" me="$2" winner rc
  _post_issue_comment "$n" "CLAIM $me"
  # write-through cache bust (AC 4) -- no-op, harmlessly, for the local
  # backend and for a real gh call with the cache already off.
  if [ "${FWF_ISSUES:-}" != "local" ]; then
    "$DIR/fwf-ghcache.sh" invalidate issue "$n" >/dev/null 2>&1 || true
  fi
  winner="$(_first_live_claim_role "$n")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # Read failure post-post: same anti-stall philosophy as authz's own
    # INDETERMINATE branch below -- claiming is cheap/reversible, and
    # refusing on a mere read failure would manufacture the exact stall
    # #462 exists to relieve. WARN, don't refuse.
    echo "fwf claim #$n: WARNING — could not re-read the claim thread to adjudicate the race (infrastructure cause), proceeding as claimed" >&2
    return 0
  fi
  if [ -z "$winner" ]; then
    # We just posted our own comment above; a still-empty read here means
    # the write-through bust above didn't take (or this backend serves an
    # eventually-consistent view) -- fail open, same anti-stall reasoning.
    echo "fwf claim #$n: WARNING — could not confirm our own claim landed on the thread (infrastructure cause), proceeding as claimed" >&2
    return 0
  fi
  if [ "$winner" != "$me" ]; then
    _post_issue_comment "$n" "STAND-DOWN #$n: $me — $winner's claim is first and live; standing down (issue #462 claim-race adjudication)"
    refuse "$me lost the claim race on #$n: $winner's claim is first and live" "race"
  fi
  return 0
}

# --- issue #370: LIFECYCLE, reported alongside AUTHORIZATION but never
# merged into it -- "does the work exist" and "may it be built" are
# orthogonal axes, answered by different mechanisms (a body scan here vs.
# `fwf-authz.sh`'s sentinel oracle), and flattening them into one verdict
# word is exactly what let a declined prerequisite (closed `not_planned`,
# but still `product-wip` and therefore HELD forever) read as merely
# "not yet clear" -- indistinguishable from one still awaiting a keypress.
# Report both; combine neither.
FWF_CLAIM_MENTION_CAP="${FWF_CLAIM_MENTION_CAP:-20}"

# Batched lifecycle read for a set of issue/PR numbers -- ONE call, not N
# sequential reads (issue #370 AC 9: a body can mention a couple dozen
# issues, and reading each one's state separately is a per-claim,
# per-seat cost invisible to correctness that only ever shows up as
# rate-limit pressure). Real backend: a single `gh api graphql` call with
# every number aliased under one `repository` fetch, using
# `issueOrPullRequest` so a PR-numbered mention is distinguished from an
# issue in the same response, not a second lookup. A number this repo
# never had -- a mistyped ref, or a different identifier namespace that
# happens to share the `#N` spelling (issue #370 AC 6's captured `#1118`
# transom-id fixture) -- comes back null: a SILENT skip, not a failure.
# Local backend (FWF_ISSUES=local, test/dev only): the local issue store
# has no PR concept and no `stateReason` at all -- reported honestly as
# "reason unknown" on a closed issue rather than guessed as `completed`,
# which is precisely the collapse AC 6 forbids.
# Output: TSV "n\ttype\tstate\treason\tclosed_at" per EXISTING number (a
# nonexistent number contributes no row at all). rc 1 = the whole read
# failed (infrastructure, not "these don't exist") -- callers render
# every requested number as a loud UNKNOWN rather than silently skipping,
# because a batch-level failure cannot tell "doesn't exist" from
# "exists but unreadable" apart per-number, and AC 6 requires the second
# case to be loud.
_lifecycle_batch() { # $@ = deduped issue/PR numbers
  [ "$#" -eq 0 ] && return 0
  if [ "${FWF_ISSUES:-}" = "local" ]; then
    local n st
    for n in "$@"; do
      st="$("$DIR/fwf-issues.sh" view "$n" --json state --jq '.state' 2>/dev/null)" || continue
      case "$st" in
        open|OPEN)     printf '%s\tIssue\tOPEN\t\t\n' "$n" ;;
        closed|CLOSED) printf '%s\tIssue\tCLOSED\tUNKNOWN\t\n' "$n" ;;
      esac
    done
    return 0
  fi
  local owner repo slug query n out
  slug="$(fwf_repo_slug)"
  owner="${slug%%/*}"; repo="${slug#*/}"
  query="query { repository(owner: \"$owner\", name: \"$repo\") {"
  for n in "$@"; do
    query="$query n$n: issueOrPullRequest(number: $n) { __typename ... on Issue { state stateReason closedAt } ... on PullRequest { state closedAt } }"
  done
  query="$query } }"
  out="$(gh api graphql -f "query=$query" --jq '.data.repository' 2>/dev/null)"
  if [ -z "$out" ] || [ "$out" = "null" ]; then return 1; fi
  for n in "$@"; do
    printf '%s' "$out" | jq -r --arg k "n$n" --arg num "$n" '
      .[$k] as $v
      | if $v == null then empty
        else [$num, ($v.__typename // "Issue"), ($v.state // "UNKNOWN"),
              ($v.stateReason // "UNKNOWN"), ($v.closedAt // "")] | @tsv
        end' 2>/dev/null
  done
}

# One rendering of a single lifecycle row, shared by the declared-heading
# scan and the weak mention scan below so the two never drift in wording.
# $1=n $2=type(Issue|PullRequest) $3=state(OPEN|CLOSED) $4=reason $5=closed_at
# $6=mode(declared|mention) -- "declared" is asserting a real prerequisite
# and speaks plainly ("the prerequisite shipped"); "mention" is the weak
# scan and must never claim more than "this body mentions a declined
# issue" (issue #370's own thesis: an absent mechanical distinction
# between "asserts" and "merely mentions" is what this ticket routes
# around, not what it re-introduces here).
_lifecycle_line() {
  local n="$1" type="$2" state="$3" reason="$4" closed_at="$5" mode="$6" date=""
  [ -n "$closed_at" ] && date="${closed_at%%T*}"
  if [ "$type" = "PullRequest" ]; then
    echo "    #$n: is a PULL REQUEST, not an issue"
    return
  fi
  case "$state" in
    OPEN)
      [ "$mode" = declared ] && echo "    #$n: OPEN"
      ;;
    CLOSED)
      case "$reason" in
        COMPLETED)
          if [ "$mode" = declared ]; then
            echo "    #$n: CLOSED (completed) — the prerequisite shipped"
          else
            echo "    #$n: closed completed${date:+ on $date}"
          fi
          ;;
        NOT_PLANNED)
          if [ "$mode" = declared ]; then
            echo "    #$n: CLOSED (not planned)${date:+ on $date} — DECLINED, not pending; see its closing comment before relying on it"
          else
            echo "    #$n: closed not planned${date:+ on $date} — see its closing comment before relying on it"
          fi
          ;;
        *)
          echo "    #$n: CLOSED (reason unknown)"
          ;;
      esac
      ;;
    *)
      echo "    #$n: UNKNOWN — could not verify its lifecycle"
      ;;
  esac
}

# --- (j)/(j2): declared-prerequisite scan, warn-only, PARTIAL BY CONSTRUCTION
# The convention (a "## HARD PREREQUISITE(S)" heading, #135's own example)
# is deliberately NOT minted here -- this consumes whatever's already
# established, never derives it from free prose. Two independent
# mechanisation attempts (a prose-dependency-language sweep in each
# direction) failed identically per this ticket's own body, which is WHY
# this only ever WARNS, never refuses, on what it finds -- and why an
# absent heading must say so explicitly (AC j2: silence is not "no
# prerequisites", it is "the scan found nothing", a narrower claim).
_scan_prerequisites() { # $1=issue-number
  local body heading_line nums n verdict rc read_rc lc_data lc_rc row type state reason closed_at
  # #211's convention, here too: a genuinely EMPTY body (rc 0, a real and
  # common state for a terse ticket) is not the same fact as "the read
  # itself failed" (nonzero rc) -- collapsing them would misreport a real
  # empty body as UNKNOWN, and a real read failure as "no heading, proceed
  # calmly" (the WORSE direction, since it hides a read failure behind the
  # routine, unworried message).
  body="$(_issue_read "$1" --json body --jq '.body' 2>/dev/null)"; read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    echo "  prerequisites: UNKNOWN — could not read the issue body to scan for a declared-prerequisite heading" >&2
    return 0
  fi
  # The heading line itself (case-insensitive) plus the two lines after it --
  # #135's own example puts the referenced numbers directly on the heading
  # line ("## HARD PREREQUISITES -- #234 AND #189 land first"), and this
  # stays deliberately narrow (a heading match, never free prose) per the
  # ticket's own "cannot be derived from prose" finding.
  # issue #370 AC 10: widened to the spellings actually in use on this
  # floor -- measured at filing time, EVERY open issue declaring a hard
  # dependency under a heading spelled it "## HARD DEPENDENCY", never the
  # "## HARD PREREQUISITE" this used to require alone. `-E` for the
  # alternation; case-insensitivity is unchanged (`-i`, already present).
  heading_line="$(printf '%s\n' "$body" | grep -inA2 -E '^##.*(HARD PREREQUISITE(S)?|HARD DEPENDENC(Y|IES))' | head -3)"
  if [ -z "$heading_line" ]; then
    echo "  prerequisites: no '## HARD PREREQUISITE' heading found (a PARTIAL scan -- this is not the same claim as 'no prerequisites exist', see issue #243 AC j2)" >&2
    return 0
  fi
  nums="$(printf '%s\n' "$heading_line" | grep -oE '#[0-9]+' | tr -d '#' | sort -un)"
  if [ -z "$nums" ]; then
    echo "  prerequisites: a HARD PREREQUISITE heading was found but named no #<n> references" >&2
    return 0
  fi
  echo "  prerequisites (declared, from a HARD PREREQUISITE heading -- a partial scan, not a schema):" >&2
  lc_data="$(_lifecycle_batch $nums)"; lc_rc=$?
  for n in $nums; do
    [ "$n" = "$1" ] && continue   # never report an issue as its own prerequisite
    # LIFECYCLE first, on its own line -- never merged into the authz verdict
    # below (issue #370's own thesis: "closed" and "HELD" mean opposite
    # things about whether the work exists vs. whether it may be built).
    if [ "$lc_rc" -ne 0 ]; then
      echo "    #$n: UNKNOWN — could not verify its lifecycle" >&2
    else
      row="$(printf '%s\n' "$lc_data" | awk -F'\t' -v n="$n" '$1==n{print; exit}')"
      if [ -n "$row" ]; then
        IFS=$'\t' read -r _ type state reason closed_at <<<"$row"
        _lifecycle_line "$n" "$type" "$state" "$reason" "$closed_at" declared >&2
      fi
      # no row and rc 0 -> the number never existed; silent (issue #370 AC 6)
    fi
    # AUTHORIZATION second, its own line. Split into every verdict
    # fwf-authz.sh can return (issue #370 AC 3's second half): the old
    # catch-all folded HELD (rc 10, awaiting a keypress), INVALID (rc 11,
    # "a forgery attempt or a botched operator action -- not routine
    # HELD" per fwf-authz.sh's own words) and INDETERMINATE (rc 2, the
    # thread could not be read) into one "NOT YET CLEAR" string --
    # collapsing a security-relevant verdict into the same reading as a
    # routine hold.
    verdict="$("$DIR/fwf-authz.sh" "$n" 2>&1)"; rc=$?
    case "$rc" in
      0)  echo "    #$n: AUTHORIZED" >&2 ;;
      12) echo "    #$n: NOT-GATED (no gate ever applied)" >&2 ;;
      10) echo "    #$n: NOT YET CLEAR ($(printf '%s' "$verdict" | head -1))" >&2 ;;
      11) echo "    #$n: INVALID — security-relevant, not a routine hold ($(printf '%s' "$verdict" | head -1))" >&2 ;;
      2)  echo "    #$n: INDETERMINATE — the thread could not be read ($(printf '%s' "$verdict" | head -1))" >&2 ;;
      *)  echo "    #$n: NOT YET CLEAR ($(printf '%s' "$verdict" | head -1))" >&2 ;;
    esac
  done
}

# --- issue #370 §2: a WEAK mention scan -- does NOT require solving the
# prose-dependency problem the two mechanisation attempts above already
# failed at. It asks a strictly smaller question than "is #N a
# prerequisite of this issue": only "does this body mention #N, and is #N
# closed not_planned" -- a lookup, not an inference, and sufficient to
# stop a reader the way the declared-prerequisite scan above cannot (that
# scan only ever looks at a heading; most dependencies on this floor are
# written in prose, per this ticket's own filing). Fence-stripped (AC 7,
# reusing #218's existing stripper rather than re-deriving it), self- and
# duplicate-excluded (AC 8), capped (AC 9) and honest about both (AC 4/9).
_scan_mentions() { # $1=issue-number
  local body stripped mentions total n count lc_data lc_rc row type state reason closed_at line lines cap_note
  body="$(_issue_read "$1" --json body --jq '.body' 2>/dev/null)" || return 0
  stripped="$(printf '%s\n' "$body" | fwf_strip_fences)"
  # first-occurrence order, deduped, self excluded (AC 8) -- same
  # `[ "$n" = "$1" ] && continue` exclusion as the declared-prerequisite
  # loop, applied here via the awk filter instead of a shell loop.
  mentions="$(printf '%s\n' "$stripped" | grep -oE '#[0-9]+' | tr -d '#' | awk -v self="$1" '$0!=self && !seen[$0]++')"
  [ -z "$mentions" ] && return 0
  total="$(printf '%s\n' "$mentions" | wc -l | tr -d ' ')"
  local -a nums=()
  count=0
  while IFS= read -r n; do
    count=$((count + 1))
    [ "$count" -gt "$FWF_CLAIM_MENTION_CAP" ] && break
    nums+=("$n")
  done <<<"$mentions"
  lc_data="$(_lifecycle_batch "${nums[@]}")"; lc_rc=$?
  lines=""
  for n in "${nums[@]}"; do
    if [ "$lc_rc" -ne 0 ]; then
      # Whole batch failed -- can't tell "doesn't exist" from "exists but
      # unreadable" per number, and AC 6 requires the second case to be
      # loud, so every scanned number renders loud here (the conservative
      # direction: never let a read failure collapse into silence, which
      # would read as "nothing declined").
      lines="$lines
    #$n: UNKNOWN — could not verify its lifecycle"
      continue
    fi
    row="$(printf '%s\n' "$lc_data" | awk -F'\t' -v n="$n" '$1==n{print; exit}')"
    [ -z "$row" ] && continue   # never existed (404-equivalent) -- silent, AC 6
    IFS=$'\t' read -r _ type state reason closed_at <<<"$row"
    [ "$state" = "OPEN" ] && continue   # open mentions: nothing to say
    line="$(_lifecycle_line "$n" "$type" "$state" "$reason" "$closed_at" mention)"
    [ -n "$line" ] && lines="$lines
$line"
  done
  cap_note=""
  if [ "$total" -gt "$FWF_CLAIM_MENTION_CAP" ]; then
    cap_note="  mentions: scanned $FWF_CLAIM_MENTION_CAP of $total distinct #N references (capped) — an unscanned mention could still be declined and would not show here"
  fi
  # Silence means "the scan found nothing" (same discipline as AC j2's
  # absent-heading line above) -- but a cap notice is itself a finding
  # (incompleteness), so it prints even when nothing else does.
  [ -z "$lines" ] && [ -z "$cap_note" ] && return 0
  echo "  mentions of DECLINED issues (a weak signal — this does NOT assert a dependency):" >&2
  [ -n "$cap_note" ] && echo "$cap_note" >&2
  [ -n "$lines" ] && printf '%s\n' "$lines" | sed '/^$/d' >&2
  return 0
}

if [ -n "$role" ]; then
  _adjudicate_claim_race "$num" "$role"
fi

verdict_out="$("$DIR/fwf-authz.sh" "$num" 2>&1)"; rc=$?
case "$rc" in
  0)
    # AUTHORIZED — proceed.
    ;;
  12)
    # NOT-GATED (#215) — proceed (AC c): a fix-forward on an issue no gate
    # ever held must not be caught by this.
    echo "fwf claim #$num: NOT-GATED — $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
  2)
    # INDETERMINATE — warn (infrastructure cause) and ALLOW (AC b). This is
    # the anti-stall half: claiming is cheap and reversible, and refusing
    # here on a mere READ failure is exactly the policy that would
    # manufacture the stall this ticket exists to relieve.
    echo "fwf claim #$num: WARNING — infrastructure cause, proceeding anyway (claiming is cheap/reversible; #207's merge-time check is what actually binds)" >&2
    echo "  $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
  10|11)
    # HELD or INVALID — refuse (AC a). Both are a POLICY cause (a real
    # verdict was read; it says no), distinct from INDETERMINATE's
    # infrastructure cause above.
    refuse "$(printf '%s' "$verdict_out" | head -1)" "policy"
    ;;
  *)
    # Any other/unexpected exit from fwf-authz.sh: fail closed the same
    # direction as INDETERMINATE (a read that cannot complete must not
    # collapse into a confident value either way), but distinguishably
    # worded so it is never mistaken for the well-known INDETERMINATE case.
    echo "fwf claim #$num: WARNING — unrecognized fwf-authz.sh exit ($rc), infrastructure cause, proceeding anyway" >&2
    echo "  $(printf '%s' "$verdict_out" | head -1)" >&2
    ;;
esac

_scan_prerequisites "$num"
_scan_mentions "$num"

echo "$ERGONOMIC_NOTICE" >&2

# --- (i0)/(i2): the claim artifact -- pinned here, no branch management ----
# Verified against the templates: only dev/refactor ever GAVE the command
# (git commit --allow-empty -m "claim #<n>: <title>"), and they agreed
# exactly; defect-report/ideation/validate referenced the artifact without
# ever defining it. This is now the one place the definition lives.
# Deliberately does NOT switch/create a branch (#177: one worktree per
# branch, so a claim verb that switches branches inherits that deadlock;
# one that only commits does not) -- the caller is assumed to already be
# on the branch it wants this commit on.
title="$(_issue_read "$num" --json title --jq '.title' 2>/dev/null)"
if [ -z "$title" ]; then
  echo "fwf claim #$num: could not read the issue title (gh failed) -- committing without one" >&2
  title="(title unavailable)"
fi
if ! git commit --allow-empty -m "claim #$num: $title" -m "Co-Authored-By: Claude <noreply@anthropic.com>" >&2; then
  echo "fwf claim #$num: git commit failed -- see above" >&2
  exit 1
fi
echo "fwf claim #$num: claimed."
exit 0
