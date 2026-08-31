#!/usr/bin/env bash
# fwf-gate-verdict-watchdog.sh — issue #469: a recorded GREEN gate-tip
# verdict is a claim on the pipeline, not a passive record. On 2026-08-31
# `local-ci` recorded GREEN for staging c9a338d at 06:35:24, durable in the
# role-keyed gate-tip store (lib.sh fwf_gate_tip_record/#202) -- and nothing
# noticed that it went unconsumed for ~27 minutes while the conductor sat
# wedged on an unrelated foreign prompt (#466/#467). A reviewing agent's
# human-style pane read at 06:28:40 saw a frozen tick and judged it
# "consistent with a long promote cycle" -- correct-looking and wrong. This
# is the mechanical, verdict-anchored backstop: it does not ask whether the
# conductor LOOKS busy, only whether a recorded green was actually consumed.
#
# THE OBLIGED CALL SITE (#462 AC 3's own lesson, repeated on this very
# incident): reuse the existing needs-captain mechanism (#113), same as
# #385's fwf-pr-route-check.sh, rather than inventing a new channel --
# `fwf flag-captain sweep` is ALREADY run, ENFORCED, on every captain tick
# (templates/dev/captain.tmpl). This script is wired into that SAME line,
# right alongside `fwf pr-route-check sweep`, so it inherits the same
# obligation and the same liveness guarantee: if the captain's own tick
# (#99) stops advancing, the existing pane-liveness/respawn machinery
# catches THAT independently of this check -- this ticket does not need a
# second scheduler, it needs a call site that already exists and is bound.
#
# WHAT IS WATCHED: the ROLE-keyed gate-tip record (fwf_gate_tip_marker_path,
# lib.sh #202) for one role -- default "conductor", the only role that ever
# gates the promotion path. That record is overwritten on every gate run,
# so its current contents (tip sha, verdict, recorded-at) always reflect the
# MOST RECENT gate outcome; an older, still-unpromoted green is naturally
# treated as superseded the moment a newer verdict (green or red) lands for
# a newer tip, with no separate bookkeeping required.
#
# NO NATURAL PR/ISSUE NUMBER: a stalled promotion is not about any one
# implementer's PR (it may bundle several commits) -- it is about the
# PIPELINE. So, mirroring fwf-reconcile-guard.sh's (#179) already-accepted
# shape (a single marker-tagged tracking issue, found by grepping its body
# for a stable key, updated in place, closed automatically on resolution),
# this raises `needs-captain` on ONE durable tracking issue rather than
# guessing a "Closes #n" target from the stalled commit.
#
# GH-ONLY, matching fwf-reconcile-guard.sh's own precedent: a promotion
# stall is a floor-wide pipeline concern, not a per-issue one, so there is
# no local-issues analogue to build parity for (the local backend has no PR
# concept either, per fwf-pr-route-check.sh's own header comment).
#
# ACTED ON (any one clears the claim):
#   - INTEGRATION_BRANCH has advanced to include the recorded tip, OR
#   - a newer verdict (green or red) has been recorded for a newer tip
#     (superseded), OR
#   - a release freeze is in effect (issue release-hold label present
#     anywhere in the open tracker -- docs/tutorial.md's own description of
#     what a "release freeze" IS: the PM applies release-hold broadly for
#     the duration).
#
# THE WINDOW (issue's own measured basis): timing starts from the verdict
# being RECORDED, not from when the gate began -- the ~1450s e2e run itself
# never counts against it. The incident's own recovery (respawn at 06:38:23
# -> integration advanced at 06:44, ~5.5 minutes) nearly falsifies a tight
# bound, so the default sits comfortably above that single measured healthy
# interval: FWF_GATE_VERDICT_WATCHDOG_WINDOW_SECS, default 1200 (20m).
#
# BACKOFF (AC 9 -- stated, not left implicit): a persisting stall
# RE-ANNOUNCES on the SAME fixed interval as the initial window, not once
# and never again -- so a stall that runs for hours produces a comment
# roughly every WINDOW_SECS, not one flag that ages into silence.
#
# Usage: fwf gate-verdict-watchdog sweep [--role ROLE]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

WATCHDOG_ROLE_TAG="gate-verdict-watchdog"
DEFAULT_WATCH_ROLE="conductor"
WINDOW_SECS="${FWF_GATE_VERDICT_WATCHDOG_WINDOW_SECS:-1200}"
GH="${FWF_GH:-gh}"

# --- controllable clock (AC 1: tests must not sleep for the real window) ---
now_epoch() { echo "${FWF_GATE_VERDICT_WATCHDOG_NOW_EPOCH:-$(date -u +%s)}"; }

# --- gh access, cd'd into the repo so {owner}/{repo} placeholders resolve --
gh_() { if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && "$GH" "$@" ); else "$GH" "$@"; fi; }

# --- gate-tip record (issue #202/#237's own store) --------------------------
# $1=role -> "sha verdict recorded" on stdout, or nonzero with no output if
# there is no record, or it is present but unreadable/malformed (#211: an
# absent/broken record is UNKNOWN, never confidently "not gated").
tip_record() {
  local role="${1:?tip_record needs a role}" f sha verdict recorded
  f="$(fwf_gate_tip_marker_path "$role")"
  [ -f "$f" ] || return 1
  sha="$(_fwf_gate_owner_field tip "$f")"
  verdict="$(_fwf_gate_owner_field verdict "$f")"
  recorded="$(_fwf_gate_owner_field recorded "$f")"
  [ -n "$sha" ] && [ -n "$verdict" ] || return 1
  printf '%s %s %s\n' "$sha" "$verdict" "${recorded:-0}"
}

# --- "has INTEGRATION_BRANCH advanced to include this sha" ------------------
# 0 = yes (acted on). 1 = no. Fetches first so a stale local view never
# reports a false stall.
integration_includes() {
  local sha="$1"
  git -C "$FWF_REPO" fetch origin "$INTEGRATION_BRANCH" >/dev/null 2>&1 || return 1
  git -C "$FWF_REPO" merge-base --is-ancestor "$sha" "origin/$INTEGRATION_BRANCH" 2>/dev/null
}

# --- release freeze (docs/tutorial.md: the PM applies HOLD_LABEL broadly
# for the duration of a freeze) -- any open item carrying it means a freeze
# is on right now, regardless of which item this stalled sha is "about".
release_freeze_active() {
  local n
  n="$(gh_ issue list --state open --label "$HOLD_LABEL" --json number --jq 'length' 2>/dev/null)" || return 1
  case "$n" in ''|*[!0-9]*) return 1;; esac
  [ "$n" -gt 0 ]
}

# --- the one durable tracking issue (mirrors fwf-reconcile-guard.sh #179) --
TRACK_MARKER_KEY="fwf-gate-verdict-watchdog:v1"
TRACK_MARKER="<!-- $TRACK_MARKER_KEY -- do not remove, this key is how the watchdog finds this issue -->"
TRACK_TITLE="[gate-verdict-watchdog] a green gate verdict has not been promoted"

tracking_issue_find() {
  gh_ issue list --state open --limit 100 --json number,body \
    --jq ".[] | select(.body != null and (.body | contains(\"$TRACK_MARKER_KEY\"))) | .number" \
    2>/dev/null | head -1
}

tracking_body() { # $1=sha $2=elapsed-secs
  cat <<BODY
$TRACK_MARKER

**Automated.** A GREEN gate-tip verdict for \`$1\` (fwf-gate-tip-record,
issue #202) has not been promoted into \`$INTEGRATION_BRANCH\` for ${2}s --
past the ${WINDOW_SECS}s window this watchdog uses (issue #469). A recorded
green verdict is a claim on the pipeline, not a passive record: something is
blocking the conductor from consuming it (a wedged loop, a stuck pane, an
unresolved question -- see #466/#467 for the incident this backstops).

### What to check

- Is the conductor's pane actually alive? \`fwf dash\` / attach and look.
- The conductor's own tick counter (issue #99) -- static means it stopped
  advancing a cycle, not merely that a long e2e run is in progress.
- If wedged, a respawn (\`fwf respawn conductor\`) is usually what unsticks it.

This issue closes itself automatically once \`$INTEGRATION_BRANCH\` advances
to include \`$1\`, a newer green verdict supersedes it, or a release freeze
(\`$HOLD_LABEL\`) is declared.
BODY
}

tracking_issue_create() { # $1=sha $2=elapsed -> echoes the new issue number
  gh_ issue create --title "$TRACK_TITLE" --body "$(tracking_body "$1" "$2")" \
    --json number --jq .number 2>/dev/null
}

tracking_issue_update_body() { # $1=num $2=sha $3=elapsed
  gh_ issue edit "$1" --body "$(tracking_body "$2" "$3")" >/dev/null 2>&1 || true
}

tracking_issue_close() { # $1=num $2=note
  gh_ issue close "$1" --comment "$2" >/dev/null 2>&1 || true
}

# find-or-create, then refresh its body to the CURRENT sha/elapsed either way
# (so a re-announced stall's body always reflects the latest numbers, not
# the ones from when it was first filed).
tracking_target() { # $1=sha $2=elapsed -> echoes the issue number
  local sha="$1" elapsed="$2" num
  num="$(tracking_issue_find || true)"
  if [ -z "$num" ]; then
    num="$(tracking_issue_create "$sha" "$elapsed" || true)"
    case "$num" in ''|*[!0-9]*) return 1;; esac
  else
    tracking_issue_update_body "$num" "$sha" "$elapsed"
  fi
  printf '%s\n' "$num"
}

# --- flag-captain bridge (issue #113), same shape as fwf-pr-route-check.sh --
flag_captain_raise() { "$DIR/fwf-flag-captain.sh" "$1" --role "$WATCHDOG_ROLE_TAG" --reason "$2" >/dev/null; }
flag_captain_clear() { "$DIR/fwf-flag-captain.sh" "$1" --clear --note "$2" >/dev/null; }

# --- per-role dedupe/backoff state (AC 4/9) ----------------------------------
state_path() { echo "$FWF_STATE_DIR/gate-verdict-watchdog/$1"; } # $1=watched role

state_read() { # $1=role -> "sha flagged_at count" or nonzero+empty if none
  local f="$1" sha flagged_at count
  f="$(state_path "$1")"
  [ -f "$f" ] || return 1
  sha="$(_fwf_gate_owner_field sha "$f")"
  flagged_at="$(_fwf_gate_owner_field flagged_at "$f")"
  count="$(_fwf_gate_owner_field count "$f")"
  [ -n "$sha" ] || return 1
  printf '%s %s %s\n' "$sha" "${flagged_at:-0}" "${count:-0}"
}

state_write() { # $1=role $2=sha $3=flagged_at $4=count
  local f; f="$(state_path "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf 'sha=%s\nflagged_at=%s\ncount=%s\n' "$2" "$3" "$4" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

state_clear() { rm -f "$(state_path "$1")" 2>/dev/null || true; }

# clear an active flag/close the tracking issue for a resolved stall (AC 5/6:
# superseded or promoted or frozen no longer needs the flag) -- a no-op if
# nothing is currently tracked, so callers never need to check first.
resolve_flag() { # $1=role $2=note
  local role="$1" note="$2" num
  num="$(tracking_issue_find || true)"
  if [ -n "$num" ]; then
    flag_captain_clear "$num" "$note"
    tracking_issue_close "$num" "$note"
  fi
  state_clear "$role"
}

cmd_sweep() {
  local role="$DEFAULT_WATCH_ROLE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2;;
      *) echo "fwf gate-verdict-watchdog: unknown flag '$1'" >&2; return 2;;
    esac
  done

  local rec tip verdict recorded
  if ! rec="$(tip_record "$role")"; then
    echo "gate-verdict-watchdog: no gate-tip record for role '$role' -- nothing to watch"
    return 0
  fi
  read -r tip verdict recorded <<<"$rec"

  local st st_sha st_flagged_at st_count
  st_sha=""; st_flagged_at=0; st_count=0
  if st="$(state_read "$role")"; then
    read -r st_sha st_flagged_at st_count <<<"$st"
  fi

  if [ "$verdict" != green ]; then
    if [ -n "$st_sha" ]; then
      resolve_flag "$role" "latest verdict for role '$role' is now '$verdict' for a newer tip -- the earlier unpromoted green ($st_sha) is superseded"
    fi
    echo "gate-verdict-watchdog: role '$role''s latest verdict is '$verdict' (not green) -- nothing to watch"
    return 0
  fi

  # verdict == green from here on. A DIFFERENT sha than what we last tracked
  # means a newer green superseded an older, still-unpromoted one (AC 5) --
  # clear that old flag before evaluating the new tip fresh.
  if [ -n "$st_sha" ] && [ "$st_sha" != "$tip" ]; then
    resolve_flag "$role" "superseded by a newer GREEN verdict for $tip"
    st_sha=""; st_flagged_at=0; st_count=0
  fi

  if integration_includes "$tip"; then
    if [ -n "$st_sha" ]; then
      resolve_flag "$role" "$INTEGRATION_BRANCH has advanced to include $tip"
      echo "gate-verdict-watchdog: $tip now reflected in $INTEGRATION_BRANCH -- cleared"
    else
      echo "gate-verdict-watchdog: $tip already reflected in $INTEGRATION_BRANCH -- nothing to watch"
    fi
    return 0
  fi

  local now elapsed
  now="$(now_epoch)"
  case "$recorded" in ''|*[!0-9]*) recorded=0;; esac
  elapsed=$(( now - recorded ))
  if [ "$elapsed" -lt "$WINDOW_SECS" ]; then
    echo "gate-verdict-watchdog: green verdict for $tip recorded ${elapsed}s ago -- within the ${WINDOW_SECS}s window, not stalled yet"
    return 0
  fi

  if release_freeze_active; then
    if [ -n "$st_sha" ]; then
      resolve_flag "$role" "a release freeze ($HOLD_LABEL) is in effect -- a deliberate hold, not a stall"
      echo "gate-verdict-watchdog: release freeze in effect -- cleared the flag on $tip"
    else
      echo "gate-verdict-watchdog: a release freeze ($HOLD_LABEL) is in effect for the ${elapsed}s-old verdict on $tip -- a deliberate hold, not a stall"
    fi
    return 0
  fi

  # A genuine, unresolved stall.
  if [ -n "$st_sha" ]; then
    local since=$(( now - st_flagged_at ))
    if [ "$since" -lt "$WINDOW_SECS" ]; then
      echo "gate-verdict-watchdog: $tip already flagged ${since}s ago -- waiting for the next ${WINDOW_SECS}s backoff interval"
      return 0
    fi
    local num nextcount=$(( st_count + 1 ))
    num="$(tracking_target "$tip" "$elapsed")" || { echo "gate-verdict-watchdog: could not file/find the tracking issue" >&2; return 1; }
    flag_captain_raise "$num" "still stalled: green verdict for $tip recorded ${elapsed}s ago, $INTEGRATION_BRANCH has not advanced (re-announcement #$nextcount, issue #469)"
    state_write "$role" "$tip" "$now" "$nextcount"
    echo "gate-verdict-watchdog: re-flagged $tip (stalled ${elapsed}s, backoff interval elapsed, announcement #$nextcount)"
  else
    local num
    num="$(tracking_target "$tip" "$elapsed")" || { echo "gate-verdict-watchdog: could not file/find the tracking issue" >&2; return 1; }
    flag_captain_raise "$num" "green verdict for $tip recorded ${elapsed}s ago (>= ${WINDOW_SECS}s window), $INTEGRATION_BRANCH has not advanced (issue #469)"
    state_write "$role" "$tip" "$now" "1"
    echo "gate-verdict-watchdog: flagged $tip (stalled ${elapsed}s)"
  fi
}

main() {
  case "${1:-}" in
    sweep) shift; cmd_sweep "$@";;
    *) echo "fwf gate-verdict-watchdog: usage: fwf gate-verdict-watchdog sweep [--role ROLE]" >&2; return 2;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
