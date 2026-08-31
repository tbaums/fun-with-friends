#!/usr/bin/env bash
# fwf-reap-orphans.sh -- issue #468: the REAPING fallback for an e2e/
# test-run process tree, or a leaked `fwf-selftest-*` tmux session, whose
# owner is gone. Self-limiting (scripts/conductor-e2e.sh's own owner check)
# is the PRIMARY mechanism -- a harness that refuses to spawn its next
# retry generation once its owner is gone needs no privileged killer at
# all. This sweep is the backstop for a tree ALREADY wedged before
# self-limiting could fire -- e.g. `bash test/run.sh` invoked bare, never
# through fwf-gate.sh, OOM-killed mid-run (a SIGKILL never runs its own
# EXIT trap, so the orphan and its /tmp fixture dir both survive).
#
# THIS SCRIPT KILLS PROCESS TREES AND TMUX SESSIONS. Its safety rails are
# the actual point, not an afterthought:
#   - exact-PID only, never `pkill -f` (a shared script name matches every
#     role's identically-named process -- see docs/never-pkill-by-name).
#   - dry-run is the DEFAULT; a caller must pass --live to reap for real.
#   - a bound on kills per sweep; exceeding it reaps NOTHING and fails
#     closed (a sweep that suddenly wants to kill many things is more
#     likely a broken predicate than a real incident).
#   - one audit line per kill: PID, root command, and the owner-liveness
#     evidence that justified it.
#
# Usage: fwf-reap-orphans.sh [--live] [--bound N]
#   Default: DRY-RUN -- reports candidates, kills nothing. --live reaps
#   for real. fwf-gate.sh's --e2e path (issue #468 AC 8, the obliged call
#   site) passes --live on every invocation.
#
# Exit codes: 0 = swept (dry-run: reported; live: reaped, possibly zero
#   candidates). 1 = usage error. 2 = the bound was exceeded -- refused,
#   escalated, reaped NOTHING (fail closed).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

mode=dryrun
bound="${FWF_REAP_BOUND:-5}"
while [ $# -gt 0 ]; do
  case "$1" in
    --live) mode=live; shift ;;
    --dry-run) mode=dryrun; shift ;;
    --bound) [ $# -ge 2 ] || { echo "usage: fwf-reap-orphans.sh [--live] [--bound N]" >&2; exit 1; }; bound="$2"; shift 2 ;;
    *) echo "usage: fwf-reap-orphans.sh [--live] [--bound N]" >&2; exit 1 ;;
  esac
done
case "$bound" in ''|*[!0-9]*) echo "fwf-reap-orphans: --bound must be a non-negative integer" >&2; exit 1 ;; esac

# --- owner-liveness (issue #468 AC 2) ---------------------------------------
# The current tmux server's socket, if one exists. `stat`'s mtime on that
# socket IS the server's start time (the file is created once, at server
# start, and never rewritten) -- the same signal the incident itself used
# ("started 05:26:14, before the tmux server was created at 06:09:53").
_reap_tmux_socket_path() {
  if [ -n "${TMUX:-}" ]; then
    local s="${TMUX%%,*}"
    [ -S "$s" ] && { printf '%s' "$s"; return 0; }
  fi
  local uid d
  uid="$(id -u 2>/dev/null)"
  d="${TMUX_TMPDIR:-/tmp}/tmux-$uid"
  [ -S "$d/default" ] && { printf '%s' "$d/default"; return 0; }
  return 1
}
_reap_tmux_server_start_epoch() {
  # Test seam: a fixed epoch bypasses the real socket lookup entirely so
  # the discriminator itself (start_epoch vs server_epoch) can be proven
  # deterministically, without depending on this box's own incidental
  # live tmux server (which may be running for an unrelated real floor).
  if [ -n "${FWF_REAP_SERVER_EPOCH_OVERRIDE:-}" ]; then
    printf '%s' "$FWF_REAP_SERVER_EPOCH_OVERRIDE"
    return 0
  fi
  local sock; sock="$(_reap_tmux_socket_path)" || return 1
  stat -c %Y "$sock" 2>/dev/null || stat -f %m "$sock" 2>/dev/null || return 1
}

# rc 0 = candidate is presumed LIVE-OWNED (do not reap). rc 1 = orphaned.
# $1=pid (a tree ROOT candidate, per _reap_candidate_roots below).
_reap_owner_alive() {
  local pid="$1" ppid
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  # A live, non-init direct parent is a live owner -- covers the ordinary
  # case (a role's pane shell, this very session's own subshell, a still-
  # running fwf-gate.sh wrapper) without needing anything tmux-specific.
  if [ -n "$ppid" ] && [ "$ppid" != 1 ] && kill -0 "$ppid" 2>/dev/null; then
    return 0
  fi
  # Reparented (or the direct parent is already gone). issue #468 AC 2:
  # PPID=1 alone is a pre-filter, never the decision -- corroborate via
  # OWNER-LIVENESS. If this process started AFTER the CURRENT tmux
  # server came into existence, it may have been legitimately daemonized
  # under the still-live floor; if it predates the current server, it
  # can only belong to a NOW-DEAD prior incarnation. No code path in this
  # repo deliberately double-forks a test/run.sh or conductor-e2e.sh tree
  # (verified: no disown/setsid near either name) -- so in practice this
  # branch only ever fires for the genuine orphan case, and the decoy
  # test below proves the discriminator itself, not a real caller.
  local server_epoch elapsed now start_epoch
  server_epoch="$(_reap_tmux_server_start_epoch)" || return 1   # no live server at all -> definitely orphaned
  elapsed="$(_fwf_ps_elapsed_secs "$pid" 2>/dev/null || true)"
  [ -n "$elapsed" ] || return 0   # can't measure age -- fail OPEN (never reap what we can't verify)
  now="$(date +%s)"
  start_epoch=$(( now - elapsed ))
  [ "$start_epoch" -ge "$server_epoch" ]
}

# --- candidate discovery: process tree roots --------------------------------
# ROOTS only: a matching pid whose own parent is ALSO a matching pid is a
# child of the same tree, not a second root -- it dies with its root below
# (walked and killed individually by PID, never by name/group, per AC 4).
_reap_matches() { case "$1" in *test/run.sh*|*conductor-e2e.sh*) return 0 ;; *) return 1 ;; esac; }
_reap_candidate_roots() {
  local pid ppid rest pargs
  ps -eo pid=,ppid=,args= 2>/dev/null | while read -r pid ppid rest; do
    [ -n "$pid" ] || continue
    _reap_matches "$rest" || continue
    pargs="$(ps -o args= -p "$ppid" 2>/dev/null || true)"
    _reap_matches "$pargs" && continue   # parent is also a candidate -> not a root
    printf '%s\t%s\n' "$pid" "$rest"
  done
}
# All descendants of $1, portable (repeated ps -eo pid,ppid scan, no pgrep
# -P dependency), deepest-first so a kill never orphans a not-yet-killed
# child onto init mid-sweep.
_reap_descendants() {
  local root="$1" next found=1 out=""
  local frontier="$root"
  while [ "$found" = 1 ]; do
    found=0
    next=""
    while read -r pid ppid; do
      [ -n "$pid" ] || continue
      case " $frontier " in
        *" $ppid "*)
          case " $frontier $next " in *" $pid "*) ;; *) next="$next $pid"; found=1 ;; esac
          ;;
      esac
    done < <(ps -eo pid=,ppid= 2>/dev/null)
    [ -n "$next" ] && { out="$next $out"; frontier="$frontier $next"; }
  done
  printf '%s' "$out"
}

# --- sweep: process trees ----------------------------------------------------
# The issue this sweep's own bound-exceeded escalation is filed against --
# a real, existing target so `fwf flag-captain` has somewhere to post.
# Overridable for tests, which point it at a throwaway fixture issue
# instead of the real #468.
FWF_REAP_ESCALATION_ISSUE="${FWF_REAP_ESCALATION_ISSUE:-468}"
reap_kill_count=0
reap_candidates="$(_reap_candidate_roots)"
if [ -n "$reap_candidates" ]; then
  n="$(printf '%s\n' "$reap_candidates" | grep -c .)"
  if [ "$n" -gt "$bound" ]; then
    echo "fwf-reap-orphans: $n candidate tree(s) exceed the bound ($bound) -- refusing to reap ANY of them (fail closed, issue #468 AC 5)" >&2
    "$DIR/fwf-flag-captain.sh" "$FWF_REAP_ESCALATION_ISSUE" --role conductor --reason "fwf-reap-orphans: $n orphan-tree candidates exceed the bound of $bound in one sweep -- likely a broken predicate, not $n real orphans. Nothing was reaped. Investigate: ps -eo pid,ppid,etime,args | grep -E 'test/run\\.sh|conductor-e2e\\.sh'" >/dev/null 2>&1 || true
    exit 2
  fi
  while IFS=$'\t' read -r pid rest; do
    [ -n "$pid" ] || continue
    if _reap_owner_alive "$pid"; then
      continue   # live owner -- never touched, even under --live
    fi
    if [ "$mode" = dryrun ]; then
      echo "fwf-reap-orphans: DRY-RUN would reap pid $pid (owner dead) -- $rest"
    else
      descendants="$(_reap_descendants "$pid")"
      for d in $descendants $pid; do
        kill -KILL "$d" 2>/dev/null
      done
      echo "fwf-reap-orphans: reaped pid $pid (+$( [ -n "$descendants" ] && printf '%s' "$descendants" | wc -w || echo 0) descendant(s)), owner dead -- $rest" >&2
      reap_kill_count=$((reap_kill_count + 1))
    fi
  done <<<"$reap_candidates"
fi

# --- sweep: leaked fwf-selftest-* tmux sessions (issue #468 AC 10) ---------
# Naming convention: fwf-selftest-<id>-<ownerpid>-<build|coord>. A session
# whose <ownerpid> is confirmed dead is removed; one whose owner is alive
# (or whose name does not parse) is left untouched -- never a name-pattern
# kill, only ever this session's own name after we have read its owner.
if command -v tmux >/dev/null 2>&1; then
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    case "$sess" in
      fwf-selftest-*-build|fwf-selftest-*-coord)
        rest="${sess#fwf-selftest-}"
        rest="${rest%-*}"             # strip the trailing build|coord suffix -> <id>-<ownerpid>
        ownerpid="${rest##*-}"
        case "$ownerpid" in
          ''|*[!0-9]*) continue ;;    # name doesn't parse -- never touched
        esac
        if kill -0 "$ownerpid" 2>/dev/null; then
          continue   # owner alive -- untouched
        fi
        if [ "$mode" = dryrun ]; then
          echo "fwf-reap-orphans: DRY-RUN would kill tmux session '$sess' (owner pid $ownerpid dead)"
        else
          tmux kill-session -t "$sess" 2>/dev/null
          echo "fwf-reap-orphans: killed tmux session '$sess' (owner pid $ownerpid dead)" >&2
        fi
        ;;
    esac
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
fi

# --- sweep: /tmp/fwf-test.* fixture dirs (issue #468 AC 11) ----------------
# Independent of test/run.sh:46's own EXIT trap, which a SIGKILL never
# runs -- so this must not rely on that trap firing. A dir counts as
# reapable only when NO live process anywhere still has it as a cwd (never
# deleted while a live run might still read from it), and only once it is
# past a short minimum age so a run mid-startup is never raced.
FWF_REAP_FIXTURE_MIN_AGE_SECS="${FWF_REAP_FIXTURE_MIN_AGE_SECS:-120}"
_reap_dir_is_live() { # $1=dir -> rc 0 if some live process still appears to use it
  local d="$1" p cwd
  if command -v lsof >/dev/null 2>&1; then
    lsof +D "$d" >/dev/null 2>&1 && return 0
    return 1
  fi
  if [ -d /proc ]; then
    for p in /proc/[0-9]*; do
      cwd="$(readlink "$p/cwd" 2>/dev/null || true)"
      case "$cwd" in "$d"|"$d"/*) return 0 ;; esac
    done
    return 1
  fi
  return 0   # cannot determine either way -- fail OPEN, never delete unverified
}
_reap_fixture_glob="${TMPDIR:-/tmp}/fwf-test.*"
for d in $_reap_fixture_glob; do
  [ -d "$d" ] || continue
  mtime="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || true)"
  [ -n "$mtime" ] || continue
  age=$(( $(date +%s) - mtime ))
  [ "$age" -ge "$FWF_REAP_FIXTURE_MIN_AGE_SECS" ] || continue
  _reap_dir_is_live "$d" && continue
  if [ "$mode" = dryrun ]; then
    echo "fwf-reap-orphans: DRY-RUN would remove fixture dir $d (age ${age}s, no live referrer)"
  else
    rm -rf "$d" 2>/dev/null
    echo "fwf-reap-orphans: removed fixture dir $d (age ${age}s, no live referrer)" >&2
  fi
done

exit 0
