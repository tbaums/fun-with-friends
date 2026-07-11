# Cross-machine version-skew warning (issue #79/#94 — see
# docs/proposals/79-upgrade-staleness-check.md for the full design rationale).
# fwf flows live in the templates, which ship in the repo — so a box only has
# the latest flow (e.g. discovery tickets) if its install is current. `fwf
# upgrade` propagates it, but that is opt-in, so a forgotten box would
# silently run a stale flow. This warns (NEVER blocks) at launch when the
# local VERSION is behind the latest release.
#
# Profile-independent on purpose: `fwf doctor` runs after only config.sh (no
# profile/template resolved yet), so this file depends only on $FWF_HOME and
# $FWF_RUN (both set by config.sh) — never lib.sh's profile/template state.
# Sourced by both `fwf` (top-level, for doctor) and lib.sh (for fwf-up.sh's
# fwf_version_skew_warn call site) so every caller agrees on one cache.
#
# Cache lives at $FWF_RUN/upgrade-check/{latest,ts} — the shared-state root,
# not $TMPDIR (which can diverge per shell/sandbox/user) — one file shared
# across every profile and process on the machine, since "latest fwf release"
# has nothing to do with which profile is running.
FWF_VERSION_CHECK_WINDOW="${FWF_VERSION_CHECK_WINDOW:-43200}"   # 12h staleness window
FWF_VERSION_CHECK_STALE_MULT=3                                  # "could not check" past this many windows
fwf_version_skew_dir() { printf '%s\n' "$FWF_RUN/upgrade-check"; }

# rc 0 if semver $1 < semver $2 ("vX.Y.Z" or "X.Y.Z"; missing/non-numeric
# segments treat as 0). Bash-3.2-safe numeric field-by-field compare — NOT a
# string inequality, so a local build newer than the cached "latest" (a
# maintainer ahead of the release, or a freshly-released box whose cache is
# still momentarily behind) is correctly NOT flagged as out of date.
_fwf_semver_lt() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1="${a1%%[!0-9]*}"; a2="${a2%%[!0-9]*}"; a3="${a3%%[!0-9]*}"
  b1="${b1%%[!0-9]*}"; b2="${b2%%[!0-9]*}"; b3="${b3%%[!0-9]*}"
  a1="${a1:-0}"; a2="${a2:-0}"; a3="${a3:-0}"
  b1="${b1:-0}"; b2="${b2:-0}"; b3="${b3:-0}"
  [ "$a1" -lt "$b1" ] && return 0; [ "$a1" -gt "$b1" ] && return 1
  [ "$a2" -lt "$b2" ] && return 0; [ "$a2" -gt "$b2" ] && return 1
  [ "$a3" -lt "$b3" ] && return 0
  return 1
}

# The actual network fetch + cache write. NEVER call this inline on the hot
# path — always via a detached background subshell (see fwf_version_skew_check)
# so a slow/hung `gh` can never block a caller. Non-blocking single-flight: if
# another refresh is already in progress (the lock dir exists), this one just
# bails immediately rather than waiting — the loser's caller keeps using
# whatever cache it already had, and the next staleness window retries.
# `ts` is written ONLY on a successful fetch, so a dead/failing checker shows
# up as a stale `ts` (see fwf_doctor_version_line) rather than silently
# masquerading as fresh.
#
# Releases the lock explicitly on every path rather than via `trap ... EXIT`
# — a trap set inside a function invoked as `func &` does not reliably fire
# when run non-interactively (confirmed: it silently never runs under plain
# `bash script.sh`), so this only ever releases the lock it took, inline.
_fwf_version_skew_refresh() {
  local dir lockdir repo latest
  dir="$(fwf_version_skew_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  lockdir="$dir/.refresh.lock"
  mkdir "$lockdir" 2>/dev/null || return 0   # someone else already refreshing — non-blocking, bail
  if ! command -v gh >/dev/null 2>&1; then rmdir "$lockdir" 2>/dev/null; return 0; fi
  repo="${FWF_UPGRADE_REPO:-tbaums/fun-with-friends}"
  latest="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || echo '')"
  if [ -n "$latest" ]; then
    printf '%s' "$latest" >"$dir/latest.tmp" 2>/dev/null && mv -f "$dir/latest.tmp" "$dir/latest" 2>/dev/null
    printf '%s' "$(date +%s 2>/dev/null || echo 0)" >"$dir/ts.tmp" 2>/dev/null && mv -f "$dir/ts.tmp" "$dir/ts" 2>/dev/null
  fi
  rmdir "$lockdir" 2>/dev/null
}

# Read-only: never touches the network. Echoes "latest|ts" (either may be
# empty/0 if no successful check has ever completed). Used by both the
# fwf-up warning and `fwf doctor`'s three-state line so they agree on the cache.
fwf_version_skew_read_cache() {
  local dir latest="" ts=0
  dir="$(fwf_version_skew_dir)"
  [ -f "$dir/latest" ] && latest="$(cat "$dir/latest" 2>/dev/null || echo '')"
  [ -f "$dir/ts" ] && ts="$(cat "$dir/ts" 2>/dev/null || echo 0)"
  printf '%s|%s\n' "$latest" "$ts"
}

# The full kill switch (INCIDENT_PROTOCOL — distinct from per-version silence
# below): disables the check ENTIRELY, no cache read, no background refresh,
# for offline/air-gapped operation. FWF_ACK_VERSION only silences the banner.
# Echoes "cur|latest" when a warning is due; empty otherwise. ALWAYS returns 0.
fwf_version_skew_check() {
  local cur dir latest ts now age cache
  [ "${FWF_SKIP_VERSION_CHECK:-0}" = "1" ] && return 0
  cur="$(cat "$FWF_HOME/VERSION" 2>/dev/null)" || return 0
  [ -n "$cur" ] || return 0
  dir="$(fwf_version_skew_dir)"
  cache="$(fwf_version_skew_read_cache)"
  latest="${cache%%|*}"; ts="${cache##*|}"
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - ts ))
  # Stale or never-checked: kick a DETACHED, non-blocking refresh for NEXT time.
  # This call never waits on it — that's the whole point (issue #94 axis 1).
  if [ -z "$latest" ] || [ "$age" -ge "$FWF_VERSION_CHECK_WINDOW" ]; then
    command -v gh >/dev/null 2>&1 && ( _fwf_version_skew_refresh >/dev/null 2>&1 & ) 2>/dev/null
  fi
  [ -n "$latest" ] || return 0
  _fwf_semver_lt "$cur" "$latest" || return 0   # local >= latest: nothing to warn, ever (maintainer-ahead safe)
  [ "${FWF_ACK_VERSION:-}" = "$latest" ] && return 0   # per-version silence — a NEW release still re-arms
  printf '%s|%s\n' "$cur" "$latest"
  unset dir
}

# fwf-up.sh call site: prints the loud warning (never blocks — the refresh
# fwf_version_skew_check kicks off is always detached). ALWAYS returns 0.
fwf_version_skew_warn() {
  local out cur latest
  out="$(fwf_version_skew_check)" || true
  [ -n "$out" ] || return 0
  cur="${out%%|*}"; latest="${out##*|}"
  printf '⚠️  fwf v%s on this box, but %s is released — newer flows (e.g. discovery tickets) need an upgrade here.\n' "$cur" "$latest" >&2
  printf "    run 'fwf upgrade', then 'fwf resume' (or 'fwf respawn <role>') to re-arm running panes on the new templates.\n" >&2
  return 0
}

# `fwf doctor`'s three-state line: up-to-date / out-of-date / could-not-check.
# "could not check" fires when the last SUCCESSFUL fetch (ts) is older than
# FWF_VERSION_CHECK_STALE_MULT staleness windows (or has never happened), so a
# dead/broken checker is never rendered as "you're current" — it renders as
# its own distinct, diagnosable state instead.
fwf_doctor_version_line() {
  local cur latest ts now age stale_after
  cur="$(cat "$FWF_HOME/VERSION" 2>/dev/null)"
  if [ -z "$cur" ]; then
    printf '  fwf       : version unknown (no VERSION file)\n'
    return 0
  fi
  if [ "${FWF_SKIP_VERSION_CHECK:-0}" = "1" ]; then
    printf '  fwf       : v%s — upgrade check disabled (FWF_SKIP_VERSION_CHECK=1)\n' "$cur"
    return 0
  fi
  local cache; cache="$(fwf_version_skew_read_cache)"
  latest="${cache%%|*}"; ts="${cache##*|}"
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - ts ))
  stale_after=$(( FWF_VERSION_CHECK_WINDOW * FWF_VERSION_CHECK_STALE_MULT ))
  if [ -z "$latest" ] || [ "$ts" = 0 ] || [ "$age" -ge "$stale_after" ]; then
    if [ "$ts" = 0 ] || [ -z "$latest" ]; then
      printf '  fwf       : v%s — could not check (no successful check yet)\n' "$cur"
    else
      printf '  fwf       : v%s — could not check (last success %dh ago; gh unreachable?)\n' "$cur" "$(( age / 3600 ))"
    fi
    return 0
  fi
  if _fwf_semver_lt "$cur" "$latest"; then
    printf '  fwf       : v%s — OUT OF DATE, %s available: run '"'"'fwf upgrade'"'"' (checked %dh ago)\n' "$cur" "$latest" "$(( age / 3600 ))"
  else
    printf '  fwf       : v%s — up to date (checked %dh ago)\n' "$cur" "$(( age / 3600 ))"
  fi
}
