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
      di comment "$n" --body "go ahead — approved via fwf dash; removing $WIP_LABEL so implementers can claim it."
      di edit "$n" --remove-label "$WIP_LABEL";;
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
        if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then printf 'DRYRUN: fwf-issues.sh view %s --comments\n' "$n"
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
