#!/usr/bin/env bash
# Shared helpers. Sources config.sh + the selected profile, then exposes
# wt_dir() and fwf_render(). Source this from every fwf-*.sh entrypoint.

# --- bash floor -------------------------------------------------------------
# macOS ships bash 3.2 (2007) as /bin/bash; Linux ships 4/5. This codebase is
# deliberately 3.2-clean (no associative arrays, no ${var^^}, no mapfile), so
# 3.2 is the floor. We only reject a non-bash shell or something older than 3.2.
if [ -z "${BASH_VERSINFO:-}" ]; then
  echo "fwf: must run under bash (got a non-bash shell). Try: bash $0" >&2; exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "fwf: bash >= 3.2 required (found $BASH_VERSION). On macOS the stock 3.2 is fine; otherwise upgrade bash." >&2; exit 1
fi

FWF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FWF_LIB_DIR/config.sh"

PROFILE="${FWF_PROFILE:-example}"
PROFILE_FILE="$FWF_LIB_DIR/profiles/$PROFILE.sh"
[ -f "$PROFILE_FILE" ] || { echo "fwf: unknown profile '$PROFILE' (missing $PROFILE_FILE)" >&2; exit 1; }
# shellcheck source=/dev/null  # profile path is resolved at runtime
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

# Clear whatever is sitting in the pane's Claude composer before we type into it,
# so a stale/half-typed buffer doesn't garble the next prompt (the "wedged buffer"
# problem). Ctrl+U is the TUI's reliable line-clear; we repeat it to drain
# multi-line drafts. Deliberately NOT Ctrl+C (a second Ctrl+C exits the session)
# and NOT Ctrl+A/Ctrl+K (readline, which this TUI does not honor).
fwf_clear_composer() { # $1=pane
  local p="$1"
  for _ in 1 2 3; do tmux send-keys -t "$p" C-u 2>/dev/null; done
  sleep 0.3
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
  local p="$1"
  for _ in 1 2 3 4 5; do                          # retry attempts (counter unused)
    _fwf_pane_is_shell "$p" || return 0          # claude already running
    tmux send-keys -t "$p" C-c 2>/dev/null; sleep 0.4   # clear any half-typed/lost line
    tmux send-keys -t "$p" -l "$CLAUDE_CMD"; tmux send-keys -t "$p" Enter
    for _ in $(seq 1 15); do                       # wait up to 15s for claude to take over
      sleep 1
      _fwf_pane_is_shell "$p" || return 0
    done
  done
  return 1
}
