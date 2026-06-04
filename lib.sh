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
  text="${text//__HOLD_LABEL__/$HOLD_LABEL}"
  text="${text//__PM_INTERVAL__/$PM_INTERVAL}"
  text="${text//__STOPFILE__/$STOP_FILE}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  text="${text//__GATE__/$GATE_CMD}"
  text="${text//__E2E__/$E2E_CMD}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__DEVUI__/$devui}"
  printf '%s' "$text" | tr '\n' ' ' | tr -s ' '
}

# True while the pane is still sitting at a shell (claude has not taken over).
_fwf_pane_is_shell() { # $1=pane
  case "$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in
    zsh|-zsh|bash|-bash|sh|-sh|fish|-fish|"") return 0;; *) return 1;;
  esac
}

# Ensure claude is actually RUNNING in a pane. A freshly-respawned/just-split
# shell often isn't ready when we first type, so the keystrokes are lost and the
# pane stays at the shell. So: (re)send the launch command, wait for claude to
# take over, and retry a few times. Returns 0 once claude is up, 1 if it never
# came up. Safe to call on a pane that already has claude (returns immediately).
fwf_ensure_claude() { # $1=pane
  local p="$1" try w
  for try in 1 2 3 4 5; do
    _fwf_pane_is_shell "$p" || return 0          # claude already running
    tmux send-keys -t "$p" C-c 2>/dev/null; sleep 0.4   # clear any half-typed/lost line
    tmux send-keys -t "$p" -l "$CLAUDE_CMD"; tmux send-keys -t "$p" Enter
    for w in $(seq 1 15); do
      sleep 1
      _fwf_pane_is_shell "$p" || return 0
    done
  done
  return 1
}
