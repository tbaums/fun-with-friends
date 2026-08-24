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
#   Arguments are passed straight through to `fwf reconcile`.
#   Exit 0 = reconcile clean (and any open artifact was closed), OR every
#            non-safe branch was cas-lost only (issue #238) -- a lost
#            compare-and-swap against a CONCURRENT, benign writer, not a
#            divergence. Self-healing: re-classified next tick, no artifact
#            filed or closed either way, this run just couldn't confirm.
#   Exit 1 = a REAL divergence (halted-diverged/suspect) persists; an open
#            artifact exists and names it.
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
  local out existing
  out="$("$RECONCILE_SCRIPT" "$@" 2>&1)" || true
  printf '%s\n' "$out"

  # fwf_reconcile_branch (lib.sh) returns rc 1 alike for halted-diverged,
  # suspect, AND cas-lost -- but those are NOT alike. halted-diverged/suspect
  # genuinely need a human. cas-lost is a lost compare-and-swap against a
  # CONCURRENT, benign writer (another reconcile tick, a release) -- lib.sh's
  # own comment on it: "re-classify next tick, don't assume-safe in the
  # meantime." That is a self-healing race, not a divergence, so the combined
  # rc must never be trusted here -- classify per LINE instead (issue #238).
  local escalate=0 caslost_only=0
  printf '%s\n' "$out" | grep -qE '^(halted-diverged|suspect) ' && escalate=1
  printf '%s\n' "$out" | grep -qE '^cas-lost ' && caslost_only=1
  [ "$escalate" -eq 1 ] && caslost_only=0

  existing="$(guard_find)"

  if [ "$caslost_only" -eq 1 ]; then
    # AC1: do not file. AC3: do not close either -- a cas-lost run is NOT
    # evidence a real divergence resolved, so an existing artifact is left
    # exactly as it was for the next tick's genuine verdict to act on.
    echo "reconcile-guard: cas-lost only (self-healing race, ref moved under a concurrent writer) — not filing, not closing, re-checking next tick"
    return 0
  fi

  if [ "$escalate" -eq 0 ]; then
    if [ -n "$existing" ]; then
      echo "reconcile-guard: clean — closing artifact #$existing"
      "$GH" issue comment "$existing" --body "Resolved: \`fwf reconcile\` returned clean on a later push to \`${DEFAULT_BRANCH}\`. Closing automatically." >/dev/null 2>&1 || true
      "$GH" issue close "$existing" >/dev/null 2>&1 || true
    else
      echo "reconcile-guard: clean — no artifact to close"
    fi
    return 0
  fi

  if [ -n "$existing" ]; then
    # AC4: the divergence persisted across another push. Update in place.
    # Never file a second artifact.
    echo "reconcile-guard: divergence persists — updating existing artifact #$existing (no duplicate filed)"
    guard_body "$out" | "$GH" issue edit "$existing" --body-file - >/dev/null 2>&1 || true
  else
    echo "reconcile-guard: divergence detected — filing durable artifact"
    guard_body "$out" | "$GH" issue create --title "$GUARD_TITLE" --body-file - 2>&1 | tail -1
  fi
  return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
