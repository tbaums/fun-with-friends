#!/usr/bin/env bash
# fwf-gate-recover.sh — issue #473: the conductor's OBLIGED call site for
# self-recovering a non-final verdict on an unmoved tip, instead of
# escalating to a human on both of the incidents that filed this ticket.
#
# WHEN THIS RUNS: the conductor's promote gate (__PROMOTE_GATE__, fwf-gate.sh
# --tip-cmd) exits 75 (EX_SKIPPED) whenever the watched tip is unchanged AND
# a COMPLETED verdict (green or red — fwf_gate_tip_unchanged, lib.sh) is
# already on record for it. Two real incidents hid behind that one exit
# code with opposite correct actions:
#
#   1. An unconsumed GREEN (the gate ran, recorded PASS, but the conductor
#      died before promoting). The recorded verdict already authorizes a
#      promote — no re-run needed, EVER (AC 2).
#   2. An unconfirmed RED with no new commit. `fwf-gate.sh:55`'s own
#      documented escape hatch (FWF_GATE_FORCE=1) exists for exactly this,
#      but nothing was calling it (AC 1).
#
# Usage: fwf gate-recover <role> <target-branch>
#   Reads <role>'s CURRENT gate-tip record (the same one fwf-gate.sh's
#   --tip-cmd just consulted to produce the 75 this script is a response
#   to) and acts on it. Never re-resolves the watched ref itself — the
#   record IS the tip to act on (issue #254's own reasoning, reused).
#
# Exit codes:
#   0   an action was taken and succeeded (promoted directly, or a
#       force-resume run confirmed and then promoted).
#   75  nothing actionable this cycle — already consumed, or (for a red
#       tip) still within the bounded retry budget with no confirmed
#       result yet. Never a failure; the next cycle tries again.
#   1   escalated — see stderr. A kill switch was off, `fwf gate-promote`
#       itself refused (AC 3 — never bypassed, never retried with force),
#       or the force-resume budget for this tip is exhausted (AC 1's own
#       "escalates only once the bound is exhausted, and says so").
#
# KILL SWITCHES (AC 9), independent, both env-var opt-outs so today's plain
# escalate-to-human behaviour is always one line away without a revert:
#   FWF_CONDUCTOR_AUTO_PROMOTE       default "1" (on) — AC 2's automatic
#                                    promote-a-consumed-green half.
#   FWF_CONDUCTOR_AUTO_FORCE_RESUME  default "0" (off) — AC 1's automatic
#                                    force-resume-a-red half. Off by
#                                    default: this is the half that can
#                                    MANUFACTURE a green out of a red (AC 5
#                                    fences it), so it is opt-in per profile
#                                    by someone who has read that fence,
#                                    never on by omission.
#
# BOUNDED, PER-TIP RETRY (AC 4): FWF_CONDUCTOR_FORCE_RESUME_MAX (default 2,
# matching scripts/conductor-e2e.sh's own #446 precedent of "N=2 forced
# re-runs beyond the first"). Keyed to the tip SHA in
# $FWF_STATE_DIR/gate-recover-retries/<role>, so a NEW commit gets a fresh
# budget (a different sha never shares the old one's count) and a
# persistently-red tip cannot re-run forever.
#
# NOT "RETRY UNTIL GREEN" (AC 5): #436 already decided that a tip which has
# genuinely failed once needs TWO CONSECUTIVE greens, not one, before it is
# trustworthy again — policy that lives in fwf-local-ci.sh's own verdict
# store, consulted through its EXIT CODE (never by reading its verdict file
# and eyeballing whether it starts with "green" — that is precisely how a
# caller silently bypasses a "recovered:1", not-yet-confirmed state). A
# force-resume attempt therefore runs through `fwf-local-ci.sh run`/`verdict`
# rather than a bare re-invocation of the wrapped gate command: this SHA is
# first seeded into that store as "has failed" (mark-failed, idempotent —
# never resets progress already made toward a SECOND confirming green), so
# the FIRST successful forced re-run correctly lands as an unconfirmed
# recovered:1, not a bare, promotable green.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

LOCAL_CI="$DIR/fwf-local-ci.sh"
GATE_PROMOTE="$DIR/fwf-gate-promote.sh"
RECOVER_ROLE_TAG="gate-recover"
FORCE_RESUME_MAX="${FWF_CONDUCTOR_FORCE_RESUME_MAX:-2}"
AUTO_PROMOTE="${FWF_CONDUCTOR_AUTO_PROMOTE:-1}"
AUTO_FORCE_RESUME="${FWF_CONDUCTOR_AUTO_FORCE_RESUME:-0}"
EX_SKIPPED=75

usage() { echo "usage: fwf gate-recover <role> <target-branch>" >&2; }

# --- gh access, cd'd into the repo so {owner}/{repo} placeholders resolve --
gh_() { if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh "$@" ); else gh "$@"; fi; }

# --- "has <target> advanced to include this sha" (mirrors #469's watchdog) -
# $2=target, passed explicitly (not read from an outer-scope var) so this
# and every other seam below can be overridden wholesale in a test the same
# way fwf-gate-verdict-watchdog.sh's own tests already do (source the real
# script, redefine the small seams, call main directly).
integration_includes() {
  local sha="$1" target="$2"
  git -C "$FWF_REPO" fetch origin "$target" >/dev/null 2>&1 || return 1
  git -C "$FWF_REPO" merge-base --is-ancestor "$sha" "origin/$target" 2>/dev/null
}

# --- the actual promote call (AC 3: the ONLY path that ever advances
# <target> — never a raw git sequence, never called on a belief the check
# already passed) ------------------------------------------------------------
gate_promote_call() { "$GATE_PROMOTE" "$1" "$2"; } # $1=role $2=target

# --- force-resume's suite execution + confirmation (AC 5) -------------------
local_ci_mark_failed() { "$LOCAL_CI" mark-failed "$1" >&2; }
local_ci_run() { ( cd "$FWF_REPO" && "$LOCAL_CI" run ); }
local_ci_verdict() { "$LOCAL_CI" verdict "$1" >&2; }

# --- per-tip retry state (AC 4) ---------------------------------------------
retry_state_path() { echo "$FWF_STATE_DIR/gate-recover-retries/$1"; } # $1=role

retry_state_read() { # $1=role -> "sha count" or nonzero+empty if none
  local f sha count
  f="$(retry_state_path "$1")"
  [ -f "$f" ] || return 1
  sha="$(_fwf_gate_owner_field sha "$f")"
  count="$(_fwf_gate_owner_field count "$f")"
  [ -n "$sha" ] || return 1
  printf '%s %s\n' "$sha" "${count:-0}"
}

retry_state_write() { # $1=role $2=sha $3=count
  local f; f="$(retry_state_path "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf 'sha=%s\ncount=%s\n' "$2" "$3" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# --- escalation: a durable tracking issue, mirroring #469's own precedent --
TRACK_MARKER_KEY="fwf-gate-recover:v1"
TRACK_MARKER="<!-- $TRACK_MARKER_KEY -- do not remove, this key is how gate-recover finds this issue -->"
TRACK_TITLE="[gate-recover] the promote gate needs a human"

tracking_issue_find() {
  gh_ issue list --state open --limit 100 --json number,body \
    --jq ".[] | select(.body != null and (.body | contains(\"$TRACK_MARKER_KEY\"))) | .number" \
    2>/dev/null | head -1
}

tracking_body() { cat <<BODY # $1=role $2=reason
$TRACK_MARKER

**Automated (issue #473).** The conductor's promote gate for role \`$1\`
could not self-recover and needs a human: $2
BODY
}

tracking_target() { # $1=role $2=reason -> echoes the issue number
  local role="$1" reason="$2" num
  num="$(tracking_issue_find || true)"
  if [ -z "$num" ]; then
    num="$(gh_ issue create --title "$TRACK_TITLE" --body "$(tracking_body "$role" "$reason")" --json number --jq .number 2>/dev/null)"
    case "$num" in ''|*[!0-9]*) return 1;; esac
  else
    gh_ issue edit "$num" --body "$(tracking_body "$role" "$reason")" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$num"
}

flag_captain_raise() { "$DIR/fwf-flag-captain.sh" "$1" --role "$RECOVER_ROLE_TAG" --reason "$2" >/dev/null; }

escalate() { # $1=role $2=reason -- AC 1/9: "escalates ... and says so"
  local role="$1" reason="$2" num
  num="$(tracking_target "$role" "$reason")" || { echo "fwf gate-recover: ESCALATING but could not file/find the tracking issue: $reason" >&2; return 1; }
  flag_captain_raise "$num" "$reason"
  echo "fwf gate-recover: ESCALATED (#$num) — $reason" >&2
}

main() {
  local role="${1:-}" target="${2:-}"
  if [ -z "$role" ] || [ -z "$target" ]; then usage; return 2; fi

  # --- read the record fwf-gate.sh's --tip-cmd just consulted ---------------
  local marker tip verdict
  marker="$(fwf_gate_tip_marker_path "$role")"
  if [ ! -f "$marker" ]; then
    echo "fwf gate-recover: no gate-tip record for role '$role' — nothing to recover" >&2
    return "$EX_SKIPPED"
  fi
  tip="$(_fwf_gate_owner_field tip "$marker")"
  verdict="$(_fwf_gate_owner_field verdict "$marker")"
  if [ -z "$tip" ] || [ -z "$verdict" ]; then
    echo "fwf gate-recover: role '$role''s gate-tip record is unreadable/malformed — nothing to recover" >&2
    return "$EX_SKIPPED"
  fi

  case "$verdict" in
    green)
      if [ "$AUTO_PROMOTE" = 0 ]; then
        echo "fwf gate-recover: FWF_CONDUCTOR_AUTO_PROMOTE=0 — leaving the unconsumed green for $tip to a human (AC 9)" >&2
        return "$EX_SKIPPED"
      fi
      if integration_includes "$tip" "$target"; then
        echo "fwf gate-recover: $tip is already reflected in $target — nothing to promote (AC 6)"
        return "$EX_SKIPPED"
      fi
      echo "fwf gate-recover: AC(2) — unconsumed green for $tip, promoting with no suite re-run"
      local out
      if out="$(gate_promote_call "$role" "$target" 2>&1)"; then
        printf '%s\n' "$out"
        return 0
      fi
      printf '%s\n' "$out" >&2
      escalate "$role" "fwf gate-promote refused for the recorded green $tip: $out" || true
      return 1
      ;;

    red)
      if [ "$AUTO_FORCE_RESUME" = 0 ]; then
        escalate "$role" "AC(9): FWF_CONDUCTOR_AUTO_FORCE_RESUME=0 — red tip $tip needs a human (force-resume is opt-in per profile)" || true
        return 1
      fi

      local st local_sha="" local_count=0
      if st="$(retry_state_read "$role")"; then
        read -r local_sha local_count <<<"$st"
      fi
      case "$local_count" in ''|*[!0-9]*) local_count=0;; esac
      if [ "$local_sha" != "$tip" ]; then
        # AC 4: a different (or first-seen) tip always gets a fresh budget.
        local_sha="$tip"; local_count=0
      fi

      if [ "$local_count" -ge "$FORCE_RESUME_MAX" ]; then
        escalate "$role" "AC(1): force-resume bound exhausted ($local_count/$FORCE_RESUME_MAX attempts) for red tip $tip, still not confirmed" || true
        return 1
      fi

      local_count=$((local_count + 1))
      retry_state_write "$role" "$tip" "$local_count"
      echo "fwf gate-recover: AC(1) — force-resume attempt $local_count/$FORCE_RESUME_MAX for red tip $tip"

      # AC 5: seed the SHA-keyed store's "has failed" state before
      # consulting it, so a first confirming green lands as recovered:1
      # (not skip-eligible) rather than a bare, promotable green --
      # idempotent, so a SECOND attempt never resets progress already made.
      local_ci_mark_failed "$tip"

      local run_out
      if run_out="$(local_ci_run 2>&1)"; then
        printf '%s\n' "$run_out"
        if local_ci_verdict "$tip" >/dev/null 2>&1; then
          echo "fwf gate-recover: AC(5) — $tip confirmed (two consecutive greens), authorizing the promote"
          fwf_gate_tip_record "$role" "$tip" green "force-resume confirmed (issue #473, attempt $local_count/$FORCE_RESUME_MAX)"
          if out="$(gate_promote_call "$role" "$target" 2>&1)"; then
            printf '%s\n' "$out"
            return 0
          fi
          printf '%s\n' "$out" >&2
          escalate "$role" "fwf gate-promote refused after a confirmed force-resume of $tip: $out" || true
          return 1
        fi
        echo "fwf gate-recover: AC(5) — $tip has one confirming green so far (recovered:1), needs one more before promoting; not yet ship-on-one-forced-green" >&2
        return "$EX_SKIPPED"
      fi
      printf '%s\n' "$run_out" >&2
      if [ "$local_count" -ge "$FORCE_RESUME_MAX" ]; then
        escalate "$role" "AC(1): force-resume bound exhausted ($local_count/$FORCE_RESUME_MAX attempts) for red tip $tip, still red" || true
        return 1
      fi
      echo "fwf gate-recover: still red after attempt $local_count/$FORCE_RESUME_MAX — the next cycle retries" >&2
      return "$EX_SKIPPED"
      ;;

    *)
      echo "fwf gate-recover: role '$role''s recorded verdict '$verdict' is neither green nor red — nothing this script knows how to recover, deferring to a human" >&2
      escalate "$role" "unrecognized gate-tip verdict '$verdict' for $tip" || true
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; exit $?; fi
