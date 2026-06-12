#!/usr/bin/env bash
# fwf dash (issue #40) — a k9s-style captain dashboard: a persistent, deterministic
# status board + an actionable decision inbox. Judgment stays in the captain's chat
# session; STATE DISPLAY and DECISION ERGONOMICS move here so the human can look at
# current status any time without scrolling, and act on a gated issue with y/n/c/o.
#
# Bash-native MVP, in the repo's grain (one ubiquitous dep: fzf). No daemon, no LLM
# in the read path or the button path. The DATA IS DERIVED FIRST, so the dashboard
# works with the factory parked:
#   roles    <- tmux pane state (alive? + current command)
#   pipeline <- git branch deltas in the target repo
#   decisions<- the label protocol: open + WIP_LABEL + a "GV-SIGNOFF" comment ⇒
#               awaiting the human's go-ahead (the exact gate the PM/captain honor)
# The captain's tick MAY write state/<profile>/status.json (prod/pipeline/per-role
# detail/recommendations + release decisions); the board OVERLAYS it when fresh and
# degrades gracefully when it is stale or absent. See docs/dash.md for the schema.
#
# ACTIONS route through the SAME `fwf issues` abstraction the factory uses, so the
# gh and local-issues backends behave identically — `y` posts the standard approval
# comment + un-gates (removes WIP_LABEL); the captain reacts on its next tick, exactly
# as if the human had typed in the issue. r/s wrap fwf-respawn.sh/fwf-stop.sh; `t`
# send-keys a one-liner to the captain pane without leaving the dashboard.
#
# Subcommands (the launcher wires the interactive panes to the rest):
#   (default)         open the TUI: a tmux window, status-board loop + fzf inbox
#   board             render the status board once (top pane loops this)
#   decisions         emit the decision-inbox rows (TSV id<TAB>flags<TAB>title)
#   issues            emit every open issue (the issues tab), same row shape
#   roles             emit the role roster (TSV role<TAB>state<TAB>detail)
#   preview <id>      render one issue (body + thread) for the fzf preview / pager
#   act <verb> [args] perform an action (see `act` below) — the button path
#   help
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

die() { echo "fwf dash: $*" >&2; exit 1; }

# Per-profile judgment overlay the captain's tick may write. Freshness is decided
# by the FILE's mtime (portable, jq-free); the overlay's CONTENT needs jq, and when
# jq is absent the board simply renders derived-only — never an error.
STATE_DIR="$FWF_RUN/state/$PROFILE"
STATUS_JSON="$STATE_DIR/status.json"
DASH_STALE_SECS="${FWF_DASH_STALE_SECS:-90}"   # captain ticks every CAPTAIN_INTERVAL (2m); 90s = "this tick"

# Portable mtime (BSD stat -f, GNU stat -c). Echoes epoch seconds, or nothing.
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true; }
# True when status.json exists and is younger than DASH_STALE_SECS.
status_fresh() {
  local m age
  [ -f "$STATUS_JSON" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  m="$(file_mtime "$STATUS_JSON")"; [ -n "$m" ] || return 1
  age=$(( $(date +%s) - m ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$DASH_STALE_SECS" ]
}
# Read one jq expression from status.json; empty string on any failure.
status_q() { status_fresh || { echo ""; return 0; }; jq -r "$1" "$STATUS_JSON" 2>/dev/null || echo ""; }

# --- the action seam --------------------------------------------------------
# Every mutation runs through _run so the hermetic tests can assert the exact
# command WITHOUT a tracker or tmux (FWF_DASH_DRYRUN=1 prints the argv instead of
# executing it) — the same "assert the constructed command" pattern as the
# gh-write-guard tests. It doubles as a real `--dry-run` for cautious operators.
_run() {
  if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then printf 'DRYRUN: %s\n' "$*"; return 0; fi
  "$@"
}

# `di` — issue access routed to the ACTIVE backend, gh-shaped either way. Read
# verbs (list/view) are called directly; write verbs go through `di` too so the
# dryrun seam catches them. gh runs with the target repo as its cwd so it resolves
# the right GitHub project; the local store is repo-independent.
di() {
  if [ "$FWF_ISSUES" = "local" ]; then
    _run "$DIR/fwf-issues.sh" "$@"
  else
    _run gh issue "$@"
  fi
}
# Read variants never go through the dryrun seam (they must return real data even
# in dryrun mode, e.g. to derive the decision list under test) and gh reads run in
# the repo dir. Local reads are cwd-independent.
di_read() {
  if [ "$FWF_ISSUES" = "local" ]; then
    "$DIR/fwf-issues.sh" "$@"
  elif [ -d "$FWF_REPO/.git" ]; then
    ( cd "$FWF_REPO" && gh issue "$@" )
  else
    gh issue "$@"
  fi
}

# Normalize a tracker number to the bare integer the backends' write verbs expect
# (gh: 384 · local: 384 — strips a display "LI-"/"#" if one slips in).
issue_num() { local n="$1"; n="${n#LI-}"; n="${n#\#}"; printf '%s' "$n"; }

# --- derivation: issues -----------------------------------------------------
# Open issues, optionally filtered to one label, as "number<TAB>title" rows. Both
# backends print number-first / title-second TSV in non-interactive mode, so one
# parse serves both (no jq needed on the read path).
list_open() { # $1=label-or-empty
  local args
  args="list --state open"
  [ -n "${1:-}" ] && args="$args --label $1"
  # Best-effort read: the board degrades gracefully when the tracker is
  # unreachable. `|| true` also absorbs the local backend's `list` exiting
  # non-zero in plain (non-JSON) mode — a benign quirk that set -e would amplify.
  # shellcheck disable=SC2086  # word-splitting the flag string is intentional
  { di_read $args 2>/dev/null || true; } | awk -F'\t' 'NF>=2 { n=$1; sub(/^LI-/,"",n); sub(/^#/,"",n); print n "\t" $2 }'
}

# Does an issue carry a current GV sign-off? The gate the human waits behind: the
# GV posts a comment whose first line is "GV-SIGNOFF" once the spec is top-notch.
# Captured-then-matched (not `… | grep -q`): a piped grep that exits on first match
# SIGPIPEs the still-writing producer, which `set -o pipefail` would read as failure.
has_gv_signoff() { # $1=number
  local thread; thread="$(di_read view "$1" --comments 2>/dev/null || true)"
  case "$thread" in *GV-SIGNOFF*) return 0;; *) return 1;; esac
}

# --- views ------------------------------------------------------------------
# Decision inbox: derived gated items (open + WIP_LABEL + GV-SIGNOFF) enriched with
# the captain's recommendation from status.json when fresh, PLUS any non-issue
# decisions the captain queued (e.g. a release) that have no gated issue of their own.
cmd_decisions() {
  local num title rec
  while IFS="$(printf '\t')" read -r num title; do
    [ -n "$num" ] || continue
    has_gv_signoff "$num" || continue
    rec=""
    status_fresh && rec="$(status_q ".decisions[]? | select((.issue|tostring)==\"$num\") | .recommendation // \"\"")"
    printf '%s\t%s\t%s\n' "$num" "$(_flagcol "GV ✓✓" "$rec")" "$title"
  done <<EOF
$(list_open "$WIP_LABEL")
EOF
  # Captain-queued decisions that are not gated issues (release gates, etc).
  if status_fresh; then
    status_q '.decisions[]? | select((.kind // "")=="release") | [(.id // "REL"), (.gv // ""), .title] | @tsv' \
      | while IFS="$(printf '\t')" read -r id gv title; do
          [ -n "${id:-}" ] || continue
          printf '%s\t%s\t%s\n' "$id" "$(_flagcol "$gv" "")" "$title"
        done
  fi
}

# A compact "flags" column: "GV ✓✓   captain: ship". Kept narrow for the inbox row.
_flagcol() { # $1=gv-marker $2=recommendation
  local out="${1:-}"
  [ -n "${2:-}" ] && out="${out:+$out · }captain: $2"
  printf '%s' "$out"
}

# Issues tab: every open issue (not just gated ones), same row shape so the same
# open/comment keys work. The flags column marks gated issues — the gated set is
# derived ONCE (jq-free) from the label filter, not per-issue.
cmd_issues() {
  local nl gated num title flag
  nl=$'\n'   # a literal newline ($(printf '\n') would be stripped to empty)
  gated="$nl$(list_open "$WIP_LABEL" | cut -f1)$nl"
  while IFS="$(printf '\t')" read -r num title; do
    [ -n "$num" ] || continue
    flag=""
    case "$gated" in *"$nl$num$nl"*) flag="gated";; esac
    printf '%s\t%s\t%s\n' "$num" "$flag" "$title"
  done <<EOF
$(list_open "")
EOF
}

# Roles roster: derived liveness (● up / ○ down) from tmux pane state, overlaid with
# the captain's per-role detail (#issue + title) from status.json when fresh.
cmd_roles() {
  local role sess token pane state detail cmd
  for role in $(fwf_all_roles); do
    case "$role" in
      impl*|qa*|conductor) sess="$BUILD_SESSION";;
      pm|gv|captain)       sess="$COORD_SESSION";;
      *) case "$(fwf_extra_session "$role" 2>/dev/null)" in   # honor a template extra role's session
           build) sess="$BUILD_SESSION";; *) sess="$COORD_SESSION";;
         esac;;
    esac
    token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
    case "$role" in impl*|qa*) token="$token ·";; esac
    pane="$(fwf_find_pane "$sess" "$token" 2>/dev/null || true)"
    if [ -n "$pane" ]; then
      cmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
      case "$cmd" in bash|zsh|sh|fish|"") state="○ idle";; *) state="● live";; esac
    else
      state="· down"
    fi
    detail=""
    status_fresh && detail="$(status_q ".roles[]? | select(.id==\"$role\") | \"#\"+(.issue|tostring)+\" \"+(.title // \"\")")"
    printf '%s\t%s\t%s\n' "$role" "$state" "$detail"
  done
}

# --- the status board (top pane) --------------------------------------------
# A single deterministic render: a header (profile · template · prod · freshness),
# the role roster, the pipeline line, and the decision count. The top pane loops it.
cmd_board() {
  local prod pipeline parked ndec stamp
  prod="—"; pipeline="—"
  if status_fresh; then
    prod="$(status_q '.prod // "—"')"; [ -n "$prod" ] || prod="—"
    pipeline="$(status_q '.pipeline // "—"')"; [ -n "$pipeline" ] || pipeline="—"
    stamp="status.json ✓"
  else
    pipeline="$(derive_pipeline)"
    stamp="$([ -f "$STATUS_JSON" ] && echo 'status.json stale' || echo 'derived')"
  fi
  parked=""
  [ -f "$STOP_FILE" ] && parked="  · ⏸ PARKED (STOP)"
  ndec="$(cmd_decisions | grep -c . || true)"

  printf 'fwf · %s · %s    prod %s · %s%s\n' "$PROFILE" "$FWF_TEMPLATE" "$prod" "$stamp" "$parked"
  printf '\n'
  printf 'ROLES\n'
  cmd_roles | while IFS="$(printf '\t')" read -r role state detail; do
    printf '  %-10s %-7s %s\n' "$role" "$state" "$detail"
  done
  printf '\nPIPELINE  %s\n' "$pipeline"
  printf '\nDECISIONS (%s)  — switch to the inbox below: j/k move · enter open · y/n/c/o · r/s roles · t captain\n' "$ndec"
}

# Pipeline derived from the TARGET repo's branch deltas (best-effort; the captain's
# status.json supersedes this when fresh). Counts commits each branch is ahead of
# the next, and flags when integration == default (i.e. main is at the release point).
derive_pipeline() {
  local repo="$FWF_REPO" sa=0 ic="clean" md="main=prod"
  [ -d "$repo/.git" ] || { printf '—'; return 0; }
  sa="$(git -C "$repo" rev-list --count "${INTEGRATION_BRANCH}..${STAGING_BRANCH}" 2>/dev/null || echo 0)"
  if [ "$(git -C "$repo" rev-list --count "${DEFAULT_BRANCH}..${INTEGRATION_BRANCH}" 2>/dev/null || echo 0)" != "0" ]; then
    ic="ahead"; md="integration > $DEFAULT_BRANCH"
  fi
  printf '%s +%s ahead · %s %s · %s' "$STAGING_BRANCH" "$sa" "$INTEGRATION_BRANCH" "$ic" "$md"
}

# --- preview / pager --------------------------------------------------------
cmd_preview() { # $1=id
  local n; n="$(issue_num "${1:-}")"
  [ -n "$n" ] || { echo "(no issue selected)"; return 0; }
  di_read view "$n" --comments 2>/dev/null || echo "(could not load issue $n)"
}

# Prompt for one line on the controlling terminal (works under fzf's execute(),
# which restores the tty). Echoes what was typed; empty on EOF/no tty.
_prompt() { # $1=prompt-text
  local r=""
  printf '%s' "$1" >&2
  [ -r /dev/tty ] && IFS= read -r r </dev/tty || true
  printf '%s' "$r"
}

# --- actions (the button path) ----------------------------------------------
# act <verb> [args]:
#   approve <id>          un-gate (remove WIP_LABEL) + post the standard go-ahead
#   reject  <id> [reason] post a rejection comment; the issue stays gated
#   comment <id> [text]   post a comment (prompts on the tty when text is omitted)
#   open    <id>          open in the browser (gh) / page the issue (local)
#   respawn <role>        fwf-respawn.sh <role>
#   stop                  fwf-stop.sh (swarm-wide graceful stop)
#   passthrough [text]    send-keys to the captain pane (prompts when omitted)
cmd_act() {
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
      local n msg; n="$(issue_num "${1:-}")"; [ -n "$n" ] || die "comment: need an issue id"; shift || true
      msg="$*"; [ -n "$msg" ] || msg="$(_prompt 'comment> ')"
      [ -n "$msg" ] || { echo "fwf dash: empty comment — skipped" >&2; return 0; }
      di comment "$n" --body "$msg";;
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
      local msg cp; msg="$*"; [ -n "${msg:-}" ] || msg="$(_prompt 'captain> ')"
      [ -n "${msg:-}" ] || { echo "fwf dash: empty message — skipped" >&2; return 0; }
      cp="$(fwf_find_pane "$COORD_SESSION" "CAPTAIN" || true)"
      [ -n "$cp" ] || die "passthrough: no CAPTAIN pane in '$COORD_SESSION' (is the factory up?)"
      if [ "${FWF_DASH_DRYRUN:-0}" = 1 ]; then
        printf 'DRYRUN: tmux send-keys -t %s -l %s\n' "$cp" "$msg"
      else
        fwf_clear_composer "$cp"
        tmux send-keys -t "$cp" -l "$msg"; sleep 0.3
        tmux send-keys -t "$cp" Enter; sleep 0.3
        tmux send-keys -t "$cp" Enter
        echo "fwf dash: sent to CAPTAIN ($cp)"
      fi;;
    *) die "act: unknown verb '${verb:-}' (approve|reject|comment|open|respawn|stop|passthrough)";;
  esac
}

# --- the interactive launcher (default) -------------------------------------
# A dedicated tmux window: a top status-board pane on a plain refresh loop, and a
# bottom fzf inbox whose preview is the issue body and whose keybinds are the
# actions. fzf's reload keeps the inbox live; nothing here is a daemon. Tabs switch
# the inbox between decisions / issues / roles.
cmd_launch() {
  command -v fzf >/dev/null 2>&1 || die "the dashboard needs fzf (brew/apt install fzf)"
  command -v tmux >/dev/null 2>&1 || die "the dashboard needs tmux"

  # Materialize the two pane commands as small scripts under the run dir (rewritten
  # each launch, so nothing leaks and nothing is stale). tmux then just runs
  # `bash <script>` — no giant double-quoted command strings to mis-escape — and the
  # scripts EXPORT the resolved context so every fzf bind can call this script plainly
  # (no per-bind profile prefix, no nested $()). Prompts are read inside `act` from
  # /dev/tty, which fzf's execute() makes available.
  local rundir="$FWF_RUN/dash/$PROFILE"
  mkdir -p "$rundir"
  local board="$rundir/board.sh" inbox="$rundir/inbox.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf "export FWF_PROFILE=%s FWF_RUN_DIR=%s FWF_ISSUES=%s FWF_TEMPLATE=%s\n" \
      "$(_q "$PROFILE")" "$(_q "$FWF_RUN")" "$(_q "$FWF_ISSUES")" "$(_q "$FWF_TEMPLATE")"
    printf "while :; do clear; %s board; sleep 3; done\n" "$(_q "$DIR/fwf-dash.sh")"
  } > "$board"
  {
    printf '#!/usr/bin/env bash\n'
    printf "export FWF_PROFILE=%s FWF_RUN_DIR=%s FWF_ISSUES=%s FWF_TEMPLATE=%s\n" \
      "$(_q "$PROFILE")" "$(_q "$FWF_RUN")" "$(_q "$FWF_ISSUES")" "$(_q "$FWF_TEMPLATE")"
    printf 'D=%s\n' "$(_q "$DIR/fwf-dash.sh")"
    cat <<'INBOX'
HDR_D='DECISIONS · enter preview · y approve · n reject · c comment · o open · F2 issues · F3 roles · t captain'
HDR_I='ISSUES (all open) · enter preview · c comment · o open · F1 decisions · F3 roles'
HDR_R='ROLES · r respawn · s stop (swarm) · F1 decisions · F2 issues'
"$D" decisions | fzf --ansi --delimiter=$'\t' --with-nth=2.. --header="$HDR_D" \
  --preview="$D preview {1}" --preview-window=right,58%,wrap \
  --bind="y:execute-silent($D act approve {1})+reload($D decisions)" \
  --bind="n:execute($D act reject {1})+reload($D decisions)" \
  --bind="c:execute($D act comment {1})" \
  --bind="o:execute($D act open {1})" \
  --bind="r:execute-silent($D act respawn {1})+reload($D roles)" \
  --bind="s:execute($D act stop)" \
  --bind="t:execute($D act passthrough)" \
  --bind="f1:reload($D decisions)+change-header($HDR_D)" \
  --bind="f2:reload($D issues)+change-header($HDR_I)" \
  --bind="f3:reload($D roles)+change-header($HDR_R)" \
  --bind="ctrl-r:reload($D decisions)"
INBOX
  } > "$inbox"

  if [ -n "${TMUX:-}" ]; then
    # Inside tmux already (the coord session): a dedicated window, board pane on top.
    tmux new-window -n "fwf-dash" "bash '$inbox'"
    tmux split-window -v -b -l '38%' "bash '$board'"
    tmux select-pane -D
  else
    # Standalone: a throwaway session that closes when you quit the inbox (q/Esc).
    local sess="fwf-dash-$PROFILE"
    tmux has-session -t "$sess" 2>/dev/null && exec tmux attach -t "$sess"
    tmux new-session -d -s "$sess" "bash '$board'"
    tmux split-window -t "$sess" -v -l '62%' "bash '$inbox'"
    tmux select-pane -t "$sess" -D
    exec tmux attach -t "$sess"
  fi
}

# Single-quote a value for safe embedding in a generated script (closes/reopens
# around any embedded single quote).
_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- dispatch ---------------------------------------------------------------
cmd="${1:-launch}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  launch|"")  cmd_launch "$@";;
  board)      cmd_board "$@";;
  decisions)  cmd_decisions "$@";;
  issues)     cmd_issues "$@";;
  roles)      cmd_roles "$@";;
  preview)    cmd_preview "$@";;
  act)        cmd_act "$@";;
  help|-h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//';;
  *) die "unknown subcommand '$cmd' (try 'fwf dash help')";;
esac
