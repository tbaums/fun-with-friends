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

# Resolve the factory template: the directory of role prompts the panes run.
# A template may ship a template.sh of config DEFAULTS (e.g. the refactor
# factory defaults to fewer pairs) — sourced after the profile so profile/env/
# CLI still win wherever they used the ${VAR:-default} pattern.
FWF_TEMPLATE_DIR="$FWF_LIB_DIR/templates/$FWF_TEMPLATE"
if [ ! -d "$FWF_TEMPLATE_DIR" ]; then
  echo "fwf: unknown template '$FWF_TEMPLATE' (missing $FWF_TEMPLATE_DIR) — see 'fwf templates'" >&2; exit 1
fi
for _fwf_t in implementer qa conductor pm gv captain; do
  if [ ! -f "$FWF_TEMPLATE_DIR/$_fwf_t.tmpl" ]; then
    echo "fwf: template '$FWF_TEMPLATE' is missing $_fwf_t.tmpl" >&2; exit 1
  fi
done
unset _fwf_t
# shellcheck source=/dev/null  # template path is resolved at runtime
[ -f "$FWF_TEMPLATE_DIR/template.sh" ] && source "$FWF_TEMPLATE_DIR/template.sh"

# Derive the implementer/QA pair id array AFTER profile + template load, so
# either can set its own FWF_PAIRS default (env/CLI win — they arrive pre-set).
FWF_PAIRS="${FWF_PAIRS:-3}"
case "$FWF_PAIRS" in
  ''|*[!0-9]*|0) echo "fwf: FWF_PAIRS must be a positive integer (got '$FWF_PAIRS')" >&2; exit 1;;
esac
PAIRS=()
_fwf_i=1
while [ "$_fwf_i" -le "$FWF_PAIRS" ]; do PAIRS+=("$_fwf_i"); _fwf_i=$((_fwf_i+1)); done
unset _fwf_i

# The claude launch command for a role, honoring the per-role model overrides
# (FWF_MODEL_<ROLE>, falling back to FWF_MODEL, falling back to the CLI default).
# $1 = role tag or family: impl2 / qa1 / conductor / pm / gv / captain.
fwf_claude_cmd() { # $1=role
  local m=""
  case "$1" in
    impl*)     m="${FWF_MODEL_IMPL:-$FWF_MODEL}";;
    qa*)       m="${FWF_MODEL_QA:-$FWF_MODEL}";;
    conductor) m="${FWF_MODEL_CONDUCTOR:-$FWF_MODEL}";;
    pm)        m="${FWF_MODEL_PM:-$FWF_MODEL}";;
    gv)        m="${FWF_MODEL_GV:-$FWF_MODEL}";;
    captain)   m="${FWF_MODEL_CAPTAIN:-$FWF_MODEL}";;
  esac
  if [ -n "$m" ]; then printf '%s --model %s' "$CLAUDE_CMD" "$m"; else printf '%s' "$CLAUDE_CMD"; fi
}

# Worktree directory for a role tag (impl1 / qa1 / pm / conductor).
wt_dir() { echo "$WT_BASE/${WT_PREFIX}-$1"; }

# The canonical set of looped roles, one per line, in launch/arm order. Single
# source of truth — fwf-up delivers prompts to these and fwf-resume re-arms them.
fwf_all_roles() {
  local id
  for id in "${PAIRS[@]}"; do echo "impl$id"; done
  for id in "${PAIRS[@]}"; do echo "qa$id"; done
  echo conductor; echo pm; echo gv; echo captain
}

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
  text="${text//__COORD_SESSION__/$COORD_SESSION}"
  text="${text//__BUILD_SESSION__/$BUILD_SESSION}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  text="${text//__GATE__/$GATE_CMD}"
  text="${text//__E2E__/$E2E_CMD}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__DEVUI__/$devui}"
  printf '%s' "$text" | tr '\n' ' ' | tr -s ' '
}

# Find the pane in a session whose @l label contains a token (PM ·, GRAND
# VIZIER, CAPTAIN, IMPL1, …). Echoes the pane id; returns 1 if the session is
# down or no pane matches. Sessions are single-window, so list-panes suffices.
fwf_find_pane() { # $1=session  $2=label-token
  local p
  tmux has-session -t "$1" 2>/dev/null || return 1
  for p in $(tmux list-panes -t "$1" -F '#{pane_id}'); do
    case "$(tmux show -p -t "$p" @l 2>/dev/null)" in *"$2"*) echo "$p"; return 0;; esac
  done
  return 1
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
fwf_ensure_claude() { # $1=pane  $2=launch command (default: $CLAUDE_CMD)
  local p="$1" cmd="${2:-$CLAUDE_CMD}"
  for _ in 1 2 3 4 5; do                          # retry attempts (counter unused)
    _fwf_pane_is_shell "$p" || return 0          # claude already running
    tmux send-keys -t "$p" C-c 2>/dev/null; sleep 0.4   # clear any half-typed/lost line
    tmux send-keys -t "$p" -l "$cmd"; tmux send-keys -t "$p" Enter
    for _ in $(seq 1 15); do                       # wait up to 15s for claude to take over
      sleep 1
      _fwf_pane_is_shell "$p" || return 0
    done
  done
  return 1
}
