#!/usr/bin/env bash
# fwf-auth.sh — operator-facing wrapper around the claude auth sink (issue
# #217). `fwf up`/`fwf-up.sh` calls fwf_resolve_claude_auth directly on every
# launch; this exists for the two cases that aren't a full `up`:
#   fwf auth resolve   (Re)resolve and print the current source, without
#                      launching anything — for diagnosing "which credential
#                      would `fwf up` pick up right now".
#   fwf auth clear     Remove the sink without tearing the floor down (`fwf
#                      down` already does this on a full teardown) — the
#                      explicit path the ticket requires so `rm` isn't the
#                      only documented way to clear it. Idempotent.
#
# Usage: [FWF_PROFILE=example] fwf-auth.sh <resolve|clear>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

case "${1:-}" in
  resolve)
    src="$(fwf_resolve_claude_auth)" || { fwf_claude_auth_failure_message "fwf auth"; exit 1; }
    path="$(sed -n 's/^export FWF_AUTH_SOURCE_PATH=//p' "$FWF_AUTH_ENV_FILE" 2>/dev/null)"
    if [ -n "$path" ]; then echo "resolved from: $src ($path)"; else echo "resolved from: $src"; fi
    ;;
  clear)
    fwf_auth_clear
    echo "auth sink cleared ($FWF_AUTH_ENV_FILE)"
    ;;
  *)
    echo "usage: fwf auth <resolve|clear>" >&2
    exit 1
    ;;
esac
