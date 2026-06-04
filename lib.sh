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
  text="${text//__WIP_LABEL__/$WIP_LABEL}"
  text="${text//__PM_INTERVAL__/$PM_INTERVAL}"
  text="${text//__STOPFILE__/$STOP_FILE}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  text="${text//__GATE__/$GATE_CMD}"
  text="${text//__E2E__/$E2E_CMD}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__DEVUI__/$devui}"
  printf '%s' "$text" | tr '\n' ' ' | tr -s ' '
}

# Wait until claude has actually booted in each given pane (its current command
# is no longer a shell), so a prompt is never typed into the shell by mistake.
# Returns 0 when all panes are ready, 1 on timeout (FWF_BOOT_TIMEOUT seconds).
fwf_wait_ready() { # $@ = pane ids
  local elapsed=0 p cmd notready
  while [ "$elapsed" -lt "$FWF_BOOT_TIMEOUT" ]; do
    notready=0
    for p in "$@"; do
      cmd="$(tmux display -p -t "$p" '#{pane_current_command}' 2>/dev/null)"
      case "$cmd" in zsh|-zsh|bash|-bash|sh|-sh|fish|"") notready=1;; esac
    done
    [ "$notready" -eq 0 ] && return 0
    sleep 1; elapsed=$((elapsed + 1))
  done
  return 1
}
