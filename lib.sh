#!/usr/bin/env bash
# Shared helpers. Sources config.sh + the selected profile, then exposes
# wt_dir() and fwf_render(). Source this from every fwf-*.sh entrypoint.

FWF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FWF_LIB_DIR/config.sh"

PROFILE="${FWF_PROFILE:-transom}"
PROFILE_FILE="$FWF_LIB_DIR/profiles/$PROFILE.sh"
[ -f "$PROFILE_FILE" ] || { echo "fwf: unknown profile '$PROFILE' (missing $PROFILE_FILE)" >&2; exit 1; }
source "$PROFILE_FILE"

# Worktree directory for a role tag (impl1 / qa1 / pm / conductor).
wt_dir() { echo "$WT_BASE/${WT_PREFIX}-$1"; }

# Render a prompt template into a single line, substituting placeholders.
# Uses bash substitution (not sed) so command strings with && / are safe.
fwf_render() { # $1=template-file  $2=id (may be empty for pm/conductor)
  local tmpl="$1" id="${2:-}" text devui
  text="$(cat "$tmpl")"
  devui="${DEV_UI_HINT//__DATA__/$(data_dir "impl$id")}"
  text="${text//__ID__/$id}"
  text="${text//__STAGING__/$STAGING_BRANCH}"
  text="${text//__INTEGRATION__/$INTEGRATION_BRANCH}"
  text="${text//__DEFAULT__/$DEFAULT_BRANCH}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  text="${text//__GATE__/$GATE_CMD}"
  text="${text//__E2E__/$E2E_CMD}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__DEVUI__/$devui}"
  printf '%s' "$text" | tr '\n' ' ' | tr -s ' '
}
