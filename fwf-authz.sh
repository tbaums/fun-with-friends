#!/usr/bin/env bash
# fwf-authz.sh — mechanically verify HUMAN authorization to build/un-gate an
# issue (issue #150). This is the checkable answer to "was this approved?" that
# a role can call INSTEAD of inferring authorization from label state (which is
# unattributable — every role shares one account) or, catastrophically, from
# pane/autosuggest/ghost text (which merely mirrors the thread and will always
# "agree" with the reader). The incident: a role invented a human confirmation
# out of another pane's ghost text, asserted it as fact, re-gated four approved
# tickets and closed three PRs. The fix is a POSITIVE, attributable signal —
# the operator un-gate sentinel comment (config.sh: $OPERATOR_UNGATE_SENTINEL),
# emitted only by a human keypress on the `fwf dash` board — plus this verifier.
#
# ANCHORING (issue #218): the matcher below is unanchored `grep -qF` over the
# whole concatenated thread today, and that is a live false-AUTHORIZED bug —
# confirmed on #179, #192, and (nine days after the fact) a ROADMAP status
# bullet on #154. A comment merely CONTAINING the token — quoted, discussed,
# denied, or pasted as this tool's own HELD/refusal output — flips the verdict.
# #218 fixes this: the sentinel counts only when it is the FIRST thing on a
# LINE (column 0) of a COMMENT (never the issue body — see AC (n)), evaluated
# per comment (never a concatenated blob — see AC (f)), with fenced/indented
# code regions stripped first (a fence at column 0 is the natural way to
# DOCUMENT the payload, and must not itself authorize).
#
# Usage: fwf authz <issue>
#   <issue>  bare number, #N, or LI-N (local backend).
#
# Verdicts (both a human-readable line AND an exit code, so a role can branch
# on either):
#   AUTHORIZED    (exit 0)  — an anchored, correctly-issue-referenced sentinel
#                             is present in a comment. Safe to proceed / do NOT
#                             re-gate.
#   HELD          (exit 10) — no anchored sentinel. NOT authorized: HOLD and
#                             ask; never infer a yes from pane text or a
#                             mid-line/quoted mention, never reverse work.
#   INVALID       (exit 11) — a sentinel-SHAPED line sits at column 0 but is
#                             malformed (no parseable issue reference, or names
#                             a DIFFERENT issue than this thread's own). This is
#                             security-relevant — either a forgery attempt or a
#                             botched operator action — and is surfaced on
#                             `fwf dash`, not just here (issue #218 AC (i)).
#   INDETERMINATE (exit 2)  — the thread could not be read. FAIL CLOSED: treat
#                             exactly like HELD (hold and ask), never as a yes.
#
# The verdict keys on a DURABLE comment, not the mutable label — so it stays
# correct even if a role has wrongly re-applied the gate. Read-only: it never
# mutates an issue and (gh backend) goes through the shared REST+ETag cache, so
# it never re-drains the budget.
#
# ROUND-TRIP SAFETY (issue #218 AC (m)): "a security oracle must not emit a
# string that satisfies its own matcher." None of this script's own output
# ever prints the literal sentinel — every occurrence, including a quoted
# matched line in an AUTHORIZED verdict, is defanged (OPERATOR-UNGATE ->
# OPERATOR[-]UNGATE) before printing. That is what stops a HELD/INVALID
# message — or this tool's own README example — from later being pasted back
# into a thread and satisfying the matcher it was reporting on.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

EX_HELD=10
EX_INDETERMINATE=2
EX_INVALID=11

usage() { echo "usage: fwf authz <issue>   # verify the operator un-gate authorization signal (issue #150, #218)" >&2; }

raw="${1:-}"
case "$raw" in -h|--help|help) usage; exit 0;; esac
num="${raw#LI-}"; num="${num#\#}"
case "$num" in ''|*[!0-9]*) usage; exit 1;; esac

# Read ONLY the comment thread, structured (never the issue body — #218 AC
# (n): #214's body carries a natural, well-formed sentinel line written by the
# PM while SPECIFYING the mechanism, and that must never authorize anything).
# `--json comments` is what makes this a structural guarantee rather than an
# accident of a CLI's output format: it cannot see the body no matter what.
#
# gh's human-readable `--comments` renderer has a reproducible bug (#200): for
# some issues it prints 0 bytes with exit 0 and no stderr, identically with the
# cache bypassed — indistinguishable from a genuinely empty thread. The `--json
# comments` REST path does not share this bug, so that's what we read through
# on both backends now. We key the INDETERMINATE verdict on the read COMMAND
# failing (non-zero exit) or returning something that isn't a JSON array, not
# on the thread text being empty — a thread with zero comments is a legitimate
# HELD, not a read failure (#211's three-outcome convention).
comments_json=""
read_ok=1
if [ "$FWF_ISSUES" = "local" ]; then
  comments_json="$("$DIR/fwf-issues.sh" view "$num" --json comments --jq '.comments' 2>/dev/null)" || read_ok=0
else
  # Belt-and-suspenders for a just-un-gated ticket (issue #167): read the thread
  # through a short TTL so the operator sentinel is seen within ~10s even if the
  # approve path's write-through invalidate was somehow missed. The comment-view
  # ETag conditional keeps this forced-fresh read near-free (304 when unchanged),
  # so the tighter window costs a role nothing in the common case.
  comments_json="$(FWF_GHCACHE_TTL=10 FWF_REAL_GH="$(command -v gh)" "$DIR/fwf-ghcache.sh" serve issue view "$num" --json comments --jq '.comments' 2>/dev/null)" || read_ok=0
fi
if [ "$read_ok" = 1 ]; then
  printf '%s' "$comments_json" | jq -e 'type=="array"' >/dev/null 2>&1 || read_ok=0
fi

if [ "$read_ok" != 1 ]; then
  echo "INDETERMINATE #$num — could not read the issue thread (reader command failed or returned unparseable output). FAIL CLOSED: treat as NOT authorized. HOLD and post an open question; never infer authorization from pane/ghost text, and never reverse approved work on a belief. Retry: fwf authz $num (or check 'gh auth status' / network if this repeats)." >&2
  exit "$EX_INDETERMINATE"
fi

TOKEN="$OPERATOR_UNGATE_SENTINEL"
# Regex-escape the token for use inside an ERE (default "OPERATOR-UNGATE" has
# no metacharacters, but FWF_OPERATOR_UNGATE_SENTINEL is operator-overridable).
TOKEN_RE="$(printf '%s' "$TOKEN" | sed 's/[.[\*^$()+?{|]/\\&/g')"

# Defang for OUR OWN output only (AC (m), see header comment) — never the
# literal token. Splits on the token's own '-' when it has one (matching the
# convention this ticket's own body uses: OPERATOR[-]UNGATE); otherwise splits
# the token at its midpoint. Either way the result cannot satisfy TOKEN_RE.
defang() {
  local t="$1"
  case "$t" in
    *-*) printf '%s' "${t/-/[-]}" ;;
    *)   local h=$(( ${#t} / 2 )); printf '%s[]%s' "${t:0:h}" "${t:h}" ;;
  esac
}
DTOKEN="$(defang "$TOKEN")"
defang_line() { printf '%s' "${1//$TOKEN/$DTOKEN}"; }

matched_line=""
invalid_line=""
invalid_reason=""
raw_occurrences=0

while IFS= read -r c; do
  [ -n "$matched_line" ] && break   # a genuine hit anywhere wins; stop scanning.
  body="$(printf '%s' "$c" | jq -r '.body // ""')"
  [ -n "$body" ] || continue

  # Informational only (AC (d)'s "quoted N times" note on a HELD verdict) —
  # counted on the RAW body, before stripping, since even a fenced/quoted
  # mention is worth a human glance in aggregate even though none authorize.
  cnt="$(printf '%s' "$body" | grep -oF "$TOKEN" 2>/dev/null | wc -l | tr -d ' ')"
  raw_occurrences=$((raw_occurrences + cnt))

  # Strip fenced code regions (``` or ~~~, either length/info-string) before
  # column 0 is evaluated — a REQUIREMENT, not a contingency (#218 §1). This is
  # "the main case going forward": every doc that shows the payload format
  # naturally puts it in a fence, at column 0, and that must never authorize.
  # No fence-info-string exemption; the rule is unconditional.
  #
  # QA-caught (repro qa2/repro-288, #218): a fence's closer must use the SAME
  # delimiter CHARACTER as its opener, at least as long — per CommonMark, a
  # ``` fence is only closed by backticks; a ~~~ line inside it is ordinary
  # fenced content, not a closer. The first version here accepted EITHER
  # delimiter as a closer regardless of what opened, so "```\n~~~\nSENTINEL\n```"
  # exited infence one line early and scored the sentinel as unfenced text —
  # the exact forgery class this stripping exists to close. Track the opening
  # character and run length explicitly; a candidate closer only counts when
  # it repeats that same character at least that many times with nothing but
  # trailing whitespace after.
  stripped="$(printf '%s\n' "$body" | awk '
    BEGIN { infence = 0; fchar = ""; flen = 0 }
    {
      line = $0
      sub(/^[ ]{0,3}/, "", line)
    }
    !infence {
      if (line ~ /^```/ || line ~ /^~~~/) {
        fchar = substr(line, 1, 1)
        n = 0
        while (substr(line, n + 1, 1) == fchar) n++
        flen = n
        infence = 1
        next
      }
      print
      next
    }
    infence {
      n = 0
      while (substr(line, n + 1, 1) == fchar) n++
      rest = substr(line, n + 1)
      gsub(/[ \t]/, "", rest)
      if (n >= flen && rest == "") infence = 0
      next
    }
  ')"

  while IFS= read -r line; do
    [ -n "$matched_line" ] && break
    # Column 0 means the FIRST character on the line — a blockquote ("> "),
    # any indentation (including a 4-space indented code block — #218 AC (c)
    # covers this as the same anchoring check, not a separate stripping step,
    # since an indented line already fails a true-column-0 anchor), and
    # obviously mid-sentence prose all fail here by construction.
    #
    # The one deliberate tolerance: up to two leading '*'/'_' characters — a
    # markdown bold/italic opener. This is NOT a general markdown-stripping
    # allowance; it exists because every REAL operator un-gate comment on this
    # floor today (#205, #217, #218 itself) is posted as literal
    # "**OPERATOR-UNGATE #<n>** — ...", measured from the live threads before
    # deciding this, not assumed. A matcher that required true byte-0 would
    # silently HOLD every currently-authorized ticket the day this ships.
    if [[ "$line" =~ ^([*_]{0,2})${TOKEN_RE}([*_]{0,2})[[:space:]:]*#([0-9]+)([^0-9]|$) ]]; then
      n="${BASH_REMATCH[3]}"
      if [ "$n" = "$num" ]; then
        matched_line="$line"
      elif [ -z "$invalid_line" ]; then
        invalid_line="$line"; invalid_reason="names issue #$n, not #$num — wrong-issue sentinel in this thread"
      fi
    elif [[ "$line" =~ ^([*_]{0,2})${TOKEN_RE}([*_]{0,2})([[:space:]:]|$) ]]; then
      if [ -z "$invalid_line" ]; then
        invalid_line="$line"; invalid_reason="missing a parseable '#<issue>' reference right after the token"
      fi
    fi
  done <<<"$stripped"
done < <(printf '%s' "$comments_json" | jq -c '.[]')

if [ -n "$matched_line" ]; then
  echo "AUTHORIZED #$num — operator un-gate signal present: $(defang_line "$matched_line")"
  exit 0
fi

if [ -n "$invalid_line" ]; then
  echo "INVALID #$num — a sentinel-shaped line is anchored at column 0 but malformed ($invalid_reason): $(defang_line "$invalid_line"). This is security-relevant: either a forgery attempt or a botched operator action, not routine HELD. Do NOT treat as authorized. Inspect the thread: gh issue view $num --comments; if this was a genuine operator action gone wrong, they must repost a correct $DTOKEN #$num line." >&2
  exit "$EX_INVALID"
fi

note=""
[ "$raw_occurrences" -gt 0 ] && note=" (the token is mentioned $raw_occurrences time(s) in this thread, quoted/discussed/indented/fenced — none anchored, so none authorize; seen and ignored)"
echo "HELD #$num — no operator un-gate signal ($DTOKEN) in the thread$note. This issue is NOT authorized for build. HOLD and post the doubt as an open question; do NOT infer authorization from any pane/input-box text, and do NOT take a reversing action (re-gate, close PRs, revert). An operator un-gates by posting, at the start of a comment line: $DTOKEN #$num — <reason> (via 'fwf dash' approve, or the concierge proxy)." >&2
exit "$EX_HELD"
