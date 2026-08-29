#!/usr/bin/env bash
# shellcheck disable=SC2034  # PROFILE_FILE/FWF_PROFILE_RESOLUTION_MODE/
# FWF_PROFILE_DROPPED_NAMES are set here for the CALLER (lib.sh) to consume.
# Isolated evaluation of an OUT-OF-TREE repo profile (issue #188). 3.2-clean.
#
# In-tree profiles/*.sh are sourced directly by lib.sh -- they live inside the
# fwf install and share its trust domain. An out-of-tree profile (a target
# repo's own .fwf/<name>.sh) does NOT: lib.sh is sourced by every fwf-*.sh
# entrypoint unconditionally, including fwf-authz.sh, so naively sourcing repo
# code there would let a hostile/careless target repo shadow a function or
# variable the authorization oracle depends on.
#
# fwf_profile_eval_isolated() closes that gap: the out-of-tree file is sourced
# in a throwaway child process (no inherited fwf functions/state -- only a
# plain env, same as any subprocess), which then reports back only an
# ALLOWLISTED set of plain-string values. Two things make this real rather
# than decorative:
#
#   1. The import channel has NO eval anywhere in it. The child writes a
#      NUL-delimited NAME\0VALUE\0 stream to its own stdout, but ONLY after
#      the profile has finished sourcing -- the profile's own stdout/stderr
#      are sent to /dev/null while it runs (channel separation), so it
#      cannot inject bytes onto the channel this reads. The parent reads
#      that stream with `read -r -d ''` and assigns with `printf -v`; values
#      are inert data at every step, so a profile that writes crafted
#      `declare`/assignment text to any stream still changes nothing (AC f0).
#   2. OPERATOR_UNGATE_SENTINEL and FWF_ISSUES -- the two names that decide
#      what fwf authz treats as authorization and where it reads the
#      signal from -- are DENIED to out-of-tree profiles. A profile that
#      sets either fails the whole import loudly rather than being silently
#      dropped; isolation without this denial would still let a hostile
#      profile pick the store that answers "did a human authorize this?".
#
# A profile that is neither allowlisted-safe nor denylisted is not an error:
# it is DROPPED (has no effect on the parent) and named so `fwf doctor` can
# surface "why is my setting ignored?" in one command instead of by reading
# source.

# Single source of truth for what an out-of-tree profile may set. Every real
# profile knob a repo would plausibly want lives here; add a new one here
# when profiles/example.sh gains a new documented knob, or it silently does
# not apply out-of-tree.
FWF_PROFILE_ALLOWLIST="FWF_REPO WT_PREFIX WT_BASE STAGING_BRANCH INTEGRATION_BRANCH DEFAULT_BRANCH GATE_CMD BUILD_CMD E2E_CMD E2E_SETUP_CMD GATE_CASE_EXTRACTOR DEV_UI_HINT UT_APP_URL UT_BROWSER UT_BROWSER_1 UT_BROWSER_2 UT_BROWSER_3 FWF_TEMPLATE FWF_PAIRS FWF_MODEL FWF_MODEL_IMPL FWF_MODEL_QA FWF_MODEL_PM FWF_MODEL_GV FWF_MODEL_CAPTAIN FWF_MODEL_CONDUCTOR PM_COLOR CONDUCTOR_COLOR GV_COLOR CAPTAIN_COLOR"

# Authorization-critical -- see the file header. Never importable, ever.
FWF_PROFILE_DENYLIST="OPERATOR_UNGATE_SENTINEL FWF_ISSUES"

# The bound is required (an unbounded profile would convert this trust fix
# into an availability attack on fwf authz -- a hung profile must never wedge
# the gate) but the value is unmeasured, so it is a named constant an operator
# can find and raise, following the FWF_GATE_TEARDOWN_GRACE_SECS precedent
# (#195) rather than a literal buried at the call site.
FWF_PROFILE_EVAL_TIMEOUT_SECS="${FWF_PROFILE_EVAL_TIMEOUT_SECS:-5}"

# The child script text. Single-quoted so the PARENT never expands anything
# in it; $1 is the profile path, $__FWF_TRACK/$__FWF_DENY come in via env
# (plain data we already control, not attacker input). No `eval` anywhere.
# `builtin` prefixes defend the export step itself against a profile that
# defined a function shadowing printf/read/compgen before returning control.
read -r -d '' __FWF_PROFILE_CHILD_SCRIPT <<'FWF_CHILD_EOF' || true
set -uo pipefail
__fwf_path="$1"
__fwf_track="$__FWF_TRACK"
__fwf_deny="$__FWF_DENY"

__fwf_before="$(builtin compgen -v)"
for __fwf_n in $__fwf_track $__fwf_deny; do
  if [ "${!__fwf_n+set}" = set ]; then
    builtin printf -v "__fwf_before_${__fwf_n}" '%s' "${!__fwf_n-}"
  fi
done

trap - EXIT DEBUG ERR RETURN 2>/dev/null || true
__fwf_rc=0
{ source "$__fwf_path"; } >/dev/null 2>&1 || __fwf_rc=$?
trap - EXIT DEBUG ERR RETURN 2>/dev/null || true

if [ "$__fwf_rc" -ne 0 ]; then
  builtin printf 'profile exited non-zero (%s)\n' "$__fwf_rc" >&2
  exit 3
fi

for __fwf_n in $__fwf_deny; do
  if [ "${!__fwf_n+set}" = set ]; then
    __fwf_before_var="__fwf_before_${__fwf_n}"
    if [ "${!__fwf_before_var+set}" != set ] || [ "${!__fwf_before_var-}" != "${!__fwf_n-}" ]; then
      builtin printf 'denylisted name %s was set by the profile\n' "$__fwf_n" >&2
      exit 4
    fi
  fi
done

__fwf_after="$(builtin compgen -v)"
__fwf_dropped=""
while IFS= read -r __fwf_n; do
  [ -n "$__fwf_n" ] || continue
  case "$__fwf_n" in __fwf_*) continue;; esac
  case " $__fwf_track $__fwf_deny " in *" $__fwf_n "*) continue;; esac
  case "
$__fwf_before
" in *"
$__fwf_n
"*) continue;; esac
  __fwf_dropped="$__fwf_dropped $__fwf_n"
done <<EOF
$__fwf_after
EOF

builtin printf '%s\0%s\0' "__FWF_DROPPED__" "$__fwf_dropped"
for __fwf_n in $__fwf_track; do
  if [ "${!__fwf_n+set}" = set ]; then
    builtin printf '%s\0%s\0' "$__fwf_n" "${!__fwf_n-}"
  fi
done
builtin printf '%s\0%s\0' "__FWF_OK__" "1"
FWF_CHILD_EOF

# fwf_profile_resolve LIB_DIR NAME
# Resolution rules (issue #188), both ordered and never silent:
#   1. Explicit always wins and never falls through: FWF_PROFILE_PATH, or
#      NAME itself looking like a path (contains / or ends .sh), resolves to
#      an absolute path -- and fails loudly if missing. It NEVER degrades to
#      auto-detection; an explicit choice is never silently rescued.
#   2. Bare names resolve to profiles/<name>.sh exactly as before this
#      ticket -- the common path, unchanged.
#   3. Auto-detect $FWF_REPO/.fwf/<name>.sh fires ONLY where fwf would
#      already have errored (bare name, no in-tree file) -- it strictly
#      converts an error into a success and can never change the meaning of
#      a currently-working invocation. In-tree wins the collision
#      deterministically because it is checked first.
# Sets PROFILE_FILE (absolute path actually loaded) and
# FWF_PROFILE_RESOLUTION_MODE (in-tree|explicit|auto-detected) in the
# caller's scope. Exits with the pre-existing error quality on failure.
fwf_profile_resolve() {
  local lib_dir="$1" name="$2" explicit_path="${FWF_PROFILE_PATH:-}"
  local looks_like_path=0
  case "$name" in */*|*.sh) looks_like_path=1 ;; esac

  if [ -n "$explicit_path" ] || [ "$looks_like_path" = 1 ]; then
    local p="${explicit_path:-$name}"
    case "$p" in /*) : ;; *) p="$(pwd)/$p" ;; esac
    [ -f "$p" ] || { echo "fwf: unknown profile '$name' (missing $p)" >&2; exit 1; }
    PROFILE_FILE="$p"
    FWF_PROFILE_RESOLUTION_MODE="explicit"
    return 0
  fi

  local in_tree="$lib_dir/profiles/$name.sh"
  if [ -f "$in_tree" ]; then
    PROFILE_FILE="$in_tree"
    FWF_PROFILE_RESOLUTION_MODE="in-tree"
    return 0
  fi

  if [ -n "${FWF_REPO:-}" ] && [ -d "${FWF_REPO:-}" ]; then
    local auto="$FWF_REPO/.fwf/$name.sh"
    if [ -f "$auto" ]; then
      PROFILE_FILE="$auto"
      FWF_PROFILE_RESOLUTION_MODE="auto-detected"
      return 0
    fi
  fi

  echo "fwf: unknown profile '$name' (missing $in_tree)" >&2
  exit 1
}

# fwf_profile_eval_isolated PATH
# Sets, in the CALLER's scope: every allowlisted name the profile assigned
# (plain strings, via printf -v -- never eval), plus FWF_PROFILE_DROPPED_NAMES
# (space-separated, may be empty). Returns 0 on success; on failure (denylist
# violation, timeout, non-zero profile exit, malformed channel) prints a
# reason to stderr and returns 1, setting NOTHING in the caller.
fwf_profile_eval_isolated() {
  local path="$1"
  local tmpout tmperr child_pid waited=0 rc timed_out=0
  tmpout="$(mktemp "${TMPDIR:-/tmp}/fwf-profile-eval.XXXXXX")" || return 1
  tmperr="$(mktemp "${TMPDIR:-/tmp}/fwf-profile-eval-err.XXXXXX")" || { rm -f "$tmpout"; return 1; }

  (
    export __FWF_TRACK="$FWF_PROFILE_ALLOWLIST"
    export __FWF_DENY="$FWF_PROFILE_DENYLIST"
    exec bash -c "$__FWF_PROFILE_CHILD_SCRIPT" -- "$path"
  ) >"$tmpout" 2>"$tmperr" &
  child_pid=$!

  while kill -0 "$child_pid" 2>/dev/null; do
    if [ "$waited" -ge "$FWF_PROFILE_EVAL_TIMEOUT_SECS" ]; then
      timed_out=1
      kill -TERM "$child_pid" 2>/dev/null
      sleep 0.2
      kill -KILL "$child_pid" 2>/dev/null
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$child_pid" 2>/dev/null
  rc=$?

  if [ "$timed_out" = 1 ]; then
    echo "fwf: profile '$path' failed to evaluate -- timed out after ${FWF_PROFILE_EVAL_TIMEOUT_SECS}s (FWF_PROFILE_EVAL_TIMEOUT_SECS)" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "fwf: profile '$path' failed to evaluate -- $(cat "$tmperr" 2>/dev/null)" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  fi

  local name value saw_ok=0
  local -a imported=()
  FWF_PROFILE_DROPPED_NAMES=""
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    case "$name" in
      __FWF_OK__) saw_ok=1; break ;;
      __FWF_DROPPED__) FWF_PROFILE_DROPPED_NAMES="$value" ;;
      *)
        case " $FWF_PROFILE_DENYLIST " in
          *" $name "*) continue ;;
        esac
        case " $FWF_PROFILE_ALLOWLIST " in
          *" $name "*) printf -v "$name" '%s' "$value"; imported+=("$name") ;;
        esac
        ;;
    esac
  done < "$tmpout"
  rm -f "$tmpout" "$tmperr"

  if [ "$saw_ok" != 1 ]; then
    echo "fwf: profile '$path' failed to evaluate -- import channel ended without completing (malformed or truncated output)" >&2
    return 1
  fi
  return 0
}
