#!/usr/bin/env bash
# Clear the STOP sentinel so the swarm can run again. fwf-stop cancelled each
# agent's loop, so re-arm the roles you want looping again with fwf-respawn.sh.
#
# Usage: [FWF_PROFILE=example] fwf-resume.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

if [ -e "$STOP_FILE" ]; then rm -f "$STOP_FILE"; echo "cleared STOP sentinel ($STOP_FILE)"; else echo "no STOP sentinel present"; fi
echo "re-arm agents with, e.g.:  for r in impl1 impl2 impl3 qa1 qa2 qa3 pm conductor; do FWF_PROFILE=$PROFILE $DIR/fwf-respawn.sh \$r; done"
