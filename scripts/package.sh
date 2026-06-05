#!/usr/bin/env bash
# Build a release tarball of the runnable swarm into dist/. Ships only the
# generic pieces — the example profile, not anyone's private repo profile.
#
# Usage: scripts/package.sh            -> dist/fwf-<VERSION>.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
NAME="fwf-$VERSION"
STAGE="$(mktemp -d)"
DEST="$STAGE/$NAME"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DEST/lib" "$DEST/profiles" "$DEST/prompts"
cp fwf config.sh lib.sh install.sh VERSION LICENSE README.md "$DEST/"
cp fwf-provision.sh fwf-up.sh fwf-respawn.sh fwf-stop.sh fwf-resume.sh fwf-down.sh "$DEST/"
cp lib/detect.sh lib/profile.sh "$DEST/lib/"
cp profiles/example.sh "$DEST/profiles/"        # generic template only
cp prompts/*.tmpl prompts/*.txt "$DEST/prompts/"
chmod +x "$DEST/fwf" "$DEST"/*.sh "$DEST/install.sh"

mkdir -p "$ROOT/dist"
tar -C "$STAGE" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
echo "dist/$NAME.tar.gz"
