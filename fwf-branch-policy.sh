#!/usr/bin/env bash
# fwf-branch-policy.sh — issue #220: is the committed branch-protection
# policy (.github/branch-policy.json) actually LIVE on GitHub, for every
# branch it names? This is the checker AC (a)/(f)/(g)/(h) call for --
# "CI renders a verdict, nothing obliges a merge to act on it" starts with
# making that gap MEASURABLE before anything tries to close it.
#
# WHY A COMMITTED POLICY FILE, NOT JUST GITHUB SETTINGS (AC g): a setting
# that lives only in GitHub's UI/API is unauditable from the repo and
# invisible to review -- the required-contexts list, branches, and
# enforce_admins flag are versioned here, and this checker diffs the live
# API response against them. Drift (someone flips a setting away from the
# committed policy -- possibly the owner account itself, since every seat
# holds those credentials) is a RED, never a silent divergence.
#
# THIS SCRIPT NEVER MUTATES ANYTHING. It only reads
# `GET /repos/{owner}/{repo}/branches/<branch>/protection` and compares.
# Applying protection (a `PUT` to that same endpoint) is a separate,
# deliberate, one-time admin action -- see docs/branch-protection.md for the
# exact `gh api` commands. Baking a mutation into a script every implementer
# or CI job can invoke would turn "check whether CI is honored" into another
# unreviewed, script-triggerable write to a shared, hard-to-reverse control.
#
# Usage:
#   fwf branch-policy check              check ALL policy branches, exit
#                                         non-zero (and print each violation)
#                                         if ANY branch drifts from policy.
#   fwf branch-policy check <branch>     check just one branch.
#   fwf branch-policy producible         AC (h): assert every required
#                                         context in the policy is actually
#                                         emitted by a CI job that runs on
#                                         every PR (catches the on.paths
#                                         deadlock and a silently-renamed job
#                                         before they block every merge).
#
# Exit codes: 0 = policy satisfied (or, for a branch with NO protection at
# all, that absence is reported as a violation -- see AC (a): "if it passes
# today the checker is wrong"). 1 = one or more violations found. 2 = the
# policy file itself is missing/malformed, or the live read failed
# (UNKNOWN != a real "no violations" answer -- issue #211's own lesson).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

POLICY_FILE="${FWF_BRANCH_POLICY_FILE:-$FWF_REPO/.github/branch-policy.json}"
CI_WORKFLOW_FILE="${FWF_CI_WORKFLOW_FILE:-$FWF_REPO/.github/workflows/ci.yml}"

# --- policy read (pure, no network) ------------------------------------
policy_json() {
  [ -f "$POLICY_FILE" ] || { echo "fwf-branch-policy.sh: policy file not found: $POLICY_FILE" >&2; return 2; }
  jq -c '.' "$POLICY_FILE" 2>/dev/null || { echo "fwf-branch-policy.sh: policy file is not valid JSON: $POLICY_FILE" >&2; return 2; }
}

# --- gh access (overridable by tests, same shape as fwf-pr-reviewer.sh) --
gh_branch_protection() { # $1=branch -> raw protection JSON on stdout, gh's own exit code
  if [ -d "$FWF_REPO/.git" ]; then ( cd "$FWF_REPO" && gh api "repos/{owner}/{repo}/branches/$1/protection" )
  else gh api "repos/{owner}/{repo}/branches/$1/protection"; fi
}

# $1=branch -> the raw GitHub branch-protection JSON on stdout (exit 0), OR
# nothing + a DISTINCT exit code the caller branches on: 1 = 404 (the
# branch has no protection at all -- the NORMAL, expected case for most
# branches, never collapsed into "read failed"), 2 = a real read failure
# (network/auth/rate-limit -- issue #211's own lesson: unreadable != empty,
# so this must never be silently treated as "no violations").
#
# Signals via EXIT CODE, not a side-channel variable: this function's
# caller invokes it inside a `$(...)` command substitution to capture its
# stdout, and command substitution runs in a SUBSHELL -- any plain variable
# assignment made INSIDE it (e.g. a global "last status" var) never
# propagates back to the calling shell. Exit codes DO cross that boundary
# correctly, which is why the distinction lives there instead. (Caught
# manually before this shipped: an earlier version set a global
# FWF_BP_LAST_HTTP_STATUS from inside the subshell and the caller never
# saw it change, so every 404 misread as an unreadable error.)
#
# `set -e` means a failing BARE command substitution assignment would abort
# the script before a caller could inspect the failure -- always call this
# guarded by `if out="$(live_protection_json ...)"`, per this codebase's
# convention (e.g. fwf-pr-reviewer.sh's pr_raw), never as a bare statement.
live_protection_json() {
  local branch="$1" out errfile
  errfile="$(mktemp)"
  if out="$(gh_branch_protection "$branch" 2>"$errfile")"; then
    printf '%s' "$out"
    rm -f "$errfile"
    return 0
  fi
  # gh api exits non-zero on any non-2xx; a 404 (unprotected branch) is the
  # expected, common case -- distinguish it from a real read failure
  # (network, auth, rate limit) by grepping the error for "404".
  if grep -qE "HTTP 404|'status': '404'|Branch not protected" "$errfile" 2>/dev/null; then
    cat "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  cat "$errfile" >&2
  rm -f "$errfile"
  return 2
}

# --- pure diff: policy vs one branch's live protection JSON -------------
# $1=policy-json  $2=branch  $3=live-protection-json ("" if unprotected)
# -> one violation line per mismatch (empty output = fully compliant).
diff_branch() {
  local policy="$1" branch="$2" live="${3:-}"
  if [ -z "$live" ]; then
    echo "$branch: NOT PROTECTED (no branch protection configured at all)"
    return 0
  fi
  jq -nr --argjson policy "$policy" --argjson live "$live" --arg branch "$branch" '
    ($policy.required_contexts | sort) as $want
    | (($live.required_status_checks.contexts // []) | sort) as $have
    | (($live.required_status_checks.strict // false)) as $strict
    | (($live.enforce_admins.enabled // false)) as $admins
    | [
        (if $want != $have then
           ($branch + ": required_contexts drifted -- policy wants " + ($want|tostring) + ", live has " + ($have|tostring))
         else empty end),
        (if $strict != $policy.strict then
           ($branch + ": strict drifted -- policy wants " + ($policy.strict|tostring) + ", live has " + ($strict|tostring))
         else empty end),
        (if $admins != $policy.enforce_admins then
           ($branch + ": enforce_admins drifted -- policy wants " + ($policy.enforce_admins|tostring) + ", live has " + ($admins|tostring))
         else empty end)
      ] | .[]
  '
}

# --- AC (a)/(f): check one or all policy branches -----------------------
cmd_check() {
  local only="${1:-}" policy violations=0 b live
  policy="$(policy_json)" || return 2
  local branches
  if [ -n "$only" ]; then branches="$only"
  else branches="$(printf '%s' "$policy" | jq -r '.branches[]')"
  fi
  for b in $branches; do
    local rc=0
    live="$(live_protection_json "$b" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      :
    elif [ "$rc" -eq 1 ]; then
      live=""
    else
      fwf_log_unknown_read fwf-branch-policy.sh "branch=$b protection read failed (not a 404 -- network/auth/rate-limit), refusing to report a confident compliant/violation verdict" || true
      echo "$b: UNKNOWN (could not read live protection settings)" >&2
      violations=1
      continue
    fi
    local out
    out="$(diff_branch "$policy" "$b" "$live")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      violations=1
    fi
  done
  return "$violations"
}

# --- AC (h): every required context is actually producible --------------
# A required context that no workflow job ever emits (a typo, a renamed
# job, or a job gated behind on.paths so it silently never runs on some
# PRs) blocks every PR forever with no failing check to point at -- this
# is the deadlock this AC exists to catch before it ships.
cmd_producible() {
  local policy job_names missing=0 ctx
  policy="$(policy_json)" || return 2
  [ -f "$CI_WORKFLOW_FILE" ] || { echo "fwf-branch-policy.sh: CI workflow file not found: $CI_WORKFLOW_FILE" >&2; return 2; }
  # Job `name:` fields, one per line -- matrix jobs (e.g. `functional
  # suite` x `os: [...]`) report as "<name> (<matrix-value>)", so expand
  # those explicitly rather than trying to derive them from YAML alone.
  job_names="$(awk '
    /^  [a-zA-Z0-9_-]+:$/ { in_job=1 }
    in_job && /^    name:/ { sub(/^    name:[ \t]*/, ""); gsub(/^"|"$/, ""); print; in_job=0 }
  ' "$CI_WORKFLOW_FILE")"
  # Expand the one matrix job this repo has (`functional suite` x os) using
  # the REAL, live matrix values -- issue #303: a previous version of this
  # expansion hardcoded BOTH "ubuntu-latest" and "macos-latest"
  # unconditionally, so it kept reporting "functional suite
  # (macos-latest)" as producible for a full CI cycle after 15801ee
  # actually dropped macos-latest from the matrix (`os: [ubuntu-latest]`
  # today) -- the exact "context never reports, checker never notices"
  # failure mode this function exists to catch, self-inflicted by reading
  # the matrix from memory instead of from the file.
  if printf '%s\n' "$job_names" | grep -qx "functional suite"; then
    local os_values os_line
    os_line="$(grep -m1 -E '^[[:space:]]*os:[[:space:]]*\[' "$CI_WORKFLOW_FILE")"
    os_values="$(printf '%s' "$os_line" | sed -E 's/^[[:space:]]*os:[[:space:]]*\[([^]]*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    job_names="$(printf '%s\n' "$job_names" | grep -vx "functional suite")"
    while IFS= read -r _os; do
      [ -n "$_os" ] || continue
      job_names="$job_names
functional suite ($_os)"
    done <<<"$os_values"
  fi
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if ! printf '%s\n' "$job_names" | grep -qxF "$ctx"; then
      echo "required context '$ctx' is not emitted by any job in $CI_WORKFLOW_FILE"
      missing=1
    fi
  done < <(printf '%s' "$policy" | jq -r '.required_contexts[]')
  return "$missing"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    check)      cmd_check "${1:-}";;
    producible) cmd_producible;;
    *) echo "usage: fwf branch-policy check [<branch>] | producible" >&2; return 2;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
