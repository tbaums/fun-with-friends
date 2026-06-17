#!/usr/bin/env bash
# fwf dash data provider (issue #40) — emits the WHOLE dashboard as one JSON doc.
#
# The compiled `fwf-dash` (Rust + ratatui) binary shells out to this on a refresh
# timer and renders the result; keeping the data layer here means the proven
# derived-first logic, the gh/local issue-backend abstraction, and profile/config
# resolution all stay in bash where they're already tested (the gh-dash model:
# bash gathers, the binary renders). Read-only — this NEVER mutates anything.
#
# Derived-first, so the board works with the factory parked:
#   roles    <- tmux pane state (@l label + current command)
#   pipeline <- git branch deltas in the target repo
#   decisions<- the label protocol: open + WIP_LABEL + a "GV-SIGNOFF" comment
#   prod     <- the captain's status.json overlay when fresh, else "—"
#
# Output schema (consumed by dash/src/data.rs):
#   { profile, template, parked, prod, pipeline, stamp, generated_at,
#     roles:[{role,state,detail}],
#     decisions:[{id,title,flags,body}],
#     issues:[{number,title,gated,body}] }
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
# The factory lives on tmux's DEFAULT socket (fwf launches it with plain tmux).
# The dash binary may be displayed inside a DIFFERENT tmux (e.g. a separate
# socket, to get mouse-wheel forwarding), which would otherwise point our role
# detection at the wrong server and show every role "down". Detach from the host
# tmux so pane liveness is always read off the factory's server.
unset TMUX
command -v jq >/dev/null 2>&1 || { echo '{"error":"jq is required for fwf dash"}'; exit 1; }

STATE_DIR="$FWF_RUN/state/$PROFILE"
STATUS_JSON="$STATE_DIR/status.json"
DASH_STALE_SECS="${FWF_DASH_STALE_SECS:-90}"

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
status_fresh() {
  local m age
  [ -f "$STATUS_JSON" ] || return 1
  m="$(file_mtime "$STATUS_JSON")"; [ -n "$m" ] || return 1
  age=$(( $(date +%s) - m ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$DASH_STALE_SECS" ]
}
status_q() { status_fresh || { echo ""; return 0; }; jq -r "$1" "$STATUS_JSON" 2>/dev/null || echo ""; }

# Issue access routed to the active backend, gh-shaped either way (read-only).
di_read() {
  if [ "$FWF_ISSUES" = "local" ]; then
    "$DIR/fwf-issues.sh" "$@"
  elif [ -d "$FWF_REPO/.git" ]; then
    ( cd "$FWF_REPO" && gh issue "$@" )
  else
    gh issue "$@"
  fi
}

# --- pipeline (git branch deltas in the target repo) ------------------------
derive_pipeline() {
  local repo="$FWF_REPO" sa=0 ic="clean" md="main=prod"
  [ -d "$repo/.git" ] || { printf '—'; return 0; }
  sa="$(git -C "$repo" rev-list --count "${INTEGRATION_BRANCH}..${STAGING_BRANCH}" 2>/dev/null || echo 0)"
  if [ "$(git -C "$repo" rev-list --count "${DEFAULT_BRANCH}..${INTEGRATION_BRANCH}" 2>/dev/null || echo 0)" != "0" ]; then
    ic="ahead"; md="integration > $DEFAULT_BRANCH"
  fi
  printf '%s +%s ahead · %s %s · %s' "$STAGING_BRANCH" "$sa" "$INTEGRATION_BRANCH" "$ic" "$md"
}

# --- roles (tmux pane liveness, overlaid with status.json detail) -----------
roles_json() {
  local role sess token pane state detail cmd
  for role in $(fwf_all_roles); do
    case "$role" in
      impl*|qa*|conductor) sess="$BUILD_SESSION";;
      pm|gv|captain)       sess="$COORD_SESSION";;
      *) case "$(fwf_extra_session "$role" 2>/dev/null)" in
           build) sess="$BUILD_SESSION";; *) sess="$COORD_SESSION";;
         esac;;
    esac
    token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
    case "$role" in impl*|qa*) token="$token ·";; esac
    pane="$(fwf_find_pane "$sess" "$token" 2>/dev/null || true)"
    if [ -n "$pane" ]; then
      cmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
      case "$cmd" in bash|zsh|sh|fish|"") state="idle";; *) state="live";; esac
    else
      state="down"
    fi
    detail=""
    status_fresh && detail="$(status_q ".roles[]? | select(.id==\"$role\") | \"#\"+(.issue|tostring)+\" \"+(.title // \"\")")"
    jq -n --arg role "$role" --arg state "$state" --arg detail "$detail" \
      '{role:$role, state:$state, detail:$detail}'
  done | jq -s '.'
}

# --- needs-you (captain blocked on a human decision) ------------------------
# The captain surfaces "NEEDS YOU" (and/or an interactive decision menu) in its
# pane when it's waiting on a call the gh label protocol doesn't capture — so the
# Decisions tab can read empty while the captain is actually blocked on you. Read
# the captain pane directly and flag it (with the decision question if we can find
# one) so the dash can show an unmissable banner.
needs_you_json() {
  local pane content summary
  pane="$(fwf_find_pane "$COORD_SESSION" "CAPTAIN" 2>/dev/null || true)"
  [ -n "$pane" ] || { echo '{"active":false,"summary":""}'; return 0; }
  content="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"
  # The captain prints "⛔ NEEDS YOU — nothing right now" as a STANDING status
  # line every tick, so that substring is not a signal. The reliable "actually
  # blocked on you" signal is an active interactive selection menu, whose footer
  # is "Enter to select … Esc to cancel" — present only while awaiting a choice.
  if printf '%s' "$content" | grep -qE "Enter to select"; then
    summary="$(printf '%s' "$content" | grep -E '\?[[:space:]]*$' | tail -1 \
                 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$summary" ] || summary="waiting on a decision"
    summary="$(printf '%s' "$summary" | cut -c1-140)"
    jq -n --arg s "$summary" '{active:true, summary:$s}'
  else
    echo '{"active":false,"summary":""}'
  fi
}

# --- issues + decisions -----------------------------------------------------
# All open issues, with bodies + labels, in one backend call (gh and the local
# store share the --json field names even though their plain columns differ).
open_issues_json() {
  di_read list --state open --limit 500 --json number,title,labels,body 2>/dev/null \
    | jq 'map({number:.number, title:.title, gated:(any(.labels[]?; .name=="'"$WIP_LABEL"'")), body:(.body // "")})' \
    2>/dev/null || echo '[]'
}

# A gated issue carrying a current GV sign-off is a human decision.
has_gv_signoff() { # $1=number
  local thread; thread="$(di_read view "$1" --comments 2>/dev/null || true)"
  case "$thread" in *GV-SIGNOFF*) return 0;; *) return 1;; esac
}
# Decision rows: gated + GV-SIGNOFF, enriched with the captain's recommendation
# (status.json) when fresh; plus any release-kind decisions the captain queued.
decisions_json() { # $1 = open_issues_json
  local issues="$1" num title body rec flags
  {
    printf '%s\n' "$issues" | jq -r '.[] | select(.gated) | .number' | while read -r num; do
      [ -n "$num" ] || continue
      has_gv_signoff "$num" || continue
      title="$(printf '%s' "$issues" | jq -r --argjson n "$num" '.[] | select(.number==$n) | .title')"
      body="$(printf '%s'  "$issues" | jq -r --argjson n "$num" '.[] | select(.number==$n) | .body')"
      rec=""
      status_fresh && rec="$(status_q ".decisions[]? | select((.issue|tostring)==\"$num\") | .recommendation // \"\"")"
      flags="GV ✓✓"; [ -n "$rec" ] && flags="$flags · captain: $rec"
      jq -n --arg id "$num" --arg title "$title" --arg flags "$flags" --arg body "$body" \
        '{id:$id, title:$title, flags:$flags, body:$body}'
    done
    if status_fresh; then
      status_q '.decisions[]? | select((.kind // "")=="release") | [(.id // "REL"), (.gv // ""), .title, (.body // "")] | @tsv' \
        | while IFS="$(printf '\t')" read -r id gv title body; do
            [ -n "${id:-}" ] || continue
            jq -n --arg id "$id" --arg title "${title:-}" --arg flags "${gv:-}" --arg body "${body:-}" \
              '{id:$id, title:$title, flags:$flags, body:$body}'
          done
    fi
  } | jq -s '.'
}

# --- activity (factory motion: building / in test / merged) -----------------
# PRs against the factory's integration targets (staging/integration) ARE the
# motion: draft = an implementer still building; ready = handed to QA/review
# (with CI state); recently merged = promoted. gh-only — the local issue backend
# has no PR concept, so it yields an empty activity block.
gh_pr() { if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr "$@" ); else gh pr "$@"; fi; }
activity_json() {
  if [ "${FWF_ISSUES:-gh}" = "local" ]; then
    echo '{"building":[],"in_test":[],"merged":[]}'; return 0
  fi
  local open merged
  open="$(gh_pr list --state open --limit 50 \
            --json number,title,isDraft,baseRefName,headRefName,statusCheckRollup 2>/dev/null || true)"
  merged="$(gh_pr list --state merged --limit 12 \
            --json number,title,baseRefName,headRefName,mergedAt 2>/dev/null || true)"
  [ -n "$open" ] || open='[]'
  [ -n "$merged" ] || merged='[]'
  jq -n --argjson open "$open" --argjson merged "$merged" \
        --arg staging "$STAGING_BRANCH" --arg integ "$INTEGRATION_BRANCH" \
        --arg default "$DEFAULT_BRANCH" '
    [$staging, $integ] as $t
    | def role:  (try (.headRefName | capture("^(?<r>impl[0-9]+|qa[0-9]+|conductor|pm)/").r) catch null) // "";
      def issue: (try (.headRefName | capture("issue-(?<n>[0-9]+)").n) catch null) // "";
      def checks:
        ([.statusCheckRollup[]?]) as $c
        | if   ($c|length)==0 then "none"
          elif any($c[]; .conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT") then "fail"
          elif any($c[]; (.status//"")=="IN_PROGRESS" or (.status//"")=="QUEUED" or (.status//"")=="PENDING") then "run"
          else "pass" end;
      {
        building: [ $open[]   | .baseRefName as $b | select($t|index($b)) | select(.isDraft)
                    | {pr:.number, role:role, issue:issue, base:$b, checks:checks, title:.title} ],
        in_test:  [ $open[]   | .baseRefName as $b | select($t|index($b)) | select(.isDraft|not)
                    | {pr:.number, role:role, issue:issue, base:$b, checks:checks, title:.title} ],
        merged:   [ $merged[] | .baseRefName as $b | select($t|index($b))
                    | {pr:.number, role:role, issue:issue, base:$b,
                       when:((.mergedAt // "")[5:16] | gsub("T";" ")), title:.title} ],
        to_main:  [ $open[]   | select(.baseRefName == $default)
                    | {pr:.number, role:role, issue:issue, base:.baseRefName, checks:checks, title:.title} ]
      }'
}

# --- assemble ---------------------------------------------------------------
main() {
  local prod pipeline stamp parked gen issues roles decisions activity needs_you
  if status_fresh; then
    prod="$(status_q '.prod // "—"')"; [ -n "$prod" ] || prod="—"
    pipeline="$(status_q '.pipeline // "—"')"; [ -n "$pipeline" ] || pipeline="—"
    stamp="status.json"
  else
    prod="—"; pipeline="$(derive_pipeline)"
    stamp="$([ -f "$STATUS_JSON" ] && echo 'stale' || echo 'derived')"
  fi
  parked=false; [ -f "$STOP_FILE" ] && parked=true
  gen="$(date +%H:%M:%S)"
  issues="$(open_issues_json)"
  roles="$(roles_json)"
  decisions="$(decisions_json "$issues")"
  activity="$(activity_json)"
  needs_you="$(needs_you_json)"

  jq -n \
    --arg profile "$PROFILE" --arg template "$FWF_TEMPLATE" \
    --argjson parked "$parked" \
    --arg prod "$prod" --arg pipeline "$pipeline" --arg stamp "$stamp" --arg gen "$gen" \
    --argjson roles "$roles" --argjson decisions "$decisions" --argjson issues "$issues" \
    --argjson activity "$activity" --argjson needs_you "$needs_you" \
    '{profile:$profile, template:$template, parked:$parked, prod:$prod, pipeline:$pipeline,
      stamp:$stamp, generated_at:$gen, roles:$roles, decisions:$decisions, issues:$issues,
      activity:$activity, needs_you:$needs_you}'
}

# --- detail (lazy, per-selection) -------------------------------------------
# `fwf-dash-data.sh detail <id>` emits ONE issue/decision's full thread (body +
# comments) as plain text for the dash's right pane. Fetched on demand for the
# selected row only — never in the per-tick board snapshot — so the comment you
# just posted shows up the instant the dash re-requests it after the action.
detail_view() {
  local id="$1"
  case "$id" in
    ''|*[!0-9]*) echo "(no detail for '$id')"; return 0 ;;  # numeric ids only
  esac
  # gh's `view --comments` is TTY-ONLY — it prints nothing as a subprocess. So pull
  # the thread as JSON (gh's embedded --jq works headless) and format it ourselves.
  # The local backend renders comments fine in script mode, so it keeps --comments.
  if [ "$FWF_ISSUES" = "local" ]; then
    di_read view "$id" --comments 2>/dev/null || echo "(detail unavailable for #$id)"
  else
    # A number is EITHER an issue or a PR (GitHub shares the namespace). Try the
    # issue view first; if it yields nothing the id is a PR (an Activity row), so
    # render the PR with its check rollup + comments instead.
    local out
    out="$(di_read view "$id" --json number,title,state,body,comments --jq '
      "#\(.number) · \(.title)\nstate: \(.state)\n\n\(.body)\n" +
      (if (.comments | length) > 0
       then "\n--- comments (\(.comments | length)) ---\n" +
            ([.comments[] | "\n— @\(.author.login) · \(.createdAt[0:10]) —\n\(.body)"] | join("\n"))
       else "\n(no comments yet)" end)' 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      gh_pr view "$id" --json number,title,state,isDraft,headRefName,baseRefName,body,statusCheckRollup,comments --jq '
        "PR #\(.number) · \(.title)\nstate: \(.state)\(if .isDraft then " (draft)" else "" end)   \(.headRefName) → \(.baseRefName)\n" +
        (([.statusCheckRollup[]?]) as $c
         | if ($c|length) > 0
           then "\nchecks:\n" + ([$c[] | "  \(.name // .context // "check"): \(.conclusion // .status // "?")"] | join("\n")) + "\n"
           else "" end) +
        "\n\(.body // "")\n" +
        (if (.comments | length) > 0
         then "\n--- comments (\(.comments | length)) ---\n" +
              ([.comments[] | "\n— @\(.author.login) · \(.createdAt[0:10]) —\n\(.body)"] | join("\n"))
         else "\n(no comments yet)" end)' 2>/dev/null \
        || echo "(detail unavailable for #$id)"
    fi
  fi
}

if [ "${1:-}" = "detail" ]; then
  detail_view "${2:-}"
  exit 0
fi
main
