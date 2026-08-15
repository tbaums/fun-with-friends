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
# A tool that wants to reflect the RUNNING factory (chiefly the dash) opts in
# with FWF_USE_RUNNING_TEMPLATE=1; we then prefer the factory's persisted
# template (fwf up writes $FWF_RUN/template; fwf down clears it) over the dev
# default (#51). Opt-in keeps tests and ordinary commands at the dev default and
# avoids the machine's run-state leaking into them. Explicit FWF_TEMPLATE wins.
if [ -n "${FWF_USE_RUNNING_TEMPLATE:-}" ] && [ -z "${FWF_TEMPLATE:-}" ] && [ -f "$FWF_RUN/template" ]; then
  FWF_TEMPLATE="$(cat "$FWF_RUN/template" 2>/dev/null)"
fi
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

# Roster shaping a template (or profile/env) declares — both default empty, so
# every existing template is byte-for-byte unaffected (the helpers short-circuit
# on an empty list). Lists are space-separated and match a role by its exact tag
# (conductor, gv, pm) OR by family (impl → every implN, qa → every qaN).
#
#   FWF_SUPPRESS_ROLES     roles the engine must NOT launch/provision/arm. The
#                          user-testing template suppresses "qa conductor gv" so
#                          the floor is exactly 3 personas + researcher + captain.
#   FWF_NO_WORKTREE_ROLES  roles that get NO git worktree — only a throwaway
#                          scratch dir. The user-testing personas are source-blind
#                          by construction: "impl" here means they never receive a
#                          checkout of the target's source, just a browser.
FWF_SUPPRESS_ROLES="${FWF_SUPPRESS_ROLES:-}"
FWF_NO_WORKTREE_ROLES="${FWF_NO_WORKTREE_ROLES:-}"
_fwf_role_in_list() { # $1=role tag  $2=space-separated tags/families → rc 0 if it matches
  local r fam="$1"
  case "$1" in impl*) fam=impl;; qa*) fam=qa;; esac
  for r in $2; do
    [ "$r" = "$1" ] && return 0
    [ "$r" = "$fam" ] && return 0
  done
  return 1
}
fwf_role_suppressed()  { _fwf_role_in_list "$1" "$FWF_SUPPRESS_ROLES"; }
fwf_role_no_worktree() { _fwf_role_in_list "$1" "$FWF_NO_WORKTREE_ROLES"; }

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

# Reviewer-facing "built with fwf" credit policy (issue #106): on | minimal | off.
# local-issues mode IS the existing "this repo isn't ours" signal (its own
# description: "a no-push local-issues mode for repos you don't control"), so
# default the credit OFF there and ON everywhere else — a profile/env override
# always wins. #107 (upstream-contribution mode, not yet built) will give this
# a per-target dial; until then, FWF_ISSUES=local is the only signal we have.
FWF_CREDIT="${FWF_CREDIT:-$([ "$FWF_ISSUES" = local ] && echo off || echo on)}"
case "$FWF_CREDIT" in
  on|minimal|off) ;;
  *) echo "fwf: FWF_CREDIT must be 'on', 'minimal', or 'off' (got '$FWF_CREDIT')" >&2; exit 1;;
esac

# The gh-write guard (issue #34) — the issue-tracker counterpart of #28's
# pre-push hook. In local mode every pane gets this directory PREPENDED to
# PATH; it holds (a) a `gh` wrapper that fail-closed blocks every mutating
# command unless a human authorizes that invocation with FWF_ALLOW_GH=1
# (reads stay allowed), and (b) an `fwf` symlink so the local-issues CLI is
# ALWAYS resolvable in panes — the unguarded gh fallback in the #34 incident
# started with `fwf` missing from a non-login pane PATH.
FWF_GHGUARD_DIR="$FWF_RUN/ghguard"
# Shared REST+ETag read cache (#57 sibling): collapses N agents' identical
# `gh issue/pr list` polls into one fetch per TTL off the CORE bucket (separate
# from the GraphQL pool the factory was exhausting). Tunable via env.
export FWF_GHCACHE_DIR="${FWF_GHCACHE_DIR:-$FWF_RUN/ghcache}"
export FWF_GHCACHE_TTL="${FWF_GHCACHE_TTL:-60}"
export FWF_REPO
fwf_install_ghguard() {
  local real_gh slug
  real_gh="$(command -v gh || true)"
  slug="$(git -C "$FWF_REPO" config --get remote.origin.url 2>/dev/null || true)"
  slug="${slug%.git}"; slug="${slug#git@github.com:}"; slug="${slug#https://github.com/}"; slug="${slug#ssh://git@github.com/}"
  mkdir -p "$FWF_GHGUARD_DIR"
  ln -sf "$FWF_LIB_DIR/fwf" "$FWF_GHGUARD_DIR/fwf"
  # Part (a): a `gh` shim that routes the hot, high-frequency reads through the
  # shared cache in EVERY mode. Baked install-time values (real gh path, repo,
  # cache dir) keep it self-contained in non-login panes.
  cat > "$FWF_GHGUARD_DIR/gh" <<GHGUARD
#!/usr/bin/env sh
# fwf gh shim (#57/#58): (a) REST+ETag read cache for the hot list/view/diff
# polls in all modes; (b) in local mode, the fail-closed write guard (#34).
REAL_GH="${real_gh:-gh}"
CACHE="$FWF_LIB_DIR/fwf-ghcache.sh"
export FWF_REAL_GH="\$REAL_GH" FWF_GHCACHE_DIR="$FWF_GHCACHE_DIR" FWF_REPO="$FWF_REPO" FWF_GHCACHE_REPO="$slug" FWF_GHCACHE_TTL="$FWF_GHCACHE_TTL"
_t="\${1:-}"; _v="\${2:-}"
case "\$_t \$_v" in
  "issue list"|"pr list"|"issue view"|"pr view"|"pr diff")
    shift 2; exec "\$CACHE" serve "\$_t" "\$_v" "\$@" ;;
esac
GHGUARD
  # Part (b): write policy. Local mode fails closed; gh mode passes through.
  if [ "$FWF_ISSUES" = "local" ]; then
    cat >> "$FWF_GHGUARD_DIR/gh" <<'GHGUARD'
# local-issues mode (#34): the remote tracker is not ours to write. Block
# mutations unless a HUMAN authorizes this single call with FWF_ALLOW_GH=1.
[ "${FWF_ALLOW_GH:-0}" = "1" ] && exec "$REAL_GH" "$@"
blocked() {
  echo "fwf: gh write BLOCKED ('gh $*') — local-issues mode never writes to the remote tracker." >&2
  echo "fwf: use 'fwf issues …' for the local tracker; a human can authorize one real gh write with: FWF_ALLOW_GH=1 gh …" >&2
  exit 1
}
case "${1:-}" in
  ""|help|--help|--version|version|status|search) exec "$REAL_GH" "$@" ;;
  auth)   case "${2:-}" in status|token) exec "$REAL_GH" "$@";; *) blocked "$@";; esac ;;
  config) case "${2:-}" in get|list|"") exec "$REAL_GH" "$@";; *) blocked "$@";; esac ;;
  api)
    meth="GET"; prev=""
    for a in "$@"; do
      case "$prev" in --method|-X) meth="$a";; esac
      case "$a" in --method=*) meth="${a#--method=}";; -X=*) meth="${a#-X=}";; esac
      prev="$a"
    done
    case "$meth" in GET|HEAD|get|head) exec "$REAL_GH" "$@";; *) blocked "$@";; esac ;;
  *)
    case "${2:-}" in
      list|view|status|diff|checks|download|watch) exec "$REAL_GH" "$@" ;;
      *) blocked "$@" ;;
    esac ;;
esac
GHGUARD
  else
    cat >> "$FWF_GHGUARD_DIR/gh" <<'GHGUARD'
# gh mode: every non-cached command passes straight through to real gh.
exec "$REAL_GH" "$@"
GHGUARD
  fi
  chmod +x "$FWF_GHGUARD_DIR/gh"
}

# Panes always launch claude with the guard dir first on PATH so the shared read
# cache intercepts gh (and, in local mode, the write guard fires). The literal
# \$PATH expands later, in the pane's own shell.
CLAUDE_CMD="env PATH=\"$FWF_GHGUARD_DIR:\$PATH\" $CLAUDE_CMD"

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

# token-budget unit disambiguation (issue #108): two explicit ceilings, never
# a silent pick-one. Rejected at source time, same style as bogus FWF_PAIRS.
if [ -n "${FWF_TOKEN_BUDGET:-}" ] && [ -n "${FWF_BUDGET_USD:-}" ]; then
  echo "fwf: --token-budget and --budget-usd are mutually exclusive (got both FWF_TOKEN_BUDGET=$FWF_TOKEN_BUDGET and FWF_BUDGET_USD=$FWF_BUDGET_USD) — pick one ceiling" >&2
  exit 1
fi

# Resolve the model NAME for a role, honoring the per-role overrides
# (FWF_MODEL_<ROLE>, falling back to FWF_MODEL, falling back to "" = CLI default).
# $1 = role tag or family: impl2 / qa1 / conductor / pm / gv / captain.
fwf_model_for() { # $1=role -> prints model name (empty string = CLI default)
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
  printf '%s' "$m"
}

# The claude launch command for a role, honoring the per-role model overrides.
# $1 = role tag or family: impl2 / qa1 / conductor / pm / gv / captain.
fwf_claude_cmd() { # $1=role
  local m; m="$(fwf_model_for "$1")"
  if [ -n "$m" ]; then printf '%s --model %s' "$CLAUDE_CMD" "$m"; else printf '%s' "$CLAUDE_CMD"; fi
}

# One-line build-provenance trailer stamped into every PR body + squash-merge
# commit the floor produces (build-provenance instrument): which fwf checkout +
# per-seat models built the change, recorded IN git next to the diff and ticket.
# It turns a later "did shipped quality regress?" diagnosis into a git query
# instead of archaeology — the role→model map otherwise lives only in a
# gitignored profile with no history. Generic by design: the factory's own
# identity + seats, no client/repo specifics.
fwf_provenance_block() {
  local ver sha role m seats=""
  ver="$(cat "$FWF_LIB_DIR/VERSION" 2>/dev/null)"; : "${ver:=unknown}"
  sha="$(git -C "$FWF_LIB_DIR" rev-parse --short HEAD 2>/dev/null)"; : "${sha:=unknown}"
  for role in captain pm gv impl qa conductor; do
    m="$(fwf_model_for "$role")"; [ -n "$m" ] || m="cli-default"
    seats="${seats:+$seats }$role=$m"
  done
  printf 'fwf-Provenance: fwf=%s@%s profile=%s seats=[%s]' "$ver" "$sha" "$PROFILE" "$seats"
}

# Worktree directory for a role tag (impl1 / qa1 / pm / conductor).
wt_dir() { echo "$WT_BASE/${WT_PREFIX}-$1"; }

# fwf-up.sh assumes fwf-provision.sh already created worktrees (issue #142) —
# on a never-provisioned profile, `tmux new-session -c <missing dir>` silently
# falls back to $HOME instead of erroring, so the floor LOOKS up but has no
# worktree to build in. Echoes the space-separated role tags (of the ones
# given) whose worktree/cwd doesn't exist yet; empty if all are present.
# Worktree-less roles (FWF_NO_WORKTREE_ROLES) are always fine — fwf_role_cwd
# creates their scratch dir on demand.
fwf_missing_worktrees() { # $@=role tags to check
  local missing="" r
  for r in "$@"; do
    fwf_role_no_worktree "$r" && continue
    [ -d "$(wt_dir "$r")" ] || missing="$missing $r"
  done
  printf '%s' "${missing# }"
}

# Per-worktree cargo target isolation (issue #151) ---------------------------
# THE cardinal false-GREEN this factory must never emit: a gate that goes GREEN
# on code that is not on the branch under test. Its one known mechanism is a
# SHARED cargo output dir. Cargo keys build artifacts by crate name+version, NOT
# by content — so two worktrees building the same workspace crate (same name,
# same version) from DIFFERENT source (the entire point of worktrees) clobber
# each other's rlibs in a shared dir. Last writer wins: a gate can compile/run
# the OTHER worktree's code and pass. It also serializes builds (cargo takes an
# exclusive file lock on the output dir).
#
# Fix: before any cargo build/test/gate runs in a worktree, GUARANTEE its target
# is private to that worktree. Two vectors are neutralized, both idempotent and
# both no-ops for the healthy case (and for non-Rust profiles):
#   (1) An ambient CARGO_TARGET_DIR that resolves OUTSIDE this worktree — a
#       shared env value — is dropped, so cargo falls back to its per-worktree
#       default `<worktree>/target`. A value already INSIDE the worktree is a
#       legitimate private choice and is kept.
#   (2) A legacy `<worktree>/target` SYMLINK pointing outside the worktree — the
#       pre-#151 shared-cache link — is removed so cargo recreates a real, local
#       target. If it cannot be removed we FAIL CLOSED (return non-zero): a red
#       gate is always safe; a green one built against a shared dir is not.
# RUSTC_WRAPPER (sccache) is deliberately left untouched: sccache is a
# content-addressed compile cache, so sharing it across worktrees is SOUND and
# is the right way to recover cross-worktree cache speed without the name+version
# clobber. Private target dir + shared sccache compose cleanly.
# Run with the current directory inside the worktree (the gate and the warm
# build both are). Emits a loud line on any repair — GREEN gates are audited.
fwf_cargo_isolate() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  # (1) shared ambient CARGO_TARGET_DIR
  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    local ctd
    ctd="$(cd "$CARGO_TARGET_DIR" 2>/dev/null && pwd -P)" || ctd="$CARGO_TARGET_DIR"
    case "$ctd/" in
      "$root"/*) : ;;   # private to this worktree — keep
      *) echo "fwf#151: dropping shared CARGO_TARGET_DIR=$CARGO_TARGET_DIR (outside $root) — using this worktree's own target/" >&2
         unset CARGO_TARGET_DIR ;;
    esac
  fi
  # (2) legacy shared-target symlink
  local t="$root/target"
  if [ -L "$t" ]; then
    local dst; dst="$(cd "$t" 2>/dev/null && pwd -P)" || dst=""
    case "${dst:-x}/" in
      "$root"/*) : ;;   # symlink stays within the worktree — harmless
      *) echo "fwf#151: removing shared target symlink $t -> ${dst:-?} (pre-#151 shared cache)" >&2
         rm -f "$t" || { echo "fwf#151: FAILED to remove $t — refusing to gate against a shared target dir" >&2; return 1; } ;;
    esac
  fi
  return 0
}

# Shared scratch root for source-blind (worktree-less) roles: per-profile, OUTSIDE
# any repo, so personas have a place for browser-driver plumbing and screenshot
# evidence without ever touching the target's source tree. __UT_ROOT__ resolves here.
fwf_ut_root() { echo "$FWF_RUN/ut/$PROFILE"; }

# Working directory for a role's pane: its worktree, or — for a worktree-less
# role (FWF_NO_WORKTREE_ROLES) — a throwaway per-role scratch dir, which is
# created on demand so every `tmux … -c "$(fwf_role_cwd X)"` call site is safe
# even if provision has not run. Idempotent.
fwf_role_cwd() { # $1=role tag
  if fwf_role_no_worktree "$1"; then
    local d; d="$(fwf_ut_root)/$1"; mkdir -p "$d"; echo "$d"
  else
    wt_dir "$1"
  fi
}

# Per-persona app URL (issue #42, trial-one learning). Trial one ran 3 personas
# against ONE UT_APP_URL, so a shared backend bled cross-session artifacts between
# them — the scorecard's #1 false-signal source. Give each persona its OWN app
# instance: UT_APP_URL_<id> overrides the shared UT_APP_URL for persona <id>;
# unset falls back to the shared URL. See docs/user-testing.md for the one-
# instance-per-persona setup.
fwf_ut_app_url() { # $1=persona id (empty -> shared)
  local u="${UT_APP_URL:-}"
  case "${1:-}" in [0-9]*) eval "u=\"\${UT_APP_URL_$1:-$u}\"";; esac
  printf '%s' "$u"
}

# The browser engine the personas' Playwright MCP drives. Defaults to FIREFOX —
# trial one validated on Firefox. Override with UT_BROWSER.
UT_BROWSER="${UT_BROWSER:-firefox}"
# The exact one-time setup that wired the browser MCP for trial one — echoed by
# the preflight and documented in docs/user-testing.md.
fwf_ut_browser_setup_cmds() {
  printf '  npx playwright install %s\n' "$UT_BROWSER"
  printf '  claude mcp add playwright -s user -- npx -y @playwright/mcp@latest --headless --isolated --browser %s\n' "$UT_BROWSER"
}
# Is the browser MCP REGISTERED? Read the CONFIG directly (~/.claude.json user
# mcpServers) — NOT a live `claude mcp list` probe. The probe opens a connection
# to each server, so a registered-but-momentarily-unconnectable MCP reads as
# "not registered" — a false-negative that scares the operator into a needless
# re-install (observed during a wide sweep: the MCP was ✔ Connected yet the probe
# said missing). The config is authoritative for "registered"; connectivity is a
# separate, transient concern. Generous on purpose: the server name as an
# mcpServers key ANYWHERE in the config (user scope or any project) counts.
# Overridable for tests: CLAUDE_CONFIG (path) and UT_BROWSER_MCP_NAME (server name).
fwf_ut_browser_mcp_registered() {
  local cfg="${CLAUDE_CONFIG:-$HOME/.claude.json}" name="${UT_BROWSER_MCP_NAME:-playwright}"
  [ -f "$cfg" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg n "$name" \
      '((.mcpServers // {}) | has($n)) or ([.projects[]?.mcpServers // {} | has($n)] | any)' \
      "$cfg" >/dev/null 2>&1
    return
  fi
  # jq-less fallback: the server name present as a JSON key in the operator's own
  # config. Coarse but fail-SAFE — it errs toward "registered" (no false alarm).
  grep -q "\"$name\"[[:space:]]*:" "$cfg"
}
# Browser-MCP preflight for the user-testing factory (issue #42). Personas drive a
# real browser through the Playwright MCP ("hands, not a test framework"); trial
# one could not launch until this was wired by hand. So the factory now checks:
# WARNS (fail-open) with the exact setup if the MCP is not registered — or, with
# FWF_UT_SETUP_BROWSER=1, installs it. No-op for every other template.
fwf_ut_browser_preflight() {
  [ "$FWF_TEMPLATE" = "user-testing" ] || return 0
  fwf_ut_browser_mcp_registered && return 0
  local claude_bin; claude_bin="${FWF_CLAUDE_BIN:-${CLAUDE_CMD%% *}}"
  if [ "${FWF_UT_SETUP_BROWSER:-0}" = "1" ] && command -v npx >/dev/null 2>&1 && command -v "$claude_bin" >/dev/null 2>&1; then
    echo "fwf user-testing: installing the Playwright browser MCP (browser=$UT_BROWSER)…" >&2
    npx playwright install "$UT_BROWSER" 1>&2 || true
    "$claude_bin" mcp add playwright -s user -- npx -y @playwright/mcp@latest --headless --isolated --browser "$UT_BROWSER" 1>&2 || true
    return 0
  fi
  echo "fwf user-testing: the Playwright browser MCP ('${UT_BROWSER_MCP_NAME:-playwright}') is not registered in ${CLAUDE_CONFIG:-$HOME/.claude.json} — personas would have no hands." >&2
  echo "fwf user-testing: set it up once (browser defaults to '$UT_BROWSER'; override with UT_BROWSER), then re-run:" >&2
  fwf_ut_browser_setup_cmds >&2
  echo "fwf user-testing: or re-run provision with FWF_UT_SETUP_BROWSER=1 to install it automatically. See docs/user-testing.md." >&2
  return 0
}

# Cross-machine version-skew warning (issue #79/#94): fwf_version_skew_warn +
# its helpers live in lib/version_check.sh (deliberately profile-independent —
# `fwf doctor` needs them without a profile resolved). Sourced here so
# fwf-up.sh's call site keeps working unchanged.
# shellcheck source=lib/version_check.sh
source "$FWF_LIB_DIR/lib/version_check.sh"

# PR body context-fold + built-with credit (issue #106): fwf_context_block,
# fwf_credit_block, fwf_sanitize_pr_text, fwf_pr_body_guard.
# shellcheck source=lib/pr_context.sh
source "$FWF_LIB_DIR/lib/pr_context.sh"

# Prod-target refusal for the user-testing factory (issue #42): a trial must run
# only against an isolated scratch/UAT instance, never production. Fail-closed
# ALLOW-LIST — anything that is not obviously a throwaway target is refused, so a
# misconfigured profile can't point whacky personas at a live system. A human
# can override one launch with FWF_UT_ALLOW_TARGET=1. No-op for other templates.
# Returns 0 if the target is acceptable, 1 (with guidance on stderr) if refused.
# Check ONE url against the scratch/UAT allow-list. rc 0 = acceptable, rc 1 =
# refused (with guidance on stderr). Fail-CLOSED: anything not obviously a
# throwaway target is refused, so a misconfigured profile can't point whacky
# personas at a live system.
_fwf_ut_guard_one() { # $1=url
  local url="$1" host
  host="${url#*://}"; host="${host%%/*}"; host="${host##*@}"   # strip scheme, path, userinfo
  case "$host" in "["*) host="${host%%]*}"; host="${host#[}";; *) host="${host%%:*}";; esac  # IPv6 [..]:port vs host:port
  case "$host" in
    localhost|127.*|0.0.0.0|::1|*.local|*.localhost|*.test) return 0;;
    *uat*|*staging*|*scratch*|*sandbox*|*test*|*dev*)        return 0;;
    *)
      echo "fwf user-testing: REFUSING target '$url' (host '$host') — it does not look like a scratch/UAT instance." >&2
      echo "fwf user-testing: trials run ONLY against an isolated UAT/scratch app — loopback, *.local/*.test, or a host containing uat/staging/test/scratch/sandbox/dev." >&2
      echo "fwf user-testing: if this really IS a throwaway target, re-run with FWF_UT_ALLOW_TARGET=1." >&2
      return 1;;
  esac
}
# Guard the shared UT_APP_URL AND every per-persona UT_APP_URL_<id> override
# (issue #42). A human can override ONE launch with FWF_UT_ALLOW_TARGET=1.
# No-op for every other template.
fwf_ut_guard_target() {
  [ "$FWF_TEMPLATE" = "user-testing" ] || return 0
  if [ "${FWF_UT_ALLOW_TARGET:-0}" = "1" ]; then
    echo "fwf user-testing: TARGET GUARD OVERRIDDEN (FWF_UT_ALLOW_TARGET=1) — you asserted the target(s) are scratch/UAT." >&2
    return 0
  fi
  if [ -z "${UT_APP_URL:-}" ]; then
    echo "fwf user-testing: UT_APP_URL is not set — personas have no app to drive." >&2
    echo "fwf user-testing: set UT_APP_URL in your profile to a running UAT/scratch app (e.g. http://localhost:3939). Trials NEVER target prod." >&2
    return 1
  fi
  local id u rc=0
  _fwf_ut_guard_one "$UT_APP_URL" || rc=1
  for id in "${PAIRS[@]}"; do      # per-persona overrides, if any are set
    eval "u=\"\${UT_APP_URL_$id:-}\""
    [ -n "$u" ] && { _fwf_ut_guard_one "$u" || rc=1; }
  done
  return "$rc"
}

# The canonical set of looped roles, one per line, in launch/arm order. Single
# source of truth — fwf-up delivers prompts to these and fwf-resume re-arms them.
fwf_all_roles() {
  local id r
  for id in "${PAIRS[@]}"; do fwf_role_suppressed "impl$id" || echo "impl$id"; done
  for id in "${PAIRS[@]}"; do fwf_role_suppressed "qa$id"   || echo "qa$id";   done
  for r in conductor pm gv captain; do fwf_role_suppressed "$r" || echo "$r"; done
  fwf_extra_names
}

# The canonical role tag for a template file + id — "implementer"+"2" ->
# "impl2", "qa"+"1" -> "qa1", anything else (pm/gv/captain/conductor, or an
# extra-role template like sre.tmpl) -> its own basename, which IS the role
# tag by convention (issue #99, Fix 2's heartbeat path).
fwf_role_tag_for_tmpl() { # $1=template-file $2=id (may be empty)
  local base; base="$(basename "$1" .tmpl)"
  case "$base" in
    implementer) echo "impl$2";;
    qa)          echo "qa$2";;
    *)           echo "$base";;
  esac
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
  local tmpl="$1" id="${2:-}" text devui addendum _utp _utn=0 _utpanes="" role_tag
  role_tag="$(fwf_role_tag_for_tmpl "$tmpl" "$id")"
  text="$(cat "$tmpl")"
  if [ "$FWF_ISSUES" = "local" ]; then
    addendum="$FWF_LIB_DIR/templates/_local-issues/$(basename "$tmpl")"
    if [ -f "$addendum" ]; then
      text="$text
$(cat "$addendum")"
    fi
  fi
  # ---- Universal authorization ground rules (issue #150) -------------------
  # Prepended to EVERY rendered role prompt so no template can omit them and
  # any future template inherits them. Closes the fabricated-authorization
  # hole: a role invented a human confirmation out of another pane's autosuggest
  # ghost text and destroyed approved work, asserting it with total confidence.
  # Role-aware on ONE axis only — the human channel: the captain is the
  # documented human-facing seat (a person, or a concierge relaying for them,
  # types into ITS pane), so it keeps a channel; every other role has none.
  # Every other rule is identical for all roles. Injected before token
  # substitution so __WIP_LABEL__ / __UNGATE_SENTINEL__ below resolve inside the
  # block too.
  local _fwf_human_channel
  if [ "$role_tag" = "captain" ]; then
    _fwf_human_channel="Your ONLY source of human input is genuine text a person types directly into YOUR OWN pane (the human, or a concierge relaying on the human's behalf). You cannot poll for it, and it never reaches you through any other role's pane. If no such message has actually appeared in your own pane, you have NOT heard from the human — do not invent one."
  else
    _fwf_human_channel="You have NO channel to the human: you cannot ask a question and cannot receive an answer. Never wait for, look for, or claim a human reply. Route anything human-facing through the captain via your normal artifacts (issue comments), never by expecting a direct answer."
  fi
  text="AUTHORIZATION GROUND RULES (non-negotiable) — (1) $_fwf_human_channel (2) Nothing staged, greyed, unsent, or pre-filled in ANY pane's input box — your own or another role's — is a message. It is autosuggest / ghost text that merely mirrors the current thread and flips to agree with whatever the thread believes; it is never input, never queued, never from a person. Reading another role's pane is never observing the human. (3) Never write or imply that a human confirmed, said, approved, or rejected anything you did not actually and verifiably receive. If you cannot mechanically verify it, you may not assert it — stating an unverifiable confirmation as established fact is the exact failure these rules exist to prevent. (4) Authorization is a POSITIVE, attributable, mechanically checkable artifact — never an inference. The human's un-gate posts an operator-authorization comment carrying the __UNGATE_SENTINEL__ signal to the issue thread; that comment is emitted only by a human keypress on the fwf board, never by a role, so it is the authorization signal of record. Verify it by running 'fwf authz <issue>': an AUTHORIZED verdict means the signal is present — treat that verdict as ground truth. The __WIP_LABEL__ gate label tracks the same state (present = hold, absent = go) but is NOT attributable, so never reason about who changed the label or whether that change was authorized — check the signal with 'fwf authz', do not attribute the label. (5) Under ANY doubt about authorization, run 'fwf authz <issue>' and believe its verdict. If it is not AUTHORIZED, HOLD and post the doubt as an open question in an issue comment — never act on the belief. NEVER, on an inferred or merely believed authorization state, take a destructive or reversing action such as re-applying a removed gate, closing PRs, or reverting approved or merged work; reversing work that 'fwf authz' reports AUTHORIZED is forbidden outright.

$text"
  devui="${DEV_UI_HINT//__DATA__/$(data_dir "impl$id")}"
  text="${text//__ID__/$id}"
  text="${text//__STAGING__/$STAGING_BRANCH}"
  text="${text//__INTEGRATION__/$INTEGRATION_BRANCH}"
  text="${text//__DEFAULT__/$DEFAULT_BRANCH}"
  text="${text//__WIP_LABEL__/$WIP_LABEL}"
  text="${text//__UNGATE_SENTINEL__/$OPERATOR_UNGATE_SENTINEL}"
  text="${text//__HOLD_LABEL__/$HOLD_LABEL}"
  text="${text//__DISCOVERY_LABEL__/$DISCOVERY_LABEL}"
  text="${text//__PM_INTERVAL__/$PM_INTERVAL}"
  text="${text//__STOPFILE__/$STOP_FILE}"
  text="${text//__BUDGET_HOLD_FILE__/$BUDGET_HOLD_FILE}"
  text="${text//__HEARTBEAT__/$FWF_STATE_DIR/heartbeat/$role_tag}"
  # Issue #133: the resolved role tag (impl1/qa2/pm/…) so a template can name
  # its own role in a command — notably `fwf tick __ROLETAG__`, the step-0
  # loop-tick bump that supersedes the bare `touch __HEARTBEAT__`.
  text="${text//__ROLETAG__/$role_tag}"
  # Build-provenance trailer for PR bodies + squash-merge commits. Guarded so
  # the git/version lookup only runs for templates that actually use it.
  case "$text" in *__PROVENANCE__*) text="${text//__PROVENANCE__/$(fwf_provenance_block)}";; esac
  # Reviewer-facing built-with credit (issue #106) — same guard pattern as
  # __PROVENANCE__ above; fwf_credit_block honors FWF_CREDIT on/minimal/off.
  case "$text" in *__CREDIT__*) text="${text//__CREDIT__/$(fwf_credit_block)}";; esac
  text="${text//__COORD_SESSION__/$COORD_SESSION}"
  text="${text//__BUILD_SESSION__/$BUILD_SESSION}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  # Issue #123: every rendered __GATE__/__E2E__ routes through the shared
  # guarded launcher (fwf-gate.sh) instead of the raw command string, so the
  # per-role single-flight lock applies uniformly with no per-template copy.
  # __GATE__ (the fast per-commit gate) does NOT take the floor-wide e2e
  # lock — it isn't meant to share ports with anything, so serializing it
  # floor-wide would only add a throughput bottleneck with no hermeticity
  # benefit. __E2E__ does, via --e2e, preserving the existing issue #65
  # cross-role serialization for a harness whose ports are fixed.
  text="${text//__GATE__/fwf gate $role_tag -- bash -c $(printf '%q' "$GATE_CMD")}"
  text="${text//__E2E__/fwf gate $role_tag --e2e -- bash -c $(printf '%q' "$E2E_CMD")}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__DEVUI__/$devui}"
  text="${text//__UT_APP_URL__/$(fwf_ut_app_url "$id")}"   # user-testing: this persona's UAT/scratch app (per-persona override aware)
  text="${text//__UT_ROOT__/$(fwf_ut_root)}"          # user-testing: shared evidence + findings-report root
  # user-testing: count + tags of the live persona panes, so the captain/researcher
  # prompts read correctly whether a quick gate (3) or a deep sweep (e.g. 8) is running.
  for _utp in "${PAIRS[@]}"; do
    fwf_role_suppressed "impl$_utp" && continue
    _utn=$((_utn+1)); _utpanes="${_utpanes:+$_utpanes, }impl$_utp"
  done
  text="${text//__UT_PERSONA_COUNT__/$_utn}"
  text="${text//__UT_PERSONA_PANES__/$_utpanes}"
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
      [ -n "$anchor" ] && pane=$(tmux split-window -v -P -F '#{pane_id}' -t "$anchor" -c "$(fwf_role_cwd "$role")");;
  esac
  if [ -z "$pane" ]; then
    anchor="$(tmux list-panes -t "$sess" -F '#{pane_id}' | tail -1)"
    pane=$(tmux split-window -h -P -F '#{pane_id}' -t "$anchor" -c "$(fwf_role_cwd "$role")")
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

# --- launch-socket persistence (issue #62, supersedes #57) ------------------
# The factory's tmux sessions land on whatever socket $TMUX pointed to when
# `fwf up`/`fwf respawn` launched them — a bare `tmux new-session`/`split-window`
# inherits the caller's socket, so a factory started inside `tmux -L mysock` (or
# `-S <path>`) never ends up on the default socket. A read-only tool (the dash)
# can't assume default; it must LEARN the launch socket. fwf up/respawn are the
# single source of truth: they persist it here, and fwf-dash-data.sh reads it
# back instead of guessing (see docs/dash.md).
#
# $TMUX is "socket_path,pid,session_id" — only the socket-path field (before
# the first comma) is ever persisted or queried; pid/session_id are noise.
# $TMUX unset (factory launched outside any tmux) persists the literal marker
# "default" — never an empty string, which could later resolve to a garbage
# `tmux -S ''`.
FWF_STATE_DIR="$FWF_RUN/state/$PROFILE"
FWF_TMUX_SOCKET_FILE="$FWF_STATE_DIR/tmux_socket"
# PID file for the token-budget WRITER's detached loop (issue #96) — a plain
# bash background loop, not a Claude Code role (there's no /loop skill for a
# host-side process). Per-profile since two factories on one machine must not
# share a writer. Armed at `fwf up` only when a budget is configured; killed
# at `fwf down`.
FWF_BUDGET_WRITER_PID_FILE="$FWF_STATE_DIR/budget-writer.pid"
# Run-start usage snapshot (issue #108) — written once by a genuinely fresh
# arm (see fwf_budget_baseline_ensure) so enforcement is against spend SINCE
# this run, not the lifetime total sitting in reused worktree transcripts.
# Survives floor bounces and fwf-respawn.sh (neither re-arms); cleared only by
# a full teardown (fwf-down.sh's non-floor-only path, via
# fwf_budget_baseline_clear) so the next full `fwf up` gets a fresh baseline.
BUDGET_BASELINE_FILE="$FWF_STATE_DIR/budget-baseline.json"
fwf_tmux_socket_value() {   # echoes what should be persisted, from the CURRENT $TMUX
  if [ -n "${TMUX:-}" ]; then printf '%s\n' "${TMUX%%,*}"; else printf '%s\n' default; fi
}
fwf_persist_tmux_socket() {   # $1 = value to persist (a socket path, or "default")
  mkdir -p "$FWF_STATE_DIR"
  printf '%s\n' "$1" > "$FWF_TMUX_SOCKET_FILE"
}

# --- floor-lifecycle event log (issue #85; generalized per-UNIT by #105) -----
# Single source of truth for BOTH the dash's live floor state and the
# after-the-fact audit trail — no second file that can disagree with this one.
# A crash never appends to this log, so "the last event is floor-down" cleanly
# means "deliberately idled by fwf-down.sh", not "gone".
# Append-only TSV, capped at the last N lines so it cannot grow unbounded.
# issue #105: a 6th column, "plane" (build|pm), lets this ONE log carry both
# units' lifecycles instead of fragmenting into per-unit files. A legacy
# 5-column row (written before #105, when the whole floor was one unit) has
# no plane field and reads as "build".
FWF_FLOOR_LOG="$FWF_STATE_DIR/floor-events.log"
FWF_FLOOR_LOG_CAP=200

# $1=event ("floor-down"|"floor-up")  $2=actor  $3=reason (may be empty)
# $4=plane ("build"|"pm", default "build")
fwf_floor_event() {
  local event="$1" actor="$2" reason="${3:-}" plane="${4:-build}" ts epoch tmp
  mkdir -p "$FWF_STATE_DIR"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$epoch" "$event" "$actor" "$reason" "$plane" >> "$FWF_FLOOR_LOG"
  if [ "$(wc -l < "$FWF_FLOOR_LOG")" -gt "$FWF_FLOOR_LOG_CAP" ]; then
    tmp="$(mktemp "${FWF_FLOOR_LOG}.XXXXXX")"
    tail -n "$FWF_FLOOR_LOG_CAP" "$FWF_FLOOR_LOG" > "$tmp" && mv "$tmp" "$FWF_FLOOR_LOG"
  fi
}

# $1=plane ("build"|"pm"). Echoes "active\tsince\treason\tactor" (TSV, one
# line) for THAT plane. active is "true" only when the LAST logged event FOR
# THIS PLANE is floor-down with no later floor-up on the same plane — a
# missing log, or a log whose last matching event is floor-up, both read as
# not-idle. A legacy (pre-#105) row with no 6th column counts as plane
# "build". Read-only; the dash's live-pane precedence (a role with a live
# pane is never shown idle) lives in the caller, not here.
fwf_plane_idle_state() {
  local plane="$1"
  if [ ! -f "$FWF_FLOOR_LOG" ]; then printf 'false\t\t\t\n'; return 0; fi
  awk -F'\t' -v want="$plane" '
    { pl = ($6 == "" ? "build" : $6); if (pl == want) { ts=$1; ev=$3; actor=$4; reason=$5 } }
    END {
      if (ev == "floor-down") printf "true\t%s\t%s\t%s\n", ts, reason, actor
      else printf "false\t\t\t\n"
    }
  ' "$FWF_FLOOR_LOG"
}

# --- floor-down cooldown guard (issue #88; generalized per-UNIT by #105) -----
# The DETERMINISTIC anti-thrash bound: once a unit comes up, fwf-down.sh
# refuses to take THAT unit down again for its own cooldown window —
# script-enforced, not defeatable without --force. This is what actually
# breaks the down->up->down thrash cycle; captain.tmpl's dwell guidance is
# soft and only reduces how often a single premature down fires.
# FWF_BUILD_COOLDOWN aliases the pre-#105 FWF_FLOOR_COOLDOWN by default (the
# build floor is the unit that existed, alone, before this split) — set
# FWF_BUILD_COOLDOWN explicitly to diverge the two.
FWF_FLOOR_COOLDOWN="${FWF_FLOOR_COOLDOWN:-300}"
case "$FWF_FLOOR_COOLDOWN" in
  ''|*[!0-9]*) echo "fwf: FWF_FLOOR_COOLDOWN must be a non-negative integer of seconds (got '$FWF_FLOOR_COOLDOWN')" >&2; exit 1;;
esac
FWF_BUILD_COOLDOWN="${FWF_BUILD_COOLDOWN:-$FWF_FLOOR_COOLDOWN}"
case "$FWF_BUILD_COOLDOWN" in
  ''|*[!0-9]*) echo "fwf: FWF_BUILD_COOLDOWN must be a non-negative integer of seconds (got '$FWF_BUILD_COOLDOWN')" >&2; exit 1;;
esac
FWF_PM_COOLDOWN="${FWF_PM_COOLDOWN:-300}"
case "$FWF_PM_COOLDOWN" in
  ''|*[!0-9]*) echo "fwf: FWF_PM_COOLDOWN must be a non-negative integer of seconds (got '$FWF_PM_COOLDOWN')" >&2; exit 1;;
esac

# $1=plane. Echoes the epoch of the last logged floor-up event FOR THAT
# PLANE, or "" if none on record (a fresh log, or one that has never seen an
# up for this plane — the first-ever down for a plane is intentionally
# unguarded; see #88's edge cases).
fwf_plane_last_up_epoch() {
  local plane="$1"
  [ -f "$FWF_FLOOR_LOG" ] || { printf ''; return 0; }
  awk -F'\t' -v want="$plane" '
    { pl = ($6 == "" ? "build" : $6); if ($3 == "floor-up" && pl == want) e=$2 }
    END { if (e != "") print e }
  ' "$FWF_FLOOR_LOG"
}

# $1=plane ("build"|"pm"). Echoes that plane's remaining cooldown in seconds
# (0 if elapsed, or no prior floor-up on record for it).
fwf_plane_cooldown_remaining() {
  local plane="$1" cooldown last_up now remaining
  case "$plane" in
    build) cooldown="$FWF_BUILD_COOLDOWN";;
    pm)    cooldown="$FWF_PM_COOLDOWN";;
    *) echo "fwf_plane_cooldown_remaining: unknown plane '$plane'" >&2; return 1;;
  esac
  last_up="$(fwf_plane_last_up_epoch "$plane")"
  [ -n "$last_up" ] || { printf '0'; return 0; }
  now="$(date +%s)"
  remaining=$(( cooldown - (now - last_up) ))
  [ "$remaining" -gt 0 ] || remaining=0
  printf '%s' "$remaining"
}

# --- per-plane deadlock guards (issue #105, acceptance criterion 1) ----------
# A plane's down-command must REFUSE, not idle, whenever stranding is
# possible. Both guards fail SAFE: any query error/ambiguity is treated as
# "blocked" (stay up) — the safe direction on any ambiguity, per the ticket.
# Neither is overridable by --force (--force only overrides the COOLDOWN
# timer above, which is an anti-thrash pace-limiter, not a correctness guard).

# Echoes a one-line reason if idling the BUILD floor could strand work, or ""
# if safe. Blocked when: any open PR exists (a claim/draft/ready PR still
# needs a role to act on it), OR staging is ahead of integration
# (mid-promotion — the same check the conductor's own gate uses).
# owner/name slug for `gh -R` — from the ghcache env, else parsed from the
# repo's origin remote (no API call). Mirrors fwf-ghcache.sh's repo_slug so a
# gh query resolves the FACTORY repo regardless of CWD: an operator running
# `fwf down` from $HOME (real gh, no cache shim on PATH) must not silently
# query whatever repo happens to sit under the current directory (#145).
fwf_repo_slug() {
  if [ -n "${FWF_GHCACHE_REPO:-}" ]; then printf '%s' "$FWF_GHCACHE_REPO"; return; fi
  local url
  url="$(git -C "${FWF_REPO:-.}" config --get remote.origin.url 2>/dev/null)"
  url="${url%.git}"; url="${url#git@github.com:}"; url="${url#https://github.com/}"; url="${url#ssh://git@github.com/}"
  printf '%s' "$url"
}

fwf_build_plane_blocked() {
  local pr_count staging_ahead
  pr_count="$(gh pr list -R "$(fwf_repo_slug)" --state open --json number --jq 'length' 2>/dev/null)" \
    || { printf 'could not query open PRs (gh failed) — assuming blocked'; return 0; }
  case "$pr_count" in ''|*[!0-9]*) printf 'could not query open PRs (bad gh output) — assuming blocked'; return 0;; esac
  if [ "$pr_count" -gt 0 ]; then
    printf '%s open PR(s) still in flight' "$pr_count"; return 0
  fi
  git -C "$FWF_REPO" fetch origin "$STAGING_BRANCH" "$INTEGRATION_BRANCH" >/dev/null 2>&1 \
    || { printf 'could not fetch %s/%s — assuming blocked' "$STAGING_BRANCH" "$INTEGRATION_BRANCH"; return 0; }
  staging_ahead="$(git -C "$FWF_REPO" rev-list --count "origin/$INTEGRATION_BRANCH..origin/$STAGING_BRANCH" 2>/dev/null)" \
    || { printf 'could not compare %s/%s — assuming blocked' "$STAGING_BRANCH" "$INTEGRATION_BRANCH"; return 0; }
  case "$staging_ahead" in ''|*[!0-9]*) printf 'could not compare %s/%s (bad output) — assuming blocked' "$STAGING_BRANCH" "$INTEGRATION_BRANCH"; return 0;; esac
  if [ "$staging_ahead" -gt 0 ]; then
    printf 'mid-promotion: %s is %s commit(s) ahead of %s' "$STAGING_BRANCH" "$staging_ahead" "$INTEGRATION_BRANCH"; return 0
  fi
  printf ''
}

# Echoes a one-line reason if idling the PM could strand grooming, or "" if
# safe. Blocked when any open "$WIP_LABEL"-labeled issue exists at all. This
# is deliberately COARSER than the design's ideal ("only if it NEEDS action")
# because every role authenticates as the same shared GitHub account (issue
# #82's constraint): comment AUTHORSHIP can't mechanically distinguish "the
# PM already responded" from "still awaiting the PM", so there is no reliable
# signal here for "unaddressed feedback" the way #82 solved it with an
# explicit sentinel-prefix convention. Treating ANY open draft as potential
# pending work is the safe superset — it never wrongly allows an idle while
# real work is pending. The captain's own per-tick judgment (it can actually
# read the issue content) is the finer-grained layer on top of this
# deterministic backstop, exactly like the dwell (soft) sits on the cooldown
# (hard) above.
fwf_pm_plane_blocked() {
  local n
  if [ "$FWF_ISSUES" = "local" ]; then
    n="$("$FWF_LIB_DIR/fwf-issues.sh" list --state open --label "$WIP_LABEL" --json number --jq 'length' 2>/dev/null)" \
      || { printf 'could not query %s drafts (local issues store) — assuming blocked' "$WIP_LABEL"; return 0; }
  else
    n="$(gh issue list --state open --label "$WIP_LABEL" --json number --jq 'length' 2>/dev/null)" \
      || { printf 'could not query %s drafts (gh failed) — assuming blocked' "$WIP_LABEL"; return 0; }
  fi
  case "$n" in ''|*[!0-9]*) printf 'could not query %s drafts (bad output) — assuming blocked' "$WIP_LABEL"; return 0;; esac
  if [ "$n" -gt 0 ]; then
    printf '%s open %s draft(s) still need grooming' "$n" "$WIP_LABEL"; return 0
  fi
  printf ''
}

# --- e2e lock (issue #65) ----------------------------------------------------
# Serializes EVERY e2e-equivalent run across the whole floor — not just
# conductor-vs-conductor, but implementer self-verification too — since most
# e2e harnesses bind fixed, single ports and fwf runs N parallel worktrees on
# one box. The lock dir carries a holder-identity stamp (role, pid, host,
# worktree, acquire time) so a role that dies mid-hold is recovered instead of
# wedging every future e2e run on the floor.
#
# Liveness is authoritative and beats age: a live same-host holder is NEVER
# reclaimed no matter how long it has held the lock (parallel-worktree
# contention makes full suites routinely exceed 15 minutes) — only a
# same-host holder with a confirmed-dead PID is broken immediately. A holder
# stamped from a different host, or with an unparseable stamp, is
# "indeterminate" — liveness can't be checked, so it falls back to the age
# backstop (FWF_E2E_LOCK_STALE_SECS) so the floor can't wedge forever.
FWF_E2E_LOCK_TIMEOUT="${FWF_E2E_LOCK_TIMEOUT:-900}"        # bounded wait for a live/indeterminate-but-fresh holder
FWF_E2E_LOCK_POLL="${FWF_E2E_LOCK_POLL:-5}"                # seconds between "waiting on" polls
FWF_E2E_LOCK_STALE_SECS="${FWF_E2E_LOCK_STALE_SECS:-1800}" # ~30m backstop, ONLY for indeterminate liveness

_fwf_e2e_owner_field() { # $1=field  $2=owner-file → value, or empty (never errors)
  [ -f "$2" ] || return 0
  awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$2" 2>/dev/null
}

# rc 0 = alive (same host, pid alive) — NEVER reclaim
# rc 1 = dead (same host, pid confirmed dead) — reclaim immediately
# rc 2 = indeterminate (different host, or stamp missing/unparseable) — age backstop applies
_fwf_e2e_owner_liveness() { # $1=owner-file
  local f="$1" host pid
  [ -f "$f" ] || return 2
  host="$(_fwf_e2e_owner_field host "$f")"
  pid="$(_fwf_e2e_owner_field pid "$f")"
  [ -n "$host" ] && [ -n "$pid" ] || return 2
  [ "$host" = "$(hostname)" ] || return 2
  kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

# $1 = holder label (e.g. "conductor", "impl2") → rc 0 acquired, 1 timed out.
# ALWAYS pair with a trap to fwf_e2e_lock_release so a killed/failed holder
# never leaves the lock behind: trap 'fwf_e2e_lock_release' EXIT
fwf_e2e_lock_acquire() {
  local label="${1:?fwf_e2e_lock_acquire needs a holder label}" owner="$E2E_LOCK/owner" waited=0 rc ts now holder
  mkdir -p "$(dirname "$E2E_LOCK")" 2>/dev/null   # so a missing $FWF_RUN can't masquerade as "lock held"
  while true; do
    if mkdir "$E2E_LOCK" 2>/dev/null; then
      printf 'role=%s\npid=%s\nhost=%s\nworktree=%s\nacquired=%s\n' \
        "$label" "$$" "$(hostname)" "$PWD" "$(date +%s)" > "$owner"
      return 0
    fi
    _fwf_e2e_owner_liveness "$owner"; rc=$?
    holder="$(_fwf_e2e_owner_field role "$owner")"
    if [ "$rc" = 1 ]; then
      echo "fwf: e2e lock held by dead PID $(_fwf_e2e_owner_field pid "$owner") (${holder:-unknown}) — breaking it" >&2
      rm -rf "$E2E_LOCK"; continue
    elif [ "$rc" = 2 ]; then
      ts="$(_fwf_e2e_owner_field acquired "$owner")"; now="$(date +%s)"
      if [ -n "$ts" ] && [ $(( now - ts )) -ge "$FWF_E2E_LOCK_STALE_SECS" ]; then
        echo "fwf: e2e lock indeterminate-liveness and past the ${FWF_E2E_LOCK_STALE_SECS}s backstop — breaking it" >&2
        rm -rf "$E2E_LOCK"; continue
      fi
    fi
    if [ "$waited" -ge "$FWF_E2E_LOCK_TIMEOUT" ]; then
      echo "fwf: $label timed out after ${FWF_E2E_LOCK_TIMEOUT}s waiting on the e2e lock (held by ${holder:-unknown})" >&2
      return 1
    fi
    echo "fwf: $label waiting on the e2e lock (held by ${holder:-unknown})…" >&2
    sleep "$FWF_E2E_LOCK_POLL"
    waited=$(( waited + FWF_E2E_LOCK_POLL ))
  done
}

fwf_e2e_lock_release() {
  rm -rf "$E2E_LOCK"
}

# --- per-role gate single-flight lock (issue #123) ---------------------------
# Root cause 1 of the gate pileup: an agent relaunches the FULL gate
# (test/run.sh / dash cargo test, or the conductor's promotion e2e) every tick
# without checking whether ITS OWN prior gate is still running — 8 concurrent
# test/run.sh processes were observed stacked this way (7:04-7:18 PDT), none
# finishing. This is a PER-ROLE, NON-BLOCKING guard: unlike the e2e lock above
# (which several roles wait on and share), a role that finds its own gate
# still in flight does not queue — it skips this tick and reports so, per the
# spec's fail-closed contract ("indeterminate -> skip, never stack").
#
# Distinct from fwf_e2e_lock_*, which serializes ACROSS roles on a shared
# fixed-port harness (cause 2); this one bounds a SINGLE role's own relaunch
# rate. The two compose: fwf-gate.sh (the shared launcher, issue #123 AC6)
# always takes this lock, and additionally takes the e2e lock when wrapping an
# e2e-class command.
#
# Liveness mirrors the e2e lock's same-host/dead-PID reasoning, but adds a
# max-run ceiling even for a LIVE holder (FWF_GATE_LOCK_MAX_RUN_SECS) so a
# genuinely wedged-but-alive gate (the observed S-state, ~0% CPU processes)
# can't hold the role hostage forever the way a floor-wide wait could. Pick
# the ceiling comfortably above the slowest legitimate gate run, or a healthy
# slow run gets reaped mid-flight and a second one stacks on top of it —
# recreating the very pileup this guards against.
FWF_GATE_LOCK_MAX_RUN_SECS="${FWF_GATE_LOCK_MAX_RUN_SECS:-1800}" # ~30m ceiling, even for a live holder

fwf_gate_lock_dir() { echo "$FWF_STATE_DIR/gate-lock/$1"; }   # $1=role

_fwf_gate_owner_field() { # $1=field  $2=owner-file → value, or empty (never errors)
  [ -f "$2" ] || return 0
  awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$2" 2>/dev/null
}

# rc 0 = alive, same host, past neither ceiling (or ceiling not yet due) — NOT reclaimed
# rc 1 = dead (same host, PID confirmed dead) — reclaim immediately
# rc 2 = indeterminate (different host, or stamp missing/unparseable) — ceiling backstop applies
# rc 3 = alive but past FWF_GATE_LOCK_MAX_RUN_SECS — reclaim as a wedge (anomaly)
_fwf_gate_owner_liveness() { # $1=owner-file
  local f="$1" host pid ts now
  [ -f "$f" ] || return 2
  host="$(_fwf_gate_owner_field host "$f")"
  pid="$(_fwf_gate_owner_field pid "$f")"
  ts="$(_fwf_gate_owner_field acquired "$f")"
  now="$(date +%s)"
  [ -n "$host" ] && [ -n "$pid" ] || return 2
  [ "$host" = "$(hostname)" ] || return 2
  if kill -0 "$pid" 2>/dev/null; then
    if [ -n "$ts" ] && [ $(( now - ts )) -ge "$FWF_GATE_LOCK_MAX_RUN_SECS" ]; then
      return 3
    fi
    return 0
  fi
  return 1
}

# $1 = role label (e.g. "impl2", "qa2", "conductor"). rc 0 = acquired (proceed
# with the gate); rc 1 = SKIP this tick (a prior gate for this role is still
# in flight, or its state is indeterminate — fail closed). NEVER blocks/polls;
# a skip is a normal, expected outcome the caller reports, not an error.
fwf_gate_lock_acquire() {
  local role="${1:?fwf_gate_lock_acquire needs a role}" dir owner rc reason
  dir="$(fwf_gate_lock_dir "$role")"; owner="$dir/owner"
  mkdir -p "$(dirname "$dir")" 2>/dev/null
  if mkdir "$dir" 2>/dev/null; then
    printf 'role=%s\npid=%s\nhost=%s\nacquired=%s\n' "$role" "$$" "$(hostname)" "$(date +%s)" > "$owner"
    return 0
  fi
  _fwf_gate_owner_liveness "$owner"; rc=$?
  case "$rc" in
    0)
      echo "fwf: gate for '$role' already in flight (pid $(_fwf_gate_owner_field pid "$owner")) — skipping this tick, not stacking a second" >&2
      return 1
      ;;
    1) reason="held by dead pid $(_fwf_gate_owner_field pid "$owner")";;
    2)
      echo "fwf: gate lock for '$role' has indeterminate liveness — failing closed, skipping this tick rather than risking a stack" >&2
      return 1
      ;;
    3) reason="past the ${FWF_GATE_LOCK_MAX_RUN_SECS}s max-run ceiling (pid $(_fwf_gate_owner_field pid "$owner") still alive) — treating as wedged";;
  esac
  echo "fwf: ANOMALY — reaping gate lock for '$role' ($reason)" >&2
  rm -rf "$dir"
  if mkdir "$dir" 2>/dev/null; then
    printf 'role=%s\npid=%s\nhost=%s\nacquired=%s\n' "$role" "$$" "$(hostname)" "$(date +%s)" > "$owner"
    return 0
  fi
  echo "fwf: gate lock for '$role' contested during reap — skipping this tick" >&2
  return 1
}

fwf_gate_lock_release() {
  rm -rf "$(fwf_gate_lock_dir "${1:?fwf_gate_lock_release needs a role}")"
}

# --- token-budget WRITER lifecycle (issue #96) -------------------------------
# The WRITER (fwf-budget-check.sh --loop) is a plain detached bash background
# loop, not a Claude Code role — there is no `/loop` skill for a host-side
# process. Armed at `fwf up`/`fwf up --floor-only` ONLY when a budget is
# configured (zero cost otherwise, matching "default unlimited"); killed at
# `fwf down`. Tracked via a per-profile PID file so re-arming is idempotent
# (a stale/dead PID is silently replaced) and `fwf down` can find it.
#
# rc 0 whether or not a writer was actually started (armed = a budget ceiling
# set AND a loop is now running for this profile) — callers that need to know
# check fwf_budget_writer_running after calling this.
fwf_budget_writer_start() {
  { [ -n "${FWF_TOKEN_BUDGET:-}" ] || [ -n "${FWF_BUDGET_USD:-}" ]; } || return 0   # no budget configured: never arm
  fwf_budget_writer_running && return 0        # already running for this profile — same run, don't re-baseline
  fwf_budget_baseline_ensure                   # genuinely fresh arm: snapshot run-start usage (issue #108)
  mkdir -p "$FWF_STATE_DIR" 2>/dev/null || true
  nohup "$FWF_LIB_DIR/fwf-budget-check.sh" --loop >/dev/null 2>&1 &
  disown 2>/dev/null || true
  printf '%s\n' "$!" > "$FWF_BUDGET_WRITER_PID_FILE"
}

# rc 0 if a writer loop is currently alive for this profile.
fwf_budget_writer_running() {
  [ -f "$FWF_BUDGET_WRITER_PID_FILE" ] || return 1
  local pid; pid="$(cat "$FWF_BUDGET_WRITER_PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Idempotent: safe to call even if no writer is running (e.g. no budget was
# ever configured). Also clears any hold the writer left behind — a downed
# floor spends nothing, so there is nothing left to enforce against.
# Deliberately does NOT touch BUDGET_BASELINE_FILE — this is called from both
# a floor-only teardown and a full teardown, and only the latter should reset
# the baseline (issue #108, AC5); see fwf_budget_baseline_clear, wired into
# fwf-down.sh's full-teardown path only.
fwf_budget_writer_stop() {
  if [ -f "$FWF_BUDGET_WRITER_PID_FILE" ]; then
    local pid; pid="$(cat "$FWF_BUDGET_WRITER_PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$FWF_BUDGET_WRITER_PID_FILE"
  fi
  rm -f "$BUDGET_HOLD_FILE"
}

# Write $BUDGET_BASELINE_FILE (cumulative tokens_total + cost_usd at this
# instant) iff one doesn't already exist. Called only from
# fwf_budget_writer_start right after its "already armed" check, so it fires
# ONLY on a genuinely fresh arm: a full `fwf up` following a full `fwf down`
# (the only path that clears the file — see fwf_budget_baseline_clear). A
# floor-only bounce or fwf-respawn.sh never reaches an empty file since
# neither clears it, so the existing baseline is left alone (AC5/AC7) without
# fwf-up.sh needing to distinguish "full" from "floor-only" itself.
#
# Leaves the file ABSENT (never a zero/partial baseline) if the usage
# aggregator can't be read right now — fwf-budget-check.sh's missing-baseline
# path then fails closed to UNKNOWN (AC8), the same posture as an unreadable
# aggregator, rather than silently arming with a wrong baseline.
fwf_budget_baseline_ensure() {
  [ -f "$BUDGET_BASELINE_FILE" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local usage_json
  usage_json="$("$FWF_LIB_DIR/fwf-usage-data.sh" 2>/dev/null || echo '')"
  [ -n "$usage_json" ] && printf '%s' "$usage_json" | jq -e . >/dev/null 2>&1 || return 0
  mkdir -p "$FWF_STATE_DIR" 2>/dev/null || true
  printf '%s' "$usage_json" | jq -c \
    '{tokens_total: ([.total.tokens.input, .total.tokens.cache_creation, .total.tokens.cache_read, .total.tokens.output] | add),
      cost_usd: .total.cost_usd}' > "$BUDGET_BASELINE_FILE"
}

# Explicit reset — call ONLY from a full teardown (never floor-only, never
# fwf-respawn.sh) so the next full `fwf up` snapshots a fresh baseline instead
# of inheriting this run's spend as if it were prior history.
fwf_budget_baseline_clear() {
  rm -f "$BUDGET_BASELINE_FILE"
}

# Read the baseline for delta enforcement: emits "tokens_total\tcost_usd" and
# returns 0 on a valid snapshot. Returns 1 (no stdout) if the file is
# absent/unparseable/missing a numeric field — callers MUST treat that as
# fail-closed UNKNOWN (issue #108 AC8), never as baseline=0 (reintroduces the
# instant-HOLD bug this issue fixes) and never as baseline=current (silently
# disables the budget).
fwf_budget_baseline_read() {
  [ -f "$BUDGET_BASELINE_FILE" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -re 'if (.tokens_total|type)=="number" and (.cost_usd|type)=="number"
          then "\(.tokens_total)\t\(.cost_usd)" else empty end' \
    "$BUDGET_BASELINE_FILE" 2>/dev/null
}

# --- branch reconcile (issue #114) -------------------------------------------
# Stop the swarm building on a stale base. Two hook points share this ONE
# classifier + FF-or-halt helper: (a) the release/direct-to-main write path
# (RELEASING.md's runbook + .github/workflows/release.yml), and (b) the
# captain's per-tick stale-base guard (see fwf-reconcile.sh, dispatched as
# `fwf reconcile`). Backend-agnostic (pure git refs) so it behaves identically
# whether FWF_ISSUES is "gh" or "local".
#
# Every branch is classified AGAINST $DEFAULT_BRANCH by ANCESTRY, never by
# commit counts, into exactly one of five states:
#   BEHIND    branch is a strict ancestor of main   -> stale base, FF-reconcile
#   AHEAD     main is a strict ancestor of branch   -> normal in-flight
#             promotion (staging/integration legitimately lead main between
#             releases) -- NOT divergence, no halt, no mutation, ever
#   EQUAL     branch already == main                -> clean no-op
#   DIVERGED  each side has a commit the other lacks -> human-only halt, NEVER
#             auto merge/rebase/force
#   SUSPECT   fetch/rev-parse failed or a ref is missing/detached -> fail
#             CLOSED: treated the same as a blocker, never silently skipped
FWF_RECONCILE_LOCK_DIR="$FWF_STATE_DIR/reconcile-lock"
FWF_RECONCILE_HISTORY_DIR="$FWF_STATE_DIR/reconcile-history"
# How many consecutive RECONCILED outcomes for the same branch trip the flap
# anomaly (issue #114 AC9) -- something is re-staling the branch between
# ticks, which is never expected in steady state.
FWF_RECONCILE_FLAP_THRESHOLD="${FWF_RECONCILE_FLAP_THRESHOLD:-2}"

# $1=branch $2=mainbranch -> echoes "BEHIND <branch-sha> <main-sha>" /
# "AHEAD ..." / "EQUAL ..." / "DIVERGED ..." / "SUSPECT <reason>". Always rc 0
# (the STATE word, not the exit code, is the signal -- callers branch on the
# first word). Fetches both refs fresh from origin so a caller never
# classifies against a stale local view.
fwf_reconcile_classify() {
  local branch="$1" mainbranch="$2" b_sha m_sha
  git -C "$FWF_REPO" fetch origin "$branch" "$mainbranch" >/dev/null 2>&1 \
    || { printf 'SUSPECT could not fetch %s/%s from origin\n' "$branch" "$mainbranch"; return 0; }
  b_sha="$(git -C "$FWF_REPO" rev-parse "origin/$branch" 2>/dev/null)" \
    || { printf 'SUSPECT origin/%s does not resolve\n' "$branch"; return 0; }
  m_sha="$(git -C "$FWF_REPO" rev-parse "origin/$mainbranch" 2>/dev/null)" \
    || { printf 'SUSPECT origin/%s does not resolve\n' "$mainbranch"; return 0; }
  if [ "$b_sha" = "$m_sha" ]; then
    printf 'EQUAL %s %s\n' "$b_sha" "$m_sha"; return 0
  fi
  if git -C "$FWF_REPO" merge-base --is-ancestor "$b_sha" "$m_sha" 2>/dev/null; then
    printf 'BEHIND %s %s\n' "$b_sha" "$m_sha"; return 0
  fi
  if git -C "$FWF_REPO" merge-base --is-ancestor "$m_sha" "$b_sha" 2>/dev/null; then
    printf 'AHEAD %s %s\n' "$b_sha" "$m_sha"; return 0
  fi
  printf 'DIVERGED %s %s\n' "$b_sha" "$m_sha"
}

# Non-blocking single-flight lock so a release action and a captain tick can't
# both be mid-reconcile on the same branch -- an OPTIMIZATION, not the
# correctness guarantee (that's the CAS push below); a holder that isn't
# actually alive is broken immediately so a crashed reconcile never wedges the
# branch forever. $1=branch -> rc 0 acquired, rc 1 busy (skip this tick).
fwf_reconcile_lock_try() {
  local branch="$1"
  local dir="$FWF_RECONCILE_LOCK_DIR/$branch" owner pid host
  mkdir -p "$FWF_RECONCILE_LOCK_DIR" 2>/dev/null || true
  if mkdir "$dir" 2>/dev/null; then
    printf 'pid=%s\nhost=%s\n' "$$" "$(hostname)" > "$dir/owner"
    return 0
  fi
  owner="$dir/owner"
  pid="$(_fwf_e2e_owner_field pid "$owner")"
  host="$(_fwf_e2e_owner_field host "$owner")"
  if [ -n "$pid" ] && [ "$host" = "$(hostname)" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null && { printf 'pid=%s\nhost=%s\n' "$$" "$(hostname)" > "$dir/owner"; return 0; }
  fi
  return 1
}
fwf_reconcile_lock_release() { # $1=branch
  rm -rf "${FWF_RECONCILE_LOCK_DIR:?}/$1"
}

# Record this tick's outcome for $1=branch ($2=state word) and echo "ANOMALY
# ..." if this makes >= FWF_RECONCILE_FLAP_THRESHOLD consecutive RECONCILED
# outcomes for that branch (issue #114 AC9) -- a reconcile storm must surface
# AS a storm, never blend into steady-state noise. Any non-RECONCILED outcome
# resets the streak.
fwf_reconcile_record_history() {
  local branch="$1" state="$2"
  local f="$FWF_RECONCILE_HISTORY_DIR/$branch" streak=0
  mkdir -p "$FWF_RECONCILE_HISTORY_DIR" 2>/dev/null || true
  [ -f "$f" ] && streak="$(cat "$f" 2>/dev/null || echo 0)"
  case "$streak" in ''|*[!0-9]*) streak=0;; esac
  if [ "$state" = RECONCILED ]; then
    streak=$((streak + 1))
    printf '%s\n' "$streak" > "$f"
    if [ "$streak" -ge "$FWF_RECONCILE_FLAP_THRESHOLD" ]; then
      printf 'ANOMALY: %s reconciled on %s consecutive ticks -- something is re-staling it between ticks\n' "$branch" "$streak"
    fi
  else
    printf '0\n' > "$f"
  fi
}

# The FF-or-halt helper: classify $1=branch against $2=mainbranch and, iff
# BEHIND, fast-forward it with a compare-and-swap push
# (--force-with-lease=<branch>:<observed-sha>) so a racing writer that already
# moved the ref aborts cleanly instead of double-moving or partially
# interleaving (issue #114 AC8) -- the CAS is the load-bearing correctness
# guarantee; the single-flight lock above is just an optimization that skips
# redundant concurrent work.
#
# Echoes exactly one line for the captain/release-action report to surface
# verbatim:
#   "reconciled <branch> <old-sha> -> <new-sha>"
#   "normal-ahead <branch> (leads main, no action)"
#   "clean no-op <branch> (already == main)"
#   "halted-diverged <branch> <branch-sha> <main-sha>"
#   "suspect <branch> <reason>"
#   "lock-busy <branch> (another reconcile in flight, skipping this tick)"
#   "cas-lost <branch> (ref moved under us, re-check next tick)"
# rc 0 = safe to proceed (reconciled / normal-ahead / clean no-op / lock-busy).
# rc 1 = DO NOT assign new work onto this base (halted-diverged / suspect /
# cas-lost -- cas-lost is transient-unsafe: re-classify next tick, don't
# assume-safe in the meantime).
fwf_reconcile_branch() {
  local branch="$1" mainbranch="$2" classification state b_sha m_sha
  if ! fwf_reconcile_lock_try "$branch"; then
    printf 'lock-busy %s (another reconcile in flight, skipping this tick)\n' "$branch"
    return 0
  fi
  classification="$(fwf_reconcile_classify "$branch" "$mainbranch")"
  state="${classification%% *}"
  case "$state" in
    EQUAL)
      fwf_reconcile_record_history "$branch" NOOP
      printf 'clean no-op %s (already == main)\n' "$branch"
      fwf_reconcile_lock_release "$branch"
      return 0
      ;;
    AHEAD)
      fwf_reconcile_record_history "$branch" NOOP
      printf 'normal-ahead %s (leads main, no action)\n' "$branch"
      fwf_reconcile_lock_release "$branch"
      return 0
      ;;
    DIVERGED)
      read -r _ b_sha m_sha <<<"$classification"
      fwf_reconcile_record_history "$branch" NOOP
      printf 'halted-diverged %s %s %s\n' "$branch" "$b_sha" "$m_sha"
      fwf_reconcile_lock_release "$branch"
      return 1
      ;;
    SUSPECT)
      fwf_reconcile_record_history "$branch" NOOP
      printf 'suspect %s %s\n' "$branch" "${classification#SUSPECT }"
      fwf_reconcile_lock_release "$branch"
      return 1
      ;;
    BEHIND)
      read -r _ b_sha m_sha <<<"$classification"
      if fwf_reconcile_cas_push "$branch" "$b_sha" "$m_sha"; then
        fwf_reconcile_record_history "$branch" RECONCILED
        printf 'reconciled %s %s -> %s\n' "$branch" "$b_sha" "$m_sha"
        fwf_reconcile_lock_release "$branch"
        return 0
      else
        fwf_reconcile_record_history "$branch" NOOP
        printf 'cas-lost %s (ref moved under us, re-check next tick)\n' "$branch"
        fwf_reconcile_lock_release "$branch"
        return 1
      fi
      ;;
  esac
}

# The CAS primitive itself, factored out so it's independently testable
# (issue #114 AC8): pushes $3=new-sha to $1=branch ONLY if the remote ref
# still matches $2=observed-old-sha. A racing writer that already moved the
# ref past $2 gets rejected here (git's --force-with-lease "stale info"),
# never a blind overwrite or an interleaved partial move. rc 0 = pushed, rc 1
# = lease rejected (or any other push failure) -- the caller treats both
# identically: re-classify, don't assume-safe.
fwf_reconcile_cas_push() { # $1=branch $2=observed-old-sha $3=new-sha
  local branch="$1" old_sha="$2" new_sha="$3"
  git -C "$FWF_REPO" push origin --force-with-lease="refs/heads/$branch:$old_sha" "$new_sha:refs/heads/$branch" >/dev/null 2>&1
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

# Convert a /loop-style interval ("3m", "2h", "45s", "1d", or a bare integer
# already in seconds) to whole seconds. Loop intervals (IMPL_INTERVAL etc.,
# issue #116) carry a unit suffix because they're handed straight to /loop's
# own parser — but any caller doing ARITHMETIC on one (e.g. fwf-respawn.sh's
# verify window) must normalize first, or the unit suffix makes bash treat the
# value as a base-N literal ("value too great for base"). Echoes the number of
# seconds and returns 0; on a malformed interval, prints nothing and returns 1
# rather than silently truncating with `${iv%[smhd]}` on garbage input.
fwf_interval_seconds() { # $1=interval
  local iv="$1" n unit
  case "$iv" in
    *[0-9]s) unit=1;;
    *[0-9]m) unit=60;;
    *[0-9]h) unit=3600;;
    *[0-9]d) unit=86400;;
    *[0-9]) unit=1;;
    *) echo "fwf: invalid interval '$iv' (expected N, Ns, Nm, Nh, or Nd)" >&2; return 1;;
  esac
  n="${iv%[smhd]}"
  case "$n" in
    ''|*[!0-9]*) echo "fwf: invalid interval '$iv' (expected N, Ns, Nm, Nh, or Nd)" >&2; return 1;;
  esac
  echo $((n * unit))
}

# Portable file mtime (epoch seconds); echoes nothing if the file is absent.
fwf_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }

# The heartbeat file a role's loop touches at its own step-0, before any work
# (issue #99, Fix 2) — a durable "this cycle started" signal, deliberately NOT
# the pane's animation glyph, which stays looking alive even when a role never
# actually advances a cycle.
fwf_heartbeat_path() { echo "$FWF_STATE_DIR/heartbeat/$1"; } # $1=role tag

# --- monotonic loop-tick counter (issue #133) -------------------------------
# The heartbeat's mtime answers "did a cycle START recently?" but NOT "is this
# role making progress or wedged?": a wedged agent, a healthy-but-mid-long-task
# agent, and an intentionally parked one all present an equally-stale mtime, and
# a single touch can't be told from real work. The tick counter fixes that: it
# STRICTLY INCREASES once per real loop iteration, so a reader comparing two
# samples over time reads working (advancing) vs parked/wedged (static) with no
# ambiguity — the one reliable per-role liveness signal the ticket asks for.
# It is bumped by the agent at cycle step-0 via `fwf tick <role>`, which both
# increments this counter AND refreshes the heartbeat, so every heartbeat-based
# check (boot gate, respawn verify) keeps working unchanged.
fwf_tick_path() { echo "$FWF_STATE_DIR/tick/$1"; } # $1=role tag

# Current tick count for role $1 (0 if it has never ticked / file absent or
# malformed — never errors, so callers can use it in arithmetic directly).
fwf_tick_read() { # $1=role
  local n; n="$(cat "$(fwf_tick_path "$1")" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) echo 0;; *) echo "$n";; esac
}

# Atomically bump role $1's tick counter and refresh its heartbeat — the single
# cycle-start action a looping role runs at step-0. Read-inc-write is safe
# because each role is the SOLE writer of its own counter (one pane, one serial
# loop); the write goes through a temp+mv so a reader never catches a half-
# written value. Echoes the new count.
fwf_tick_bump() { # $1=role
  local role="$1" tf hb cur next
  tf="$(fwf_tick_path "$role")"; hb="$(fwf_heartbeat_path "$role")"
  mkdir -p "$(dirname "$tf")" "$(dirname "$hb")" 2>/dev/null || true
  cur="$(fwf_tick_read "$role")"; next=$((cur + 1))
  printf '%s\n' "$next" > "$tf.tmp.$$" && mv -f "$tf.tmp.$$" "$tf"
  touch "$hb" 2>/dev/null || true
  echo "$next"
}

# Poll for role $1's heartbeat to reach or pass epoch $2 (typically "when we
# armed the pane"), for up to $3 seconds. This verifies the loop STARTED a
# cycle since arming — not that any cycle FINISHED — so a healthy first cycle
# whose work takes minutes still verifies (the heartbeat fires at step-0,
# before work). On success echoes the observed mtime and returns 0; on timeout
# echoes nothing and returns 1. Poll cadence is $FWF_HEARTBEAT_POLL_SECS
# (default 2s; tests override for speed) — kept as a separate, tmux-free
# function so it's unit-testable against a plain file, no pane required.
fwf_wait_heartbeat() { # $1=role $2=since_epoch $3=window_secs
  local role="$1" since="$2" window="$3" hb waited=0 poll="${FWF_HEARTBEAT_POLL_SECS:-2}" mt
  hb="$(fwf_heartbeat_path "$role")"
  while [ "$waited" -lt "$window" ]; do
    mt="$(fwf_file_mtime "$hb")"
    if [ -n "$mt" ] && [ "$mt" -ge "$since" ]; then echo "$mt"; return 0; fi
    sleep "$poll"; waited=$((waited + poll))
  done
  return 1
}

# Verify a respawned role's loop actually TICKS, with one bounded re-nudge —
# the full policy fwf-respawn.sh applies after arming (issue #99, Fix 2), kept
# here (not there) so it's unit-testable against a fake heartbeat + a fake
# renudge function, no real tmux pane required. $4 is a FUNCTION NAME (not a
# command string — avoids eval/quoting hazards) invoked with no args if the
# first wait times out; fwf-respawn.sh's real one re-sends the /loop tick
# line, a test's fake one can just touch the heartbeat file to simulate the
# nudge landing. Prints the standard "respawn verified" line on success,
# returns 0; on a double-timeout prints a clear failure to stderr and returns
# 1 — NEVER prints a success-shaped line without a real heartbeat advance.
fwf_verify_respawn_tick() { # $1=role $2=arm_epoch $3=window_secs $4=renudge_fn_name
  local role="$1" since="$2" window="$3" renudge_fn="$4" hb_ts
  if hb_ts="$(fwf_wait_heartbeat "$role" "$since" "$window")"; then
    echo "respawn verified: first tick observed (heartbeat @ $hb_ts)"; return 0
  fi
  echo "fwf-respawn: no tick observed within ${window}s of arming $role — re-nudging once" >&2
  "$renudge_fn"
  if hb_ts="$(fwf_wait_heartbeat "$role" "$since" "$window")"; then
    echo "respawn verified: first tick observed after one re-nudge (heartbeat @ $hb_ts)"; return 0
  fi
  echo "fwf-respawn: $role did NOT tick after arming + one re-nudge (no heartbeat within $((window * 2))s total) — respawn NOT verified; the pane may still be alive but wedged" >&2
  return 1
}

# Boot health-gate (issue #133). `fwf up` used to declare the floor "up" the
# instant claude launched in each pane — but PROCESS-ALIVE IS NOT LOOP-ALIVE:
# the /loop arm can silently fail to register (the nudge races pane readiness,
# or the agent is still churning its first cycle when the slash line lands) and
# the role then sits forever without ever claiming a ticket. This gate closes
# that hole: after arming, it confirms EACH role fired a real first tick (its
# heartbeat advanced past the pre-arm epoch), RE-ARMS any laggard once via the
# caller's renudge fn, and re-checks. Roles that STILL never ticked are named
# in the global FWF_BOOT_DEAD_ROLES array (for the caller to escalate, e.g. a
# hard respawn) and the function returns 1 — so a wedged floor is shouted about,
# never silently reported "up". Pure heartbeat + callback (no tmux), so it is
# unit-testable against fake heartbeat files and a fake renudge.
#   $1 = boot epoch (first tick must be at/after this; capture BEFORE arming)
#   $2 = renudge fn name, invoked as: <fn> <role>
#   $3.. = one "role:window_secs" spec per armed role
FWF_BOOT_DEAD_ROLES=()
fwf_verify_boot_ticks() {
  local boot_epoch="$1" renudge_fn="$2"; shift 2
  local spec role window ok_roles=""
  FWF_BOOT_DEAD_ROLES=()
  # Pass 1: verify each role; re-arm (once) any that hasn't ticked yet. A
  # healthy role usually returns immediately, so only genuine laggards wait out
  # a full window here.
  for spec in "$@"; do
    role="${spec%%:*}"; window="${spec##*:}"
    if fwf_wait_heartbeat "$role" "$boot_epoch" "$window" >/dev/null; then
      echo "boot: first tick verified — $role"
      ok_roles="$ok_roles $role"
    else
      echo "boot: $role did NOT tick within ${window}s of arming — re-arming once" >&2
      "$renudge_fn" "$role"
    fi
  done
  # Pass 2: re-check only the re-armed laggards, one more window each.
  for spec in "$@"; do
    role="${spec%%:*}"; window="${spec##*:}"
    case " $ok_roles " in *" $role "*) continue;; esac
    if fwf_wait_heartbeat "$role" "$boot_epoch" "$window" >/dev/null; then
      echo "boot: first tick verified after re-arm — $role"
    else
      echo "boot: $role STILL not ticking after one re-arm — needs recovery" >&2
      FWF_BOOT_DEAD_ROLES+=("$role")
    fi
  done
  if [ "${#FWF_BOOT_DEAD_ROLES[@]}" -gt 0 ]; then
    echo "boot health-gate: roles that never fired a first tick: ${FWF_BOOT_DEAD_ROLES[*]}" >&2
    return 1
  fi
  return 0
}

# Empty-stub-PR decision (issue #133). A dead boot loop once opened a claim-only
# draft PR (zero changed files — the claim commit IS the mutex) and then never
# advanced it, leaving an orphan stub a human had to close by hand. This is the
# pure predicate a sweeper uses: a draft PR with ZERO changed files that has sat
# untouched past the grace window is a stub to auto-close. Kept side-effect-free
# (no gh) so it is unit-testable; fwf_stub_sweep wires it to the live PR list.
# Returns 0 (close it) / 1 (leave it).
#   $1 = isDraft (true/false)  $2 = changed-file count  $3 = age secs  $4 = grace secs
fwf_pr_is_stale_stub() {
  local is_draft="$1" files="$2" age="$3" grace="$4"
  [ "$is_draft" = "true" ] || return 1          # only ever touch drafts
  [ "$files" = "0" ] || return 1                # a real diff exists → not a stub
  [ "$age" -ge "$grace" ] 2>/dev/null || return 1   # give a live loop time to push
  return 0
}

# Steady-state wedge classifier (issue #165). PURE: three scalar inputs -> one
# verdict word on stdout, no side effects, so it unit-tests exactly like
# fwf_pr_is_stale_stub above. It exists to tell a GENUINE wedge apart from a
# healthy-but-long productive cycle, using the two per-role liveness signals that
# already exist but nothing consumed in steady state: the monotonic loop tick
# (#133) and per-role token flow (#95). Given two samples over a window it emits:
#   HEALTHY  the tick advanced -> the loop iterated; unambiguously alive.
#   WORKING  tick static BUT tokens flowed -> a healthy long cycle mid-flight;
#            OR both static but not yet past the flat-for threshold (grace).
#            The "do NOT reap, keep watching" umbrella — nothing to act on.
#   WEDGED   tick static AND tokens flat, sustained past FWF_WEDGE_MIN_SECS of
#            elapsed -> the ONLY verdict a supervisor may reap on.
# The point of the ticket is the WORKING-not-WEDGED boundary: a role that hasn't
# ticked for a long time is NOT wedged as long as its tokens are still moving.
# The threshold is env-tunable (FWF_WEDGE_MIN_SECS, default 600s) rather than a
# 4th argument so the signature stays (delta_tick, delta_tokens, elapsed_secs).
# Non-numeric / negative inputs degrade to 0 (a bad sample never crashes the
# arithmetic nor fabricates a WEDGED verdict).
#   $1 = delta_tick  $2 = delta_tokens  $3 = elapsed secs since the prior sample
fwf_wedge_verdict() {
  local dtick="$1" dtok="$2" elapsed="$3" min="${FWF_WEDGE_MIN_SECS:-600}"
  case "$dtick"   in ''|*[!0-9]*) dtick=0;;   esac
  case "$dtok"    in ''|*[!0-9]*) dtok=0;;     esac
  case "$elapsed" in ''|*[!0-9]*) elapsed=0;;  esac
  if [ "$dtick" -gt 0 ]; then echo HEALTHY; return 0; fi   # loop advanced
  if [ "$dtok"  -gt 0 ]; then echo WORKING; return 0; fi   # long cycle, tokens flowing
  if [ "$elapsed" -ge "$min" ]; then echo WEDGED; return 0; fi
  echo WORKING                                             # both flat but still in grace
}

# Parse an ISO-8601 UTC timestamp (e.g. gh's 2026-08-11T14:03:22Z) to epoch
# seconds, portably across GNU and BSD date; echoes nothing on failure.
fwf_iso_to_epoch() { # $1=iso8601
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}

# Sweep abandoned claim-only draft PRs (issue #133). Lists open draft PRs, and
# for each one whose diff is EMPTY (zero changed files — a claim stub a dead
# loop opened and never advanced) and whose last update is older than the grace
# window, closes it with an explanatory comment. Uses updatedAt (last activity)
# not createdAt, so a draft a healthy loop is still pushing to is never touched.
# Grace defaults to 15m; override with FWF_STUB_GRACE_SECS. Prints one line per
# PR acted on; a no-op run prints nothing and returns 0.
fwf_stub_sweep() {
  local grace="${FWF_STUB_GRACE_SECS:-900}" now n updated files age
  now="$(date -u +%s)"
  local prs; prs="$(gh pr list --state open --draft --json number,updatedAt --jq '.[] | "\(.number) \(.updatedAt)"' 2>/dev/null || true)"
  [ -n "$prs" ] || return 0
  while read -r n updated; do
    [ -n "$n" ] || continue
    files="$(gh pr diff "$n" --name-only 2>/dev/null | grep -c . || true)"
    age="$(( now - $(fwf_iso_to_epoch "$updated" 2>/dev/null || echo "$now") ))"
    if fwf_pr_is_stale_stub true "${files:-0}" "$age" "$grace"; then
      gh pr close "$n" --comment "Auto-closed by fwf stub-sweep (issue #133): claim-only draft with zero changed files, untouched for $((age / 60))m (grace $((grace / 60))m). The claiming loop appears to have died before pushing any work; reclaim the ticket on a fresh cycle." >/dev/null 2>&1 \
        && echo "stub-sweep: closed empty draft PR #$n (idle $((age / 60))m)"
    fi
  done <<< "$prs"
  return 0
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
