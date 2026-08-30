#!/usr/bin/env bash
# fwf dash action layer (issue #40, milestone 2) — the WRITE side of the board.
#
# The compiled `fwf-dash` binary shells out to this on an action keypress
# (y/n/c/o on a decision, r/s on a role, t to the captain). Keeping the mutations
# in bash — alongside the read-only `fwf-dash-data.sh` — means the gh/local
# backend abstraction, the profile resolution, and the dryrun-seam tests all stay
# in one tested place; the binary just gathers the verb + args and renders the
# one-line result. The TUI collects free text (comment / captain message) in an
# inline modal and passes it as an argument, so nothing here reads the tty.
#
# Every mutation runs through `_run` (or the `di` write-router), so the hermetic
# tests assert the exact constructed command WITHOUT a tracker or tmux:
#   FWF_DASH_DRYRUN=1 prints `DRYRUN: <argv>` instead of executing — the same
# "assert the command" pattern as the gh-write-guard tests (#34). It also doubles
# as a real --dry-run for cautious operators.
#
# Verbs (see usage() / the case below):
#   approve <id>            un-gate (remove WIP_LABEL) + post the go-ahead
#   reject  <id> [text]     post a "needs changes" comment; issue stays gated
#   comment <id> <text>     post a comment
#   open    <id>            open in the browser (gh) / page the issue (local)
#   respawn <role>          fwf-respawn.sh <role>
#   stop                    fwf-stop.sh (swarm-wide graceful stop)
#   passthrough <text>      send-keys <text> to the captain pane
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
# Drive the factory on tmux's DEFAULT socket regardless of which tmux the dash is
# displayed in (role respawn/stop + captain passthrough send-keys must reach the
# factory's panes, not the dash's host session). See fwf-dash-data.sh for why.
unset TMUX

# Every mutation funnels through here; FWF_DASH_DRYRUN=1 prints the argv instead
# of running it (what the hermetic tests assert on).
_run() {
  if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then printf 'DRYRUN: %s\n' "$*"; return 0; fi
  "$@"
}

# Issue WRITES routed to the active backend, gh-shaped either way, through the
# dryrun seam. In local-issues mode this NEVER reaches gh (the #34 guard); in gh
# mode it runs with the target repo as cwd so it resolves the right project.
di() {
  if [ "$FWF_ISSUES" = "local" ]; then
    _run "$DIR/fwf-issues.sh" "$@"
  elif [ -d "$FWF_REPO/.git" ]; then
    ( cd "$FWF_REPO" && _run gh issue "$@" )   # subshell cd: portable (no GNU env -C)
  else
    _run gh issue "$@"
  fi
}

# Normalize an id: strip a leading LI- (local) or # so both backends take a bare
# number.
issue_num() { local n="${1:-}"; n="${n#LI-}"; n="${n#\#}"; printf '%s' "$n"; }

usage() {
  sed -n 's/^#   //p' "$0" | sed -n '/^approve <id>/,/^passthrough/p'
}

main() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    approve)
      local n; n="$(issue_num "${1:-}")"; [ -n "$n" ] || die "approve: need an issue id"
      # The comment carries the operator un-gate SENTINEL (issue #150): a
      # positive, attributable, greppable authorization signal emitted ONLY by
      # this human keypress on the board. `fwf authz <n>` verifies it, so "was
      # this approved?" has a checkable answer that no pane/ghost text can forge
      # — and, being a durable comment, it stays true even if a role wrongly
      # re-applies the gate. Comment BEFORE un-gating so the signal of record
      # exists the instant the label comes off.
      #
      # ANCHORED at column 0 (issue #218): the sentinel + issue reference must
      # be the FIRST thing on the comment's line, or the #218 matcher — which
      # no longer accepts a mid-sentence mention — will never see it. Bold
      # (**TOKEN #n**) matches the format the operator's own concierge-proxy
      # un-gates already use on this floor; the matcher tolerates that leading
      # markup specifically because this is the real, observed convention.
      # Body built via the shared fwf_ungate_comment_body() (issue #213), so
      # this path and `fwf ungate`'s can never drift in the anchored part.
      di comment "$n" --body "$(fwf_ungate_comment_body "$n" "approved via fwf dash: the human operator authorized this build by pressing approve on the board")"
      di edit "$n" --remove-label "$WIP_LABEL"
      # Write-through cache-bust (issue #167): the un-gate just changed the two
      # signals a role reads through the shared REST+ETag gh cache — the operator
      # sentinel (comment thread) and the removed WIP label (canonical open-issues
      # snapshot). Drop their staleness stamps so the un-gate is visible on the
      # very NEXT authz/impl-survey read instead of up to a full TTL later; the
      # kept ETags keep that refresh near-free. gh backend only — the local store
      # has no cache to bust.
      [ "$FWF_ISSUES" = "local" ] || _run "$DIR/fwf-ghcache.sh" invalidate issue "$n";;
    reject)
      local n; n="$(issue_num "${1:-}")"; [ -n "$n" ] || die "reject: need an issue id"; shift || true
      di comment "$n" --body "${*:-Not yet — needs changes before this is ready to build (via fwf dash). Staying gated.}";;
    comment)
      local n; n="$(issue_num "${1:-}")"; [ -n "$n" ] || die "comment: need an issue id"; shift || true
      [ -n "${*:-}" ] || die "comment: empty body"
      di comment "$n" --body "$*";;
    open)
      local n; n="$(issue_num "${1:-}")"; [ -n "$n" ] || die "open: need an issue id"
      if [ "$FWF_ISSUES" = "local" ]; then
        # The local store has no web view. The TUI sets FWF_DASH_NO_PAGER (its
        # alt-screen can't host a pager) and just shows the body in the Detail
        # pane, so here we only confirm; a CLI caller still gets the pager.
        if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then printf 'DRYRUN: fwf-issues.sh view %s --comments\n' "$n"
        elif [ "${FWF_DASH_NO_PAGER:-0}" = 1 ]; then printf 'local issue %s — shown in the Detail pane (no web view)\n' "$n"
        else "$DIR/fwf-issues.sh" view "$n" --comments | ${PAGER:-less -R}; fi
      else
        di view "$n" --web
      fi;;
    respawn)
      local role="${1:-}"; [ -n "$role" ] || die "respawn: need a role"
      _run "$DIR/fwf-respawn.sh" "$role";;
    stop)
      _run "$DIR/fwf-stop.sh";;
    passthrough)
      local msg cp; msg="$*"
      [ -n "${msg:-}" ] || die "passthrough: empty message"
      cp="$(fwf_find_pane "$COORD_SESSION" "CAPTAIN" || true)"
      [ -n "$cp" ] || die "passthrough: no CAPTAIN pane in '$COORD_SESSION' (is the factory up?)"
      if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then
        printf 'DRYRUN: tmux send-keys -t %s -l %s\n' "$cp" "$msg"
      else
        fwf_clear_composer "$cp"
        tmux send-keys -t "$cp" -l "$msg"; sleep 0.3
        tmux send-keys -t "$cp" Enter; sleep 0.3
        tmux send-keys -t "$cp" Enter
        printf 'sent to CAPTAIN (%s)\n' "$cp"
      fi;;
    ""|-h|--help|help) usage;;
    *) die "act: unknown verb '${verb:-}' (approve|reject|comment|open|respawn|stop|passthrough)";;
  esac
}
main "$@"
