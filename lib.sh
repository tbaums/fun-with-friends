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
  slug="$(git -C "$FWF_REPO" config --get remote.origin.url 2>/dev/null)"
  slug="${slug%.git}"; slug="${slug#git@github.com:}"; slug="${slug#https://github.com/}"; slug="${slug#ssh://git@github.com/}"
  mkdir -p "$FWF_GHGUARD_DIR"
  ln -sf "$FWF_LIB_DIR/fwf" "$FWF_GHGUARD_DIR/fwf"
  # Part (a): a `gh` shim that routes the hot, high-frequency reads through the
  # shared cache in EVERY mode. Baked install-time values (real gh path, repo,
  # cache dir) keep it self-contained in non-login panes.
  cat > "$FWF_GHGUARD_DIR/gh" <<GHGUARD
#!/usr/bin/env sh
# fwf gh shim (#57 sibling): (a) REST+ETag read cache for the hot list/view
# polls in all modes; (b) in local mode, the fail-closed write guard (#34).
REAL_GH="${real_gh:-gh}"
CACHE="$FWF_LIB_DIR/fwf-ghcache.sh"
export FWF_REAL_GH="\$REAL_GH" FWF_GHCACHE_DIR="$FWF_GHCACHE_DIR" FWF_REPO="$FWF_REPO" FWF_GHCACHE_REPO="$slug" FWF_GHCACHE_TTL="$FWF_GHCACHE_TTL"
_t="\${1:-}"; _v="\${2:-}"
case "\$_t \$_v" in
  "issue list"|"pr list"|"issue view"|"pr view")
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

# Cross-machine version-skew warning (fail-open, throttled). fwf flows live in the
# templates, which ship in the repo — so a box only has the latest flow (e.g.
# discovery tickets) if its install is current. `fwf upgrade` propagates it, but
# that is opt-in, so a forgotten box would silently run a stale flow. This warns
# (never blocks) at launch when the local VERSION is behind the latest release.
# Throttled to one network check / 12h via a tmp cache; offline/unauth → silent.
# Self-contained (finds VERSION next to this lib) and ALWAYS returns 0.
fwf_version_skew_warn() {
  command -v gh >/dev/null 2>&1 || return 0
  local libdir cur repo latest cache now ts age
  libdir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
  cur="$(cat "$libdir/VERSION" 2>/dev/null)" || return 0
  [ -n "$cur" ] || return 0
  repo="${FWF_UPGRADE_REPO:-tbaums/fun-with-friends}"
  cache="${TMPDIR:-/tmp}/.fwf-latest-release"
  now="$(date +%s 2>/dev/null || echo 0)"
  latest=""
  if [ -f "$cache" ] && [ -f "$cache.ts" ]; then
    ts="$(cat "$cache.ts" 2>/dev/null || echo 0)"
    age=$(( now - ts ))
    if [ "$age" -ge 0 ] && [ "$age" -lt 43200 ]; then latest="$(cat "$cache" 2>/dev/null || echo '')"; fi
  fi
  if [ -z "$latest" ]; then
    latest="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || echo '')"
    if [ -n "$latest" ]; then
      printf '%s' "$latest" >"$cache" 2>/dev/null || true
      printf '%s' "$now"    >"$cache.ts" 2>/dev/null || true
    fi
  fi
  [ -n "$latest" ] || return 0
  if [ "v$cur" != "$latest" ]; then
    printf '⚠️  fwf v%s on this box, but v%s is released — newer flows (e.g. discovery tickets) need an upgrade here.\n' "$cur" "${latest#v}" >&2
    printf "    run 'fwf upgrade', then 'fwf resume' (or 'fwf respawn <role>') to re-arm running panes on the new templates.\n" >&2
  fi
  return 0
}

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

# --- Conductor-triggered pre-promotion UX gate (issue #46) ------------------
# Pure decision helpers, kept out of fwf-ut-gate.sh so the functional test
# suite can exercise them directly (no tmux/browser/process spawning needed).
# The gate is opt-in and fails CLOSED on every ambiguity: unconfigured, over
# budget, or disabled all mean "skip the gate, let e2e-green promotion proceed
# unblocked" — never "hold promotion because the GATE itself couldn't run".

# True if this profile has wired up the gate (all three knobs set) AND the
# deploy-plumbed kill switch is off. False (rc 1) means fwf-ut-gate.sh must
# no-op — the caller is expected to say why via fwf_ut_gate_skip_reason.
fwf_ut_gate_configured() {
  [ "${FWF_UT_GATE_DISABLE:-0}" != "1" ] || return 1
  [ -n "${UT_GATE_PROFILE:-}" ] && [ -n "${UT_GATE_UI_GLOB:-}" ] && [ -n "${UT_GATE_APP_CMD:-}" ]
}
# One-line, human-readable reason the gate is (or would be) skipped, for the
# conductor's cycle report — so "gate never runs" is visible in logs, not a
# silent no-op that reads the same as "gate ran and found nothing" (the GV
# observability bar: distinguish a real run from a skip, always).
fwf_ut_gate_skip_reason() {
  if [ "${FWF_UT_GATE_DISABLE:-0}" = "1" ]; then echo "disabled (FWF_UT_GATE_DISABLE=1)"; return; fi
  if [ -z "${UT_GATE_PROFILE:-}" ] || [ -z "${UT_GATE_UI_GLOB:-}" ] || [ -z "${UT_GATE_APP_CMD:-}" ]; then
    echo "not configured for this profile (set UT_GATE_PROFILE/_UI_GLOB/_APP_CMD to enable)"; return
  fi
  echo "configured"
}
# True if the changed paths (one per line, e.g. `git diff --name-only`) touch
# UI per UT_GATE_UI_GLOB. Empty input never triggers.
fwf_ut_gate_diff_triggered() { # stdin = changed paths, one per line
  [ -n "${UT_GATE_UI_GLOB:-}" ] || return 1
  grep -qE "$UT_GATE_UI_GLOB"
}
# Daily trial budget (cost control — the trial-1 lesson: a busy factory must
# not run 20 trials/day). State is "<YYYY-MM-DD> <count>" in UT_GATE_BUDGET_FILE,
# reset automatically when the date rolls over. rc 0 = under cap, may run.
fwf_ut_gate_budget_ok() {
  local today count=0 line
  today="$(date +%Y-%m-%d)"
  if [ -f "$UT_GATE_BUDGET_FILE" ]; then
    line="$(cat "$UT_GATE_BUDGET_FILE" 2>/dev/null)"
    [ "${line%% *}" = "$today" ] && count="${line#* }"
  fi
  case "$count" in ''|*[!0-9]*) count=0;; esac
  [ "$count" -lt "${FWF_UT_GATE_DAILY_CAP:-2}" ]
}
# Record that a trial ran today (call only after fwf_ut_gate_budget_ok passed).
fwf_ut_gate_budget_bump() {
  local today count=0 line
  today="$(date +%Y-%m-%d)"
  if [ -f "$UT_GATE_BUDGET_FILE" ]; then
    line="$(cat "$UT_GATE_BUDGET_FILE" 2>/dev/null)"
    [ "${line%% *}" = "$today" ] && count="${line#* }"
  fi
  case "$count" in ''|*[!0-9]*) count=0;; esac
  mkdir -p "$(dirname "$UT_GATE_BUDGET_FILE")"
  printf '%s %d\n' "$today" "$((count + 1))" > "$UT_GATE_BUDGET_FILE"
}
# Parse a trial-one findings-report.md (format: templates/user-testing/pm.tmpl)
# for its severity mix. Prints "<blockers> <total>" (both integers). A missing
# or empty report reads as "0 0" — fail-closed toward "nothing to hold on".
# Deliberately loose (co-occurrence of "severity" and "blocker" on one line,
# case-insensitive) rather than anchored to exact markdown punctuation — the
# researcher is an LLM writing prose/markdown, not a fixed-format emitter, and
# this is a first-pass signal: the report itself is always linked/attached so
# a human can verify, never acted on blind.
fwf_ut_gate_parse_findings() { # $1 = path to findings-report.md
  local f="$1" blockers=0 total=0 sevlines
  if [ -f "$f" ]; then
    sevlines="$(grep -Ei 'severity' "$f" 2>/dev/null || true)"
    # grep -c ALWAYS prints a count (0 or more) even on no-match; it just exits
    # non-zero, so no `|| echo 0` fallback here (that would double-print "0").
    total="$(printf '%s\n' "$sevlines" | grep -Ec .)"
    blockers="$(printf '%s\n' "$sevlines" | grep -Eic 'blocker')"
  fi
  printf '%d %d\n' "$blockers" "$total"
}
# The LITERAL command the conductor's rendered prompt runs for __UT_GATE_CMD__
# (same idiom as __E2E__/__GATE__: bake an absolute, self-contained command
# into the prompt text, not a shell-env-dependent reference — a pane's shell
# is not guaranteed to inherit FWF_PROFILE). A no-op ("true ...") when the
# gate isn't configured, so the substitution is always safe to run verbatim.
fwf_ut_gate_cmd() {
  if fwf_ut_gate_configured; then
    printf 'FWF_PROFILE=%s "%s/fwf-ut-gate.sh"' "$PROFILE" "$FWF_LIB_DIR"
  else
    printf 'true # UX gate not configured for this profile (%s)' "$(fwf_ut_gate_skip_reason)"
  fi
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
  local tmpl="$1" id="${2:-}" text devui addendum _utp _utn=0 _utpanes=""
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
  text="${text//__DISCOVERY_LABEL__/$DISCOVERY_LABEL}"
  text="${text//__PM_INTERVAL__/$PM_INTERVAL}"
  text="${text//__STOPFILE__/$STOP_FILE}"
  text="${text//__COORD_SESSION__/$COORD_SESSION}"
  text="${text//__BUILD_SESSION__/$BUILD_SESSION}"
  text="${text//__REPO__/$(basename "$FWF_REPO")}"
  text="${text//__GATE__/$GATE_CMD}"
  text="${text//__E2E__/$E2E_CMD}"
  text="${text//__LOCK__/$E2E_LOCK}"
  text="${text//__UT_GATE_CMD__/$(fwf_ut_gate_cmd)}"
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
