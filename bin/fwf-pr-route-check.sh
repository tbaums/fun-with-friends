#!/usr/bin/env bash
# fwf-pr-route-check.sh — issue #385: a PR opened outside the implementer
# flow (a captain/gv/pm/conductor hotfix, or any branch not matching
# implN/*) that carries no `fwf-Reviewer:` marker resolves to NO_MARKER from
# `fwf pr-reviewer` -- correctly, per #194 -- but nothing OBLIGES anyone to
# act on that verdict. It surfaces in no seat's queue, raises no flag, and
# is only routed if a human/captain happens to notice it in the open-PR
# list. Twice in one day (#380, #384) it sat unrouted -- once for 24 minutes
# while it was the sole blocker on a release -- and was only caught because
# the captain happened to be mid-survey. Same shape as #374 (a flag raised
# into a place nothing polls) and #377 (a claim resolved on a proxy that
# does not track liveness): a correct verdict with no obliged call site.
#
# THE FIX: reuse the existing needs-captain mechanism (#113) rather than
# inventing a new channel. `fwf flag-captain sweep` is ALREADY run, ENFORCED,
# on every captain tick -- so raising into it (not printing to some other
# unread place) is what makes the signal obliged rather than another correct
# verdict nobody has to look at.
#
# WHAT COUNTS AS "UNROUTED": an open, non-draft PR whose head branch does
# NOT match the implN/* fallback pattern (fwf-pr-assign-reviewer.sh's own
# convention) -- an implN/* PR already routes via qa.tmpl's permanent
# fallback (docs/shared-account.md:262-267), so flagging it would be noise
# for a case that is not actually stranded -- AND whose `fwf pr-reviewer`
# verdict is NO_MARKER, AND has been open at least FWF_PR_ROUTE_GRACE_SECS.
#
# GRACE PERIOD (AC 2): defaults to 300s (FWF_PR_ROUTE_GRACE_SECS). Chosen to
# comfortably clear FWF_GHCACHE_TTL (60s default -- several cache refreshes
# fit inside it, so a transient stale-cache read of a just-created PR can
# never look "unrouted" for the whole window) while staying far below the
# ~24-minute real incident this ticket exists to prevent -- the flag still
# fires with plenty of margin before an unrouted PR can block a release.
#
# IDEMPOTENT + CLEARABLE (AC 4): raising and clearing both go through
# fwf-flag-captain.sh, whose own append/clear semantics (#113) already do
# the right thing -- a raise here is skipped if OUR tag ([pr-route-check])
# is already active on that item (no duplicate-raise spam every tick,
# reusing sweep's own active/cleared computation rather than a second
# hand-rolled copy of it), and a PR that resolves to a real seat/none is
# auto-cleared on the next sweep with no human step.
#
# NOT IN SCOPE (AC 3, matching the ticket): never assigns a reviewer itself
# -- this only raises/clears a SIGNAL. Guessing from a branch prefix here
# would reintroduce #194's original defect.
#
# Usage: fwf pr-route-check sweep
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

ROUTE_ROLE="pr-route-check"
GRACE_SECS="${FWF_PR_ROUTE_GRACE_SECS:-300}"

# --- gh access (overridable by tests, same shape as fwf-pr-assign-reviewer.sh)
gh_pr_list() { # -> [{number,headRefName,isDraft,createdAt,baseRefName}]
  if [ -d "$FWF_REPO/.git" ]; then
    ( cd "$FWF_REPO" && gh pr list --state open --json number,headRefName,isDraft,createdAt,baseRefName )
  else
    gh pr list --state open --json number,headRefName,isDraft,createdAt,baseRefName
  fi
}
pr_reviewer_verdict() { # $1=pr -> seat|none|NO_MARKER|UNKNOWN
  "$DIR/fwf-pr-reviewer.sh" "$1"
}
flag_captain_sweep() { "$DIR/fwf-flag-captain.sh" sweep; }
flag_captain_raise() { "$DIR/fwf-flag-captain.sh" "$1" --role "$ROUTE_ROLE" --reason "$2"; }
flag_captain_clear() { "$DIR/fwf-flag-captain.sh" "$1" --clear --note "$2"; }

# already_routed_flag_active $1=pr -> 0 if our own [pr-route-check] tag is
# an ACTIVE row in the current sweep for that PR. Reuses sweep's own
# active-vs-cleared computation (raise/append/clear-resets, #113) instead of
# re-deriving it from comments a second time -- one source of truth.
already_flag_active() {
  printf '%s\n' "$SWEEP_NOW" | grep -qE "^#${1}([[:space:]]|\().*\[${ROUTE_ROLE}\]"
}

now_epoch() { date -u +%s; }
age_secs() { # $1=ISO8601 createdAt -> seconds elapsed (portable GNU/BSD date)
  local created_epoch
  created_epoch="$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)" \
    || { echo ""; return 1; }
  echo "$(( $(now_epoch) - created_epoch ))"
}

cmd_sweep() {
  local prs n num branch draft base created age verdict reason
  prs="$(gh_pr_list)" || { echo "fwf pr-route-check: gh pr list failed (UNKNOWN, not empty)" >&2; return 1; }
  SWEEP_NOW="$(flag_captain_sweep)" || { echo "fwf pr-route-check: flag-captain sweep failed" >&2; return 1; }

  n="$(jq 'length' <<<"$prs")" || { echo "fwf pr-route-check: bad PR list JSON" >&2; return 1; }
  local i=0
  while [ "$i" -lt "$n" ]; do
    num="$(jq -r ".[$i].number" <<<"$prs")"
    branch="$(jq -r ".[$i].headRefName" <<<"$prs")"
    draft="$(jq -r ".[$i].isDraft" <<<"$prs")"
    base="$(jq -r ".[$i].baseRefName" <<<"$prs")"
    created="$(jq -r ".[$i].createdAt" <<<"$prs")"
    i=$((i + 1))

    [ "$draft" = "true" ] && continue
    [ "$base" = "$STAGING_BRANCH" ] || continue
    case "$branch" in impl[0-9]*/*) continue;; esac  # already covered by qa.tmpl's fallback

    verdict="$(pr_reviewer_verdict "$num")" || verdict="UNKNOWN"

    if [ "$verdict" != "NO_MARKER" ]; then
      # routed (a seat/none) or genuinely unreadable this tick -- either
      # way it is not "unrouted", so clear our own flag if one is active.
      if [ "$verdict" != "UNKNOWN" ] && already_flag_active "$num"; then
        flag_captain_clear "$num" "routed: fwf pr-reviewer now resolves to '$verdict' (#385)" >/dev/null
        echo "#$num: cleared (routed to $verdict)"
      fi
      continue
    fi

    age="$(age_secs "$created")" || { echo "#$num: could not compute age, skipping this tick" >&2; continue; }
    if [ "$age" -lt "$GRACE_SECS" ]; then
      echo "#$num: NO_MARKER but within the ${GRACE_SECS}s grace period (${age}s old) -- not yet flagged"
      continue
    fi

    if already_flag_active "$num"; then
      echo "#$num: already flagged (idempotent, no duplicate raise)"
      continue
    fi

    reason="unrouted PR: opened ${age}s ago on branch '$branch' (not implN/*), fwf pr-reviewer=NO_MARKER (#385)"
    flag_captain_raise "$num" "$reason" >/dev/null
    echo "#$num: flagged (unrouted, ${age}s old)"
  done
}

main() {
  case "${1:-}" in
    sweep) cmd_sweep;;
    *) echo "fwf pr-route-check: usage: fwf pr-route-check sweep" >&2; return 1;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
