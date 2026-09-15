#!/usr/bin/env bash
# fwf-scale.sh -- issue #210: reconcile impl/qa pairs on a LIVE floor to N,
# without disturbing any pane it did not create or remove itself.
#
# Usage: fwf scale --pairs N [--dry-run] [--force]
#   --pairs N    target pair count (required)
#   --dry-run    print the plan; mutate nothing
#   --force      bypass the memory/budget guardrails below. Operator-only by
#                CONVENTION ONLY: no role-prompt template ever passes this
#                flag, but this codebase has no technical mechanism today
#                that distinguishes an operator's own shell from a role's
#                autonomous one, so nothing here actually enforces that.
#                Stated plainly per this ticket's own escape hatch ("if
#                there is no such mechanism today, say so in the PR rather
#                than inventing one here") rather than inventing one.
#
# Scale UP creates only the missing implN/qaN panes (fwf_create_role_pane --
# the same primitive fwf-respawn.sh already uses for recovery) and arms them
# exactly as fwf-up.sh does: fwf_claude_cmd sources $FWF_AUTH_ENV_FILE fresh
# INSIDE the new pane's own shell at type-time, never inherited from the
# invoking shell (issue #217/#143's exact gotcha) -- then fwf_arm_pane +
# fwf_verify_boot_ticks confirm a REAL first loop tick, not just that claude
# is running. Existing panes below the current count are never touched: not
# split, not killed, not re-armed, not even looked at.
#
# Scale DOWN removes ONLY the highest-indexed pair, and only if it is
# genuinely idle (no open PR on an implN/* branch, no live "CLAIM implN").
# It refuses even when a LOWER-indexed pair is idle -- the roster must stay
# contiguous 1..N (lib.sh's PAIRS array and fwf_all_roles both assume this),
# so removing by gap would leave a pane no fwf tool can see. v1 never
# drains: a busy highest-indexed pair is a flat refusal, not a wait. The
# worktree is kept (cheap to retain, expensive to recreate) -- a later
# scale-up reuses it automatically, the same create-if-absent check a fresh
# `fwf up` already does.
#
# issue #452 AC(4): scale DOWN also clears the removed seat's
# state/<profile>/heartbeat and tick entries -- otherwise a scaled-down
# seat and a genuinely wedged one are indistinguishable on disk to any
# reader (fwf_roster_names, lib.sh), and fwf-respawn.sh's own repair path
# would resurrect a seat the operator deliberately removed. FORWARD-LOOKING
# ONLY: a seat scaled down before this shipped may still have a stray
# entry on disk, and this script does not sweep those retroactively (no
# reliable way to distinguish "scaled down before this fix" from "still
# legitimately part of the floor" after the fact, from state alone). If a
# stray entry causes fwf_roster_names to over-report, clear it by hand:
# rm -f state/<profile>/heartbeat/<role> state/<profile>/tick/<role>.
#
# Session-scoped only: never rewrites FWF_PAIRS in the profile. Says so on
# success, and separately warns that the CAPTAIN's own already-rendered
# prompt still reflects the OLD pair count until it is re-armed -- the
# roster PROSE itself is fully dynamic since issue #221 (__IMPL_ROSTER__,
# lib.sh's _fwf_roster_range off the live PAIRS array), but a live pane's
# prompt was rendered once, at arm time, and does not update itself; #221's
# own fwf dash stranded-assignment surfacing is the safety net for that
# window.
#
# NOT built here (documented, not silently skipped): a true cross-script
# mutex with `fwf up`/`fwf down` (the "scale while up/down is in flight"
# edge case is covered only by re-evaluating the plan immediately before
# mutating, per AC f2 -- not a real lock); the operator-only enforcement of
# --force (see above).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf scale --pairs N [--dry-run] [--force]" >&2; }

target=""; dry_run=0; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pairs) target="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
case "$target" in ''|*[!0-9]*) usage; exit 1 ;; esac
[ "$target" -ge 1 ] || { echo "fwf scale: --pairs must be >= 1" >&2; exit 1; }

# issue #210: the ceiling this ticket originally cited (a hardcoded 3, from
# the captain's roster being a static string) is STALE -- issue #221
# already made templates/dev/captain.tmpl's roster fully dynamic. There is
# no longer an architectural ceiling to derive here; the bound below is a
# plain sanity cap against a typo'd huge N, not a restatement of #221's old
# defect (see docs/fwf-scale.md).
SCALE_MAX_PAIRS="${FWF_SCALE_MAX_PAIRS:-20}"
[ "$target" -le "$SCALE_MAX_PAIRS" ] || {
  echo "fwf scale: refusing -- $target exceeds the sanity bound of $SCALE_MAX_PAIRS pairs (FWF_SCALE_MAX_PAIRS). This is a plain sanity cap, not #210's original 'roster hardcoded at 3' ceiling -- issue #221 already made the captain's roster dynamic." >&2
  exit 1
}

tmux has-session -t "$BUILD_SESSION" 2>/dev/null || {
  echo "fwf scale: build session '$BUILD_SESSION' is not up -- use 'fwf up' first." >&2
  exit 1
}

CURRENT="$(fwf_running_pair_count "$BUILD_SESSION")"
if [ "$CURRENT" = unknown ]; then
  echo "fwf scale: build session '$BUILD_SESSION' has an inconsistent pair state (some index has only one of implN/qaN) -- could not determine the running pair count, refusing to guess. Resolve the floor's state before scaling." >&2
  exit 1
fi

if [ "$target" = "$CURRENT" ]; then
  echo "fwf scale: already at $CURRENT pair(s) -- nothing to do."
  exit 0
fi

# --- is a given impl$id genuinely idle? Echoes a one-line reason if it is
# NOT (an open PR, a live claim, or the gh read itself failing -- fail
# CLOSED on an unreadable check, same #211 convention as the rest of this
# codebase, but the reason string says WHICH so a refusal is never misread
# as a real claim when it was actually an infrastructure failure), or ""
# if genuinely idle.
_fwf_scale_pr_reason() { # $1=impl id
  local id="$1" n
  n="$(gh pr list -R "$(fwf_repo_slug)" --state open --json headRefName --jq \
    ".[] | select(.headRefName | startswith(\"impl${id}/\")) | .headRefName" 2>/dev/null | wc -l | tr -d ' ')" \
    || { printf 'could not query open PRs (gh failed) -- assuming blocked (infrastructure)'; return 0; }
  case "$n" in ''|*[!0-9]*) printf 'could not query open PRs (bad gh output) -- assuming blocked (infrastructure)'; return 0;; esac
  [ "$n" -gt 0 ] && printf 'has an open PR (policy)'
  return 0
}
_fwf_scale_claim_reason() { # $1=impl id
  local id="$1" claims claim_created claim_body role_tag now claim_epoch claim_age
  claims="$(gh issue list -R "$(fwf_repo_slug)" --state open --json comments --jq \
    '.[] | (.comments // []) | map(select(.body | test("^CLAIM impl[0-9]+$"))) | (.[0] // empty) | "\(.createdAt)\t\(.body)"' \
    2>/dev/null)" || { printf 'could not scan open issues for a live claim (gh failed) -- assuming blocked (infrastructure)'; return 0; }
  now="$(date -u +%s)"
  while IFS=$'\t' read -r claim_created claim_body; do
    [ -n "$claim_created" ] || continue
    role_tag="${claim_body#CLAIM }"
    [ "$role_tag" = "impl$id" ] || continue
    claim_epoch="$(fwf_iso_to_epoch "$claim_created" 2>/dev/null || true)"
    case "$claim_epoch" in ''|*[!0-9]*) claim_epoch="$now";; esac
    claim_age=$(( now - claim_epoch )); [ "$claim_age" -ge 0 ] || claim_age=0
    if fwf_claim_liveness_blocks "$role_tag" "$claim_age"; then
      printf 'holds a live claim (policy)'; return 0
    fi
  done <<< "$claims"
  return 0
}

PLAN_CREATE=(); PLAN_REMOVE=()
if [ "$target" -gt "$CURRENT" ]; then
  id="$CURRENT"
  while [ "$id" -lt "$target" ]; do id=$((id+1)); PLAN_CREATE+=("$id"); done
else
  id="$CURRENT"
  while [ "$id" -gt "$target" ]; do
    reason="$(_fwf_scale_pr_reason "$id")"
    [ -n "$reason" ] || reason="$(_fwf_scale_claim_reason "$id")"
    if [ -n "$reason" ]; then
      echo "fwf scale: refusing -- impl$id/qa$id (the highest-indexed pair) $reason. Scale-down never drains -- it only removes genuinely idle pairs, even when a lower-indexed pair is idle instead." >&2
      exit 1
    fi
    PLAN_REMOVE+=("$id"); id=$((id-1))
  done
fi

# --- capacity guardrails on scale-up (issue #156's direction, reached from
# the opposite side); scale-down is never blocked by either. --force skips
# both -- see the file header for why that is convention-only, not enforced.
# issue #404 AC (3): the RAM check runs BEFORE the budget-hold check below,
# and this order is a DELIBERATE, recorded decision, not an accident left
# undecided. The two are different KINDS of refusal -- RAM is a resource
# refusal (transient, about whether the box can physically host another
# pair right now), a budget HOLD is a policy refusal (deliberate, about
# whether the operator wants more metered agent loops running at all) -- and
# RAM-first means a request that can't even be hosted never gets a message
# about a policy that was never going to be reached anyway. Flipping the
# order (policy-first) was considered and is not required by #404's
# evidence: the observed harm was a TEST reading ambient host RAM instead of
# pinning it, not a user seeing the wrong refusal message. No product
# change lands here for that reason.
if [ "${#PLAN_CREATE[@]}" -gt 0 ] && [ "$force" != 1 ]; then
  free_gb="$(fwf_free_ram_gb)"
  per_pair="${FWF_SCALE_RAM_PER_PAIR_GB:-2}"
  need_gb=$(( ${#PLAN_CREATE[@]} * per_pair ))
  if [ "$free_gb" = UNKNOWN ]; then
    echo "fwf scale: refusing -- free RAM could not be measured (fail-closed). Pass --force to override." >&2
    exit 1
  elif [ "$free_gb" -lt "$need_gb" ]; then
    echo "fwf scale: refusing -- only ${free_gb}G free RAM, need ~${need_gb}G for ${#PLAN_CREATE[@]} new pair(s) at ${per_pair}G/pair (FWF_SCALE_RAM_PER_PAIR_GB). Pass --force to override." >&2
    exit 1
  fi
  if [ -f "$BUDGET_HOLD_FILE" ]; then
    case "$(head -1 "$BUDGET_HOLD_FILE")" in
      HOLD*|UNKNOWN*)
        echo "fwf scale: refusing -- scaling UP would add ${#PLAN_CREATE[@]} more metered agent loop(s) while the subscription-usage sentinel reads '$(head -1 "$BUDGET_HOLD_FILE")'. Pass --force to override. Scale-down is never blocked by a hold." >&2
        exit 1
        ;;
    esac
  fi
fi

echo "fwf scale: $CURRENT -> $target pair(s)"
for id in ${PLAN_CREATE[@]+"${PLAN_CREATE[@]}"}; do echo "  create: impl$id, qa$id"; done
for id in ${PLAN_REMOVE[@]+"${PLAN_REMOVE[@]}"}; do echo "  remove: impl$id, qa$id (confirmed idle)"; done
i=1
while [ "$i" -le "$CURRENT" ]; do
  case " ${PLAN_REMOVE[*]+"${PLAN_REMOVE[*]}"} " in
    *" $i "*) ;;
    *) echo "  untouched: impl$i, qa$i" ;;
  esac
  i=$((i+1))
done

if [ "$dry_run" = 1 ]; then
  echo "fwf scale: --dry-run -- nothing mutated."
  exit 0
fi

# issue #210 AC(f2): re-evaluate at mutation time, never act on the plan
# printed above -- a pair that became busy in the gap must still refuse,
# and nothing gets touched if it did.
for id in ${PLAN_REMOVE[@]+"${PLAN_REMOVE[@]}"}; do
  reason="$(_fwf_scale_pr_reason "$id")"
  [ -n "$reason" ] || reason="$(_fwf_scale_claim_reason "$id")"
  if [ -n "$reason" ]; then
    echo "fwf scale: refusing -- impl$id became busy between the plan and this run ($reason, re-checked at mutation time). Nothing was touched." >&2
    exit 1
  fi
done

for id in ${PLAN_REMOVE[@]+"${PLAN_REMOVE[@]}"}; do
  p="$(fwf_find_pane "$BUILD_SESSION" "IMPL$id ·" || true)"; [ -n "$p" ] && tmux kill-pane -t "$p" 2>/dev/null
  q="$(fwf_find_pane "$BUILD_SESSION" "QA$id ·" || true)"; [ -n "$q" ] && tmux kill-pane -t "$q" 2>/dev/null
  # issue #452 AC(4): without this, a scaled-down seat and a genuinely
  # wedged one are the SAME artifact on disk -- a heartbeat/tick entry
  # with no live pane -- and fwf_roster_names (lib.sh) can't tell a
  # deliberate removal from a repair target. Removing the entries HERE,
  # at the one place a seat is deliberately taken out of the floor, is
  # what makes "an entry exists" mean "this seat belongs to the floor"
  # for every reader of that state, not just this script.
  rm -f "$(fwf_heartbeat_path "impl$id")" "$(fwf_tick_path "impl$id")"
  rm -f "$(fwf_heartbeat_path "qa$id")" "$(fwf_tick_path "qa$id")"
  echo "removed impl$id/qa$id (worktree kept -- a later scale-up reuses it; heartbeat/tick state cleared)"
done

if [ "${#PLAN_CREATE[@]}" -gt 0 ]; then
  _fwf210_auth_src="$(fwf_resolve_claude_auth)" || {
    echo "fwf scale: no claude credentials found (checked \$CLAUDE_CODE_OAUTH_TOKEN, ~/.claude/.credentials.json, and the macOS Keychain) -- run 'claude /login' first, or export CLAUDE_CODE_OAUTH_TOKEN, then re-run." >&2
    exit 1
  }
  echo "fwf scale: claude auth resolved from: $_fwf210_auth_src"

  NEW_PANES=(); NEW_ROLES=()
  for id in "${PLAN_CREATE[@]}"; do
    if [ ! -d "$(wt_dir "impl$id")" ]; then
      git -C "$FWF_REPO" worktree add "$(wt_dir "impl$id")" -b "impl$id/work" "$DEFAULT_BRANCH" 2>/dev/null \
        || git -C "$FWF_REPO" worktree add "$(wt_dir "impl$id")" "impl$id/work"
      printf '%s\n' "$PROFILE" > "$(wt_dir "impl$id")/.fwf-profile"
    fi
    if ! fwf_role_suppressed "qa$id" && [ ! -d "$(wt_dir "qa$id")" ]; then
      git -C "$FWF_REPO" worktree add --detach "$(wt_dir "qa$id")" "$DEFAULT_BRANCH"
      printf '%s\n' "$PROFILE" > "$(wt_dir "qa$id")/.fwf-profile"
    fi
    ip="$(fwf_create_role_pane "impl$id")" || { echo "fwf scale: failed to create pane for impl$id" >&2; exit 1; }
    NEW_PANES+=("$ip"); NEW_ROLES+=("impl$id")
    if ! fwf_role_suppressed "qa$id"; then
      qp="$(fwf_create_role_pane "qa$id")" || { echo "fwf scale: failed to create pane for qa$id" >&2; exit 1; }
      NEW_PANES+=("$qp"); NEW_ROLES+=("qa$id")
    fi
  done

  i=0
  while [ "$i" -lt "${#NEW_PANES[@]}" ]; do
    tmux send-keys -t "${NEW_PANES[$i]}" -l "$(fwf_claude_cmd "${NEW_ROLES[$i]}")"; tmux send-keys -t "${NEW_PANES[$i]}" Enter
    i=$((i+1))
  done
  echo "launched claude in ${#NEW_PANES[@]} pane(s); verifying each actually booted (re-sending to laggards)…"
  i=0
  while [ "$i" -lt "${#NEW_PANES[@]}" ]; do
    fwf_ensure_claude "${NEW_PANES[$i]}" "$(fwf_claude_cmd "${NEW_ROLES[$i]}")" || echo "warning: claude did not come up in pane ${NEW_PANES[$i]}"
    i=$((i+1))
  done
  sleep 2
  for p in "${NEW_PANES[@]}"; do tmux send-keys -t "$p" Enter; done   # clear one-time bypass-accept screen
  sleep 2

  BOOT_EPOCH="$(date +%s)"
  ARM_ROLES=(); ARM_PANES=(); ARM_TMPLS=(); ARM_IDS=(); ARM_INTERVALS=()
  for id in "${PLAN_CREATE[@]}"; do
    ip="$(fwf_find_pane "$BUILD_SESSION" "IMPL$id ·")"
    ARM_ROLES+=("impl$id"); ARM_PANES+=("$ip"); ARM_TMPLS+=("implementer"); ARM_IDS+=("$id"); ARM_INTERVALS+=("$IMPL_INTERVAL")
    fwf_arm_pane "$ip" "impl$id" implementer "$id" "$IMPL_INTERVAL"
    if ! fwf_role_suppressed "qa$id"; then
      qp="$(fwf_find_pane "$BUILD_SESSION" "QA$id ·")"
      ARM_ROLES+=("qa$id"); ARM_PANES+=("$qp"); ARM_TMPLS+=("qa"); ARM_IDS+=("$id"); ARM_INTERVALS+=("$QA_LOOP_INTERVAL")
      fwf_arm_pane "$qp" "qa$id" qa "$id" "$QA_LOOP_INTERVAL"
    fi
  done

  if [ "${FWF_SKIP_BOOT_GATE:-0}" != 1 ]; then
    _fwf210_boot_renudge() { # $1=role
      local r="$1" j=0
      while [ "$j" -lt "${#ARM_ROLES[@]}" ]; do
        if [ "${ARM_ROLES[$j]}" = "$r" ]; then
          fwf_arm_pane "${ARM_PANES[$j]}" "${ARM_ROLES[$j]}" "${ARM_TMPLS[$j]}" "${ARM_IDS[$j]}" "${ARM_INTERVALS[$j]}"
          return 0
        fi
        j=$((j+1))
      done
    }
    BOOT_SPECS=(); j=0
    while [ "$j" -lt "${#ARM_ROLES[@]}" ]; do
      isecs="$(fwf_interval_seconds "${ARM_INTERVALS[$j]}" 2>/dev/null || echo 180)"
      BOOT_SPECS+=("${ARM_ROLES[$j]}:$((isecs + 45))")
      j=$((j+1))
    done
    echo "verifying every new role fired a first loop tick…"
    if fwf_verify_boot_ticks "$BOOT_EPOCH" _fwf210_boot_renudge "${BOOT_SPECS[@]}"; then
      echo "boot health-gate: all ${#ARM_ROLES[@]} new role(s) ticking."
    else
      for dr in "${FWF_BOOT_DEAD_ROLES[@]}"; do
        echo "boot health-gate: hard-respawning wedged role '$dr'…" >&2
        "$DIR/fwf-respawn.sh" "$dr" || echo "warning: automated respawn of '$dr' did not verify -- run 'fwf respawn $dr' and check its pane" >&2
      done
    fi
  fi
fi

echo
echo "fwf scale: floor is now at $target pair(s) (session-scoped only -- FWF_PAIRS in the profile is unchanged; edit the profile to make $target permanent)."
echo "fwf scale: the CAPTAIN's own already-rendered prompt still reflects the OLD $CURRENT-pair roster until it is re-armed (fwf respawn captain) -- fwf dash surfaces any stranded assignment in the meantime (issue #221)."
