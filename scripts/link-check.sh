#!/usr/bin/env bash
# #609: every relative link and image under docs/** resolves to a file that
# exists. The docs tree was just reorganised wholesale (0.x moved under
# docs/legacy/, two pages promoted out of one/), and a move that silently
# breaks a link is the failure mode that reorganisation has. External links
# (http/https/mailto) and bare in-page anchors are not checked — this is a
# "does the file exist" check, not a fetcher.
#
# Run from the repository root, or from anywhere: it cds to the root itself.
set -euo pipefail
cd "$(dirname "$0")/.."

rc=0
n=0
while IFS= read -r f; do
  dir="$(dirname "$f")"
  # Markdown inline links and images: [text](target) / ![alt](target). Strip an
  # optional #anchor and an optional "title" from the target before testing it.
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      http://*|https://*|mailto:*|'#'*) continue ;;
    esac
    target="${target%% *}"
    target="${target%%#*}"
    [ -n "$target" ] || continue
    n=$((n + 1))
    if [ ! -e "$dir/$target" ]; then
      echo "FAIL $f -> $target (no such file)"
      rc=1
    fi
  done < <(grep -o '\[[^][]*\]([^()]*)' "$f" | sed 's/^\[[^][]*\](//; s/)$//')
done < <(find docs -type f -name '*.md' | sort)

if [ "$rc" -eq 0 ]; then
  echo "ok: $n relative links under docs/ all resolve"
fi
exit $rc
