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
# The dev fallback applies HERE, after the profile loads (issue #30) — config.sh
# pre-filling it silently defeated every profile's ${FWF_TEMPLATE:-name}
# persistence and launched the wrong factory.
FWF_TEMPLATE="${FWF_TEMPLATE:-dev}"
# A template may ship a template.sh of config DEFAULTS (e.g. the refactor
# factory defaults to fewer pairs) — sourced after the profile so profile/env/
# CLI still win wherever they used the ${VAR:-default} pattern. template.sh
# may also set FWF_TEMPLATE_BASE (inherit prompt files from another template,
# overriding only some) and FWF_EXTRA_ROLES (additional panes — see below), so
# it loads BEFORE the role-prompt validation.
FWF_TEMPLATE_DIR="$FWF_LIB_DIR/templates/$FWF_TEMPLATE"
if [ ! -d "$FWF_TEMPLATE_DIR" ]; then
  echo "fwf: unknown template '$FWF_TEMPLATE' (missing $FWF_TEMPLATE_DIR) — see 'fwf templates'" >&2; exit 1
fi
FWF_TEMPLATE_BASE=""
# shellcheck source=/dev/null  # template path is resolved at runtime
[ -f "$FWF_TEMPLATE_DIR/template.sh" ] && source "$FWF_TEMPLATE_DIR/template.sh"

# Extra roles a template (or profile/env) declares beyond the stock roster:
# space-separated "name:session:interval[:color]" entries, session = coord|build.
# e.g. the dev-sre template declares "sre:coord:2m:colour208".
FWF_EXTRA_ROLES="${FWF_EXTRA_ROLES:-}"
fwf_extra_names() { local e; for e in $FWF_EXTRA_ROLES; do echo "${e%%:*}"; done; }
fwf_extra_entry() { # $1=name → echo the entry; rc 1 if not declared
  local e; for e in $FWF_EXTRA_ROLES; do [ "${e%%:*}" = "$1" ] && { echo "$e"; return 0; }; done; return 1
}
fwf_extra_session()  { local e; e="$(fwf_extra_entry "$1")" || return 1; e="${e#*:}"; echo "${e%%:*}"; }
fwf_extra_interval() { local e; e="$(fwf_extra_entry "$1")" || return 1; e="${e#*:}"; e="${e#*:}"; echo "${e%%:*}"; }
fwf_extra_color()    { local e rest; e="$(fwf_extra_entry "$1")" || return 1
  rest="${e#*:*:*:}"; if [ "$rest" = "$e" ]; then echo "colour208"; else echo "$rest"; fi; }

# Resolve a role's prompt file: the template's own copy wins; otherwise fall
# back to its FWF_TEMPLATE_BASE. Echoes the path; rc 1 (with a message) if
# neither has it.
fwf_tmpl_path() { # $1=role file base name (implementer / qa / sre / …)
  if [ -f "$FWF_TEMPLATE_DIR/$1.tmpl" ]; then echo "$FWF_TEMPLATE_DIR/$1.tmpl"; return 0; fi
  if [ -n "$FWF_TEMPLATE_BASE" ] && [ -f "$FWF_LIB_DIR/templates/$FWF_TEMPLATE_BASE/$1.tmpl" ]; then
    echo "$FWF_LIB_DIR/templates/$FWF_TEMPLATE_BASE/$1.tmpl"; return 0
  fi
  echo "fwf: template '$FWF_TEMPLATE' has no $1.tmpl (base: ${FWF_TEMPLATE_BASE:-none})" >&2; return 1
}

# Every stock role and every declared extra role must resolve to a prompt.
for _fwf_t in implementer qa conductor pm gv captain $(fwf_extra_names); do
  fwf_tmpl_path "$_fwf_t" >/dev/null || exit 1
done
unset _fwf_t

# Issue-tracker backend (issue #26): "gh" = the target repo's GitHub issues;
# "local" = a markdown store outside any repo, driven by fwf-issues.sh. The
# store path is per-profile so two factories never share a tracker. Defaulted
# HERE (after profile + template) so both can persist it via ${FWF_ISSUES:-…}.
FWF_ISSUES="${FWF_ISSUES:-gh}"
case "$FWF_ISSUES" in
  gh|local) ;;
  *) echo "fwf: FWF_ISSUES must be 'gh' or 'local' (got '$FWF_ISSUES')" >&2; exit 1;;
esac
# shellcheck disable=SC2034  # consumed by fwf-issues.sh / fwf-provision.sh
FWF_ISSUES_DIR="$FWF_RUN/issues/$PROFILE"

# The gh-write guard (issue #34) — the issue-tracker counterpart of #28's
# pre-push hook. In local mode every pane gets this directory PREPENDED to
# PATH; it holds (a) a `gh` wrapper that fail-closed blocks every mutating
# command unless a human authorizes that invocation with FWF_ALLOW_GH=1
# (reads stay allowed), and (b) an `fwf` symlink so the local-issues CLI is
# ALWAYS resolvable in panes — the unguarded gh fallback in the #34 incident
# started with `fwf` missing from a non-login pane PATH.
FWF_GHGUARD_DIR="$FWF_RUN/ghguard"
fwf_install_ghguard() {
  local real_gh
  real_gh="$(command -v gh || true)"
  mkdir -p "$FWF_GHGUARD_DIR"
  ln -sf "$FWF_LIB_DIR/fwf" "$FWF_GHGUARD_DIR/fwf"
  cat > "$FWF_GHGUARD_DIR/gh" <<GHGUARD
#!/usr/bin/env sh
# fwf gh-write guard — installed for --issues local mode (issue #34).
# The factory's tracker is LOCAL; the remote's issues/labels/PRs are not ours
# to write. Mutating gh commands are blocked unless a HUMAN authorizes this
# single invocation with FWF_ALLOW_GH=1. Reads pass through.
REAL_GH="${real_gh:-gh}"
[ "\${FWF_ALLOW_GH:-0}" = "1" ] && exec "\$REAL_GH" "\$@"
blocked() {
  echo "fwf: gh write BLOCKED ('gh \$*') — local-issues mode never writes to the remote tracker." >&2
  echo "fwf: use 'fwf issues …' for the local tracker; a human can authorize one real gh write with: FWF_ALLOW_GH=1 gh …" >&2
  exit 1
}
case "\${1:-}" in
  ""|help|--help|--version|version|status|search) exec "\$REAL_GH" "\$@" ;;
  auth)   case "\${2:-}" in status|token) exec "\$REAL_GH" "\$@";; *) blocked "\$@";; esac ;;
  config) case "\${2:-}" in get|list|"") exec "\$REAL_GH" "\$@";; *) blocked "\$@";; esac ;;
  api)
    meth="GET"; prev=""
    for a in "\$@"; do
      case "\$prev" in --method|-X) meth="\$a";; esac
      case "\$a" in --method=*) meth="\${a#--method=}";; -X=*) meth="\${a#-X=}";; esac
      prev="\$a"
    done
    case "\$meth" in GET|HEAD|get|head) exec "\$REAL_GH" "\$@";; *) blocked "\$@";; esac ;;
  *)
    # topic commands (issue/pr/label/release/repo/run/workflow/gist/…):
    # allow the read-shaped subcommands, block everything else fail-closed.
    case "\${2:-}" in
      list|view|status|diff|checks|download|watch) exec "\$REAL_GH" "\$@" ;;
      *) blocked "\$@" ;;
    esac ;;
esac
GHGUARD
  chmod +x "$FWF_GHGUARD_DIR/gh"
}

# In local mode, panes launch claude with the guard dir first on PATH (the
# \$PATH stays literal here and expands in the pane's shell).
if [ "$FWF_ISSUES" = "local" ]; then
  CLAUDE_CMD="env PATH=\"$FWF_GHGUARD_DIR:\$PATH\" $CLAUDE_CMD"
fi

# Session names, template-aware (issue #31): the dev factory keeps the classic
# names; any other template embeds its name so `tmux ls` says which factory
# design is live (friends-ideation-coord/-build). Env/profile overrides win.
SESSION="${FWF_SESSION:-friends}"
_fwf_sfx=""
[ "$FWF_TEMPLATE" = "dev" ] || _fwf_sfx="-$FWF_TEMPLATE"
COORD_SESSION="${FWF_COORD_SESSION:-${SESSION}${_fwf_sfx}-coord}"   # pm · gv · captain — the human talks here
BUILD_SESSION="${FWF_BUILD_SESSION:-${SESSION}${_fwf_sfx}-build}"   # the floor
unset _fwf_sfx

# Role display identities + floor-pane descriptions (issue #31): templates
# override these so an ideation floor LOOKS like one (GEN/CRITIC/SYNTH), not
# like a build factory wearing the wrong uniform. Pane labels keep the
# canonical role token alongside the display name, so respawn/floor matching
# never depends on these.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-IMPL}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-QA}"
FWF_DISPLAY_CONDUCTOR="${FWF_DISPLAY_CONDUCTOR:-CONDUCTOR}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-PM}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-any issue → instant draft PR}"
FWF_DESC_QA="${FWF_DESC_QA:-reviews+merges}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-e2e gate}"
FWF_DESC_PM="${FWF_DESC_PM:-ideas → gated draft issues}"

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
    *)
      # Extra roles get the same treatment generically: FWF_MODEL_<NAME>
      # (uppercased role name) beats the floor-wide default. eval is safe
      # here — the name is whitelisted to [A-Z0-9_] first.
      _fwf_up="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
      case "$_fwf_up" in
        *[!A-Z0-9_]*|"") m="$FWF_MODEL";;
        *) eval "m=\"\${FWF_MODEL_$_fwf_up:-\$FWF_MODEL}\"";;
      esac
      unset _fwf_up;;
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
  fwf_extra_names
}

# Render a prompt template into a single line, substituting placeholders.
# Uses bash substitution (not sed) so command strings with && / are safe.
#
# LOCAL ISSUES MODE (issue #26): when FWF_ISSUES=local, two uniform rewrites
# retarget EVERY template at the local tracker with no per-template forks —
#   `gh issue …`  ->  `fwf --profile <P> issues …`   (the CLI is gh-shaped)
#   `#<num>`/`#N` ->  `LI-<num>`/`LI-N`              (so PR titles/bodies never
#                      auto-link an unrelated upstream issue number)
# — and a per-role ADDENDUM (templates/_local-issues/<role>.tmpl, if present)
# is appended BEFORE substitution, so addenda are written in the same gh-shaped
# conventions and stay uniform with the main prompt.
fwf_render() { # $1=template-file  $2=id (may be empty for pm/conductor)
  local tmpl="$1" id="${2:-}" text devui addendum
  text="$(cat "$tmpl")"
  if [ "$FWF_ISSUES" = "local" ]; then
    addendum="$FWF_LIB_DIR/templates/_local-issues/$(basename "$tmpl")"
    if [ -f "$addendum" ]; then
      text="$text
$(cat "$addendum")"
    fi
  fi
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
  if [ "$FWF_ISSUES" = "local" ]; then
    text="${text//gh issue /fwf --profile $PROFILE issues }"
    text="${text//#</LI-<}"
    text="${text//#N/LI-N}"
  fi
  printf '%s' "$text" | tr '\n' ' ' | tr -s ' '
}

# --- role pane identity: color + label text, shared by fwf-up and respawn ----
# One source of truth (issue #36) so a recovered pane is indistinguishable
# from a launched one. Display prefix ("GEN1 · ") appears when a template
# renames a role; the canonical token always stays in the label, so
# fwf_find_pane never depends on display names.
_fwf_disp() { # $1=display $2=token $3=id
  [ "$1" = "$2" ] || printf '%s%s · ' "$1" "$3"
}
fwf_role_color() { # $1=role tag
  case "$1" in
    impl*) pair_color "${1#impl}";;
    qa*)   pair_color "${1#qa}";;
    conductor) echo "$CONDUCTOR_COLOR";;
    pm)        echo "$PM_COLOR";;
    gv)        echo "$GV_COLOR";;
    captain)   echo "$CAPTAIN_COLOR";;
    *)         fwf_extra_color "$1" || echo colour208;;
  esac
}
fwf_role_label() { # $1=role tag → the full @l label text
  local id
  case "$1" in
    impl*) id="${1#impl}"
      printf '%sIMPL%s · %s · impl%s/*' "$(_fwf_disp "$FWF_DISPLAY_IMPL" IMPL "$id")" "$id" "$FWF_DESC_IMPL" "$id";;
    qa*)   id="${1#qa}"
      printf '%sQA%s · %s impl%s/* · loop %s' "$(_fwf_disp "$FWF_DISPLAY_QA" QA "$id")" "$id" "$FWF_DESC_QA" "$id" "$QA_LOOP_INTERVAL";;
    conductor)
      printf '%sCONDUCTOR · %s · %s → %s (never %s)' "$(_fwf_disp "$FWF_DISPLAY_CONDUCTOR" CONDUCTOR "")" "$FWF_DESC_CONDUCTOR" "$STAGING_BRANCH" "$INTEGRATION_BRANCH" "$DEFAULT_BRANCH";;
    pm)
      printf '%sPM · %s · refine loop %s' "$(_fwf_disp "$FWF_DISPLAY_PM" PM "")" "$FWF_DESC_PM" "$PM_INTERVAL";;
    gv)
      printf 'GRAND VIZIER (GV) · hardens PM specs · advises captain · loop %s' "$GV_INTERVAL";;
    captain)
      printf 'CAPTAIN · you talk here · scopes+ships, hones via GV · loop %s' "$CAPTAIN_INTERVAL";;
    *)
      printf '%s · template role · loop %s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" "$(fwf_extra_interval "$1" || echo '?')";;
  esac
}

# Recovery (issue #36): create a brand-new pane for a role whose pane closed
# entirely — fwf-up's split/label logic, available to respawn. The role's
# session must already exist. qaN tucks under its paired IMPLN when that pane
# is alive; coordination panes re-balance to even columns; the build grid is
# NOT re-laid-out (even-horizontal would flatten the impl/qa stacks).
# Echoes the new pane id.
fwf_create_role_pane() { # $1=role tag
  local role="$1" sess anchor pane
  case "$role" in
    impl*|qa*|conductor) sess="$BUILD_SESSION";;
    pm|gv|captain)       sess="$COORD_SESSION";;
    *) case "$(fwf_extra_session "$role" 2>/dev/null)" in
         build) sess="$BUILD_SESSION";; *) sess="$COORD_SESSION";;
       esac;;
  esac
  tmux has-session -t "$sess" 2>/dev/null || { echo "fwf: cannot create pane for '$role' — session '$sess' is not running (use fwf up)" >&2; return 1; }
  pane=""
  case "$role" in
    qa*)
      anchor="$(fwf_find_pane "$sess" "IMPL${role#qa} ·" || true)"
      [ -n "$anchor" ] && pane=$(tmux split-window -v -P -F '#{pane_id}' -t "$anchor" -c "$(wt_dir "$role")");;
  esac
  if [ -z "$pane" ]; then
    anchor="$(tmux list-panes -t "$sess" -F '#{pane_id}' | tail -1)"
    pane=$(tmux split-window -h -P -F '#{pane_id}' -t "$anchor" -c "$(wt_dir "$role")")
    [ "$sess" = "$COORD_SESSION" ] && tmux select-layout -t "$sess" even-horizontal >/dev/null
  fi
  tmux set -p -t "$pane" @c "$(fwf_role_color "$role")"
  tmux set -p -t "$pane" @l "$(fwf_role_label "$role")"
  printf '%s\n' "$pane"
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

# Type a prompt into a pane's claude composer and submit. Clears any stale
# buffer first (the "wedged buffer" problem). The text is sent in 1KB CHUNKS:
# tmux rejects a send-keys argument past ~10KB with "command too long", and
# the bigger role prompts (e.g. the dev-sre captain) are over that. The first
# Enter after a long paste is frequently absorbed by the TUI, so send two.
fwf_send_prompt() { # $1=pane  $2=text
  local p="$1" s="$2" off=0
  fwf_clear_composer "$p"
  while [ "$off" -lt "${#s}" ]; do
    # "--" ends option parsing: a chunk boundary can land on a "-…" word,
    # which tmux would otherwise read as a flag ("unknown flag -v").
    tmux send-keys -t "$p" -l -- "${s:$off:1024}"
    off=$((off+1024)); sleep 0.1
  done
  sleep 1; tmux send-keys -t "$p" Enter; sleep 1; tmux send-keys -t "$p" Enter
}

# Render a role's prompt and persist it for post-compaction re-hydration
# (issue #38). Echoes the file path. Per-profile so factories never collide.
fwf_write_role_prompt() { # $1=role-tag  $2=tmpl-base  $3=id
  local pf="$FWF_RUN/prompts/$PROFILE-$1.prompt"
  mkdir -p "$FWF_RUN/prompts"
  fwf_render "$(fwf_tmpl_path "$2")" "$3" > "$pf"
  printf '%s\n' "$pf"
}

# Arm a pane (issue #38): the full rendered role prompt is delivered ONCE as a
# normal message (and persisted to disk), then the /loop is started with a
# ONE-LINE tick that points back at the file. Previously the loop re-fired the
# entire multi-KB prompt every tick, burning the agent's context window and
# forcing frequent compaction; now a compacted agent re-reads the role from
# disk instead.
fwf_arm_pane() { # $1=pane  $2=role-tag  $3=tmpl-base  $4=id  $5=interval
  local pane="$1" role="$2" tmpl="$3" id="$4" interval="$5" pf
  pf="$(fwf_write_role_prompt "$role" "$tmpl" "$id")"
  fwf_send_prompt "$pane" "ADOPT THIS ROLE now and run your first cycle. Your role prompt follows — it is also saved at $pf; re-read that file whenever you have compacted or otherwise lost context. $(cat "$pf")"
  fwf_send_prompt "$pane" "/loop $interval $role tick: if you have compacted or lost ANY context since the last tick, FIRST re-read your role prompt at $pf. Then run exactly ONE cycle of that role's loop and report in its format. Act the role; do not re-state it."
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
