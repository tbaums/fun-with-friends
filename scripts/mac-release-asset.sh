#!/usr/bin/env bash
# Build the darwin-arm64 fwf-dash binary locally and attach it to a release.
#
# darwin-arm64 was removed from dash-targets.json because GitHub-hosted macOS
# runners queue unpredictably -- on v0.36.0 the darwin job sat unscheduled for
# 20+ minutes while this same build took 9 SECONDS on an Apple Silicon Mac.
# The release therefore publishes the tarball, the two Linux binaries and the
# checksums from CI; this attaches the Mac binary afterwards.
#
# `fwf dash` resolves a prebuilt binary from the release assets, so WITHOUT
# this step macOS users fall back to building from source. Run it on every
# release cut.
#
#   usage: scripts/mac-release-asset.sh [tag]     (default: v$(cat VERSION))
set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "mac-release-asset: must run on macOS (got $(uname -s))" >&2; exit 2 ;;
esac
[ "$(uname -m)" = "arm64" ] || { echo "mac-release-asset: needs Apple Silicon (got $(uname -m))" >&2; exit 2; }

ver="$(cat VERSION)"
tag="${1:-v$ver}"
asset="fwf-dash-${ver}-darwin-arm64"

echo "mac-release-asset: building $asset from $(git rev-parse --short HEAD)"
( cd dash && cargo build --release --locked --target aarch64-apple-darwin )
cp "dash/target/aarch64-apple-darwin/release/fwf-dash" "$asset"
file "$asset" | grep -q 'Mach-O.*arm64' || { echo "mac-release-asset: not a Mach-O arm64 binary" >&2; exit 1; }

# Fold this checksum into the published checksums file rather than replacing it:
# the Linux lines were produced by CI and must survive verbatim.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if gh release download "$tag" -p "fwf-dash-${ver}-checksums.txt" -D "$tmp" 2>/dev/null; then
  grep -v " ${asset}\$" "$tmp/fwf-dash-${ver}-checksums.txt" > "$tmp/new.txt" || true
else
  : > "$tmp/new.txt"
fi
shasum -a 256 "$asset" >> "$tmp/new.txt"
sort -k2 "$tmp/new.txt" > "fwf-dash-${ver}-checksums.txt"

gh release upload "$tag" "$asset" "fwf-dash-${ver}-checksums.txt" --clobber
echo "mac-release-asset: attached $asset to $tag"
gh release view "$tag" --json assets -q '.assets[].name' | sort
