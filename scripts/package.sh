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

# NOTE: docs/ and templates/ are cp -R'd whole below — pre-creating their
# destinations would nest them (cp -R src dest/src when dest exists).
mkdir -p "$DEST/lib" "$DEST/profiles" "$DEST/prompts" "$DEST/eval" "$DEST/containers"
cp fwf config.sh lib.sh install.sh VERSION LICENSE README.md CHANGELOG.md RELEASING.md "$DEST/"
cp fwf-provision.sh fwf-up.sh fwf-respawn.sh fwf-stop.sh fwf-resume.sh fwf-down.sh "$DEST/"
cp lib/detect.sh lib/profile.sh "$DEST/lib/"
cp profiles/example.sh "$DEST/profiles/"        # generic template only
cp prompts/*.txt "$DEST/prompts/"               # shared assets (role prompts live in templates/)
cp -R templates "$DEST/templates"               # factory design templates (dev/refactor/ideation/dev-sre)
cp -R docs "$DEST/docs"
cp containers/Dockerfile "$DEST/containers/"
cp -R eval/run.sh eval/scenarios "$DEST/eval/"  # harness + shipped scenarios (not results/)
chmod +x "$DEST/fwf" "$DEST"/*.sh "$DEST/install.sh" "$DEST/eval/run.sh"

mkdir -p "$ROOT/dist"
tar -C "$STAGE" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
echo "dist/$NAME.tar.gz"
