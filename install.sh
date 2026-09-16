#!/usr/bin/env bash
# Put fwf on your PATH. 1.0 is the default (#583): `fwf` is the Rust supervisor
# in one/, and the v0.42 bash tool is installed beside it as `fwf-legacy`.
#
#   ./install.sh            -> installs into ~/.local/bin (or the first writable
#                              PATH bin dir), creating it if needed.
#   ./install.sh /custom/bin
#   FWF_VERSION=1.0.6 ./install.sh   -> install that published release, whatever
#                              the checked-out tree says (skips the source build)
#
# The 1.0 binary is built from one/ when cargo is present. Without cargo — or
# with FWF_VERSION naming a release to pin to — the matching `v<version>` asset
# for this platform is downloaded and its sha256 verified against the checksums
# published with the release. `fwf-legacy` is installed either way, but an
# install that produces no working `fwf` now EXITS NON-ZERO (#660): it used to
# print the failure and exit 0, so a scripted install read it as a success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="$ROOT/fwf-legacy"
[ -x "$LEGACY" ] || { echo "install: can't find executable fwf-legacy next to this script" >&2; exit 1; }

# Choose a target bin dir: explicit arg, else the first writable dir already on
# PATH, else ~/.local/bin (created).
choose_bin() {
  [ $# -gt 0 ] && { echo "$1"; return; }
  local d
  for d in "$HOME/.local/bin" "/usr/local/bin"; do
    case ":$PATH:" in *":$d:"*) [ -w "$d" ] 2>/dev/null && { echo "$d"; return; };; esac
  done
  echo "$HOME/.local/bin"
}

BIN="$(choose_bin "$@")"
mkdir -p "$BIN"
BIN="$(cd "$BIN" && pwd)"   # absolutize so the PATH advice below is usable

# Re-installing over our own (or any) symlink is fine; a regular file we did not
# put there is somebody else's binary — don't silently destroy it.
refuse_if_foreign() {
  local path="$1"
  if [ -e "$path" ] && [ ! -L "$path" ]; then
    echo "install: $path exists and is not a symlink — refusing to overwrite it." >&2
    echo "install: remove it, or pick another dir: ./install.sh <dir>" >&2
    exit 1
  fi
}

# --- the 0.x tool, under its own name -------------------------------------
refuse_if_foreign "$BIN/fwf-legacy"
ln -sf "$LEGACY" "$BIN/fwf-legacy"
echo "installed: $BIN/fwf-legacy -> $LEGACY (v0.42, deprecated)"

# --- fwf 1.0: build it, or fetch the release asset ------------------------
ONE="$ROOT/one"
# Which version to install: FWF_VERSION when set, else the checked-out tree's,
# which is what `release-publish.sh` tags. Naming a version means "give me that
# published release", so it takes the download path even where cargo exists —
# otherwise a box with a toolchain would quietly build the working tree instead.
ONE_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ONE/Cargo.toml" 2>/dev/null | head -1)"
VERSION="${FWF_VERSION:-$ONE_VERSION}"
BUILT=""

if [ -z "${FWF_VERSION:-}" ] && [ -d "$ONE" ] && command -v cargo >/dev/null 2>&1; then
  echo "install: building fwf $ONE_VERSION from one/ (cargo build --release)"
  if cargo build --release --quiet --manifest-path "$ONE/Cargo.toml"; then
    BUILT="$ONE/target/release/fwf"
  else
    echo "install: cargo build failed" >&2
  fi
fi

# No cargo (or the build failed): take the published tarball for this platform,
# verify its sha256, and install the binary out of it. A download that cannot be
# verified is never installed. The names are one/RELEASING.md's contract (#584):
# `<bin>-<version>-<slug>.tar.gz` plus `<asset>.sha256`, built by
# `release-publish.sh` (macos-arm64) and `one-release.yml` (linux-x86_64).
if [ -z "$BUILT" ] && command -v curl >/dev/null 2>&1; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  SLUG="macos-arm64";;
    Linux-x86_64)  SLUG="linux-x86_64";;
    *) SLUG="";;
  esac
  ASSET="fwf-${VERSION}-${SLUG}.tar.gz"
  # The tag is `v<version>` — what `release-publish.sh` tags (`TAG="v$VERSION"`)
  # and what the remote carries. It was `one-v<version>` here until #660, which
  # has 404'd every clean-box install since the spelling changed in #641.
  BASE="https://github.com/tbaums/fun-with-friends/releases/download/v${VERSION}"
  if [ -n "$SLUG" ] && [ -n "$VERSION" ]; then
    DL="$(mktemp -d)"
    echo "install: fetching $ASSET from v$VERSION"
    if curl -fsSL "$BASE/$ASSET" -o "$DL/$ASSET" && curl -fsSL "$BASE/$ASSET.sha256" -o "$DL/want"; then
      WANT="$(awk '{print $1}' "$DL/want" | head -1)"
      if command -v shasum >/dev/null 2>&1; then GOT="$(shasum -a 256 "$DL/$ASSET" | awk '{print $1}')"
      else GOT="$(sha256sum "$DL/$ASSET" | awk '{print $1}')"; fi
      if [ -n "$WANT" ] && [ "$WANT" = "$GOT" ]; then
        tar -C "$DL" -xzf "$DL/$ASSET"
        if [ -x "$DL/fwf-${VERSION}-${SLUG}/fwf" ]; then
          mkdir -p "$ONE/target/release"
          mv "$DL/fwf-${VERSION}-${SLUG}/fwf" "$ONE/target/release/fwf"
          BUILT="$ONE/target/release/fwf"
        else
          echo "install: $ASSET carries no fwf binary — not installing it" >&2
        fi
      else
        echo "install: sha256 mismatch for $ASSET (want ${WANT:-<none published>}, got $GOT) — not installing it" >&2
      fi
    else
      echo "install: could not download $ASSET (or its .sha256) from v$VERSION" >&2
    fi
    rm -r "$DL" 2>/dev/null || true
  else
    echo "install: no prebuilt fwf asset for $(uname -s)-$(uname -m)" >&2
  fi
fi

FAILED=0
if [ -n "$BUILT" ]; then
  refuse_if_foreign "$BIN/fwf"
  ln -sf "$BUILT" "$BIN/fwf"
  echo "installed: $BIN/fwf -> $BUILT (fwf $VERSION)"
  # One release only: scripts and notes that still say `fwfd` keep working.
  refuse_if_foreign "$BIN/fwfd"
  ln -sf "$BUILT" "$BIN/fwfd"
  echo "installed: $BIN/fwfd -> $BUILT (temporary alias, goes next release)"
else
  FAILED=1
  echo "install: fwf 1.0 was NOT installed — install a Rust toolchain (rustup.rs) and re-run," >&2
  echo "install: or download the v$VERSION asset yourself. fwf-legacy is installed and usable." >&2
fi

case ":$PATH:" in
  *":$BIN:"*) echo "ready: run 'fwf doctor'";;
  *) echo "note: $BIN is not on your PATH. Add this to your shell profile:"
     echo "  export PATH=\"$BIN:\$PATH\"";;
esac

# An install that produced no `fwf` is a failed install, and says so in the one
# place a script reads (#660). What did get installed stays installed: the
# message above names what is missing and what to do about it.
exit "$FAILED"
