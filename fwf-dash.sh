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
# The dash is a SINGLE fzf surface (issue #40 UAT): the board is the fzf header
# (atomic repaint — no flicker), the issue is the preview, and `--disabled` makes
# every printable key a binding (no fuzzy field to swallow j/k). One pane ⇒ no
# nested-tmux focus problem. The subcommands below are what the fzf binds call:
#   (default)         open the dash (the fzf surface)
#   board             render the full status board once (standalone glance)
#   header <view>     the compact 3-line header fzf shows (board + key legend)
#   keys              the `?` help overlay (key reference)
#   decisions         decision-inbox rows  — TSV "issue#<TAB>display"
#   issues            all open issues (the issues tab), same row shape
#   roles             role roster (raw: role<TAB>state<TAB>detail) for board/header
#   roles-view        roles tab rows for the inbox — TSV "role<TAB>display"
#   preview <key>     render one issue (body + thread) for the fzf preview / pager
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

# Portable mtime: GNU stat (-c %Y) first so the BSD fallback (-f %m) is never
# called on Linux (where -f means --file-system and outputs unrelated text).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
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
# Open issues, optionally filtered to one label, as "number<TAB>title" rows.
# Uses the gh-shaped `--json number,title --jq` both backends implement, because
# their PLAIN columns differ (gh: number/state/title…; local: number/title…) —
# the JSON field names are the only uniform contract. gh's `--jq` is its own
# embedded jq (no system jq needed); the local store's `--jq` uses system jq,
# which local-issues factories already require. Best-effort: any read failure
# (tracker down, no jq for the local store) degrades to an empty list, not a crash.
list_open() { # $1=label-or-empty
  local prog='.[] | "\(.number)\t\(.title)"'
  if [ -n "${1:-}" ]; then
    di_read list --state open --label "$1" --json number,title --jq "$prog" 2>/dev/null || true
  else
    di_read list --state open --json number,title --jq "$prog" 2>/dev/null || true
  fi
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
# Every view emits "KEY<TAB>DISPLAY": fzf hides field 1 (--with-nth=2..) and acts on
# it ({1}); field 2 is the human row. Decisions/issues key on the issue number,
# roles on the role tag.
#
# Decision inbox: derived gated items (open + WIP_LABEL + GV-SIGNOFF) enriched with
# the captain's recommendation from status.json when fresh, PLUS any non-issue
# decisions the captain queued (e.g. a release) that have no gated issue of their own.
cmd_decisions() {
  local num title rec flags
  while IFS="$(printf '\t')" read -r num title; do
    [ -n "$num" ] || continue
    has_gv_signoff "$num" || continue
    rec=""
    status_fresh && rec="$(status_q ".decisions[]? | select((.issue|tostring)==\"$num\") | .recommendation // \"\"")"
    flags="$(_flagcol "GV ✓✓" "$rec")"
    printf '%s\t#%-5s %s%s\n' "$num" "$num" "$title" "${flags:+   ·   $flags}"
  done <<EOF
$(list_open "$WIP_LABEL")
EOF
  # Captain-queued decisions that are not gated issues (release gates, etc).
  if status_fresh; then
    status_q '.decisions[]? | select((.kind // "")=="release") | [(.id // "REL"), (.gv // ""), .title] | @tsv' \
      | while IFS="$(printf '\t')" read -r id gv title; do
          [ -n "${id:-}" ] || continue
          printf '%s\t%-6s %s%s\n' "$id" "$id" "$title" "${gv:+   ·   $gv}"
        done
  fi
}

# A compact "flags" column: "GV ✓✓ · captain: ship". Kept narrow for the inbox row.
_flagcol() { # $1=gv-marker $2=recommendation
  local out="${1:-}"
  [ -n "${2:-}" ] && out="${out:+$out · }captain: $2"
  printf '%s' "$out"
}

# Issues tab: every open issue (not just gated ones), same open/comment keys. Gated
# issues are marked; the gated set is derived ONCE (jq-free) from the label filter.
cmd_issues() {
  local nl gated num title mark
  nl=$'\n'   # a literal newline ($(printf '\n') would be stripped to empty)
  gated="$nl$(list_open "$WIP_LABEL" | cut -f1)$nl"
  while IFS="$(printf '\t')" read -r num title; do
    [ -n "$num" ] || continue
    mark=""
    case "$gated" in *"$nl$num$nl"*) mark="⚑ gated · ";; esac
    printf '%s\t#%-5s %s%s\n' "$num" "$num" "$mark" "$title"
  done <<EOF
$(list_open "")
EOF
}

# Roles VIEW for the inbox tab: "role<TAB>display" so r/s act on field 1 while the
# role name stays visible in the row (cmd_roles keeps the raw board shape for the
# board/header/tests).
cmd_roles_view() {
  cmd_roles | while IFS="$(printf '\t')" read -r role state detail; do
    printf '%s\t%-10s %-7s %s\n' "$role" "$role" "$state" "$detail"
  done
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

# --- the status board -------------------------------------------------------
# Shared board data as "prod<TAB>stamp<TAB>pipeline": the status.json overlay when
# fresh, else derived. One source so the full board and the dash header never drift.
board_fields() {
  local prod pipeline stamp
  if status_fresh; then
    prod="$(status_q '.prod // "—"')"; [ -n "$prod" ] || prod="—"
    pipeline="$(status_q '.pipeline // "—"')"; [ -n "$pipeline" ] || pipeline="—"
    stamp="status.json ✓"
  else
    prod="—"; pipeline="$(derive_pipeline)"
    stamp="$([ -f "$STATUS_JSON" ] && echo 'status.json stale' || echo 'derived')"
  fi
  printf '%s\t%s\t%s\n' "$prod" "$stamp" "$pipeline"
}

# A one-line roster glance ("3 live · 0 idle · 7 down") for the compact header.
_roles_glance() {
  local live=0 idle=0 down=0 st
  while IFS="$(printf '\t')" read -r _ st _; do
    case "$st" in *live*) live=$((live+1));; *idle*) idle=$((idle+1));; *) down=$((down+1));; esac
  done <<EOF
$(cmd_roles)
EOF
  printf '%s live · %s idle · %s down' "$live" "$idle" "$down"
}

# The full board (profile · prod · the role roster · pipeline · decision count) —
# rendered ONCE, never in a clear-loop. Useful standalone (`fwf dash board`); the
# interactive dash uses the compact `header` instead so fzf owns the screen.
cmd_board() {
  local prod stamp pipeline parked ndec
  IFS="$(printf '\t')" read -r prod stamp pipeline <<EOF
$(board_fields)
EOF
  parked=""
  [ -f "$STOP_FILE" ] && parked="  · ⏸ PARKED (STOP)"
  ndec="$(cmd_decisions | grep -c . || true)"

  printf 'fwf · %s · %s    prod %s · %s%s\n' "$PROFILE" "$FWF_TEMPLATE" "$prod" "$stamp" "$parked"
  printf '\nROLES\n'
  cmd_roles | while IFS="$(printf '\t')" read -r role state detail; do
    printf '  %-10s %-7s %s\n' "$role" "$state" "$detail"
  done
  printf '\nPIPELINE  %s\n' "$pipeline"
  printf '\nDECISIONS (%s)\n' "$ndec"
}

# The COMPACT header the interactive dash shows above the inbox: three lines —
# identity + prod, a roster glance + pipeline, and a context-sensitive key legend.
# fzf repaints it atomically (transform-header on each action), so it never flickers.
cmd_header() { # $1 = active view (decisions|issues|roles)
  local view="${1:-decisions}" prod stamp pipeline parked legend
  IFS="$(printf '\t')" read -r prod stamp pipeline <<EOF
$(board_fields)
EOF
  parked=""; [ -f "$STOP_FILE" ] && parked="  ·  ⏸ PARKED"
  case "$view" in
    issues) legend='j/k move · ↵ preview · c comment · o open · F1 decisions · F3 roles · ? help · q quit';;
    roles)  legend='j/k move · r respawn · s stop(swarm) · t captain · F1 decisions · F2 issues · ? help · q quit';;
    *)      legend='j/k move · y approve · n reject · c comment · o open · t captain · F2 issues · F3 roles · ? help · q quit';;
  esac
  printf 'fwf · %s · %s   ·   prod %s · %s%s\n' "$PROFILE" "$FWF_TEMPLATE" "$prod" "$stamp" "$parked"
  printf 'roles %s   ·   pipeline %s\n' "$(_roles_glance)" "$pipeline"
  printf '%s' "$legend"
}

# The `?` help overlay (shown in the preview pane; any cursor move restores the
# issue preview). One screen, so a first-timer never needs docs/dash.md.
cmd_keys() {
  cat <<'KEYS'
  fwf dash — keys

  MOVE      j / ↓   down        k / ↑   up
            the preview follows the cursor

  DECISIONS & ISSUES
    y  approve   un-gate (remove the WIP label) + post the go-ahead
    n  reject    post a "needs changes" comment; the issue stays gated
    c  comment   type a comment and post it
    o  open      browser (gh backend) / pager (local backend)

  ROLES
    r  respawn   restart the role under the cursor
    s  stop      swarm-wide graceful stop (resumable)

  ANY VIEW
    t  captain   send a one-line message to the captain pane
    F1/F2/F3     switch to decisions / issues / roles
    ctrl-r       refresh now      ? this help      q / esc  quit
KEYS
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
cmd_preview() { # $1=row key (issue number, a role tag, or a release id)
  local n; n="$(issue_num "${1:-}")"
  case "$n" in
    '') echo "(nothing selected)"; return 0;;
    *[!0-9]*) echo "(no issue body for this row — keys: ? for help)"; return 0;;  # role / release rows
  esac
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
# ONE fzf surface (issue #40 UAT). The board is the fzf HEADER — repainted
# atomically by fzf, never a clear-loop, so it cannot flicker. The issue is the
# PREVIEW. `--disabled` turns OFF fuzzy typing, so every printable key is a real
# binding (j/k/y/n/c/o/r/s/t/?) — input can never land in a filter field as
# garbage. One pane ⇒ no nested-tmux focus problem: fzf is a single fullscreen app,
# `q` returns you to the shell. Run it in whatever pane/window/terminal you like.
#
# transform-header re-renders the board after each action and on every move
# (the `focus` bind), so the board tracks state without a daemon; ctrl-r forces it.
# Prompts (c/t) are read inside `act` from /dev/tty, which fzf's execute() restores.
cmd_launch() {
  command -v fzf >/dev/null 2>&1 || die "the dashboard needs fzf — see docs/dash.md (brew install fzf / apt install fzf)"
  local D="$DIR/fwf-dash.sh" tab
  tab="$(printf '\t')"
  # Children spawned by fzf binds inherit the resolved context, so the binds call
  # this script plainly — no per-bind env prefix, no nested quoting.
  export FWF_PROFILE="$PROFILE" FWF_RUN_DIR="$FWF_RUN" FWF_ISSUES="$FWF_ISSUES" FWF_TEMPLATE="$FWF_TEMPLATE"

  "$D" decisions | fzf \
    --ansi --disabled --no-sort --layout=reverse --header-first --cycle \
    --delimiter="$tab" --with-nth='2..' \
    --prompt='decisions ▸ ' --pointer='▶' \
    --header="$("$D" header decisions)" \
    --preview="$D preview {1}" --preview-window='right,55%,wrap,border-left' \
    --bind='j:down,k:up,ctrl-n:down,ctrl-p:up,g:first,G:last' \
    --bind="y:execute-silent($D act approve {1})+reload($D decisions)+transform-header($D header decisions)" \
    --bind="n:execute($D act reject {1})+reload($D decisions)+transform-header($D header decisions)" \
    --bind="c:execute($D act comment {1})+refresh-preview" \
    --bind="o:execute($D act open {1})" \
    --bind="r:execute-silent($D act respawn {1})+reload($D roles-view)+transform-header($D header roles)" \
    --bind="s:execute($D act stop)+transform-header($D header roles)" \
    --bind="t:execute($D act passthrough)" \
    --bind="f1:reload($D decisions)+change-prompt(decisions ▸ )+transform-header($D header decisions)" \
    --bind="f2:reload($D issues)+change-prompt(issues ▸ )+transform-header($D header issues)" \
    --bind="f3:reload($D roles-view)+change-prompt(roles ▸ )+transform-header($D header roles)" \
    --bind="?:preview($D keys)" \
    --bind="ctrl-r:reload($D decisions)+transform-header($D header decisions)" \
    || true   # q/esc exit non-zero; that is a normal quit, not a failure
}

# --- dispatch ---------------------------------------------------------------
cmd="${1:-launch}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  launch|"")  cmd_launch "$@";;
  board)      cmd_board "$@";;
  header)     cmd_header "$@";;
  keys)       cmd_keys "$@";;
  decisions)  cmd_decisions "$@";;
  issues)     cmd_issues "$@";;
  roles)      cmd_roles "$@";;
  roles-view) cmd_roles_view "$@";;
  preview)    cmd_preview "$@";;
  act)        cmd_act "$@";;
  help|-h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//';;
  *) die "unknown subcommand '$cmd' (try 'fwf dash help')";;
esac
