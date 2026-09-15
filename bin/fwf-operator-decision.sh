#!/usr/bin/env bash
# fwf-operator-decision.sh — issue #192: a documented, artifact-first
# operator→captain channel, for the moment a floor-wide HELD needs a human
# call and the board keypress isn't available (operator away from the
# board). The 2026-08-23 incident this closes: the only path to unblock a
# correctly-HELD floor was reading fwf-dash-act.sh's `passthrough` source —
# an undiscoverable, chat-shaped `tmux send-keys` into the captain pane.
#
# THE PANE MESSAGE IS A POINTER, NEVER THE PAYLOAD. Documenting `passthrough`
# directly would make the authorization gate's override callable by the very
# role agents it holds — any process on this box can run a CLI verb. So this
# verb inverts what carries the decision:
#   1. writes an attributable ARTIFACT — a comment on the target issue/PR —
#      which is the record;
#   2. degrades the pane send-keys to a fixed-length NOTIFICATION naming the
#      issue, carrying no decision content;
#   3. the captain re-derives the decision by reading the artifact and
#      running `fwf authz` — it never trusts pane text (issue #150).
#
# NO ATTRIBUTION PREFIX. Every fwf-self role shares one GitHub account, so
# the artifact this writes is durable and reviewable, not attributable — a
# forgeable "from the operator" claim would train the captain to trust the
# forgeable thing. The channel confers NO authorization: `fwf authz` is the
# sole oracle (issue #150), and this verb is structurally incapable of
# emitting its sentinel — a message containing OPERATOR_UNGATE_SENTINEL is
# refused outright, never neutralised-and-posted.
#
# Usage:
#   fwf operator-decision <n> <text>       post to issue/PR <n>
#   fwf operator-decision --floor <text>   post to the profile's configured
#                                          floor issue (FWF_FLOOR_ISSUE);
#                                          refuses if unconfigured rather
#                                          than guessing a destination.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
# Drive the factory on tmux's DEFAULT socket regardless of which tmux this
# verb is invoked from (fwf-dash-act.sh's passthrough does the same, for the
# same reason) — the pane notification must reach the FACTORY's captain
# pane, not whatever session this shell happens to be attached to.
unset TMUX

die() { echo "fwf operator-decision: $*" >&2; exit 1; }

usage() { echo "usage: fwf operator-decision <n> <text> | fwf operator-decision --floor <text>" >&2; }

# --- gh backend --------------------------------------------------------------
gh_() { if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh "$@" ); else gh "$@"; fi; }

# GitHub shares one number sequence across issues and PRs (same detection
# fwf-flag-captain.sh uses) — `gh issue`/`gh pr` each fail on the other
# kind's number, so this decides which verb to call.
gh_kind() { # $1=num -> "issue"|"pr"
  local pr
  pr="$(gh_ api "repos/{owner}/{repo}/issues/$1" --jq '.pull_request // empty' 2>/dev/null || true)"
  [ -n "$pr" ] && echo pr || echo issue
}
# -> prints the item's state (OPEN/CLOSED/MERGED) on stdout, or fails
# (nonzero, nothing on stdout) if the item can't be read — including "does
# not exist". The caller treats a failed read as refusal to guess a
# destination, never as license to post anyway.
gh_state() { # $1=num
  if [ "$(gh_kind "$1")" = pr ]; then gh_ pr view "$1" --json state --jq .state 2>/dev/null
  else gh_ issue view "$1" --json state --jq .state 2>/dev/null
  fi
}
gh_post() { # $1=num $2=body
  if [ "$(gh_kind "$1")" = pr ]; then gh_ pr comment "$1" --body "$2"
  else gh_ issue comment "$1" --body "$2"
  fi
}

# --- local backend (fwf-issues.sh) -------------------------------------------
local_state() { "$DIR/fwf-issues.sh" view "$1" --json state --jq .state 2>/dev/null; }
local_post()  { "$DIR/fwf-issues.sh" comment "$1" --body "$2" >/dev/null; }

main() {
  local target msg

  if [ "${1:-}" = "--floor" ]; then
    shift
    # Edge case (spec): no natural target and no configured floor issue is a
    # refusal, never an invented destination.
    [ -n "${FLOOR_ISSUE:-}" ] || die "--floor: no floor issue configured (set FWF_FLOOR_ISSUE in the profile) — refusing rather than guessing a destination"
    target="$FLOOR_ISSUE"
  else
    case "${1:-}" in
      ''|*[!0-9]*) usage; die "need an issue number, or --floor";;
      *) target="$1"; shift;;
    esac
  fi

  msg="$*"
  [ -n "$msg" ] || die "empty message"

  # AC(d): sentinel injection is refused outright — a message that could mint
  # an AUTHORIZED verdict through this verb must never be posted, neutralised
  # or otherwise. This is the concrete form of "this channel confers no
  # authorization."
  case "$msg" in
    *"$OPERATOR_UNGATE_SENTINEL"*)
      die "message contains the operator un-gate sentinel ($OPERATOR_UNGATE_SENTINEL) — refusing. This channel confers no authorization; fwf authz is the sole oracle. Rephrase the message, or use the board/concierge un-gate if you mean to authorize a build.";;
  esac

  local state
  if [ "$FWF_ISSUES" = "local" ]; then
    state="$(local_state "$target")" || die "issue $target not found (local store) — refusing to post nowhere"
  else
    state="$(gh_state "$target")" || die "issue/PR $target not found (or unreadable) — refusing to post nowhere"
  fi
  [ "$state" = "OPEN" ] || die "issue/PR $target is $state — refusing to post a decision to a closed item"

  # No attribution prefix (AC g): OPERATOR-DECISION: labels what the comment
  # IS (a delivered channel message), never who wrote it — any process on
  # this box can run this verb, so the artifact is durable and reviewable,
  # not attributable. The trust boundary is restated inline so a reader who
  # lands on the comment without the docs still sees it.
  local body="OPERATOR-DECISION: $msg

Not an authorization signal — fwf authz is the sole oracle (issue #150). Delivered via \`fwf operator-decision\`; durable and reviewable, not attributable — every fwf-self role shares one GitHub account, and any process on this box can run this verb."

  if [ "$FWF_ISSUES" = "local" ]; then local_post "$target" "$body"
  else gh_post "$target" "$body" >/dev/null
  fi
  echo "operator-decision: posted to #$target"

  # Pane notification: a fixed-length POINTER only, never the payload
  # (AC e) — degrades to a plain report if no CAPTAIN pane is up, since the
  # artifact above is already the record and must not depend on the pane
  # being alive (edge case: captain respawning / floor down).
  local cp
  cp="$(fwf_find_pane "$COORD_SESSION" "CAPTAIN" || true)"
  if [ -z "$cp" ]; then
    echo "operator-decision: pane notification NOT delivered — no CAPTAIN pane in '$COORD_SESSION' (the comment on #$target is still the record)"
    return 0
  fi
  local pointer="operator message on #$target — go read it."
  if [ "${FWF_OPERATOR_DECISION_DRYRUN:-0}" = 1 ]; then
    printf 'DRYRUN: tmux send-keys -t %s -l %s\n' "$cp" "$pointer"
  else
    fwf_clear_composer "$cp"
    tmux send-keys -t "$cp" -l "$pointer"; sleep 0.3
    tmux send-keys -t "$cp" Enter; sleep 0.3
    tmux send-keys -t "$cp" Enter
    echo "operator-decision: notified CAPTAIN ($cp)"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
