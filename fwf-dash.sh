#!/usr/bin/env bash
# fwf dash — launch the read-only status board (issue #40, milestone 1).
#
# The gh-dash model: this bash wrapper resolves the profile/config, makes sure a
# runnable fwf-dash binary exists, points it at the bash data provider, and execs
# it. The binary is purely the renderer; all the derived-first data gathering and
# the gh/local backend abstraction live in `fwf-dash-data.sh` (which sources
# lib.sh just like every other engine script).
#
# Binary resolution (issue #63 — drop the first-run cargo build):
#   1. FWF_DASH_BIN            explicit override; used verbatim, no build/download
#   2. cached arch+version binary   ~/.fun-with-friends/cache/dash/fwf-dash-<ver>-<slug>
#   3. matching release asset  downloaded, sha256-verified, cached, then run
#   4. source `cargo build`    the original first-run fallback (offline / no asset)
#
# Usage: [FWF_PROFILE=example] fwf dash
#   FWF_DASH_BIN          override the binary path (skip resolution entirely)
#   FWF_DASH_REFRESH      auto-refresh seconds (default 5; read by the binary)
#   FWF_DASH_RELEASE_BASE base URL for release assets (test seam; default GitHub)
#   FWF_DASH_NO_DOWNLOAD  set to skip the download step (force source/cache only)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

# lib.sh does not define die (it lives in the `fwf` dispatcher, which exec's us),
# so define our own messaging here — otherwise the error paths below would emit
# "die: command not found" (issue #63).
_dash_die()  { echo "fwf: dash: $*" >&2; exit 1; }
_dash_note() { echo "fwf: dash: $*" >&2; }

CRATE="${FWF_DASH_CRATE:-$DIR/dash}"   # FWF_DASH_CRATE is a test seam
VERSION="$(cat "$DIR/VERSION" 2>/dev/null || echo unknown)"
# Same repo the upgrade path uses, so download + upgrade stay in lockstep.
RELEASE_REPO="${FWF_UPGRADE_REPO:-tbaums/fun-with-friends}"
RELEASE_BASE="${FWF_DASH_RELEASE_BASE:-https://github.com/$RELEASE_REPO/releases/download}"
# FWF_RUN is the runtime root (~/.fun-with-friends by default); FWF_HOME is the
# repo dir, so don't cache there. Keep the cache out of the checkout entirely.
CACHE_DIR="${FWF_DASH_CACHE_DIR:-${FWF_RUN:-$HOME/.fun-with-friends}/cache/dash}"

# Map the host to a canonical os-arch slug. Echoes nothing for an unsupported
# host (caller treats empty slug as "no prebuilt available").
dash_slug() {
  local os arch
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "darwin-arm64";;
        # Intel Mac (x86_64) has no prebuilt: empty slug ⇒ skip the doomed
        # download and fall straight to the source-build path with a clear note.
      esac;;
    Linux)
      case "$arch" in
        x86_64|amd64)  echo "linux-x86_64";;
        aarch64|arm64) echo "linux-arm64";;
      esac;;
  esac
}

# Compute the sha256 of a file, portably (macOS: shasum; Linux: sha256sum).
dash_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Fetch a URL to a file. curl-first (no auth needed for public releases); falls
# back to wget. Returns non-zero on any failure (no network, 404, missing tool).
dash_fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 -o "$out" "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 10 -O "$out" "$url" 2>/dev/null
  else
    return 1
  fi
}

# Try to download + verify the release asset for this VERSION/slug into the
# cache. Echoes the cached path on success; returns non-zero (printing nothing
# meaningful) on any failure so the caller falls through to the source build.
# Security: the binary is only chmod+moved into place AFTER its sha256 matches
# the published checksums file. No checksum ⇒ no execution.
dash_download() {
  local slug="$1" dest="$2"
  [ -n "$slug" ] || return 1
  [ "$VERSION" != "unknown" ] || return 1
  [ -z "${FWF_DASH_NO_DOWNLOAD:-}" ] || return 1
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1

  local asset sums base tmp tmpsum want have
  asset="fwf-dash-${VERSION}-${slug}"
  sums="fwf-dash-${VERSION}-checksums.txt"
  base="$RELEASE_BASE/v${VERSION}"

  mkdir -p "$CACHE_DIR" || return 1
  tmp="$(mktemp "$CACHE_DIR/.dl.XXXXXX")" || return 1
  tmpsum="$(mktemp "$CACHE_DIR/.sum.XXXXXX")" || { rm -f "$tmp"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' '$tmpsum'" RETURN

  dash_fetch "$base/$asset" "$tmp"  || return 1
  dash_fetch "$base/$sums"  "$tmpsum" || return 1

  # Pull the expected checksum for our asset out of the checksums file (lines are
  # "<sha256>  <asset-name>"). No matching line ⇒ refuse to run.
  want="$(awk -v a="$asset" '$2==a || $2=="*"a {print $1; exit}' "$tmpsum")"
  [ -n "$want" ] || return 1
  have="$(dash_sha256 "$tmp")" || return 1
  [ "$want" = "$have" ] || { _dash_note "checksum mismatch for $asset — ignoring download"; return 1; }

  chmod +x "$tmp" || return 1
  mv -f "$tmp" "$dest" || return 1   # atomic within the same dir
  echo "$dest"
}

# --- resolve the binary -----------------------------------------------------
BIN=""
if [ -n "${FWF_DASH_BIN:-}" ]; then
  # 1. Explicit override: use it verbatim, never build or download.
  BIN="$FWF_DASH_BIN"
else
  SLUG="$(dash_slug)"
  CACHED="$CACHE_DIR/fwf-dash-${VERSION}-${SLUG}"
  if [ -n "$SLUG" ] && [ -x "$CACHED" ]; then
    # 2. Cached arch+version-matched binary.
    BIN="$CACHED"
  elif [ -n "$SLUG" ] && BIN="$(dash_download "$SLUG" "$CACHED")"; then
    # 3. Downloaded + verified release asset (now cached).
    :
  else
    # 4. Source build fallback (the original gh-dash first-run behavior).
    BIN="$CRATE/target/release/fwf-dash"
    if [ ! -x "$BIN" ]; then
      command -v cargo >/dev/null 2>&1 \
        || _dash_die "no prebuilt binary for ${SLUG:-this host} @ ${VERSION} and cargo isn't installed — install Rust (https://rustup.rs) or set FWF_DASH_BIN to a prebuilt fwf-dash."
      _dash_note "no prebuilt binary for ${SLUG:-this host} @ ${VERSION}; building from source (cargo build --release) ..."
      ( cd "$CRATE" && cargo build --release ) \
        || _dash_die "cargo build failed — see the output above."
    fi
  fi
fi
[ -x "$BIN" ] || _dash_die "no runnable binary at $BIN."

command -v jq >/dev/null 2>&1 || _dash_die "jq is required for the data provider (brew install jq)."

# The renderer shells out to these — the read-only provider on its refresh timer,
# the action layer on a y/x/c/o/r/s/t keypress. Export both (and let the resolved
# FWF_PROFILE flow through) so they resolve the same factory the binary renders.
export FWF_DASH_DATA="$DIR/fwf-dash-data.sh"
export FWF_DASH_ACT="$DIR/fwf-dash-act.sh"
export FWF_USAGE_DATA="$DIR/fwf-usage-data.sh"

# Mouse-wheel scroll in the detail pane needs the host tmux to forward wheel
# events to the alt-screen TUI, which only happens when that session has
# `mouse on`. Enable it for the duration (session-local) and revert on exit so
# the wheel works wherever the dash is stood up — concierge, factory, or the
# user's own tmux — without editing any tmux.conf. Outside tmux this is a no-op.
if [ -n "${TMUX:-}" ]; then
  tmux set mouse on 2>/dev/null || true
  "$BIN"; rc=$?
  tmux set -u mouse 2>/dev/null || true   # drop our override; revert to prior default
  exit "$rc"
fi
exec "$BIN"
