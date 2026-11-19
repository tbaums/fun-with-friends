#!/usr/bin/env bash
# Proves baked-paths-check.sh can fail (#719, QA on #729). CI otherwise only
# ever runs the checker on a clean binary, so one that always said `ok` would
# stay green. Each fixture is binary data — NUL and non-UTF-8 bytes around the
# string, as in a real executable — so a checker that lost `grep -a` misses
# them under GNU grep, which reports binary matches on stderr only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/baked-paths-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A root with regex metacharacters, so an unescaped `.` or `+` is caught too.
root=/home/run.ner/work/f+f/f+f
fail=0

fixture() { # name, string to bury in binary bytes
  printf '\177ELF\002\001\000\000\377\376%s\000\200\201tail\000' "$2" >"$tmp/$1"
}
expect() { # want, name
  local rc=0
  "$check" "$tmp/$2" "$root" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$1" ]; then echo "ok   $2: exit $rc"
  else echo "FAIL $2: exit $rc, want $1"; fail=1; fi
}

fixture up-prompts "$root/one/../prompts"
fixture one-prompts "$root/one/prompts"
fixture root-prompts "$root/prompts/dev/impl-job.md"
fixture one-scripts "$root/one/scripts/seat-up.sh"
fixture run-together "x$root/one/promptsfwfFWF_ALLOW_STALE"
for f in up-prompts one-prompts root-prompts one-scripts run-together; do expect 1 "$f"; done

# Clean: the root with no prompts/scripts after it, another root's prompts, and
# a lookalike root that only an unescaped `.`/`+` would match.
fixture clean-target "$root/one/target/debug/deps/libfoo.rlib"
fixture clean-other-root "/home/runner/work/other/other/one/prompts"
fixture clean-lookalike "/home/runXner/work/fff/fff/one/prompts"
for f in clean-target clean-other-root clean-lookalike; do expect 0 "$f"; done

rc=0
"$check" "$tmp/up-prompts" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then echo "ok   usage: exit 2"; else echo "FAIL usage: exit $rc, want 2"; fail=1; fi
exit $fail
