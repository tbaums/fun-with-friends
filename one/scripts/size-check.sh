#!/usr/bin/env bash
# T-30: no source file over 1,000 lines. Three files predate the rule; they are
# listed in size-baseline.txt with their ceiling and may only shrink. Anything
# else over the limit fails. Run from the repo root or from one/.
set -euo pipefail
cd "$(dirname "$0")/.."
LIMIT=1000
rc=0
while IFS= read -r f; do
  n=$(wc -l <"$f" | tr -d ' ')
  cap=$(awk -v f="$f" '$1==f {print $2}' scripts/size-baseline.txt)
  if [ -n "$cap" ]; then
    if [ "$n" -gt "$cap" ]; then echo "FAIL $f: $n lines > baseline ceiling $cap (split it, do not grow it)"; rc=1
    else echo "ok   $f: $n (grandfathered, ceiling $cap)"; fi
  elif [ "$n" -gt "$LIMIT" ]; then echo "FAIL $f: $n lines > $LIMIT"; rc=1
  else echo "ok   $f: $n"; fi
done < <(find src scripts prompts -type f \( -name '*.rs' -o -name '*.sh' -o -name '*.md' \) | sort)
exit $rc
