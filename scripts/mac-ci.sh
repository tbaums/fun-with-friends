#!/usr/bin/env bash
# Run the functional suite on REAL macOS, the way CI used to.
#
# GitHub-hosted macOS runners were removed from ci.yml: they queue
# unpredictably (observed unscheduled for 20+ minutes while the same build took
# 9 seconds locally), and a macOS job that never starts blocks every merge and
# every release behind it. The BSD coverage did not go away -- it lives here,
# on real Darwin hardware.
#
# This is the ORACLE for any macOS-only ticket. A Linux gate cannot observe a
# GNU-vs-BSD defect in either direction: the code works there.
#
#   usage: scripts/mac-ci.sh [git-ref]      (default: current worktree)
#
# Exits with the suite's own status. A run is only valid if it prints DONE and
# an explicit summary -- a truncated log is NOT a pass. That distinction cost
# real time: a suite that dies mid-run looks identical to a slow one.
set -uo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "mac-ci: this must run on macOS -- that is the entire point (got $(uname -s))" >&2; exit 2 ;;
esac

ref="${1:-}"
stamp="$(date +%Y%m%d-%H%M%S)"
run="${TMPDIR:-/tmp}/mac-ci-$stamp"
log="$run/suite.log"
mkdir -p "$run"

if [ -n "$ref" ]; then
  tree="$run/tree"
  git worktree add -q --detach "$tree" "$ref" || { echo "mac-ci: cannot check out '$ref'" >&2; exit 2; }
  cleanup() { git worktree remove --force "$tree" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
else
  tree="$PWD"
fi

# Use the SYSTEM bash (/bin/bash, 3.2 on macOS), not whatever is first on PATH.
# The ci.yml matrix comment this replaces said macOS "exercises the bash 3.2
# floor path" -- and a Mac with Homebrew bash 5.x first on PATH would silently
# test 5.x instead, quietly dropping the exact coverage this script exists to
# preserve. Override with MAC_CI_BASH=... if you deliberately want another.
export MAC_CI_BASH="${MAC_CI_BASH:-/bin/bash}"
[ -x "$MAC_CI_BASH" ] || { echo "mac-ci: no bash at $MAC_CI_BASH" >&2; exit 2; }
_bashver="$("$MAC_CI_BASH" --version | head -1 | sed 's/.*version //;s/ .*//')"
case "$_bashver" in
  3.*) : ;;
  *) echo "mac-ci: WARNING -- testing bash $_bashver, not the 3.2 floor. The" >&2
     echo "mac-ci:   bash-3.2 path is what macOS CI used to cover; a 5.x run" >&2
     echo "mac-ci:   does NOT substitute for it." >&2 ;;
esac
echo "mac-ci: $(sw_vers -productName) $(sw_vers -productVersion) · $MAC_CI_BASH $_bashver"
echo "mac-ci: tree $tree @ $(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "mac-ci: log  $log"

# Isolated run dir and tmux server: the suite forks process groups and drives
# tmux, and must never touch a live factory's locks or panes.
(
  cd "$tree" || exit 2
  FWF_RUN_DIR="$run/fwf-run" TMUX_TMPDIR="$run/tmux" \
    "$MAC_CI_BASH" -c 'mkdir -p "$FWF_RUN_DIR" "$TMUX_TMPDIR"; "$MAC_CI_BASH" test/run.sh'
) > "$log" 2>&1
rc=$?
echo "EXIT=$rc" >> "$log"
echo "DONE"    >> "$log"

summary="$(grep -E '[0-9]+ passed, [0-9]+ failed' "$log" | tail -1)"
echo
if [ -z "$summary" ]; then
  echo "mac-ci: NO SUMMARY LINE -- the suite did not finish. This is NOT a pass."
  echo "mac-ci: last lines:"; tail -5 "$log"
  exit 1
fi
echo "mac-ci: $summary (exit $rc)"
[ "$rc" -eq 0 ] || { echo "mac-ci: failures:"; grep '  FAIL ' "$log" | head -20; }
exit "$rc"
