#!/usr/bin/env bash
# Put `fwf` on your PATH by symlinking it into a bin dir. Run from a clone:
#   ./install.sh            -> symlinks into ~/.local/bin (or the first writable
#                              PATH bin dir), creating it if needed.
#   ./install.sh /custom/bin
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fwf"
[ -x "$SRC" ] || { echo "install: can't find executable fwf next to this script" >&2; exit 1; }

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

# Re-installing over our own (or any) symlink is fine; a regular file named fwf
# is somebody else's binary — don't silently destroy it.
if [ -e "$BIN/fwf" ] && [ ! -L "$BIN/fwf" ]; then
  echo "install: $BIN/fwf exists and is not a symlink — refusing to overwrite it." >&2
  echo "install: remove it, or pick another dir: ./install.sh <dir>" >&2
  exit 1
fi
ln -sf "$SRC" "$BIN/fwf"
echo "installed: $BIN/fwf -> $SRC"

case ":$PATH:" in
  *":$BIN:"*) echo "ready: run 'fwf doctor'";;
  *) echo "note: $BIN is not on your PATH. Add this to your shell profile:"
     echo "  export PATH=\"$BIN:\$PATH\"";;
esac
