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

# #727: host prefixes. A release build passes the runner's HOME; any path
# under it fails, wherever it sits in the binary. The prefix has a `.` and a
# `+` so an unescaped one is caught by the lookalike, and the registry fixture
# is padded past 4 MiB so a checker that scans only a prefix misses it.
host=/home/run.ner+x
expect_host() { # want, name, prefix...
  local want=$1 name=$2 rc=0
  shift 2
  "$check" "$tmp/$name" "$root" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   $name ($*): exit $rc"
  else echo "FAIL $name ($*): exit $rc, want $want"; fail=1; fi
}
fixture host-rustup "$host/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/core/src/panic.rs"
{ head -c 4194304 /dev/zero; printf '\377%s\000' "$host/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/ureq-2.12.1/src/lib.rs"; } >"$tmp/host-registry-deep"
fixture host-lookalike "/home/runXnerrx/.cargo/registry/src/x.rs"
fixture host-remapped "/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/ureq-2.12.1/src/lib.rs"
expect_host 1 host-rustup "$host"
expect_host 1 host-registry-deep "$host"
expect_host 1 host-registry-deep /elsewhere "$host/"
expect_host 0 host-lookalike "$host"
expect_host 0 host-remapped "$host"
# without a prefix the checker stays #719's: a host path is not a checkout path
expect_host 0 host-rustup
expect_host 2 host-rustup ""
exit $fail
