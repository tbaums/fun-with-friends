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
#   roles      <- tmux pane state (@l label + current command)
#   pipeline   <- git branch deltas in the target repo
#   decisions  <- the label protocol: open + WIP_LABEL + a "GV-SIGNOFF" comment
#   prod       <- the captain's status.json overlay when fresh, else "—"
#   floor_idle <- the last floor-lifecycle event (issue #85): a deliberate
#                 `fwf-down.sh --floor-only` idle, distinct from a crash
#
# Output schema (consumed by dash/src/data.rs):
#   { profile, template, parked, prod, pipeline, stamp, generated_at,
#     roles:[{role,state,detail,heartbeat_age}],
#     decisions:[{id,title,flags,body}],
#     issues:[{number,title,gated,body}],
#     floor_idle:{active,since,reason,actor},
#     visibility:{factory_visible,newest_heartbeat_age,state_dir,profile,host},
#     unrouted_prs:[{pr,author,branch,created_at,reason}],
#     stranded_assignments:{unknown,reason,count,issues:[{number,assigned}]} }
#   unrouted_prs (issue #194 AC (d)) is data-layer only as of this field's
#   introduction -- dash/src/data.rs does not yet deserialize or render it;
#   query `fwf-dash-data.sh` directly (or `.unrouted_prs` off its JSON) until
#   the Rust side picks it up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The dash reflects the RUNNING factory, so it opts in to resolving the
# persisted running template (lib.sh reads $FWF_RUN/template only under this
# flag, so other tools/tests keep the dev default) — see #51.
export FWF_USE_RUNNING_TEMPLATE=1
# shellcheck source=lib.sh
source "$DIR/lib.sh"
command -v jq >/dev/null 2>&1 || { echo '{"error":"jq is required for fwf dash"}'; exit 1; }

# issue #206: the versioned wire format `fwf dash --remote` reads over ssh.
# ONE constant, read by both the emitter (below) and the local-side remote
# reader (fwf-dash-remote.sh, which sources this file for it) -- a version
# bump and the emitter that needs to match it can never drift into two
# different numbers by construction. Bump this whenever emit_snapshot's
# field set changes; test/run.sh asserts the emitted field set against the
# CURRENT value, so an unbumped change to the fields is a RED, not a silent
# drift (AC i2).
DASH_SNAPSHOT_SCHEMA_VERSION=1

STATE_DIR="$FWF_STATE_DIR"
STATUS_JSON="$STATE_DIR/status.json"
DASH_STALE_SECS="${FWF_DASH_STALE_SECS:-90}"

# --- resolve the factory's tmux socket (issue #62, supersedes #57) ----------
# The factory lands on whatever socket $TMUX pointed to when `fwf up`/`fwf
# respawn` launched it — NOT necessarily the default socket (e.g. the whole
# factory was started inside `tmux -L mysock`). The dash binary may ALSO be
# displayed inside a completely different tmux (e.g. a separate socket used
# purely for mouse-wheel forwarding), so blindly trusting our OWN $TMUX would
# be exactly as wrong as blindly unsetting it — either can point role
# detection at a server the factory was never on, showing every role "down".
# Learn the socket fwf up/respawn persisted instead — shared with
# fwf-supervise.sh (issue #193 AC g) as fwf_resolve_tmux_socket (lib.sh), so
# the two readers can never independently mis-resolve and disagree about
# whether the factory is even visible. Probing BOTH sessions (not just
# BUILD_SESSION, the pre-#193 bug) means a coord-only factory (mid `fwf down
# --floor-only`) still resolves correctly on the absent-field migration path.
FWF_TMUX_SOCK="$(fwf_resolve_tmux_socket "$BUILD_SESSION" "$COORD_SESSION")"
unset TMUX   # never let our own socket leak into a query by accident (must run AFTER the resolve above, which needs it)

# Every tmux call below — including lib.sh's fwf_find_pane — goes through this
# shadow, so pane queries transparently target the resolved factory socket.
tmux() {
  if [ -n "$FWF_TMUX_SOCK" ]; then command tmux -S "$FWF_TMUX_SOCK" "$@"
  else command tmux "$@"; fi
}

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
  else
    case "${1:-}" in
      # Hot reads through the shared REST+ETag cache (off GraphQL) — same
      # snapshot the floor reads, so the dash never re-drains the budget (#57).
      list|view) FWF_REAL_GH="$(command -v gh)" "$DIR/fwf-ghcache.sh" serve issue "$@" ;;
      *) if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh issue "$@" ); else gh issue "$@"; fi ;;
    esac
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

# --- floor lifecycle (issue #85) — dash's IDLE-vs-crash signal --------------
# Derived the same way `parked` is (read-only, alongside it in main()): the
# LAST logged floor-lifecycle event. Active only when it's a floor-down with
# no later floor-up, so a crash (which never logs anything) still reads as
# not-idle here — roles_json()'s pane check is what actually renders "down".
# issue #105: floor-events.log is now per-plane (build|pm); this dash surface
# stays plane-agnostic for now and reads only the BUILD plane (the pre-#105
# "floor"), matching every existing dash consumer/test unchanged. Per-plane
# dash rendering (e.g. a separate PM-idle badge) is a fast-follow, not part
# of this ticket's acceptance criteria.
floor_idle_json() {
  local line active since reason actor
  line="$(fwf_plane_idle_state build)"
  active="$(printf '%s' "$line" | cut -f1)"
  since="$(printf '%s' "$line" | cut -f2)"
  reason="$(printf '%s' "$line" | cut -f3)"
  actor="$(printf '%s' "$line" | cut -f4)"
  jq -n --argjson active "$active" --arg since "$since" --arg reason "$reason" --arg actor "$actor" \
    '{active:$active, since:$since, reason:$reason, actor:$actor}'
}

# issue #193 (AC a/b/i0): seconds since $1's heartbeat last touched, or empty
# on a missing/unreadable/future (clock-skew) mtime — NEVER a negative age,
# never fabricated. Shared by the per-role STALE annotation and (via
# visibility_json below) the header's always-shown newest-heartbeat line.
_fwf193_heartbeat_age() { # $1=role -> stdout: age in seconds, or empty
  local hb m now age
  hb="$(fwf_heartbeat_path "$1")"
  [ -f "$hb" ] || return 0
  m="$(file_mtime "$hb")"
  [ -n "$m" ] || return 0
  now="$(date +%s)"
  age=$(( now - m ))
  [ "$age" -lt 0 ] && return 0   # clock skew -> UNKNOWN-shaped, never a false-fresh negative
  printf '%s' "$age"
}

# issue #193 (AC b/e): whole-factory visibility, always emitted — the
# header's newest-heartbeat age (shown whether fresh or stale, per (b): an
# operator who only ever sees this during an incident has never calibrated
# what "normal" looks like), plus what a "no factory here" banner needs to
# name (AC e's edge case: this must be diagnosable as MY mistake, e.g. the
# wrong FWF_PROFILE, not just reported as a mystery).
visibility_json() {
  local visible=false newest="" role age
  fwf_factory_visible && visible=true
  for role in $(fwf_all_roles); do
    age="$(_fwf193_heartbeat_age "$role")"
    [ -n "$age" ] || continue
    if [ -z "$newest" ] || [ "$age" -lt "$newest" ]; then newest="$age"; fi
  done
  jq -n --argjson visible "$visible" --arg newest "$newest" \
        --arg state_dir "$FWF_STATE_DIR" --arg profile "$PROFILE" \
        --arg host "$(hostname 2>/dev/null || echo unknown)" \
        '{factory_visible:$visible,
          newest_heartbeat_age:(if $newest=="" then null else ($newest|tonumber) end),
          state_dir:$state_dir, profile:$profile, host:$host}'
}

# --- roles (tmux pane liveness, overlaid with status.json detail) -----------
# $1 = floor_idle_json (so a pane-less floor role can render a deliberate IDLE
# instead of "down" — see floor_idle_json above). Optional and defaults to
# inactive (old "no floor_idle at all" behavior) so callers that don't pass it
# — e.g. tests exercising roles_json in isolation — still get a plain down/live/idle read.
roles_json() {
  local fi_json="${1:-}" fi_active="false" fi_since="" fi_reason="" fi_actor=""
  if [ -n "$fi_json" ]; then
    fi_active="$(printf '%s' "$fi_json" | jq -r '.active // false')"
    fi_since="$(printf '%s' "$fi_json" | jq -r '.since // ""')"
    fi_reason="$(printf '%s' "$fi_json" | jq -r '.reason // ""')"
    fi_actor="$(printf '%s' "$fi_json" | jq -r '.actor // ""')"
  fi
  local role sess token pane state detail cmd hb_age
  for role in $(fwf_all_roles); do
    sess="$(fwf_role_session "$role")"
    token="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
    case "$role" in impl*|qa*) token="$token ·";; esac
    pane="$(fwf_find_pane "$sess" "$token" 2>/dev/null || true)"
    hb_age=""
    if [ -n "$pane" ]; then
      # Live-pane precedence (issue #193 AC i0): a role with a live pane is
      # NEVER shown idle/stale/unknown off any other signal — heartbeat age,
      # session-visibility, gate-lock, however they read — the pane itself is
      # the strongest positive evidence there is. Still surface the heartbeat
      # age alongside the real state word (i0's fixture), not instead of it.
      cmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
      case "$cmd" in bash|zsh|sh|fish|"") state="idle";; *) state="live";; esac
      hb_age="$(_fwf193_heartbeat_age "$role")"
    elif { case "$role" in impl*|qa*|conductor) true;; *) false;; esac; } && [ "$fi_active" = "true" ]; then
      # No pane + a logged floor-down with no later floor-up = deliberately
      # idled by --floor-only, not crashed. floor_idle is a BUILD-plane-only
      # concept (issue #85/#105 — this surface stays plane-agnostic and
      # reads only the build plane) — issue #193 AC (e2) requires pm/gv/
      # captain to keep rendering their REAL state even while the build
      # floor is legitimately idled, never floor_idle, since --floor-only
      # never tears any of the three coord roles down. Excluding only
      # "captain" (pre-#193) left pm/gv able to render a false floor_idle
      # whenever their own pane merely wasn't found for any other reason —
      # pm/gv/captain with no pane are always their real state, never a
      # fabricated "floor_idle".
      state="floor_idle"
    elif ! fwf_role_session_visible "$role" 2>/dev/null; then
      # issue #193 (AC c/e): we cannot even confirm the SESSION this role's
      # pane would live in is visible from this host (wrong socket, wrong
      # host, wrong profile) — "no pane found" here proves nothing. Never
      # collapse "I cannot tell" into "down".
      state="unknown"
    elif [ -d "$(fwf_gate_lock_dir "$role")" ]; then
      # issue #193 (AC i): holding the gate lock is a POSITIVE liveness fact
      # strictly stronger than pane presence or tick age — a role deep in a
      # long gate run has no pane visible here in some fixtures, but IS
      # working. Checked before heartbeat staleness so a frozen tick during a
      # long gate never reads as STALE, let alone DOWN.
      state="busy"
    elif [ -f "$(fwf_heartbeat_path "$role")" ]; then
      # issue #193 (AC a/d): the session IS visible and this role has a
      # heartbeat file (evidence it ran here at some point), but no pane and
      # no gate lock right now. STALE, not DOWN — DOWN is reserved for a role
      # with NO heartbeat trace at all (the genuinely-never-seen case AC (d)
      # requires this fix not to weaken).
      state="stale"
      hb_age="$(_fwf193_heartbeat_age "$role")"
    else
      state="down"
    fi
    detail=""
    status_fresh && detail="$(status_q ".roles[]? | select(.id==\"$role\") | \"#\"+(.issue|tostring)+\" \"+(.title // \"\")")"
    if [ "$state" = "floor_idle" ]; then
      detail="floor idled by $fi_actor since ${fi_since} — ${fi_reason}"
    fi
    jq -n --arg role "$role" --arg state "$state" --arg detail "$detail" --arg hb "$hb_age" \
      '{role:$role, state:$state, detail:$detail, heartbeat_age:(if $hb=="" then null else ($hb|tonumber) end)}'
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

# --- upgrade-available banner (issue #94, from the #79 proposal) ------------
# Cache-only — never triggers a network call itself. fwf_version_skew_check
# (lib/version_check.sh) reads the shared $FWF_RUN/upgrade-check cache and, if
# it's stale, kicks off its OWN detached single-flight refresh for next time;
# this call never waits on that, so a dash tick never blocks on gh either.
upgrade_json() {
  local out cur latest
  out="$(fwf_version_skew_check)"
  if [ -z "$out" ]; then
    echo '{"available":false,"current":"","latest":""}'
    return 0
  fi
  cur="${out%%|*}"; latest="${out##*|}"
  jq -n --arg cur "$cur" --arg latest "$latest" '{available:true, current:$cur, latest:$latest}'
}

# --- installed-version (issue #153, running-vs-installed drift) -------------
# The INSTALLED version on disk, re-read fresh EVERY tick via a cheap `cat` —
# never a `fwf --version` subprocess, never cached. Deliberately separate from
# upgrade_json() above: that only reports anything when the INSTALL itself is
# behind the latest GitHub release, so it's routinely EMPTY exactly when a
# running dash is most likely to have just gone stale (right after a fresh
# `fwf upgrade`, the install is current -> upgrade_json() has nothing to say,
# but an already-running dash process is now behind it).
installed_version_json() {
  local cur
  cur="$(cat "$FWF_HOME/VERSION" 2>/dev/null || true)"
  jq -n --arg v "$cur" '{version: $v}'
}

# --- API budget headroom, rendered as a NAMED, assertable element (#239) ----
# A correlated failure (rate-limit exhaustion) takes every role's read layer
# out AT ONCE — every seat shares one account, one budget — which is exactly
# when a false-confident "nothing in flight" is most damaging. This is the
# OPERATOR-FACING end of that chain: not just that a read returns UNKNOWN
# (fwf-ghcache.sh's own job, already covered), but that the state actually
# reaches a human looking at the board, as a specific string this file's own
# tests can assert on — never left to "an operator could probably notice
# the dash looks emptier than usual", which is unfalsifiable and was this
# AC's own prior, rejected wording.
# --- claim refusals, EVENT-SOURCED (issue #243 AC f) ------------------------
# A refusal must surface as a distinct dash state -- "N items blocked on
# authz" -- so a human sees a QUEUE, not a floor that has mysteriously gone
# quiet. The count is a plain read of fwf-claim.sh's own durable rolling
# log, NEVER recomputed by re-running fwf authz per candidate issue per
# render: #239 already measured that exact per-render cost as this dash's
# dominant term, and a second one here would double it before #239 even
# finished measuring the first. "Recent" is a fixed trailing window
# (default 24h) so the count reflects an ongoing queue, not all-time noise.
claim_refusals_json() {
  local log="$STATE_DIR/claim-refusals.log" window="${FWF_CLAIM_REFUSAL_WINDOW:-86400}" cutoff n
  if [ ! -f "$log" ]; then
    jq -n '{count:0}'
    return 0
  fi
  cutoff=$(( $(date +%s) - window ))
  n="$(awk -v cutoff="$cutoff" '
    { ts=""
      for (i=1;i<=NF;i++) if ($i ~ /^ts=/) ts=substr($i,4)
      if (ts=="" || ts+0 < cutoff) next
      n++
    }
    END { print n+0 }
  ' "$log")"
  jq -n --argjson n "${n:-0}" '{count:$n}'
}

# issue #309 (#221 AC h/h2): issues carrying "ASSIGNED implN" for a seat NOT
# on the live floor -- reachable via a pane dying and never respawning, a
# future `fwf scale --pairs N` reducing pairs while an assignment is
# outstanding, or the captain assigning from a prompt rendered before a
# scale. Two independent reads, EACH of which can fail, and per AC (h2)
# neither may silently default: an unreadable live-roster defaulting to
# empty would flag every assignment as stranded (false alarm); an
# unreadable assignment list defaulting to empty would flag none (the
# exact silence this check exists to break). Either failure reports the
# WHOLE result as unknown (#193 vocabulary), naming which input failed.
stranded_assignments_json() {
  local live
  live="$(fwf_live_impl_indices "$BUILD_SESSION" 2>/dev/null)"
  if [ "$live" = unknown ]; then
    jq -n '{unknown:true, reason:"could not determine the live floor roster (tmux unreachable)", count:null, issues:null}'
    return 0
  fi
  local raw rc=0
  raw="$(di_read list --state open --json number,comments --limit 500 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] || ! printf '%s' "$raw" | jq -e 'type=="array"' >/dev/null 2>&1; then
    jq -n '{unknown:true, reason:"could not read the open-issue comment list", count:null, issues:null}'
    return 0
  fi
  # LAST matching "ASSIGNED implN" comment per issue wins (a re-assignment
  # supersedes an earlier one) -- unanchored: a bold-markdown-prefixed
  # "**ASSIGNED implN**" is the captain's own real posting shape (same
  # reason implementer surveys check for "ASSIGNED" appearing anywhere, not
  # "^ASSIGNED", per this floor's own established convention), so an
  # anchored match would silently miss the common case. Emits one
  # "number\tassigned" TSV row per issue that carries an assignment at all
  # -- liveness is decided in bash below, since $live is a plain index list.
  local pairs
  pairs="$(printf '%s' "$raw" | jq -r '
    .[] | . as $i |
    ([(.comments // [])[] | .body
       | (capture("ASSIGNED (?<role>impl[0-9]+)") // null)
       | if . == null then empty else .role end] | last) as $a |
    select($a != null) | "\($i.number)\t\($a)"
  ' 2>/dev/null)"
  local stranded="[]" num role idx found j
  while IFS=$'\t' read -r num role; do
    [ -n "$num" ] || continue
    idx="${role#impl}"
    found=0
    for j in $live; do [ "$j" = "$idx" ] && { found=1; break; }; done
    if [ "$found" = 0 ]; then
      stranded="$(printf '%s' "$stranded" | jq -c --argjson n "$num" --arg r "$role" '. + [{number:$n, assigned:$r}]')"
    fi
  done <<< "$pairs"
  printf '%s' "$stranded" | jq -c '{unknown:false, reason:"", count:length, issues:.}'
}

api_budget_json() {
  local hr remaining limit reset label status
  hr="$("$DIR/fwf-ghcache.sh" headroom 2>/dev/null)" || true
  if [ "$hr" = "UNKNOWN" ] || [ -z "$hr" ]; then
    jq -n '{status:"EXHAUSTED", label:"API BUDGET EXHAUSTED", remaining:null, limit:null, reset:null}'
    return 0
  fi
  remaining="$(printf '%s' "$hr" | grep -oE 'remaining=[0-9]+' | cut -d= -f2)"
  limit="$(printf '%s' "$hr" | grep -oE 'limit=[0-9]+' | cut -d= -f2)"
  reset="$(printf '%s' "$hr" | grep -oE 'reset=[0-9]+' | cut -d= -f2)"
  if [ -z "$remaining" ] || [ -z "$limit" ]; then
    jq -n '{status:"EXHAUSTED", label:"API BUDGET EXHAUSTED", remaining:null, limit:null, reset:null}'
    return 0
  fi
  status="OK"; label="API BUDGET OK"
  if [ "$remaining" -le 0 ] 2>/dev/null; then status="EXHAUSTED"; label="API BUDGET EXHAUSTED"; fi
  jq -n --argjson remaining "$remaining" --argjson limit "$limit" --argjson reset "${reset:-0}" \
    --arg status "$status" --arg label "$label" \
    '{status:$status, label:$label, remaining:$remaining, limit:$limit, reset:$reset}'
}

# --- issues + decisions -----------------------------------------------------
# All open issues, with bodies + labels, in one backend call (gh and the local
# store share the --json field names even though their plain columns differ).
# issue #266 AC (b3): a DEGRADED list read (fwf-ghcache.sh exit 2 — served,
# but never confirmed fresh against upstream) is the sharpest case, because a
# row that never made it into this snapshot has no per-row check downstream
# to mark it — has_gv_signoff/gv_signoff_state is never even reached for a
# row absent from the list. `main()` invokes this via `issues="$(open_issues_json)"`
# — a command substitution, i.e. a SUBSHELL — so a plain variable set inside
# it is invisible to the caller once that subshell exits; a PID-scoped file
# is what actually crosses that boundary (decisions_json, called from the
# SAME top-level process, reads it back). A fresh/validated read (exit 0) or
# a hard failure the gh backend already falls back on (any other exit) write
# 0 — always written, so a stale value from an earlier call in the same PID
# can never linger past this call.
LIST_DEGRADED_FILE="${TMPDIR:-/tmp}/fwf-dash-list-degraded.$$"
open_issues_json() {
  local raw rc=0
  raw="$(di_read list --state open --limit 500 --json number,title,labels,body 2>/dev/null)" || rc=$?
  if [ "$rc" = 2 ]; then echo 1 > "$LIST_DEGRADED_FILE" 2>/dev/null; else echo 0 > "$LIST_DEGRADED_FILE" 2>/dev/null; fi
  printf '%s' "$raw" | jq 'map({number:.number, title:.title, gated:(any(.labels[]?; .name=="'"$WIP_LABEL"'")), body:(.body // "")})' \
    2>/dev/null || echo '[]'
}

# A gated issue's GV sign-off state — THREE-way (issue #266 build note; same
# shape as fwf authz's INDETERMINATE, #211/#219's convention): SIGNED / NONE /
# INDETERMINATE. "Could not tell" must never render as "no sign-off" — a
# degraded read (fwf-ghcache.sh exit 2) that didn't find the marker is
# INDETERMINATE, not NONE, because the marker could be sitting on a page/
# snapshot state this read never confirmed. Uses `--json comments` (not
# `--comments`, which fwf-ghcache.sh's reshape_view doesn't model at all and
# always falls straight through to the unmodified tier1 fallback, bypassing
# this signal entirely) so the degraded exit code actually reaches here.
gv_signoff_state() { # $1=number -> SIGNED | NONE | INDETERMINATE
  local n="$1" rc=0 thread
  thread="$(di_read view "$n" --json comments --jq '[.comments[].body] | join("\n")' 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then echo INDETERMINATE; return; fi
  case "$thread" in
    *GV-SIGNOFF*) echo SIGNED;;
    *) [ "$rc" = 2 ] && echo INDETERMINATE || echo NONE;;
  esac
}
# Back-compat boolean shape for any caller that just wants "is this a
# decision" without the third state.
has_gv_signoff() { [ "$(gv_signoff_state "$1")" = SIGNED ]; }
# #218 AC (i): an INVALID sentinel (a column-0-anchored but malformed or
# wrong-issue un-gate attempt — either a forgery attempt or a botched operator
# action) is security-relevant and must be visible on the board itself, not
# only in `fwf authz`'s own output that nobody but a role reads.
has_invalid_sentinel() { # $1=number
  "$DIR/fwf-authz.sh" "$1" >/dev/null 2>&1
  [ "$?" = 11 ]
}
# Templates where the CAPTAIN sequences releases of GV-signed-off items in
# dependency order — so a gated + GV-SIGNOFF issue is the captain's queue, not a
# human go/no-go (#51). The human's decisions in these modes surface via the
# captain's NEEDS-YOU menu (needs_you_json) instead. In dev-style templates the
# human un-gates GV-approved items (the dash `y` key), so they ARE decisions.
captain_sequences_releases() {
  case "$FWF_TEMPLATE" in refactor) return 0;; *) return 1;; esac
}
# Decision rows: gated + GV-SIGNOFF, enriched with the captain's recommendation
# (status.json) when fresh; plus any release-kind decisions the captain queued.
decisions_json() { # $1 = open_issues_json
  local issues="$1" num title body rec flags state
  # issue #266 AC (b2): counts tickets whose sign-off state was INDETERMINATE
  # (a degraded read that never found the marker — could be genuinely absent
  # or sitting on a snapshot state this read never confirmed). A plain shell
  # var set inside the `while read` below would be lost — that loop runs in a
  # subshell (piped from jq) — so a file is the counter instead.
  local indet_f; indet_f="$(mktemp 2>/dev/null || echo /tmp/fwf-dash-indet.$$)"; : > "$indet_f"
  {
    # A gated + GV-SIGNOFF issue is a human decision ONLY where the human un-gates
    # (dev-style). In captain-sequenced templates the captain releases these in
    # order, so skip them — they'd otherwise read as false "needs you" rows (#51).
    if ! captain_sequences_releases; then
    printf '%s\n' "$issues" | jq -r '.[] | select(.gated) | .number' | while read -r num; do
      [ -n "$num" ] || continue
      state="$(gv_signoff_state "$num")"
      case "$state" in
        NONE) continue;;
        INDETERMINATE) printf '%s\n' "$num" >> "$indet_f"; continue;;
      esac
      title="$(printf '%s' "$issues" | jq -r --argjson n "$num" '.[] | select(.number==$n) | .title')"
      body="$(printf '%s'  "$issues" | jq -r --argjson n "$num" '.[] | select(.number==$n) | .body')"
      rec=""
      status_fresh && rec="$(status_q ".decisions[]? | select((.issue|tostring)==\"$num\") | .recommendation // \"\"")"
      flags="GV ✓✓"; [ -n "$rec" ] && flags="$flags · captain: $rec"
      jq -n --arg id "$num" --arg title "$title" --arg flags "$flags" --arg body "$body" \
        '{id:$id, title:$title, flags:$flags, body:$body}'
    done
    fi
    if status_fresh; then
      status_q '.decisions[]? | select((.kind // "")=="release") | [(.id // "REL"), (.gv // ""), .title, (.body // "")] | @tsv' \
        | while IFS="$(printf '\t')" read -r id gv title body; do
            [ -n "${id:-}" ] || continue
            jq -n --arg id "$id" --arg title "${title:-}" --arg flags "${gv:-}" --arg body "${body:-}" \
              '{id:$id, title:$title, flags:$flags, body:$body}'
          done
    fi
    # #218 AC (i): an INVALID sentinel is its own decision row, independent of
    # GV sign-off state or release-sequencing mode — a forged-looking un-gate
    # attempt matters regardless of whether GV has otherwise blessed the work.
    printf '%s\n' "$issues" | jq -r '.[] | select(.gated) | .number' | while read -r num; do
      [ -n "$num" ] || continue
      has_invalid_sentinel "$num" || continue
      title="$(printf '%s' "$issues" | jq -r --argjson n "$num" '.[] | select(.number==$n) | .title')"
      jq -n --arg id "$num" --arg title "$title" \
        '{id:$id, title:$title, flags:("⚠ INVALID SENTINEL — see: fwf authz " + $id),
          body:"A sentinel-shaped comment on this issue is anchored at column 0 but malformed or references the wrong issue (issue #218). This is security-relevant — a forgery attempt or a botched operator action — inspect before treating it as noise."}'
    done
  } | jq -s '.' | {
    # issue #266 AC (b2)/(b3): the two "we could not tell" summaries, appended
    # after the main rows so they never displace a real decision — a count of
    # zero means neither exists in the array below, exactly as before this
    # ticket. (b2) wording is the ticket's own: "N tickets whose sign-off
    # state could not be verified."
    local base indet_n
    base="$(cat)"
    indet_n="$(wc -l < "$indet_f" 2>/dev/null | tr -d ' ')"; indet_n="${indet_n:-0}"
    if [ "$indet_n" -gt 0 ]; then
      base="$(printf '%s' "$base" | jq -c --arg n "$indet_n" --arg ids "$(paste -sd, "$indet_f" 2>/dev/null)" \
        '. + [{id:"INDET", title:($n + " tickets whose sign-off state could not be verified"),
               flags:"⚠ SIGN-OFF UNVERIFIED",
               body:("A degraded (unconfirmed-fresh) read found no GV-SIGNOFF comment for issue(s) " + $ids + " — this does NOT mean none exists; the read that would have found it never confirmed it was looking at the current thread (issue #266). Re-check once ghcache reports current for these.")}]')"
    fi
    local list_degraded=0
    [ -f "$LIST_DEGRADED_FILE" ] && list_degraded="$(cat "$LIST_DEGRADED_FILE" 2>/dev/null)"
    if [ "${list_degraded:-0}" = 1 ]; then
      base="$(printf '%s' "$base" | jq -c \
        '. + [{id:"LISTDEG", title:"the open-issue list itself is degraded — some tickets may be missing or stale",
               flags:"⚠ ISSUE LIST UNCONFIRMED",
               body:"The canonical open-issues snapshot was served without confirming it against upstream (issue #266) — a just-filed or just-gated ticket may be entirely absent from this queue, or present with stale labels, until the next confirmed read."}]')"
    fi
    printf '%s' "$base"
  }
  rm -f "$indet_f"
}

# --- activity (factory motion: building / in test / merged) -----------------
# PRs against the factory's integration targets (staging/integration) ARE the
# motion: draft = an implementer still building; ready = handed to QA/review
# (with CI state); recently merged = promoted. gh-only — the local issue backend
# has no PR concept, so it yields an empty activity block.
gh_pr() {
  case "${1:-}" in
    list|view) FWF_REAL_GH="$(command -v gh)" "$DIR/fwf-ghcache.sh" serve pr "$@" ;;
    *) if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh pr "$@" ); else gh pr "$@"; fi ;;
  esac
}
# $1=open-PRs-json (gh_pr list shape, must include headRefOid) -> same
# shape, each entry with a `gate_verdict` field: the value this FLOOR's own
# gate actually recorded for that PR's head SHA (fwf_gate_verdict_read,
# issue #220 AC (r)) -- "green"/"red"/"stale", or "unknown" if the gate has
# never recorded anything for that SHA. Deliberately DISTINCT from `checks`
# (GitHub's own statusCheckRollup) above: `checks` is what CI reported;
# `gate_verdict` is what fwf gate itself ran and recorded, which can differ
# (a role gating locally before CI finishes, or `--tip-cmd`'s stale-tip
# handling). This is what makes the recorded verdict genuinely
# REVIEWER-READABLE rather than only locally readable by the gate that
# wrote it (issue #220 AC (r)'s own wording) -- `fwf dash` is an artifact a
# reviewer/captain actually looks at, unlike the raw state-dir file.
_activity_attach_gate_verdict() {
  printf '%s' "$1" | jq -c '.[]' | while IFS= read -r pr; do
    local sha line verdict
    sha="$(printf '%s' "$pr" | jq -r '.headRefOid // empty')"
    verdict="unknown"
    if [ -n "$sha" ] && line="$(fwf_gate_verdict_read "$sha" 2>/dev/null)"; then
      verdict="$(printf '%s' "$line" | sed -n 's/.*verdict=\([a-z]*\).*/\1/p')"
      [ -n "$verdict" ] || verdict="unknown"
    fi
    printf '%s' "$pr" | jq -c --arg v "$verdict" '.gate_verdict = $v'
  done | jq -sc '.'
}

activity_json() {
  if [ "${FWF_ISSUES:-gh}" = "local" ]; then
    echo '{"building":[],"in_test":[],"merged":[]}'; return 0
  fi
  local open merged
  open="$(gh_pr list --state open --limit 50 \
            --json number,title,isDraft,baseRefName,headRefName,headRefOid,statusCheckRollup 2>/dev/null || true)"
  merged="$(gh_pr list --state merged --limit 12 \
            --json number,title,baseRefName,headRefName,mergedAt 2>/dev/null || true)"
  [ -n "$open" ] || open='[]'
  [ -n "$merged" ] || merged='[]'
  open="$(_activity_attach_gate_verdict "$open")"
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
                    | {pr:.number, role:role, issue:issue, base:$b, checks:checks, gate_verdict:(.gate_verdict // "unknown"), title:.title} ],
        in_test:  [ $open[]   | .baseRefName as $b | select($t|index($b)) | select(.isDraft|not)
                    | {pr:.number, role:role, issue:issue, base:$b, checks:checks, gate_verdict:(.gate_verdict // "unknown"), title:.title} ],
        merged:   [ $merged[] | .baseRefName as $b | select($t|index($b))
                    | {pr:.number, role:role, issue:issue, base:$b,
                       when:((.mergedAt // "")[5:16] | gsub("T";" ")), title:.title} ],
        to_main:  [ $open[]   | select(.baseRefName == $default)
                    | {pr:.number, role:role, issue:issue, base:.baseRefName, checks:checks, gate_verdict:(.gate_verdict // "unknown"), title:.title} ]
      }'
}

# --- unrouted PRs (issue #194 AC (d)) ---------------------------------------
# A PR whose fwf-Reviewer: assignment is "none", absent with no branch-prefix
# fallback, or names a configured QA seat that isn't currently live -- so a
# PR nobody can reach is structurally distinguishable from one being actively
# reviewed. NOT YET rendered by the dash/ (Rust) frontend -- this emits the
# data half; dash/src/data.rs consuming it into a visible panel is separate
# follow-up work (no cargo test harness for dash/ lives in THIS repo's gate).
# $1 = roles_json (for which qaN seats are currently live)
unrouted_prs_json() {
  local roles_j="${1:-[]}"
  if [ "${FWF_ISSUES:-gh}" = "local" ]; then echo '[]'; return 0; fi
  local open live_qa
  open="$(gh_pr list --state open --json number,headRefName,isDraft,author,createdAt,body,comments 2>/dev/null || true)"
  [ -n "$open" ] || open='[]'
  live_qa="$(printf '%s' "$roles_j" | jq -c '[.[] | select(.role|test("^qa[0-9]+$")) | select(.state!="down") | .role]')"
  jq -n --argjson open "$open" --argjson live "$live_qa" '
    def marker_of($body): ($body | capture("(?m)^fwf-Reviewer:[ \t]*(?<v>[A-Za-z0-9_-]+)"; "").v) // null;
    def resolved($pr):
      ([$pr.comments[]? | select((.body // "") | test("(?m)^fwf-Reviewer:"))] | sort_by(.createdAt) | last) as $c
      | if $c != null then (marker_of($c.body // "") // null) else (marker_of($pr.body // "") // null) end;
    def fallback($pr):
      (($pr.headRefName | capture("^impl(?<n>[0-9]+)/"; "").n) // null) as $n | if $n then "qa"+$n else null end;
    [ $open[] | select(.isDraft|not)
      | . as $pr
      | (resolved($pr)) as $r
      | (
          if   $r == "none" then "no QA seat configured"
          elif $r == null and (fallback($pr) == null) then "no fwf-Reviewer marker and branch does not match implN/*"
          elif $r == null then null
          elif ($live | index($r)) then null
          else "assigned to " + $r + ", which is not currently live"
          end
        ) as $reason
      | select($reason != null)
      | {pr:$pr.number, author:($pr.author.login // "unknown"), branch:$pr.headRefName,
         created_at:($pr.createdAt // ""), reason:$reason}
    ]'
}

# --- assemble ---------------------------------------------------------------
main() {
  local prod pipeline stamp parked gen issues roles decisions activity needs_you floor_idle upgrade unrouted_prs visibility stranded_assignments
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
  floor_idle="$(floor_idle_json)"
  issues="$(open_issues_json)"
  roles="$(roles_json "$floor_idle")"
  decisions="$(decisions_json "$issues")"
  activity="$(activity_json)"
  needs_you="$(needs_you_json)"
  upgrade="$(upgrade_json)"
  installed="$(installed_version_json)"
  unrouted_prs="$(unrouted_prs_json "$roles")"
  visibility="$(visibility_json)"
  api_budget="$(api_budget_json)"
  claim_refusals="$(claim_refusals_json)"
  stranded_assignments="$(stranded_assignments_json)"

  # #291: roles/decisions/issues/activity/needs_you/unrouted_prs/visibility can
  # each carry full comment-thread bodies (open_issues_json, unrouted_prs_json
  # etc. pull .body/.comments straight off gh), so on a repo with verbose
  # threads their combined size blows ARG_MAX when passed as --argjson on the
  # command line -- jq then exits 126 with "Argument list too long" and takes
  # the WHOLE data provider down with it (every dash tab reads a confident,
  # wrong 0 -- see dash/src/main.rs render_tabs). Route them through files on
  # stdin (--slurpfile) instead, so argv only ever carries short scalars; the
  # rest (parked/prod/floor_idle/upgrade/installed/api_budget/claim_refusals)
  # are small fixed-shape values with no comment-body content and stay as
  # --argjson. mktemp -d + trap RETURN keeps this self-cleaning even on error.
  local _ddir
  _ddir="$(mktemp -d)" || { echo '{"error":"mktemp failed"}'; return 1; }
  trap 'rm -rf "$_ddir"' RETURN
  printf '%s' "$roles"        > "$_ddir/roles.json"
  printf '%s' "$decisions"    > "$_ddir/decisions.json"
  printf '%s' "$issues"       > "$_ddir/issues.json"
  printf '%s' "$activity"     > "$_ddir/activity.json"
  printf '%s' "$needs_you"    > "$_ddir/needs_you.json"
  printf '%s' "$unrouted_prs" > "$_ddir/unrouted_prs.json"
  printf '%s' "$visibility"   > "$_ddir/visibility.json"

  # issue #188: resolution is otherwise invisible (the #30/#31 class of pain)
  # -- surface which absolute profile file actually loaded and how, plus any
  # name an out-of-tree profile set that got dropped (not in the allowlist).
  # Data-layer only, following the unrouted_prs precedent (#194 AC d): dash/
  # src/data.rs does not yet deserialize or render this field; query
  # `fwf-dash-data.sh` directly (or `.profile_resolution` off its JSON).
  profile_resolution="$(jq -n --arg path "${PROFILE_FILE:-}" --arg mode "${FWF_PROFILE_RESOLUTION_MODE:-}" \
    --arg dropped "${FWF_PROFILE_DROPPED_NAMES:-}" \
    '{path:$path, mode:$mode, dropped:($dropped | split(" ") | map(select(length>0)))}')"

  jq -n \
    --arg profile "$PROFILE" --arg template "$FWF_TEMPLATE" \
    --argjson parked "$parked" \
    --arg prod "$prod" --arg pipeline "$pipeline" --arg stamp "$stamp" --arg gen "$gen" \
    --slurpfile _roles "$_ddir/roles.json" --slurpfile _decisions "$_ddir/decisions.json" \
    --slurpfile _issues "$_ddir/issues.json" --slurpfile _activity "$_ddir/activity.json" \
    --slurpfile _needs_you "$_ddir/needs_you.json" \
    --slurpfile _unrouted_prs "$_ddir/unrouted_prs.json" \
    --slurpfile _visibility "$_ddir/visibility.json" \
    --argjson floor_idle "$floor_idle" --argjson upgrade "$upgrade" --argjson installed "$installed" \
    --argjson api_budget "$api_budget" \
    --argjson claim_refusals "$claim_refusals" --argjson profile_resolution "$profile_resolution" \
    --argjson stranded_assignments "$stranded_assignments" \
    '{profile:$profile, template:$template, parked:$parked, prod:$prod, pipeline:$pipeline,
      stamp:$stamp, generated_at:$gen, roles:$_roles[0], decisions:$_decisions[0], issues:$_issues[0],
      activity:$_activity[0], needs_you:$_needs_you[0], floor_idle:$floor_idle, upgrade:$upgrade,
      installed:$installed, unrouted_prs:$_unrouted_prs[0], visibility:$_visibility[0], api_budget:$api_budget,
      claim_refusals:$claim_refusals, profile_resolution:$profile_resolution,
      stranded_assignments:$stranded_assignments}'
  rm -f "$LIST_DEGRADED_FILE" 2>/dev/null   # issue #266: this PID's scratch signal, done with it
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

# --- versioned snapshot (issue #206) -----------------------------------------
# `fwf dash --emit-snapshot` -> the scrubbed, allowlisted subset of the board
# this ticket names as safe to leave the box: roles, issues, heartbeat ages,
# schema version. NOT the full board -- decisions/pipeline/prod/activity/
# needs_you/unrouted_prs/api_budget/etc. stay local-only; a remote dash is a
# read-only roles+issues view, not full parity, and that narrowing is what
# keeps the allowlist short enough to audit.
#
# CONSTRUCTION, NOT SUBTRACTION (AC j2): every field below is named
# explicitly, both at the top level and INSIDE each roles[]/issues[] object --
# `roles_json`/`open_issues_json` are reused for their derivation logic, but
# their per-item objects are rebuilt field-by-field here rather than passed
# through whole, so a field added to either of those functions' internal
# JSON cannot reach the snapshot without someone naming it on the line below.
# This is the property the AC (j2) test asserts directly: stub roles_json to
# return an extra key and confirm it does not survive this reconstruction.
#
# NO PROCESS ENVIRONMENT, NO TOKENS, NO FILE CONTENTS ever touch this
# function -- verified structurally (grep the source), not by scanning
# output for what looks credential-shaped after the fact (AC j's own
# framing: that scan is a regression backstop, not the mechanism).
emit_snapshot() {
  local floor_idle roles issues gen _sdir
  floor_idle="$(floor_idle_json)"
  roles="$(roles_json "$floor_idle")"
  issues="$(open_issues_json)"
  gen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # #291's own lesson, reproduced here rather than reread: open_issues_json
  # carries every open issue's full body text, so on this repo's corpus the
  # combined payload blows ARG_MAX passed as --argjson on the command line
  # -- route through files (--slurpfile) instead, exactly like main() does.
  _sdir="$(mktemp -d)" || { echo '{"error":"mktemp failed"}'; return 1; }
  trap 'rm -rf "$_sdir"' RETURN
  printf '%s' "$roles"  > "$_sdir/roles.json"
  printf '%s' "$issues" > "$_sdir/issues.json"
  jq -n \
    --argjson schema_version "$DASH_SNAPSHOT_SCHEMA_VERSION" \
    --arg profile "$PROFILE" --arg gen "$gen" \
    --slurpfile _roles "$_sdir/roles.json" --slurpfile _issues "$_sdir/issues.json" \
    '{
       schema_version: $schema_version,
       profile: $profile,
       generated_at: $gen,
       roles: [$_roles[0][] | {role, state, detail, heartbeat_age}],
       issues: [$_issues[0][] | {number, title, gated}]
     }'
}

# Dispatch only when run directly. Sourcing the script (e.g. from the test
# suite) just loads the functions so they can be unit-tested with stubbed
# di_read/gh_pr/status — no gh, no tmux (#52).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--emit-snapshot" ]; then
    emit_snapshot
    exit 0
  fi
  if [ "${1:-}" = "detail" ]; then
    detail_view "${2:-}"
    exit 0
  fi
  main
fi
