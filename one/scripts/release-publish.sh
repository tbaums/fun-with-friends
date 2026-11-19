#!/usr/bin/env bash
# Cut one fwf 1.0 release: refuse, then tag. Nothing else (#727).
#
#   usage: one/scripts/release-publish.sh <notes.md>
#
# Every release asset is built by GitHub CI; nothing is built here and nothing
# is uploaded from here. This script checks that the commit is fit to be a
# release and pushes an annotated tag `v<version>` whose message is the notes.
# The tag push starts `.github/workflows/one-release.yml`, which checks the tag,
# creates a DRAFT release with those notes, builds and tests macos-arm64 and
# linux-x86_64, verifies all four assets with `release-verify.sh`, and only
# then publishes. A failure anywhere leaves a draft, never a public release.
#
# Refusals, in order: no notes / empty notes; a dirty tree; a stale Cargo.lock
# (#604); HEAD is not origin/main; the version is already tagged here or on
# origin. It does not run the gate (CI does, on both hosts), build, or call
# `gh` — so it runs on any host with git and cargo.
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
# The notes become the tag message, and CI makes the release body from it
# (`--notes-from-tag`). Whitespace only is no notes.
grep -q '[^[:space:]]' "$NOTES" || die "the notes file $NOTES is empty; the tag message is the release notes"

# The version and the binary's name both come from Cargo.toml — the binary was
# renamed once already (#583) and will not be hardcoded here again.
VERSION="$(sed -n '/^\[package\]/,/^\[/{s/^version *= *"\(.*\)"/\1/p;}' Cargo.toml | head -1)"
BIN="$(awk '/^\[\[bin\]\]/{inbin=1; next} inbin && /^name *=/{gsub(/.*= *"|"/,""); print; exit}' Cargo.toml)"
[ -n "$VERSION" ] || die "no version in $ONE/Cargo.toml"
[ -n "$BIN" ] || die "no [[bin]] name in $ONE/Cargo.toml"
TAG="v$VERSION"
echo "release-publish: $BIN $VERSION → $TAG in $REPO_SLUG"

step "refusals"
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] || die "the tree is dirty; a release is cut from a committed state:
$DIRTY"
# The lock has to already agree with the version being tagged (#604): CI builds
# with `--locked`, so a stale lock fails every leg after the tag exists.
# `cargo metadata --locked` asks the question and writes nothing.
cargo metadata --locked --format-version 1 >/dev/null 2>&1 || die "Cargo.lock is stale — commit the lock with the version bump:
  (cd $ONE && cargo update -w) && git add $ONE/Cargo.lock && git commit --amend"
# A release is cut from main, and main only fast-forwards from a Green staging.
git fetch -q origin main 2>/dev/null || die "cannot fetch origin main; a release is tagged at origin/main"
HEAD_SHA="$(git rev-parse HEAD)"
MAIN_SHA="$(git rev-parse origin/main)"
[ "$HEAD_SHA" = "$MAIN_SHA" ] || die "HEAD ($HEAD_SHA) is not origin/main ($MAIN_SHA); check out main, pull, and cut from there"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "$TAG already exists locally — bump Cargo.toml's version (a tag is never moved)"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]; then
  die "$TAG already exists on origin — it is released (or half-released); recover it with one-release.yml, see docs/releasing.md"
fi
echo "ok: notes, clean tree, lock current, HEAD is origin/main, $TAG is free"

# `--cleanup=verbatim`: the default cleanup strips every line that starts with
# `#`, which is every Markdown heading in the notes.
step "tag"
git tag -a "$TAG" --cleanup=verbatim -F "$NOTES" "$HEAD_SHA"
if ! git push origin "refs/tags/$TAG"; then
  git tag -d "$TAG" >/dev/null
  die "pushing $TAG failed; the local tag was removed, so a re-run starts clean"
fi

cat <<DONE

tagged:   $TAG at $HEAD_SHA (annotated, notes in the message)
ci:       https://github.com/$REPO_SLUG/actions/workflows/one-release.yml?query=branch%3A$TAG
          it creates a draft, builds both assets, verifies all four, then publishes
then:     $BIN release-check --repo $REPO_SLUG --tag $TAG --expect 4
DONE
