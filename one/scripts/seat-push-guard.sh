#!/usr/bin/env bash
# The seat's push policy, as one testable program (#621).
#
#   usage: seat-push-guard.sh              # hook mode: PreToolUse JSON on stdin
#          seat-push-guard.sh '<command>'  # judge one command line (tests)
#
# Exit 0 allows the Bash call; exit 2 denies it and the reason on stderr goes
# back to the seat — the PreToolUse contract. `seat-up.sh` installs this into
# the floor's `.claude/` and names it as the hook, so the policy lives here and
# not inside a JSON string.
#
# Why a program and not a glob: `permissions.deny` globs and the old hook's
# `case` patterns matched `--force` as a *substring*, so they also refused
# `--force-with-lease=<ref>:<sha>` — the compare-and-swap the rework prompt
# instructs and the only way a rebased branch can be delivered. Every rework
# that rebased ended in a refusal (#621). A token is the real word boundary,
# so each rule below judges whole arguments.
set -uo pipefail

deny() {
  echo "fwf: $*" >&2
  exit 2
}

if [ "$#" -gt 0 ]; then
  cmd="$1"
else
  # jq reads the whole of stdin, so a pretty-printed payload is read too.
  cmd="$(jq -r '.tool_input.command // ""')"
fi

# Nothing here is about anything but pushing.
[[ $cmd == *push* ]] || exit 0

# Protected branches: the promoter's path, never a seat's. Unchanged.
[[ $cmd =~ push.*(staging|main) ]] &&
  deny "pushes to staging/main are denied for seats"

# Globbing off: the loop below must see the words the seat typed, not what the
# working directory happens to contain.
set -f
for tok in $cmd; do
  # A bare force (`--force`, `--force=…`, `-f`) overwrites whatever is
  # upstream, including work this seat never saw.
  [[ $tok =~ ^--force(=.*)?$ ]] &&
    deny "bare --force is denied; use --force-with-lease=<ref>:<sha> (the lease is the safety)"
  [[ $tok =~ ^-f$ ]] &&
    deny "-f is a bare force; use --force-with-lease=<ref>:<sha>"
  # `+refspec` is the same force spelled in the refspec.
  [[ $tok =~ ^\+ ]] &&
    deny "a +refspec force is denied; use --force-with-lease=<ref>:<sha>"
  # A lease with no expected sha is a force with extra steps: git fills the
  # expectation in from its own remote-tracking ref, which the seat just
  # fetched. Only the explicit form states what it believes it is replacing.
  if [[ $tok =~ ^--force-with-lease ]]; then
    [[ $tok =~ ^--force-with-lease=[^:[:space:]]+:[^:[:space:]]+$ ]] ||
      deny "an unqualified lease is a force with extra steps; use --force-with-lease=<ref>:<sha>, naming the head you expect to replace"
  fi
done
exit 0
