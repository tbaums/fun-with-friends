#!/usr/bin/env bash
# fwf-reconcile-guard.sh -- issue #179 Hole 1/3: give the reconcile verdict a
# consequence on the UNTAGGED direct-to-main path.
#
# WHY THIS EXISTS. `fwf reconcile` (#114) has always classified correctly. The
# defect #179 names is one sentence: "the classifier is sound, and no call site
# is obliged to act on its verdict." On the tagged release path the obligation
# is now the pre-publish `--check` gate in release.yml. On the UNTAGGED path --
# a direct-to-main hotfix, which is exactly the path the original incident took
# -- there is no publish to gate, so the verdict needs a consequence that
# OUTLIVES the workflow run. A `::warning::` inside a green run is not one: it
# is invisible the moment the run scrolls away, which is Hole 2 wearing
# different clothes.
#
# THE CONSEQUENCE IS A DURABLE ARTIFACT: one auto-filed, auto-closed tracking
# issue, plus a non-zero exit so the check itself goes red. Chosen over the two
# alternatives deliberately, and the menu is NOT left open in the code (#179
# AC3): a failed check alone blocks nothing once the run is buried, and a
# `release-hold` label has no stated carrier in this repo.
#
# IDEMPOTENCY IS PART OF THE CONTRACT, NOT A NICETY (#179 AC4). ci.yml fires on
# EVERY push to main. A divergence that persists across ten pushes must produce
# ONE artifact, not ten -- otherwise the mechanism built to make divergence
# visible becomes the noise that trains people to ignore it: the ::warning::
# failure again, with more volume. So: reuse the open artifact if there is one,
# edit it in place, and close it when reconcile next comes back clean.
#
# Usage: fwf reconcile-guard [--against BRANCH] [--branch NAME ...]
#   Arguments are passed straight through to `fwf reconcile`. Branches on
#   `fwf reconcile`'s EXIT CODE (issue #238 AC6), never on the text of its
#   report -- substring-matching human-readable prose to make a safety
#   decision breaks silently the moment someone rewords the message (the
#   same class of defect as #218's sentinel and #236's marker).
#   Exit 0 = reconcile confirmed CLEAN (rc 0: reconciled/normal-ahead/clean
#            no-op on every branch) -- any open artifact is closed.
#   Exit 1 = ESCALATE (rc 1: halted-diverged/suspect on any branch, including
#            one reached via the AC7 consecutive-indeterminate counter) -- an
#            open artifact exists and names it.
#   Exit 2 = INDETERMINATE (rc 2: lock-busy/cas-lost on some branch, nothing
#            escalated) -- a lost race against a CONCURRENT, benign writer
#            (another reconcile tick, a release), not a divergence. Neither
#            files nor closes an artifact (issue #238 AC1/AC3/AC5): this run
#            simply could not confirm either way, so it must touch nothing.
#            Self-healing -- re-classified next tick.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

# The artifact is found by listing open issues and grepping this marker
# LOCALLY -- deliberately NOT via `gh issue list --search`. GitHub's search
# index is eventually consistent and can lag by minutes; two pushes inside that
# window would each fail to find the other's artifact and file a duplicate,
# breaking AC4 precisely when pushes come fastest. A list+grep is deterministic.
GUARD_MARKER_KEY="fwf-reconcile-guard:v1"
GUARD_MARKER="<!-- $GUARD_MARKER_KEY -- do not remove, this key is how the guard finds this issue -->"
GUARD_TITLE="[reconcile] staging/integration diverged from ${DEFAULT_BRANCH}"
GH="${FWF_GH:-gh}"
# Overridable the same way GH is above, so a test can substitute a stub that
# emits deterministic report lines instead of racing a REAL concurrent CAS
# push to reproduce cas-lost (issue #238).
RECONCILE_SCRIPT="${FWF_RECONCILE_SCRIPT:-$DIR/fwf-reconcile.sh}"

# Echo the number of the single open guard artifact, or nothing.
# Uses gh's built-in --jq rather than a python/jq dependency, so the guard
# needs nothing the rest of fwf does not already require.
guard_find() {
  "$GH" issue list --state open --limit 100 --json number,body \
    --jq ".[] | select(.body != null and (.body | contains(\"$GUARD_MARKER_KEY\"))) | .number" \
    2>/dev/null | head -1
}

guard_body() { # $1=reconcile output
  cat <<BODY
$GUARD_MARKER

**Automated.** \`fwf reconcile\` reported a state that needs a human on a push to
\`${DEFAULT_BRANCH}\`. This issue is filed and closed automatically by
\`fwf reconcile-guard\` (issue #179); it is the durable artifact for the untagged
direct-to-main path, where there is no publish to gate.

### Reconcile output

\`\`\`
$1
\`\`\`

### What this means

A \`halted-diverged\` branch is **not** stale — it has commits \`${DEFAULT_BRANCH}\`
does not, and \`${DEFAULT_BRANCH}\` has commits it does not. \`fwf reconcile\` will
never auto-merge, rebase or force-push out of that state, by design. It needs a
human decision, **not a rerun**.

### How to resolve

\`\`\`sh
fwf reconcile --branch <branch> --against ${DEFAULT_BRANCH}   # re-read the classification
\`\`\`

Then reconcile the branch by hand. **Releases are blocked in the meantime**: the
pre-publish check in \`.github/workflows/release.yml\` fails on this same state
before any artifact is built.

This issue **closes itself** on the next push to \`${DEFAULT_BRANCH}\` where
reconcile comes back clean. It is updated in place rather than re-filed while
the divergence persists, so there is only ever one of it.
BODY
}

# --- issue #258: CI-durable indeterminate streak -------------------------
#
# fwf_reconcile_indeterminate_streak (lib.sh) already implements issue #238
# AC7's escalate-by-streak for a caller with a PERSISTENT $FWF_RUN (a
# captain's local tick) -- that mechanism is untouched by anything below and
# keeps working exactly as it does today. It is unreachable in CI: every
# run starts on a fresh runner disk (no cache/artifact step -- see the top
# of this file), so the local counter resets to 0/1 every time and a
# threshold of 3 is never reached. That gap is #258's whole subject.
#
# This adds a SEPARATE, durable counter using the SAME list+grep marker-issue
# pattern as the divergence artifact above, but it is explicitly NOT that
# artifact: issue #238 AC1 forbids filing/closing THE DIVERGENCE ARTIFACT on
# an indeterminate verdict, and this is a distinct, low-noise marker that
# must never be presented as a human-decision row (#258 route 1). It exists
# only so a stateless runner can still count to
# FWF_RECONCILE_INDETERMINATE_THRESHOLD consecutive indeterminate verdicts,
# per branch, with no intervening clean -- the same "no intervening clean"
# rule lib.sh's own local counter uses, so a halted-diverged/suspect branch
# in between neither increments nor resets this counter (that state already
# has its own human-facing consequence via the divergence artifact).
STREAK_MARKER_KEY="fwf-reconcile-guard:indeterminate-streak:v1"
STREAK_MARKER="<!-- $STREAK_MARKER_KEY -- do not remove, this key is how the guard finds this issue -->"
STREAK_TITLE="[reconcile] indeterminate-streak counter (machine state -- not an alert)"

streak_find() {
  "$GH" issue list --state open --limit 100 --json number,body \
    --jq ".[] | select(.body != null and (.body | contains(\"$STREAK_MARKER_KEY\"))) | .number" \
    2>/dev/null | head -1
}

streak_body() { # $1=state-lines ("<!-- streak:branch:N -->" per line)
  cat <<BODY
$STREAK_MARKER

**Automated, machine-only state -- not a human alert.** Do not action this
issue and do not close it expecting anything to happen (a later run just
recreates it). It exists only because a CI runner has no durable disk across
runs: it is \`fwf-reconcile-guard\`'s per-branch count of CONSECUTIVE
indeterminate (\`lock-busy\`/\`cas-lost\`) verdicts with no intervening clean,
used to reach \`FWF_RECONCILE_INDETERMINATE_THRESHOLD\` on a stateless runner
(issue #238 AC7, issue #258). A branch's own \`halted-diverged\`/\`suspect\`
divergence issue is the human-facing consequence; this issue only lets a
fresh runner keep counting toward it.

$1
BODY
}

# Read a marker-issue body ($1=issue number) -> echoes it, or returns 1 on a
# failed read. Kept separate from streak_find (which already tolerates a
# failed list as "no issue yet") because a failed VIEW of a KNOWN issue is a
# different case (issue #211/#258 AC(a2)): it must not be treated as "the
# issue has no state yet," or every hiccup would silently reset the streak
# a caller derives from the (in that case, wrongly empty) body.
streak_read() {
  "$GH" issue view "$1" --json body --jq '.body' 2>/dev/null
}

# Echo "branch count" pairs (one per line) parsed from an issue body given on
# stdin. A branch absent from the output means "no count seen yet" (0), not
# an error -- callers treat a missing line as streak 0.
streak_parse() {
  grep -oE '<!-- streak:[^:]+:[0-9]+ -->' 2>/dev/null | sed -E 's/<!-- streak:([^:]+):([0-9]+) -->/\1 \2/'
}

# $1=branch $2=state-lines("branch count" pairs, may be empty) -> echoes the
# count for $1, or 0 if it has no line yet.
streak_lookup() {
  local branch="$1" lines="$2" b c
  while read -r b c; do
    [ "$b" = "$branch" ] && { printf '%s' "$c"; return 0; }
  done <<<"$lines"
  printf '0'
}

# $1=branch $2=count $3=state-lines(existing "branch count" pairs) -> echoes
# updated marker-body lines with $1 set to $2 (replacing its old line if
# present, appending one if not), every other branch's line unchanged.
streak_set() {
  local branch="$1" count="$2" lines="$3" found=0 b c out=""
  while read -r b c; do
    [ -z "$b" ] && continue
    if [ "$b" = "$branch" ]; then
      out="${out}<!-- streak:$branch:$count -->"$'\n'
      found=1
    else
      out="${out}<!-- streak:$b:$c -->"$'\n'
    fi
  done <<<"$lines"
  [ "$found" -eq 1 ] || out="${out}<!-- streak:$branch:$count -->"$'\n'
  printf '%s' "$out"
}

# $1=reconcile report text (one line per branch) -> for each line this run
# can classify, echoes "<branch> indeterminate" (lock-busy/cas-lost) or
# "<branch> safe" (clean no-op/normal-ahead/reconciled), one pair per
# recognized line. A halted-diverged/suspect line, or any line this parse
# does not recognize (issue #238 AC6's whole point -- the guard's FILE/CLOSE
# decision below is driven ONLY by the reconcile script's exit code, never
# by this text), is silently skipped: this bookkeeping is additive to that
# decision, never a substitute for it.
streak_classify_lines() {
  local line word branch
  while IFS= read -r line; do
    word="${line%% *}"
    case "$word" in
      lock-busy | cas-lost)
        branch="$(printf '%s\n' "$line" | awk '{print $2}')"
        [ -n "$branch" ] && printf '%s indeterminate\n' "$branch"
        ;;
      clean)
        branch="$(printf '%s\n' "$line" | awk '{print $3}')" # "clean no-op <branch> ..."
        [ -n "$branch" ] && printf '%s safe\n' "$branch"
        ;;
      normal-ahead | reconciled)
        branch="$(printf '%s\n' "$line" | awk '{print $2}')"
        [ -n "$branch" ] && printf '%s safe\n' "$branch"
        ;;
    esac
  done <<<"$1"
}

# $1=reconcile report text -> updates the durable per-branch streak for
# every branch this run's report classifies as indeterminate or safe, and
# echoes the space-separated list of branches whose streak JUST reached
# FWF_RECONCILE_INDETERMINATE_THRESHOLD this run (empty if none). Touches
# NOTHING for a branch this run's text does not recognize (AC6, and issue
# #258 AC(a2): a failed READ of an existing streak issue is a failed
# MEASUREMENT, not evidence of "no streak yet" -- it is reported and this
# run's update is skipped entirely rather than fabricating a fresh 0/1, so a
# transient read failure pauses the count instead of resetting it).
streak_apply() {
  local classified issue_num body lines branch state count escalated=""
  classified="$(streak_classify_lines "$1")"
  [ -n "$classified" ] || { printf ''; return 0; }

  issue_num="$(streak_find)"
  lines=""
  if [ -n "$issue_num" ]; then
    if ! body="$(streak_read "$issue_num")"; then
      echo "reconcile-guard: could not read the indeterminate-streak counter (#$issue_num) — skipping this run's streak update rather than resetting it" >&2
      printf ''
      return 0
    fi
    lines="$(printf '%s\n' "$body" | streak_parse)"
  fi

  while read -r branch state; do
    [ -z "$branch" ] && continue
    count="$(streak_lookup "$branch" "$lines")"
    if [ "$state" = indeterminate ]; then
      count=$((count + 1))
    else
      count=0
    fi
    lines="$(streak_set "$branch" "$count" "$lines")"
    if [ "$state" = indeterminate ] && [ "$count" -ge "$FWF_RECONCILE_INDETERMINATE_THRESHOLD" ]; then
      escalated="$escalated$branch
"
    fi
  done <<<"$classified"

  if [ -n "$issue_num" ]; then
    streak_body "$lines" | "$GH" issue edit "$issue_num" --body-file - >/dev/null 2>&1 || true
  else
    streak_body "$lines" | "$GH" issue create --title "$STREAK_TITLE" --body-file - >/dev/null 2>&1 || true
  fi
  printf '%s' "$escalated"
}

main() {
  local out grc existing escalated eb note names
  grc=0
  out="$("$RECONCILE_SCRIPT" "$@" 2>&1)" || grc=$?
  printf '%s\n' "$out"

  escalated="$(streak_apply "$out")"
  if [ "$grc" -eq 2 ] && [ -n "$escalated" ]; then
    note=""
    names=""
    while read -r eb; do
      [ -z "$eb" ] && continue
      names="$names $eb"
      note="$note
suspect $eb $FWF_RECONCILE_INDETERMINATE_THRESHOLD consecutive indeterminate verdicts (lock-busy/cas-lost) with no intervening clean (issue #258, CI-durable streak)"
    done <<<"$escalated"
    echo "reconcile-guard: indeterminate-streak threshold reached for:$names — treating as suspect"
    out="$out$note"
    grc=1
  fi

  existing="$(guard_find)"

  case "$grc" in
    0)
      # SAFE: confirmed clean on every branch. Only THIS verdict may close.
      if [ -n "$existing" ]; then
        echo "reconcile-guard: clean — closing artifact #$existing"
        "$GH" issue comment "$existing" --body "Resolved: \`fwf reconcile\` returned clean on a later push to \`${DEFAULT_BRANCH}\`. Closing automatically." >/dev/null 2>&1 || true
        "$GH" issue close "$existing" >/dev/null 2>&1 || true
      else
        echo "reconcile-guard: clean — no artifact to close"
      fi
      return 0
      ;;
    2)
      # INDETERMINATE (issue #238 AC1/AC3/AC5): lock-busy/cas-lost, nothing
      # escalated. Touch NOTHING either direction -- this run could not
      # confirm safe or unsafe, so it is not evidence for either a close or
      # a file. lib.sh's own AC7 counter escalates this to rc 1 (a "suspect"
      # verdict) if it recurs 3 times running with no intervening clean, so
      # a race that is not actually transient still gets a durable
      # consequence eventually -- just not from a single indeterminate tick.
      echo "reconcile-guard: indeterminate (lock-busy/cas-lost — a lost race against a concurrent, benign writer) — not filing, not closing, re-checking next tick"
      return 2
      ;;
    *)
      # ESCALATE (rc 1, or any other unexpected nonzero -- fail toward
      # escalation, never toward silently doing nothing).
      if [ -n "$existing" ]; then
        # AC4 (#179): the divergence persisted across another push. Update
        # in place. Never file a second artifact.
        echo "reconcile-guard: divergence persists — updating existing artifact #$existing (no duplicate filed)"
        guard_body "$out" | "$GH" issue edit "$existing" --body-file - >/dev/null 2>&1 || true
      else
        echo "reconcile-guard: divergence detected — filing durable artifact"
        guard_body "$out" | "$GH" issue create --title "$GUARD_TITLE" --body-file - 2>&1 | tail -1
      fi
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
