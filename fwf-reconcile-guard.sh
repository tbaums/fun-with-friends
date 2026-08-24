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

main() {
  local out grc existing
  grc=0
  out="$("$RECONCILE_SCRIPT" "$@" 2>&1)" || grc=$?
  printf '%s\n' "$out"

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
