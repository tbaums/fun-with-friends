#!/usr/bin/env bash
# Cut and publish one fwf 1.0 release. One command, every refusal in it (#584).
#
#   usage: one/scripts/release-publish.sh <notes.md>
#
# In order: refuse a dirty tree; refuse a version that is already tagged (here
# or on the remote); run the gate this repo runs in CI; build release; stage the
# macOS arm64 tarball with its checksum; `gh release create` — which creates the
# tag AND the release in one call, so `one-release.yml` can never race a release
# that does not exist yet; then prove the release is really there with
# `release-check`. The Linux x86_64 tarball is uploaded onto the same release by
# `one-release.yml`, which the tag push triggers.
#
# Nothing is staged inside the repo: a re-run after a partial failure must see
# the same clean tree the first run saw. Artifacts land in a temp dir whose path
# is printed (override with FWF_RELEASE_DIR).
set -euo pipefail

REPO_SLUG="${FWF_RELEASE_REPO:-tbaums/fun-with-friends}"
ONE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ONE"

die() { echo "release-publish: $*" >&2; exit 1; }
step() { printf '\n=== %s\n' "$*"; }

NOTES="${1:-}"
[ -n "$NOTES" ] || die "usage: one/scripts/release-publish.sh <notes.md>"
[ -f "$NOTES" ] || die "no notes file at $NOTES (a release needs notes)"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

# The version and the binary's name both come from Cargo.toml — the binary was
# renamed once already (#583) and will not be hardcoded here again.
VERSION="$(sed -n '/^\[package\]/,/^\[/{s/^version *= *"\(.*\)"/\1/p;}' Cargo.toml | head -1)"
BIN="$(awk '/^\[\[bin\]\]/{inbin=1; next} inbin && /^name *=/{gsub(/.*= *"|"/,""); print; exit}' Cargo.toml)"
[ -n "$VERSION" ] || die "no version in $ONE/Cargo.toml"
[ -n "$BIN" ] || die "no [[bin]] name in $ONE/Cargo.toml"
TAG="one-v$VERSION"
echo "release-publish: $BIN $VERSION → $TAG in $REPO_SLUG"

# The tarball says macos-arm64, so refuse to build it anywhere else rather than
# ship a Linux binary under a macOS name. Linux comes from one-release.yml.
HOST="$(uname -s)-$(uname -m)"
[ "$HOST" = "Darwin-arm64" ] || die "this step builds the macos-arm64 asset; host is $HOST (Linux x86_64 is one-release.yml's job)"

step "refusals"
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] || die "the tree is dirty; a release is cut from a committed state:
$DIRTY"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "$TAG already exists locally — bump Cargo.toml's version, or publish the existing tag by hand"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]; then
  die "$TAG already exists on origin — it is released (or half-released): see
  gh release view $TAG --repo $REPO_SLUG"
fi
command -v gh >/dev/null || die "gh is not installed; it publishes the release"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
echo "ok: clean tree, $TAG is free, gh ready"

# Exactly what one-ci.yml runs, in one place: a release that cannot pass the
# gate is not a release.
step "gate"
cargo fmt --check
cargo clippy --quiet --all-targets -- -D warnings
cargo test --quiet
bash scripts/size-check.sh >/dev/null
echo "ok: fmt, clippy, tests, size"

step "build"
cargo build --release --locked
[ -x "target/release/$BIN" ] || die "cargo build produced no target/release/$BIN"

step "stage"
OUT="${FWF_RELEASE_DIR:-$(mktemp -d)}"
mkdir -p "$OUT"
NAME="$BIN-$VERSION-macos-arm64"
STAGE="$OUT/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "target/release/$BIN" "$STAGE/$BIN"
cp README.md RELEASING.md CHANGELOG.md "$STAGE/"
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
( cd "$OUT" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
echo "ok: $OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"
tar -tzf "$OUT/$NAME.tar.gz"

# `gh release create <tag>` tags the current HEAD and publishes the release in
# one call: the tag push that triggers one-release.yml therefore cannot land
# before the release it uploads onto exists.
step "publish"
gh release create "$TAG" \
  --repo "$REPO_SLUG" \
  --title "fwf $VERSION" \
  --notes-file "$NOTES" \
  "$OUT/$NAME.tar.gz" "$OUT/$NAME.tar.gz.sha256"

# A tag is not a release: prove the object exists with the two assets this step
# uploaded. The Linux pair makes it four — `--expect 4` once the workflow ends.
step "verify"
"target/release/$BIN" release-check --repo "$REPO_SLUG" --tag "$TAG" --expect 2

cat <<DONE

released: $TAG (2 assets) — artifacts in $OUT
next:     one-release.yml is building the linux-x86_64 pair; when it finishes,
          $BIN release-check --repo $REPO_SLUG --tag $TAG --expect 4
DONE
