#!/usr/bin/env bash
# Resume the factory after a graceful stop: clear the STOP sentinel and re-arm
# every role's loop (respawn its pane) for the active profile — the inverse of
# fwf-stop. With --clear-only, just clear the sentinel and leave the panes alone.
#
# Usage: [FWF_PROFILE=example] fwf-resume.sh [--clear-only]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

clear_only=0
case "${1:-}" in
  "") ;;
  --clear-only) clear_only=1;;
  *) echo "usage: fwf-resume.sh [--clear-only]" >&2; exit 1;;
esac

if [ -e "$STOP_FILE" ]; then rm -f "$STOP_FILE"; echo "cleared STOP sentinel ($STOP_FILE)"; else echo "no STOP sentinel present"; fi

if [ "$clear_only" = 1 ]; then
  echo "--clear-only: panes left as-is. Re-arm with 'fwf resume' (no flag) or 'fwf respawn <role>'."
  exit 0
fi

# Re-arm only if a session is up; otherwise the launch path ('fwf up') is what you want.
any_up=0
for s in "$COORD_SESSION" "$BUILD_SESSION"; do tmux has-session -t "$s" 2>/dev/null && any_up=1; done
if [ "$any_up" = 0 ]; then
  echo "sessions '$COORD_SESSION' / '$BUILD_SESSION' are not running — run 'fwf up' to launch and arm them."
  exit 0
fi

echo "re-arming all roles for profile '$PROFILE'…"
failed=""
for r in $(fwf_all_roles); do
  if "$DIR/fwf-respawn.sh" "$r"; then :; else failed="$failed $r"; fi
done
if [ -n "$failed" ]; then
  echo "resume: could not re-arm:$failed (that role's session may be down — check 'fwf up')." >&2
  exit 1
fi
echo "resume: all roles re-armed."
