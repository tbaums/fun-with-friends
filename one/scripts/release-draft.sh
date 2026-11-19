#!/usr/bin/env bash
# #734: one-release.yml's draft job. Creates a DRAFT release for <tag> whose
# notes are the tag's message, or reuses the one release that tag already has
# (the #604 recovery path; its notes are left alone). Never a second release.
#
#   GITHUB_REPOSITORY=<owner/name> release-draft.sh <tag> <version>
#
# Run from a checkout whose `origin` has the tag. The notes go to gh through
# `--notes-file`, written from the tag's `%(contents)` to a temp file outside
# the checkout: gh refuses `--notes-from-tag` together with `--repo` (run
# 44468070939), and without `--repo` gh would guess the repository from the
# checkout's remote. Exit 0: a draft created, or the one release reused.
# 1: more than one release, a lightweight tag, an empty message, or a failed
# git/gh call. 2: bad arguments.
set -euo pipefail
if [ $# -ne 2 ] || [ "$1" != "v$2" ] || [ -z "$2" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "usage: GITHUB_REPOSITORY=<owner/name> $0 v<version> <version>" >&2
  exit 2
fi
tag=$1
version=$2
repo=$GITHUB_REPOSITORY
die() { echo "::error::$*" >&2; exit 1; }

# checkout's shallow fetch can leave an annotated tag lightweight; fetch the
# tag object itself.
git fetch --no-tags --force origin "refs/tags/$tag:refs/tags/$tag"
ids="$(gh api "repos/$repo/releases?per_page=100" --paginate \
  --jq ".[] | select(.tag_name == \"$tag\") | .id")"
n="$(printf '%s\n' "$ids" | grep -c . || true)"
case "$n" in
  0) ;;
  1)
    gh api "repos/$repo/releases/$ids" \
      --jq '"reusing release \(.id) for \(.tag_name), draft=\(.draft), \(.assets | length) assets"'
    exit 0 ;;
  *) die "$tag has $n releases; resolve that by hand before re-running" ;;
esac

# A lightweight tag's %(contents) is the commit's message, not the notes, so
# the kind is checked here and not taken on trust from `meta`.
kind="$(git cat-file -t "refs/tags/$tag")"
[ "$kind" = tag ] || die "$tag is a lightweight tag ($kind); the release notes are an annotated tag's message"
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
# The trailing `x` keeps the message's own final newlines through $( ), which
# strips only the one for-each-ref adds; the file is the message, byte for byte.
msg="$(git for-each-ref --format='%(contents)x' "refs/tags/$tag")"
printf '%s' "${msg%x}" >"$notes"
grep -q '[^[:space:]]' "$notes" || die "$tag has an empty message; the tag message is the release notes"
gh release create "$tag" --repo "$repo" --draft --verify-tag \
  --title "fwf $version" --notes-file "$notes"
echo "created a draft release for $tag"
