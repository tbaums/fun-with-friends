#!/usr/bin/env bash
# #727: the gate between a draft release and a public one. one-release.yml
# downloads every asset of the draft into an empty directory and runs this; it
# publishes only on exit 0, so a release with a missing, extra or corrupt asset
# stays a draft. A dry run runs it on the build artifacts instead.
#
#   release-verify.sh <dir> <bin> <version>
#
# <dir> must hold exactly these four files and nothing else:
#   <bin>-<version>-macos-arm64.tar.gz    <bin>-<version>-macos-arm64.tar.gz.sha256
#   <bin>-<version>-linux-x86_64.tar.gz   <bin>-<version>-linux-x86_64.tar.gz.sha256
# Each .sha256 names its tarball and matches its bytes, and each tarball holds
# <bin>-<version>-<slug>/{<bin>,README.md,RELEASING.md,CHANGELOG.md}, the binary
# non-empty. Exit 1 on any failure (every one is listed), 0 if all hold, 2 on
# bad arguments.
set -euo pipefail
if [ $# -ne 3 ]; then
  echo "usage: $0 <dir> <bin> <version>" >&2
  exit 2
fi
dir=${1%/}
bin=$2
version=$3
if [ ! -d "$dir" ] || [ -z "$bin" ] || [ -z "$version" ]; then
  echo "release-verify: no directory at '$dir', or an empty bin or version" >&2
  exit 2
fi
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1"; }
else sha() { shasum -a 256 "$1"; }; fi

fail=0
bad() { echo "FAIL $*"; fail=1; }
slugs="macos-arm64 linux-x86_64"

want=""
for s in $slugs; do
  want="$want$bin-$version-$s.tar.gz"$'\n'"$bin-$version-$s.tar.gz.sha256"$'\n'
done
want=$(printf '%s' "$want" | LC_ALL=C sort)
have=$(cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)
while IFS= read -r f; do
  [ -z "$f" ] || printf '%s\n' "$have" | grep -qxF -- "$f" || bad "missing asset: $f"
done <<<"$want"
while IFS= read -r f; do
  [ -z "$f" ] || printf '%s\n' "$want" | grep -qxF -- "$f" || bad "unexpected asset: $f"
done <<<"$have"

for s in $slugs; do
  name="$bin-$version-$s"
  tarball="$dir/$name.tar.gz"
  sumfile="$tarball.sha256"
  [ -f "$tarball" ] && [ -f "$sumfile" ] || continue
  # `<64 hex>  <name>.tar.gz`, as both sha256sum and `shasum -a 256` write it.
  read -r claimed claimed_name _ <"$sumfile" || true
  actual=$(sha "$tarball" | awk '{print $1}')
  if [ "${claimed_name#\*}" != "$name.tar.gz" ]; then
    bad "$name.tar.gz.sha256 names '${claimed_name:-nothing}', not $name.tar.gz"
  elif [ "$claimed" != "$actual" ]; then
    bad "$name.tar.gz checksum mismatch: .sha256 says ${claimed:-nothing}, the file is $actual"
  fi
  if ! names=$(tar -tzf "$tarball" 2>/dev/null); then
    bad "$name.tar.gz is not a readable gzip tarball"
    continue
  fi
  for member in "$bin" README.md RELEASING.md CHANGELOG.md; do
    printf '%s\n' "$names" | grep -qxF -- "$name/$member" || bad "$name.tar.gz holds no $name/$member"
  done
  # The binary is not an empty placeholder. Counted by extracting it to stdout,
  # which GNU tar and bsdtar agree on (their -tv columns do not).
  if printf '%s\n' "$names" | grep -qxF -- "$name/$bin" &&
    [ "$(tar -xzOf "$tarball" "$name/$bin" | wc -c | tr -d ' ')" = 0 ]; then
    bad "$name.tar.gz: $name/$bin is empty"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "release-verify: $dir is not a releasable $bin $version — the release stays a draft"
  exit 1
fi
echo "ok   $dir: 4 assets, checksums match, each tarball holds $bin, README.md, RELEASING.md, CHANGELOG.md"
