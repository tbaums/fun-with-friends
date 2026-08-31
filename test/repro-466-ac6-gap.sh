#!/usr/bin/env bash
# QA repro for PR #474 (issue #466): AC6's regression grep excludes ANY line
# containing the literal string "drun()" -- including drun()'s own function
# definition, whether or not that definition still routes through
# fwf_test_isolated_exec. This means AC6 cannot catch the one regression it
# exists to prevent: someone stripping the guard from the real call site
# (drun()) that #466's incident actually named.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Reproduce the exact pre-fix drun() shape (env -i, no fwf_test_isolated_exec
# wrapper, no TMUX_TMPDIR re-injection) -- this is the #466 vulnerability.
sed \
  -e 's/^drun() { fwf_test_isolated_exec env -i HOME="\$TMP\/dhome" PATH="\$DBIN:\/usr\/bin:\/bin" TMPDIR="\$TMP" TMUX_TMPDIR="\$TMUX_TMPDIR" FWF_PROFILE=example "\$@" bash "\$ROOT\/fwf-dash.sh" 2>&1; }$/drun() { env -i HOME="$TMP\/dhome" PATH="$DBIN:\/usr\/bin:\/bin" TMPDIR="$TMP" FWF_PROFILE=example "$@" bash "$ROOT\/fwf-dash.sh" 2>\&1; }/' \
  "$ROOT/test/run.sh" > "$TMP/reverted-run.sh"

if ! grep -q '^drun() { env -i HOME="\$TMP/dhome"' "$TMP/reverted-run.sh"; then
  echo "FAIL setup: sed did not actually revert drun() to the pre-fix shape -- repro is not testing what it claims" >&2
  exit 1
fi

# This is AC6's own check, verbatim, run against the reverted file.
UNGUARDED="$(grep -n 'env -i' "$TMP/reverted-run.sh" | grep -v 'fwf_test_isolated_exec\|^[0-9]*:#\|F466_\|drun()' | wc -l | tr -d ' ')"

echo "AC6 grep result against a drun() with its #466 guard stripped: $UNGUARDED"
if [ "$UNGUARDED" != "0" ]; then
  echo "ok   AC6's regression grep correctly flagged the stripped guard (unexpected -- gap may already be fixed)"
  exit 0
fi

echo "FAIL AC6's regression grep reports 0 unguarded 'env -i' sites even though drun() -- the one real call site #466's incident named -- has had its fwf_test_isolated_exec guard stripped." >&2
echo "     Cause: the exclusion pattern 'drun()' in AC6's grep -v matches the function-definition line by NAME, not by whether it's actually wrapped, so it blind-spots exactly the site the fix must protect." >&2
echo "     Confirmed: none of drun()'s own callers (D1-D8, the fwf-dash resolver tests) exercise tmux, so no other assertion in the suite would catch this regression either." >&2
exit 1
