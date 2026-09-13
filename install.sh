#!/usr/bin/env bash
# Put fwf on your PATH. 1.0 is the default (#583): `fwf` is the Rust supervisor
# in one/, and the v0.42 bash tool is installed beside it as `fwf-legacy`.
#
#   ./install.sh            -> installs into ~/.local/bin (or the first writable
#                              PATH bin dir), creating it if needed.
#   ./install.sh /custom/bin
#
# The 1.0 binary is built from one/ when cargo is present. Without cargo, the
# matching `one-v<version>` release asset for this platform is downloaded and
# its sha256 verified against the checksums published with the release; if
# neither path works, `fwf-legacy` is still installed and the failure is named.
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
ONE_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ONE/Cargo.toml" 2>/dev/null | head -1)"
BUILT=""

if [ -d "$ONE" ] && command -v cargo >/dev/null 2>&1; then
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
  ASSET="fwf-${ONE_VERSION}-${SLUG}.tar.gz"
  BASE="https://github.com/tbaums/fun-with-friends/releases/download/one-v${ONE_VERSION}"
  if [ -n "$SLUG" ] && [ -n "$ONE_VERSION" ]; then
    DL="$(mktemp -d)"
    echo "install: no cargo; fetching $ASSET from one-v$ONE_VERSION"
    if curl -fsSL "$BASE/$ASSET" -o "$DL/$ASSET" && curl -fsSL "$BASE/$ASSET.sha256" -o "$DL/want"; then
      WANT="$(awk '{print $1}' "$DL/want" | head -1)"
      if command -v shasum >/dev/null 2>&1; then GOT="$(shasum -a 256 "$DL/$ASSET" | awk '{print $1}')"
      else GOT="$(sha256sum "$DL/$ASSET" | awk '{print $1}')"; fi
      if [ -n "$WANT" ] && [ "$WANT" = "$GOT" ]; then
        tar -C "$DL" -xzf "$DL/$ASSET"
        if [ -x "$DL/fwf-${ONE_VERSION}-${SLUG}/fwf" ]; then
          mkdir -p "$ONE/target/release"
          mv "$DL/fwf-${ONE_VERSION}-${SLUG}/fwf" "$ONE/target/release/fwf"
          BUILT="$ONE/target/release/fwf"
        else
          echo "install: $ASSET carries no fwf binary — not installing it" >&2
        fi
      else
        echo "install: sha256 mismatch for $ASSET (want ${WANT:-<none published>}, got $GOT) — not installing it" >&2
      fi
    else
      echo "install: could not download $ASSET (or its .sha256) from one-v$ONE_VERSION" >&2
    fi
    rm -r "$DL" 2>/dev/null || true
  else
    echo "install: no prebuilt fwf asset for $(uname -s)-$(uname -m)" >&2
  fi
fi

if [ -n "$BUILT" ]; then
  refuse_if_foreign "$BIN/fwf"
  ln -sf "$BUILT" "$BIN/fwf"
  echo "installed: $BIN/fwf -> $BUILT (fwf $ONE_VERSION)"
  # One release only: scripts and notes that still say `fwfd` keep working.
  refuse_if_foreign "$BIN/fwfd"
  ln -sf "$BUILT" "$BIN/fwfd"
  echo "installed: $BIN/fwfd -> $BUILT (temporary alias, goes next release)"
else
  echo "install: fwf 1.0 was NOT installed — install a Rust toolchain (rustup.rs) and re-run," >&2
  echo "install: or download the one-v* asset yourself. fwf-legacy is installed and usable." >&2
fi

case ":$PATH:" in
  *":$BIN:"*) echo "ready: run 'fwf doctor'";;
  *) echo "note: $BIN is not on your PATH. Add this to your shell profile:"
     echo "  export PATH=\"$BIN:\$PATH\"";;
esac
