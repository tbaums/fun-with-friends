#!/usr/bin/env bash
# #719: refuse a binary that bakes in a path to its own checkout's prompts or
# scripts. `env!("CARGO_MANIFEST_DIR")` fixes the build tree's path at compile
# time, so a release asset built on a runner looks for
# /home/runner/work/…/one/prompts on every other host, and every seat job fails
# with `No such file or directory` (v1.0.26). The prompts and scripts are
# embedded now; this keeps it that way.
#
#   baked-paths-check.sh <binary> <checkout-root>
#
# Exit 1 if the binary contains <checkout-root>/…prompts or
# <checkout-root>/…scripts, 0 if it does not, 2 on bad arguments.
set -euo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 <binary> <checkout-root>" >&2
  exit 2
fi
bin=$1
root=${2%/}
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
