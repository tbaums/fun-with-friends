#!/usr/bin/env bash
# #719: refuse a binary that bakes in a path to its own checkout's prompts or
# scripts. `env!("CARGO_MANIFEST_DIR")` fixes the build tree's path at compile
# time, so a release asset built on a runner looks for
# /home/runner/work/…/one/prompts on every other host, and every seat job fails
# with `No such file or directory` (v1.0.26). The prompts and scripts are
# embedded now; this keeps it that way.
#
#   baked-paths-check.sh <binary> <checkout-root> [<host-prefix>...]
#
# Exit 1 if the binary contains <checkout-root>/…prompts or
# <checkout-root>/…scripts, 0 if it does not, 2 on bad arguments.
#
# #727: each optional <host-prefix> (a release build passes the runner's HOME)
# must not appear at all, followed by `/`. A release build remaps the toolchain,
# registry and checkout paths (`--remap-path-prefix`), so any path left under
# the build host's home is a leak of its layout. Debug builds in one-ci.yml are
# not remapped and do not pass a prefix.
set -euo pipefail
if [ $# -lt 2 ]; then
  echo "usage: $0 <binary> <checkout-root> [<host-prefix>...]" >&2
  exit 2
fi
bin=$1
root=${2%/}
shift 2
if [ ! -f "$bin" ] || [ -z "$root" ]; then
  echo "baked-paths-check: no binary at '$bin', or an empty checkout root" >&2
  exit 2
fi
# The root is matched literally; what follows it may be any path characters,
# so `<root>/one/../prompts` and `<root>/one/scripts/seat-up.sh` both count.
re=$(printf '%s' "$root" | sed 's/[][\.*^$+?(){}|]/\\&/g')
hits=$(LC_ALL=C grep -aoE "$re/[A-Za-z0-9._/-]*(prompts|scripts)" "$bin" | sort -u || true)
if [ -n "$hits" ]; then
  echo "FAIL $bin bakes in checkout paths under $root:"
  printf '%s\n' "$hits" | sed 's/^/  /'
  exit 1
fi
echo "ok   $bin bakes in no path under $root/…/{prompts,scripts}"
fail=0
for prefix in "$@"; do
  prefix=${prefix%/}
  if [ -z "$prefix" ]; then
    echo "baked-paths-check: an empty host prefix would match everything" >&2
    exit 2
  fi
  re=$(printf '%s' "$prefix" | sed 's/[][\.*^$+?(){}|]/\\&/g')
  hits=$(LC_ALL=C grep -aoE "$re/[A-Za-z0-9._/-]*" "$bin" | sort | uniq -c | sort -rn | head -20 || true)
  if [ -n "$hits" ]; then
    echo "FAIL $bin bakes in host paths under $prefix/ (count, path; first 20):"
    printf '%s\n' "$hits" | sed 's/^/  /'
    fail=1
  else
    echo "ok   $bin bakes in no path under $prefix/"
  fi
done
exit $fail
