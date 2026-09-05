#!/usr/bin/env bash
# fwf-gate.sh — the shared guarded-launch helper (issue #123): the ONE
# entrypoint every tick-driven gate/e2e launcher (qa PR re-review gate, impl
# gate, conductor promotion-e2e) routes through, so the gate-pileup's two
# root causes are fixed exactly once, not per-role/per-template:
#
#   (A) per-role single-flight lock (fwf_gate_lock_acquire/release, lib.sh) —
#       a role whose OWN prior gate is still in flight does not launch a
#       second; it skips this tick. Fail-closed: indeterminate liveness also
#       skips, never stacks. A wedged-but-alive holder past the max-run
#       ceiling is reaped as an anomaly (see lib.sh for the reasoning).
#   (B) hermetic gate under CROSS-agent concurrency — with --e2e, additionally
#       takes the existing floor-wide e2e lock (fwf_e2e_lock_acquire/release,
#       issue #65). That lock is the documented serialize-lock FALLBACK for a
#       harness whose ports are fixed and can't be made ephemeral cheaply
#       (profiles/example.sh's E2E_CMD contract). The fast per-commit
#       GATE_CMD path does not take --e2e: it isn't meant to share ports with
#       anything, so floor-wide serialization would only add a throughput
#       bottleneck with no hermeticity benefit.
#
# --cargo-build (issue #138 piece C) additionally bounds how many roles run a
# full cargo build SIMULTANEOUSLY, via a SEMAPHORE — not a mutex like the e2e
# lock: up to FWF_CARGO_BUILD_CONCURRENCY roles hold a build slot at once
# (fwf_cargo_build_slot_acquire/release, lib.sh), so N concurrent full builds
# no longer CPU/IO-thrash each other. Auto-appended by fwf_render whenever a
# profile's GATE_CMD/E2E_CMD contains "cargo" (see lib.sh) — a profile with no
# Rust suite never passes it and pays zero overhead.
#
# Usage: fwf gate <role> [--e2e] [--cargo-build] [--tip-cmd 'CMD'] -- <command> [args...]
#   <role>     the per-role lock key (e.g. impl2, qa2, conductor) — the
#              literal role tag used elsewhere (heartbeat path, etc).
#   --e2e      ALSO take a resource-keyed e2e lease (issue #205; was a single
#              floor-wide mutex, issue #65). Use for an E2E_CMD-class run;
#              omit for the fast GATE_CMD (see above). Exports FWF_E2E_PORT
#              and FWF_E2E_DATA_DIR into the wrapped command's environment
#              ONLY (never persisted elsewhere) -- a profile's E2E_CMD reads
#              those instead of hardcoding a port/data dir to actually get
#              concurrent lanes once FWF_E2E_MAX_LANES is raised above its
#              default of 1 (a strict no-op until then).
#   --e2e-spec FILE  (issue #494 AC5/AC6, repeatable) a SHORT lease: holds the
#              same lane an --e2e run would, but names specific spec file(s)
#              via FWF_E2E_SPEC (newline-joined, same gated-process-only
#              export contract as FWF_E2E_PORT/FWF_E2E_DATA_DIR above) so a
#              profile's E2E_CMD can run just those instead of the full
#              suite. This flag is a pure pass-through -- fwf-gate.sh does
#              not shorten the lease itself; it is the consumer choosing to
#              run less that makes the hold shorter. Requires --e2e.
#   --cargo-build  ALSO take a cargo-build concurrency slot (see above).
#   --tip-cmd  Make this gate TIP-triggered, not just timer-triggered (issue
#              #202): CMD is evaluated (via `eval`, in the caller's cwd) to
#              read the value of whatever ref this gate cares about (e.g.
#              `git rev-parse origin/staging`), BEFORE the lock is acquired.
#              If that value matches the last COMPLETED gate's recorded value
#              for this role, the lock is never taken and this run exits
#              EX_SKIPPED — a timer tick that finds nothing new to gate costs
#              nothing. CMD is re-evaluated after the wrapped command exits;
#              if the value moved DURING the run, the verdict is for a
#              superseded tip and must never read as promotable, so this run
#              instead exits EX_STALE (regardless of the wrapped command's own
#              rc) and the run is recorded as stale, not green/red. Otherwise
#              the wrapped command's rc is recorded as this tip's verdict
#              (green/red) so an unchanged tip is skipped on the NEXT tick
#              too. Set FWF_GATE_FORCE=1 to force a re-run of an unchanged tip
#              (the "explicit resume" escape hatch). State lives under
#              fwf_gate_tip_marker_path (lib.sh) — persisted by this script,
#              never by a role's memory.
#   --tip-ancestry  Ruling from issue #202/#254: "the ref changed" is the
#              wrong question — a completed, valid verdict must not be
#              discarded just because the tip moved, ONLY because what was
#              gated is no longer in the promotable history. Requires
#              --tip-cmd, and the two values MUST be commit-ish (this runs
#              `git merge-base --is-ancestor`, so a non-git --tip-cmd value —
#              a content hash, a checksum — makes the ancestry call error,
#              which (below) fails closed to STALE forever; --tip-ancestry is
#              only for a git-ref --tip-cmd). When the tip moved during the
#              run: if the BEFORE value is still an ancestor of the AFTER
#              value (the ordinary case — someone merged on top), the verdict
#              stands and is recorded green/red as the wrapped command
#              returned — newer commits ride the next cycle. If it is NOT an
#              ancestor (force-push, rebase, history rewritten) or ancestry
#              could not be determined (shallow clone, missing objects), this
#              still fails to STALE/76 exactly as without the flag. Without
#              this flag: ANY tip move is STALE regardless of ancestry — the
#              pre-#254 behaviour, kept as the default so an OLD rendered
#              prompt (no flag) degrades to "wasteful but safe", never to
#              "promotes a SHA the gate never fully verdicted". A caller that
#              relaxes this MUST ALSO pin its promote step to the recorded
#              tip's literal hash, never a re-resolved ref (issue #254 AC
#              (d)+(e)) — the ancestry test only makes a fixed ref usable, the
#              literal-hash promote is what actually uses it safely.
#   <command>  exec'd directly via "$@" after the lock(s) are held — no extra
#              shell re-parsing, so a multi-command GATE_CMD string must be
#              passed through `bash -c '...'` by the caller (that's exactly
#              how __GATE__/__E2E__/__PROMOTE_GATE__ render it — see
#              lib.sh's fwf_render).
#
# PROMOTE-TREE PRECONDITION (issue #278): when <role> is the literal
# "conductor" (never keyed on --e2e, which implementers also pass — see the
# check itself for why), this refuses UNLESS the caller's own worktree is a
# DETACHED HEAD at exactly origin/$STAGING_BRANCH's current SHA — the tree a
# promote gate is supposed to be asserting about. A non-conductor role, or a
# conductor whose worktree is already correctly positioned, is unaffected
# and silent. Exit 1 on refusal; not a new verdict class (AC e), just a
# precondition before the suite is ever launched.
#
# Exit codes: the wrapped command's own exit code on a real run; 75 (the
# traditional EX_TEMPFAIL) when this tick was SKIPPED — a prior gate for this
# role is still running, a --e2e run found the floor-wide lock busy, a
# --cargo-build run found every build slot busy past its timeout, or
# --tip-cmd found the watched ref unchanged since the last completed gate; 76
# (EX_STALE) when --tip-cmd detected the watched ref moved DURING the run —
# a real result exists but is for a superseded tip and must not be treated as
# promotable. Callers MUST treat 75 as "nothing to report, try again next
# tick" and 76 as "a verdict exists but don't act on it, the next tick will
# gate the new tip" — never as a gate failure; an agent that greps for a
# green/red gate result should check for both exit codes first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- issue #156 hole #1: kill-safe process-group ownership -------------------
# Become a process-group LEADER exactly once (guarded by a sentinel), BEFORE any
# lock/admission work, so the cargo child launched below inherits our group. A
# kill then takes cargo down WITH us — trappable signals via the trap installed
# further down, and an untrappable SIGKILL (tmux `respawn-pane -k`) via the
# memory-admission reaper, which SIGKILLs the stamped group when it drops our
# now-dead reservation. Without this, a killed gate ORPHANS a multi-GB cargo
# (reparented to PID1, still building) while its lock auto-releases, and the
# next agent stacks a SECOND build on top of the orphan — the failed prototype's
# fatal flaw. macOS has no setsid(1); /usr/bin/perl (present on macOS and Linux)
# does setpgid then re-execs the original argv. FAIL-CLOSED when the leader is
# REQUIRED but perl is absent — never silently run ungrouped.
# issue #195 (nested-gate fix): `_FWF_GATE_IS_PGLEADER` alone is not a safe
# guard here -- it is a plain exported env var, so a NESTED fwf-gate.sh
# invocation (e.g. this very script, run for a DIFFERENT role, from inside
# a wrapped command that is itself already running under an outer `fwf
# gate` -- exactly how test/run.sh is always invoked) inherits it from the
# ancestor and wrongly concludes IT is already its own group leader,
# silently skipping setpgid/re-exec and staying in the ANCESTOR's group.
# That breaks every pgid-based guarantee below (teardown isolation, the
# self-vs-reused-pgid disambiguation in _fwf_kill_orphan_group) for the
# nested call. Pairing the flag with the PID that actually set it makes
# the check a true self-test: exec() preserves PID across both hops
# (perl's own exec, then perl's exec of "$0" "$@"), so "$$" is identical
# before and after a genuine self-re-exec, but differs for any inherited-
# from-ancestor case (a different, child PID) -- forcing every distinct
# invocation to redo its own setpgid, nested or not.
if [ "${FWF_GATE_PGLEADER_ENABLE:-1}" = 1 ] && [ "${_FWF_GATE_PGLEADER_PID:-}" != "$$" ]; then
  if command -v perl >/dev/null 2>&1; then
    export _FWF_GATE_IS_PGLEADER=1
    export _FWF_GATE_PGLEADER_PID="$$"
    exec perl -e 'use POSIX qw(setpgid); setpgid(0,0) or die "setpgid: $!"; exec @ARGV or die "exec: $!"' -- "$0" "$@"
  else
    echo "fwf gate: FWF_GATE_PGLEADER_ENABLE=1 but perl is absent — refusing to gate ungrouped (set FWF_GATE_PGLEADER_ENABLE=0 to override)" >&2
    exit 1
  fi
fi

# issue #276 AC4: name which tree this gate binary itself lives in, in every
# run's own output. #276's incident cost 4h45m because a wrapper/tree
# mismatch (the INSTALLED gate silently gating a DIFFERENT, already-fixed
# checkout) was invisible until a /proc/<pid>/environ read on the live
# process settled it. Unconditional and purely factual -- not a "mismatch
# detected" heuristic, which would either miss cases or false-positive on
# every ordinary `fwf gate <role> -- ...` self-verification call (those
# deliberately run the shared installed binary against a DIFFERENT
# worktree, by design, and that is correct, not a defect to flag).
echo "fwf-gate.sh: running from $DIR" >&2

# issue #277 AC(a1)/(b): when THIS caller's own worktree carries a
# fwf-gate.sh/lib.sh that differs in CONTENT from the copy actually
# executing above ($DIR, the installed gate), hint the by-path remedy.
# Deliberately NOT "does $DIR differ from the caller's cwd" -- an
# implementer's/qa's own `fwf gate <role> -- ...` self-verification ALWAYS
# runs the installed binary against a DIFFERENT worktree, by design (see
# #276 AC4's own note above); that is the ordinary, correct case, not the
# failure mode this guards. Only a genuine CONTENT difference in the gate
# path itself means the installed gate cannot validate a fix to itself --
# this ticket's whole point (a gate defect can't reach release without
# passing the gate it's fixing) -- and that is the discriminating test
# AC(b) requires: a role changing the gate path sees this; a role changing
# anything else does not.
_fwf_gate_wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$_fwf_gate_wt" ] && [ -f "$_fwf_gate_wt/fwf-gate.sh" ] \
   && { ! cmp -s "$DIR/fwf-gate.sh" "$_fwf_gate_wt/fwf-gate.sh" 2>/dev/null \
        || { [ -f "$_fwf_gate_wt/lib.sh" ] && ! cmp -s "$DIR/lib.sh" "$_fwf_gate_wt/lib.sh" 2>/dev/null; }; }; then
  # issue #277 AC(c): the by-path invocation shares the SAME floor-wide
  # E2E_LOCK (config.sh, $FWF_RUN-derived) so it is safety-equivalent --
  # PROVIDED your diff does not touch the locking path itself
  # (fwf_gate_lock_acquire / fwf_e2e_lock_acquire, lib.sh). If it does,
  # that equivalence is exactly what may be broken, so it is stated here
  # conditionally, never flatly: verify the locks are actually held
  # (state/<profile>/gate-lock/<role>/owner and $FWF_RUN/e2e.lock/owner
  # name this pid) before trusting the result.
  echo "fwf-gate.sh: this worktree's fwf-gate.sh/lib.sh differ from the installed copy at $DIR (issue #277) -- a defect in the gate path itself cannot be validated through the installed gate, since the wrapper doing the validating is the pre-fix release. Run it by path instead: bash \"$_fwf_gate_wt/fwf-gate.sh\" <role> ... -- safety-equivalent PROVIDED your diff does not touch the locking path (fwf_gate_lock_acquire / fwf_e2e_lock_acquire in lib.sh); if it does, verify state/<profile>/gate-lock/<role>/owner and \$FWF_RUN/e2e.lock/owner name this pid before trusting the result." >&2
fi

# --- issue #175: do not leak OUR profile resolution into the wrapped command --
# Sourcing lib.sh below resolves a profile — we need it, for the lock paths —
# and in doing so SETS FWF_PROFILE/FWF_PAIRS/FWF_REPO in this shell. Those
# values are OURS, not the caller's. Running the wrapped command with them
# still set hands it an ambient profile it never asked for.
#
# That is not cosmetic: test/run.sh builds its own throwaway fixtures, and an
# inherited FWF_REPO/FWF_PROFILE overrides them — measured at 41 otherwise-
# passing tests going RED. Because the gate always runs inside a pane where
# those ARE set, the gate was false-RED on EVERY cycle, so no implementer
# could ever reach green. Correct values leak just as harmfully as wrong ones;
# this is about provenance, not validity.
#
# Snapshot the caller's real environment HERE, before the source, and restore
# it verbatim before handing control to the wrapped command.
_fwf_gate_had_profile=0; _fwf_gate_had_pairs=0; _fwf_gate_had_repo=0
_fwf_gate_old_profile=""; _fwf_gate_old_pairs=""; _fwf_gate_old_repo=""
if [ -n "${FWF_PROFILE+x}" ]; then _fwf_gate_had_profile=1; _fwf_gate_old_profile="$FWF_PROFILE"; fi
if [ -n "${FWF_PAIRS+x}" ];   then _fwf_gate_had_pairs=1;   _fwf_gate_old_pairs="$FWF_PAIRS"; fi
if [ -n "${FWF_REPO+x}" ];    then _fwf_gate_had_repo=1;    _fwf_gate_old_repo="$FWF_REPO"; fi

# Restore the caller's environment exactly: a var the caller had stays with its
# ORIGINAL value; a var the caller did not have is unset, not blanked (an empty
# FWF_PROFILE is not the same as an absent one to a ${VAR:-default} reader).
_fwf_gate_env_restore() {
  if [ "$_fwf_gate_had_profile" = 1 ]; then export FWF_PROFILE="$_fwf_gate_old_profile"; else unset FWF_PROFILE; fi
  if [ "$_fwf_gate_had_pairs" = 1 ];   then export FWF_PAIRS="$_fwf_gate_old_pairs";     else unset FWF_PAIRS; fi
  if [ "$_fwf_gate_had_repo" = 1 ];    then export FWF_REPO="$_fwf_gate_old_repo";       else unset FWF_REPO; fi
}

# shellcheck source=lib.sh
source "$DIR/lib.sh"

EX_SKIPPED=75
EX_STALE=76

usage() { echo "usage: fwf gate <role> [--e2e] [--e2e-spec FILE]... [--cargo-build] [--tip-cmd 'CMD'] [--tip-ancestry] -- <command> [args...]" >&2; }

role="${1:-}"
[ -n "$role" ] || { usage; exit 1; }
shift

# issue #426: a role deep in one or several back-to-back gate cycles is
# unambiguously alive and working, but its own loop only bumps
# state/<profile>/tick/<role> at STEP 0 of a FRESH cycle -- a role that
# keeps re-launching/retrying gates without a cycle in between (measured:
# several roles' ticks froze for 1.5-6h while they provably pushed commits
# and merged PRs the whole time) leaves that file looking dead for hours.
# Bumping it here too, at the START of every gate attempt -- including one
# that's about to be SKIPPED (an unchanged --tip-cmd, or a busy per-role
# lock, both below) -- makes tick freshness track ACTUAL WORK rather than
# "did the agent's own loop restart recently", the same structural-fix
# pattern #156's own "hole #1" used: move the guarantee out of per-caller
# discipline and into the shared tooling every caller already goes
# through. Best-effort and silenced (`>/dev/null`): a tick-bump failure
# (e.g. an unwritable state dir) must never abort a real gate run over a
# liveness nicety.
fwf_tick_bump "$role" >/dev/null 2>&1 || true

want_e2e=0
want_cargo_build=0
tip_cmd=""
want_tip_ancestry=0
e2e_specs=()
while :; do
  case "${1:-}" in
    --e2e) want_e2e=1; shift ;;
    # issue #494 (scope item 1): a short lease. Repeatable so a caller can
    # name several specs in one run; each holds the SAME lane the full
    # suite would, just for however long the consumer's own E2E_CMD takes
    # to run only these specs instead of everything. This flag is a pure
    # pass-through (FWF_E2E_SPEC below) -- fwf-gate.sh itself does not know
    # what a "spec" is for any given profile's E2E_CMD, so it never
    # shortens the lease itself; the consumer's own choice to run less is
    # what makes AC5's hold-duration claim true.
    --e2e-spec) [ $# -ge 2 ] || { usage; exit 1; }; e2e_specs+=("$2"); shift 2 ;;
    --cargo-build) want_cargo_build=1; shift ;;
    --tip-cmd) [ $# -ge 2 ] || { usage; exit 1; }; tip_cmd="$2"; shift 2 ;;
    --tip-ancestry) want_tip_ancestry=1; shift ;;
    *) break ;;
  esac
done
if [ "${#e2e_specs[@]}" -gt 0 ] && [ "$want_e2e" != 1 ]; then
  echo "fwf gate: --e2e-spec requires --e2e" >&2
  usage; exit 1
fi

[ "${1:-}" = "--" ] || { usage; exit 1; }
shift
[ $# -gt 0 ] || { echo "fwf gate: no command given after --" >&2; usage; exit 1; }

# issue #278 (AC a): the PROMOTE gate must run against the exact tree it
# would advance, or a promote decision rests on a suite run against a stale
# SHA with nothing noticing (measured: a conductor worktree left on a local
# `integration` branch, five commits behind the `staging` it was told to
# check out). Keyed on the literal role tag "conductor", never on --e2e —
# `--e2e` is not the conductor's alone: implementer.tmpl also passes it for
# an impl's own e2e self-verification, run FROM A FEATURE BRANCH by design
# (AC d2), and that population must never trip this. A literal role-tag
# check is fine (lib.sh:260's FWF_SEAT_ROLES already treats role tags as
# literals); the target REF must not be — it is derived from $STAGING_BRANCH
# (lib/profile.sh), the same variable __PROMOTE_GATE__'s own rendering uses
# (lib.sh:970), never a hardcoded "origin/staging" (a second floor with a
# differently-named staging branch is measured in the ticket). Checked
# BEFORE the lock is taken, same reasoning as --tip-cmd below: a gate that
# is going to refuse should never contend for it first.
if [ "$role" = conductor ]; then
  _fwf278_target_sha="$(git rev-parse "origin/$STAGING_BRANCH" 2>/dev/null)" || {
    echo "fwf gate: could not resolve origin/$STAGING_BRANCH — refusing to guess the promote target (issue #278)" >&2
    exit 1
  }
  _fwf278_head_sha="$(git rev-parse HEAD 2>/dev/null)" || {
    echo "fwf gate: could not resolve this worktree's HEAD — refusing to guess the promote target (issue #278)" >&2
    exit 1
  }
  # AC (d): a detached HEAD at the correct SHA is the normal, intended
  # state and must pass with NO output — a check that speaks on the happy
  # path becomes noise and gets tuned out (issue #277 (b)'s same argument).
  if ! { ! git symbolic-ref -q HEAD >/dev/null 2>&1 && [ "$_fwf278_head_sha" = "$_fwf278_target_sha" ]; }; then
    echo "fwf gate: promote gate is not at the ref it would advance — this worktree is at $_fwf278_head_sha, origin/$STAGING_BRANCH is $_fwf278_target_sha. Refusing to gate the wrong tree (issue #278)." >&2
    exit 1
  fi
  unset _fwf278_target_sha _fwf278_head_sha
fi

# --tip-cmd (issue #202): decide BEFORE the lock is ever taken, so a tick that
# finds nothing new to gate never contends for it.
tip_before=""
if [ -n "$tip_cmd" ]; then
  tip_before="$(eval "$tip_cmd")" || { echo "fwf gate: --tip-cmd failed to resolve a value — refusing to skip on an unknown tip" >&2; exit 1; }
  if verdict="$(fwf_gate_tip_unchanged "$role" "$tip_before")"; then
    echo "fwf gate: no re-gate: tip unchanged at $tip_before, last verdict $verdict" >&2
    exit "$EX_SKIPPED"
  fi
fi

# issue #298: FWF_GATE_FORCE's own decision (fwf_gate_tip_unchanged, above)
# is now made -- unset it here, in THIS process, before anything below can
# hand it on. Env vars inherit transitively: left set, a
# `FWF_GATE_FORCE=1 fwf gate <role> --tip-cmd ... -- bash -c "bash
# test/run.sh"` leaks into every subprocess the wrapped command forks,
# including this repo's own nested `fwf-gate.sh --tip-cmd` invocations
# under test/run.sh's #202 section -- which then force past the very
# unchanged-tip skip those fixtures exist to assert, producing false
# failures unrelated to whatever the outer force-resume was actually for.
unset FWF_GATE_FORCE

fwf_gate_lock_acquire "$role" || exit "$EX_SKIPPED"
gate_lock_held=1   # issue #156 BLOCKER 2: tracked so the release trap never rm's

e2e_held=0
e2e_lane=""
e2e_port=""
e2e_data_dir=""
cargo_build_slot=""
mem_token=""
# issue #195: the wrapped command's OWN process group, once it's launched
# (see the exec further down) -- separate from fwf-gate.sh's own pgleader
# group specifically so it can be torn down BEFORE any lock is released,
# while fwf-gate.sh itself survives to actually release it. A named
# constant (not a literal) since the value is admittedly arbitrary.
FWF_GATE_TEARDOWN_GRACE_SECS="${FWF_GATE_TEARDOWN_GRACE_SECS:-5}"
wrapped_pgid=""
teardown_done=0
release_done=0

# issue #195 (AC d/g): when the wrapped command FAILS, translate a bind-
# collision signature in its own stderr into a lock-protocol error naming
# the occupying PID/command/port -- the damaging part of this bug is not
# the stuck process, it's that the failure reads like an environment
# problem (ports, Playwright, the box) rather than a lock-protocol
# violation. The occupant is looked up READ-ONLY (ss, falling back to
# lsof) and is NEVER killed (blast-radius constraint: a port busy but
# owned by something outside this lock's recorded group must never be
# touched, only named). An unmatched signature -- no such line in the
# captured stderr, or a port that can't be parsed out of it -- passes
# through silently: no message taxonomy, no guessing (signature matching
# is tool- and locale-dependent; that's an accepted residual, not
# something to engineer around).
# issue #499 AC3: behavioural port-binding assertion for e2e runs sharing
# the lease pool at N>=2. Deliberately NOT a string check on E2E_CMD --
# _fwf_e2e_cmd_hardcoded_warn (lib.sh) is wrong in both directions (any
# 4-5 digit number anywhere trips it; `npm run e2e` that reads the env
# internally sails through) and stays advisory, rc 0 always, per GV review
# on #499. This polls the ALLOCATED port for an actual LISTEN socket while
# the wrapped command runs -- a consumer that never binds it (hardcoded its
# own port, or predates the env contract) is caught directly, deterministically,
# with no regex. At N=1 there is only ever one lane and this repo's own
# pre-#205 behavior already covered it; the check below is gated on N>=2 so
# it is a strict no-op at the shipped default (AC6).
_fwf_e2e_port_bound() { # $1=port -> rc 0 iff something is LISTENing on it
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | grep -q .
    return
  fi
  return 1
}

_fwf_gate_diagnose_port_collision() {
  local capture="$1" line port occ_raw occ_pid occ_cmd occ_args
  [ -f "$capture" ] || return 0
  line="$(grep -iE 'address already in use|EADDRINUSE' "$capture" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 0
  # A trailing ":<port>" is how every common runtime renders a bind
  # address (Node's EADDRINUSE, Python's OSError, Rust's std::net) --
  # the LAST such match on the matched line, so "0.0.0.0:3940" style
  # addresses win over an unrelated earlier number.
  port="$(printf '%s' "$line" | grep -oE ':[0-9]{2,5}([^0-9]|$)' | tail -1 | tr -dc '0-9')"
  [ -n "$port" ] || return 0
  occ_pid=""; occ_cmd=""; occ_args=""
  if command -v ss >/dev/null 2>&1; then
    occ_raw="$(ss -H -lptn "sport = :$port" 2>/dev/null | head -1)"
    occ_pid="$(printf '%s' "$occ_raw" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    occ_cmd="$(printf '%s' "$occ_raw" | grep -oE '\("[^"]+"' | head -1 | tr -d '("')"
  fi
  if [ -z "$occ_pid" ] && command -v lsof >/dev/null 2>&1; then
    occ_raw="$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P -F pc 2>/dev/null)"
    occ_pid="$(printf '%s' "$occ_raw" | grep '^p' | head -1 | cut -c2-)"
    occ_cmd="$(printf '%s' "$occ_raw" | grep '^c' | head -1 | cut -c2-)"
  fi
  # issue #337: prefer the occupant's FULL command line over the short name
  # ss/lsof report. On macOS `lsof -F c` yields the framework binary name
  # ("Python"), which tells an operator nothing about what is actually
  # holding the port; `ps -o args=` yields "... -m http.server 0 --bind ..."
  # on both platforms. Falls back to the ss/lsof name if ps says nothing.
  if [ -n "$occ_pid" ]; then
    occ_args="$(ps -o args= -p "$occ_pid" 2>/dev/null | head -1)"
    [ -n "$occ_args" ] && occ_cmd="$occ_args"
  fi
  if [ -n "$occ_pid" ]; then
    echo "fwf gate: port $port is held by PID $occ_pid (${occ_cmd:-unknown}), which is NOT in this lock's recorded process group — this is a lock-protocol violation, not an environment problem (see issue #195). The occupant is left running; it is never killed by this diagnostic." >&2
  else
    echo "fwf gate: the wrapped command failed with what looks like a bind collision on port $port (Address already in use), but the occupant could not be identified (ss/lsof unavailable, or it already exited) — see issue #195" >&2
  fi
}

# issue #195: releasing the lock(s) while the server the wrapped command
# spawned is still holding its port is the exact incident this exists to
# fix ("the lock is a lie"). Graceful, not the old self-inclusive KILL:
# TERM the child group, give it FWF_GATE_TEARDOWN_GRACE_SECS to exit on its
# own (a wrapped command that traps TERM and lingers gets the hard path,
# named in the log), then KILL. A no-op if the group is already gone
# (`kill -0` fails) -- teardown never fails this run.
_fwf_gate_teardown_wrapped() {
  [ -n "$wrapped_pgid" ] || return 0
  local pgid="$wrapped_pgid"
  # Clear the handle up front, not at each exit point below -- a signal
  # arriving mid-grace-window re-enters via a DIFFERENT code path
  # (_fwf_gate_signal_cleanup), but teardown_done (the caller's guard)
  # only protects against THIS function running twice, not against
  # `pgid` still looking "live" to a caller that inspects it meanwhile.
  wrapped_pgid=""
  kill -0 -"$pgid" 2>/dev/null || return 0
  kill -TERM -"$pgid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt "$FWF_GATE_TEARDOWN_GRACE_SECS" ]; do
    kill -0 -"$pgid" 2>/dev/null || return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  echo "fwf gate: wrapped command's process group ($pgid) still alive after ${FWF_GATE_TEARDOWN_GRACE_SECS}s TERM grace — SIGKILL (issue #195)" >&2
  kill -KILL -"$pgid" 2>/dev/null
}

# Only release the #123 per-role gate lock if WE currently hold it. During the
# admission wait (below) we deliberately drop it and a sibling tick may take it;
# an unconditional release here would then rm the sibling's lock. gate_lock_held
# is the guard.
#
# issue #195: teardown THEN release, in that order — the ordering that makes
# the lock honest. Both idempotency guards matter: teardown_done stops a
# signal that arrives mid-grace-window from re-entering the teardown loop
# (this function is re-entrant-unsafe by construction, e.g. two overlapping
# TERM->KILL escalations); release_done stops a double-release if this ever
# runs twice in one process (it shouldn't, given the trap discipline below,
# but the ticket asks for idempotency to be an assertable property, not an
# assumption).
_fwf_gate_release() {
  if [ "$teardown_done" != 1 ]; then
    teardown_done=1
    _fwf_gate_teardown_wrapped
  fi
  [ "$release_done" = 1 ] && return 0
  release_done=1
  [ "$gate_lock_held" = 1 ] && fwf_gate_lock_release "$role"
  [ "$e2e_held" = 1 ] && fwf_e2e_lock_release "$e2e_lane"
  fwf_cargo_build_slot_release "$cargo_build_slot"
  fwf_mem_admit_release "$mem_token"
}
trap _fwf_gate_release EXIT

# issue #195 (supersedes #156 hole #1's self-inclusive kill): the wrapped
# command now runs in its OWN process group (see the exec further down), so
# a trappable signal to fwf-gate.sh no longer needs to take fwf-gate.sh's
# OWN group down to reach it — _fwf_gate_release's teardown already targets
# the child directly and completes BEFORE releasing the lock(s), which a
# self-inclusive KILL could never do (an unblockable signal to your own
# group ends you mid-cleanup, lock still held). An untrappable SIGKILL to
# fwf-gate.sh itself bypasses this trap entirely — that path is covered by
# acquire-side reconciliation on the NEXT acquire (lib.sh's
# _fwf_kill_orphan_group), not here.
_fwf_gate_signal_cleanup() {
  trap - TERM INT HUP EXIT
  _fwf_gate_release
  exit 143
}
trap _fwf_gate_signal_cleanup TERM INT HUP

if [ "$want_e2e" = 1 ]; then
  e2e_lease="$(fwf_e2e_lock_acquire "$role")" || { echo "fwf gate: e2e lock busy, deferring" >&2; exit "$EX_SKIPPED"; }
  e2e_held=1
  read -r e2e_lane e2e_port e2e_data_dir <<<"$e2e_lease"
fi

# issue #156 BLOCKER 2 (SHARED hand-off): run a BLOCKING resource wait WITHOUT
# holding the #123 per-role gate lock, then re-acquire it before the build — so
# the lock's max-run ceiling (FWF_GATE_LOCK_MAX_RUN_SECS=1800, measured from
# acquire) only ever times the ACTUAL build, never wait+build. Used by BOTH the
# default #138 slot-acquire path AND the admission path — ONE implementation, so
# the release/re-acquire hand-off can never again be applied to one path but not
# the other (the exact asymmetry an adversarial verifier caught: it had been
# bolted onto the admission path only, leaving the as-shipped DEFAULT path holding
# the gate lock across fwf_cargo_build_slot_acquire's up-to-900s wait).
#
#   $1     name of the shell var to receive the acquired handle (slot number /
#          mem token the wait command echoes) — set ONLY on success.
#   $2     name of the release fn (takes the handle) called to free the resource
#          if we WIN the wait but LOSE the gate-lock re-acquire — so a losing
#          re-acquirer never leaks its slot/token. Single-flight: the build starts
#          ONLY after a successful re-acquire, so two builds for one role never run
#          at once.
#   $3...  the blocking wait command + args; its stdout is the handle.
#
# Releases the gate lock and clears gate_lock_held FIRST, so the EXIT / TERM-INT-
# HUP trap (_fwf_gate_release) honors the not-held window and never rm's a
# sibling's lock that was taken while we waited. The re-acquire goes through
# fwf_gate_lock_acquire, which mkdir's a fresh lock dir and RE-STAMPS acquired=now,
# so the ceiling restarts at build start.
# rc 0 = holds the resource AND re-holds the gate lock (gate_lock_held=1), out var
#        set — caller proceeds to build. rc 1 = deferred: either the wait timed out
#        (the wait fn already logged why) or we lost the re-acquire (logged here) —
#        in both cases the resource is freed and gate_lock_held is 0; the caller
#        must exit EX_SKIPPED.
_fwf_gate_locked_wait() {
  local __outvar="$1" __release_fn="$2"; shift 2
  local __handle
  fwf_gate_lock_release "$role"; gate_lock_held=0
  __handle="$("$@")" || return 1
  # issue #156 BLOCKER 2 (signal window): publish the won handle to the caller's
  # outvar (cargo_build_slot / mem_token) BEFORE re-acquiring the gate lock,
  # mirroring the old direct-assignment admission code. A trappable TERM/INT/HUP
  # arriving DURING fwf_gate_lock_acquire (resource already won, lock not yet
  # re-held) then finds the handle in the global, so _fwf_gate_signal_cleanup ->
  # _fwf_gate_release clean-releases it in that window instead of reading an empty
  # global and leaking the won slot/token until the next dead-pid reap.
  printf -v "$__outvar" '%s' "$__handle"
  if ! fwf_gate_lock_acquire "$role"; then
    echo "fwf gate: resource acquired but the per-role gate lock was taken during the wait — deferring this tick" >&2
    # Free EXACTLY once: unpublish the handle FIRST so the EXIT/TERM-INT-HUP trap's
    # _fwf_gate_release cannot ALSO free it (a double-free could rm a slot/token a
    # sibling has since re-acquired), THEN release via the local handle. Single-
    # flight holds: the build below starts only on the return-0 path, after a
    # successful re-acquire.
    printf -v "$__outvar" ''
    "$__release_fn" "$__handle"
    return 1
  fi
  gate_lock_held=1
  return 0
}

# Bound how many roles run a full cargo build at once. Two mechanisms, mutually
# exclusive per invocation — BOTH now route their blocking wait through the SAME
# _fwf_gate_locked_wait hand-off, so hole #3's bound holds identically on either:
# the #123 gate lock is DROPPED across the wait and only ever times the build, so
# slot_wait + build < 1800 and admission_wait + build < 1800 by construction (the
# wait no longer counts against the 1800s max-run ceiling), and a 25min sibling
# build can never push a waiting gate past that ceiling into a reaper-induced
# double-build.
#
#   FWF_MEM_ADMIT_ENABLE=1 (issue #156, strategy b — the chosen design): gate the
#   START on MEASURED free RAM. fwf_mem_admit holds only a sub-second decision
#   mutex, NEVER a lock across the build. reserve_gb comes from the op-class (e2e
#   build vs plain build).
#
#   default (issue #138 piece C): the pre-existing concurrency SEMAPHORE. It is
#   held for the wrapped command, but — like the admission path — its up-to-900s
#   fwf_cargo_build_slot_acquire WAIT now happens with the #123 gate lock RELEASED,
#   so wait+build no longer trips the ceiling. Kept as the safe fallback until
#   criterion (3)'s real-box profiling calibrates the reservation sizes.
if [ "$want_cargo_build" = 1 ]; then
  if [ "${FWF_MEM_ADMIT_ENABLE:-0}" = 1 ]; then
    if [ "$want_e2e" = 1 ]; then reserve_gb="$FWF_MEM_RESERVE_E2E_GB"; else reserve_gb="$FWF_MEM_RESERVE_BUILD_GB"; fi
    _fwf_gate_locked_wait mem_token fwf_mem_admit_release fwf_mem_admit "$role" "$reserve_gb" \
      || exit "$EX_SKIPPED"
  else
    _fwf_gate_locked_wait cargo_build_slot fwf_cargo_build_slot_release fwf_cargo_build_slot_acquire "$role" \
      || exit "$EX_SKIPPED"
  fi
fi

# Per-worktree cargo target isolation (issue #151): guarantee this gate builds
# ONLY its own worktree's source — never a dir shared with a sibling worktree,
# which is the one mechanism that lets a gate go GREEN on code not on its branch.
# cwd here is the pane's worktree. No-op for non-Rust gates. Fail CLOSED: if
# isolation can't be established, do NOT run the command — a red gate is safe.
#
# issue #268: only let this configure sccache (RUSTC_WRAPPER/SCCACHE_DIR) when
# the wrapped command is actually going to build cargo (--cargo-build was
# passed, mirroring the concurrency semaphore's own gating above) — otherwise
# every ordinary gate invocation (e.g. `-- bash -c "bash test/run.sh"`, which
# is every role's routine fast gate) leaked sccache into an unrelated wrapped
# command's environment regardless of whether it touched cargo at all.
fwf_cargo_isolate "$want_cargo_build" || { echo "fwf gate: could not isolate cargo target — refusing to run gate" >&2; exit 1; }

# Hand the wrapped command the CALLER's environment, not ours (issue #175).
# Deliberately after fwf_cargo_isolate, which still needs our resolution.
_fwf_gate_env_restore

# issue #205 AC(g3): the allocation is exported to THE GATED COMMAND'S
# PROCESS ONLY -- set immediately before the exec, unset immediately after.
# Never tmux set-environment, never a pane-env file, never persisted
# anywhere (the #175/#182/#217 lesson this repo has been bitten by 3 times).
if [ "$want_e2e" = 1 ]; then
  export FWF_E2E_PORT="$e2e_port" FWF_E2E_DATA_DIR="$e2e_data_dir"
  # issue #494 AC5/AC6: newline-joined so a spec path containing a space
  # still round-trips (`IFS=$'\n' read -r -d '' -a specs <<<"$FWF_E2E_SPEC"`
  # on the consumer side) -- same "gated command's process only" contract
  # as the two vars above, unset alongside them.
  if [ "${#e2e_specs[@]}" -gt 0 ]; then
    export FWF_E2E_SPEC="$(printf '%s\n' "${e2e_specs[@]}")"
  fi
fi

# issue #499 AC3: arm the port-binding watcher ONLY at N>=2 -- see
# _fwf_e2e_port_bound above. Polls in the background for the DURATION of the
# wrapped command (killed once it exits, below) rather than a single check
# afterward, since a server that binds then shuts down cleanly before this
# script gets to look would otherwise read as non-compliant.
_fwf499_port_marker=""
_fwf499_watcher_pid=""
if [ "$want_e2e" = 1 ] && [ "${FWF_E2E_MAX_LANES:-1}" -ge 2 ] 2>/dev/null; then
  _fwf499_port_marker="$(mktemp 2>/dev/null || echo "$FWF_STATE_DIR/e2e-port-seen.$$")"
  rm -f "$_fwf499_port_marker"
  ( while true; do
      _fwf_e2e_port_bound "$e2e_port" && { : > "$_fwf499_port_marker"; break; }
      sleep 0.2
    done ) &
  _fwf499_watcher_pid=$!
fi

# issue #195 (AC d/g): tee the wrapped command's STDERR to a scratch file
# (via process substitution -- bash manages the reader, no manual FIFO/pid
# bookkeeping) so a FAILED run can be scanned for a bind-collision
# signature afterward, WITHOUT touching stdout at all and without
# buffering/reordering/swallowing anything live callers watch -- the tee
# writes through to the real stderr in the same instant it writes to the
# file. Only ever READ after the fact; never influences what streams live.
wrapped_err_capture="$(mktemp 2>/dev/null || echo "$FWF_STATE_DIR/gate-stderr.$$")"
# issue #227: also tee stdout to a scratch file, same live-passthrough-only
# contract as the stderr capture above -- read AFTER the run, only when a
# GATE_CASE_EXTRACTOR is declared, to drive the flake-vs-broken report below.
# Captured unconditionally (cheap) so the wrapped-command invocation itself
# never branches on whether an extractor happens to be configured.
wrapped_out_capture="$(mktemp 2>/dev/null || echo "$FWF_STATE_DIR/gate-stdout.$$")"

rc=0
if [ -n "${_FWF_GATE_IS_PGLEADER:-}" ] && command -v perl >/dev/null 2>&1; then
  # issue #195: run the wrapped command in its OWN process group, separate
  # from fwf-gate.sh's own (the outer pgleader re-exec at the top of this
  # file) -- setpgid(0,0) makes the perl child (then whatever it execs
  # into) a NEW group leader, its own pid becoming that group's pgid, so
  # _fwf_gate_teardown_wrapped can TERM/KILL just it without also ending
  # fwf-gate.sh before the lock(s) are released.
  perl -e 'use POSIX qw(setpgid); setpgid(0,0) or die "setpgid: $!"; exec @ARGV or die "exec: $!"' -- "$@" \
    > >(tee "$wrapped_out_capture") \
    2> >(tee "$wrapped_err_capture" >&2) &
  wrapped_pgid=$!
  # Re-stamp the lock(s)' owner file(s) with the REAL child group now that
  # it exists -- acquired with fwf-gate.sh's OWN group recorded (the only
  # one that existed at acquire time). Acquire-side reconciliation on a
  # future acquire must reap the group actually holding the resource.
  _fwf_owner_restamp_pgid "$(fwf_gate_lock_dir "$role")/owner" "$wrapped_pgid" 1
  [ "$e2e_held" = 1 ] && _fwf_owner_restamp_pgid "$(fwf_e2e_lock_owner_path "$e2e_lane")" "$wrapped_pgid" 1
  wait "$wrapped_pgid" || rc=$?
  # `wait` returning means the GROUP LEADER exited -- it does NOT mean the
  # group is empty. A wrapped command that backgrounds a server and then
  # returns (this ticket's own reported scenario, and reproduced live
  # while building this fix: a `(server &)` subshell orphans a live
  # listener the instant its launching subshell exits) leaves that server
  # alive in the SAME group. wrapped_pgid stays SET here on purpose, so
  # _fwf_gate_release's teardown (below, always runs next via the EXIT
  # trap) still has a real group to check/signal -- it clears the handle
  # itself, only once it has confirmed the group is actually empty.
else
  "$@" > >(tee "$wrapped_out_capture") 2> >(tee "$wrapped_err_capture" >&2) || rc=$?
fi

if [ "$rc" -ne 0 ]; then
  _fwf_gate_diagnose_port_collision "$wrapped_err_capture"
fi

# issue #499 AC3: stop the watcher and, ONLY on an otherwise-passing run,
# turn "never bound the allocated port" into a stated failure -- a run that
# already failed on its own content has nothing this check needs to add.
if [ -n "$_fwf499_watcher_pid" ]; then
  kill "$_fwf499_watcher_pid" 2>/dev/null
  wait "$_fwf499_watcher_pid" 2>/dev/null
  if [ "$rc" -eq 0 ] && [ ! -f "$_fwf499_port_marker" ]; then
    echo "fwf gate [#499]: FWF_E2E_MAX_LANES=$FWF_E2E_MAX_LANES (N>=2) but the wrapped command never bound its allocated port $e2e_port -- the consumer must read \$FWF_E2E_PORT (issue #499 AC3) or it will silently collide with another concurrent e2e lane. Recording this run as FAILED." >&2
    rc=1
  fi
  rm -f "$_fwf499_port_marker" 2>/dev/null
fi

# issue #479: a run ended by an external signal (OOM, operator Ctrl-C, the
# box going down) must not be reported as a content verdict -- "FAILED --
# SUITE" plus a merge-base baseline is a claim about THIS diff, and a run
# that never reached a conclusion has no such claim to make. Inverting
# #447's question rather than trying to detect the kill: a signalled
# child's `wait` status is 128+N in $rc, byte-for-byte identical to an
# intentional `exit 137` -- there is no WIFSIGNALED bit exposed to a POSIX
# shell, so $rc alone can never distinguish them (rev 1 of this ticket got
# that backwards). Detect COMPLETION instead: the wrapped command
# affirmatively records that it reached a conclusion (this repo's own
# harness already does, in "N passed, N failed, N skipped"); absence of
# that record on an ambiguous (128+N-range) $rc is what makes the run
# indeterminate. $rc only ever GATES the question here -- it is never the
# answer -- so a completing run whose own exit code happens to land in the
# signal range (AC 5: a suite that exits 137 of its own accord) still
# wrote its completion record and is a real FAIL, not indeterminate.
# MUST run before the #227 history writes below and before
# wrapped_out_capture is removed (713) -- #447's marker check sits AFTER
# both, so it cannot be reused at its own position for this ticket; moving
# the check ahead (rather than moving the history writes after the rm) is
# the smaller, more local change.
FWF_GATE_COMPLETION_MARKER="${FWF_GATE_COMPLETION_MARKER-[0-9][0-9]* passed, [0-9][0-9]* failed, [0-9][0-9]* skipped}"
_fwf479_indeterminate=0
if [ "$rc" -ge 128 ] && [ -n "$FWF_GATE_COMPLETION_MARKER" ] \
   && ! grep -qE -- "$FWF_GATE_COMPLETION_MARKER" "$wrapped_out_capture" 2>/dev/null; then
  _fwf479_indeterminate=1
  echo "fwf gate [#479]: the wrapped command ended with rc=$rc (a signal-range exit) and left no completion record (matched against '$FWF_GATE_COMPLETION_MARKER') -- this run did NOT reach a conclusion (an OOM kill, an operator's Ctrl-C, and the box itself going down are all indistinguishable from here). Recording indeterminate, not a content verdict; this run is excluded from case history." >&2
fi

# issue #227: flake-vs-broken discrimination. Per-case when the profile
# declares GATE_CASE_EXTRACTOR (a shell command read on stdin, emitting
# "PASS <case-id>" / "FAIL <case-id>" lines); SUITE-level (case-id "SUITE",
# this run's own rc) otherwise -- the mode is always named in the output
# (AC d). Computed from plain `git ...` (cwd-relative), the same convention
# already used for $verdict_head below -- FWF_REPO was already restored to
# the CALLER's own value above (issue #175) and may not be this worktree.
#
# issue #479 (AC 2, AC 3, AC 4): this whole section is SKIPPED on an
# indeterminate run -- neither branch (per-case OR SUITE-level) gets to
# write a case-history record or print a baseline/flakiness stanza, since
# neither is a fact about the diff. AC 4's "any case-id killed mid-run
# gets the same treatment" is why this guards BOTH branches identically
# rather than special-casing SUITE.
_fwf227_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
_fwf227_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
_fwf227_base="$(git merge-base HEAD "origin/$STAGING_BRANCH" 2>/dev/null || true)"
_fwf237_canary_seen_fail=0
if [ "$_fwf479_indeterminate" = 1 ]; then
  : # issue #479: no history write, no content verdict -- see the message already printed above.
elif [ -n "${GATE_CASE_EXTRACTOR:-}" ]; then
  _fwf227_saw_case=0
  # Deliberately NOT `IFS= read` -- that disables field splitting entirely,
  # so with only two read-vars the whole line would land in $_fwf227_status
  # and $_fwf227_case_id would stay empty. Default IFS splits off the first
  # word (the status) and dumps the untouched remainder (spaces intact)
  # into the last var -- exactly the "PASS <case-id with spaces>" contract.
  while read -r _fwf227_status _fwf227_case_id; do
    [ -n "$_fwf227_status" ] && [ -n "$_fwf227_case_id" ] || continue
    _fwf227_saw_case=1
    # issue #237 AC (k): a canary case is a deliberately-failing sentinel the
    # harness always runs -- if it comes back green (or is simply absent
    # from what got extracted), the suite has no confirmed path to red, and
    # this run's verdict must not be trusted as a real green (see below,
    # after this loop, where the recorded verdict is actually downgraded).
    if [ -n "${FWF_GATE_CANARY_MARKER:-}" ]; then
      case "$_fwf227_case_id" in
        *"$FWF_GATE_CANARY_MARKER"*) [ "$_fwf227_status" = FAIL ] && _fwf237_canary_seen_fail=1 ;;
      esac
    fi
    fwf_gate_history_report_case "$_fwf227_case_id" "$_fwf227_status" "$_fwf227_branch" "$_fwf227_sha" "$_fwf227_base" "per-case (GATE_CASE_EXTRACTOR)"
  done < <(bash -c "$GATE_CASE_EXTRACTOR" < "$wrapped_out_capture" 2>/dev/null)
  # issue #227 (qa2 review): this fallback must NOT be conditioned on
  # `$rc` -- an extractor that matches zero lines on a PASSING run used to
  # record nothing at all (neither the per-case loop above, which had
  # nothing to iterate, nor this fallback, gated on `rc != 0`, ever ran),
  # silently dropping every one of that run's green results from history.
  # That is AC (i)'s own warned-against failure mode in miniature: with
  # only the FAILING runs' SUITE-level fallback still recording, a
  # misconfigured/intermittently-missing extractor would skew a case's
  # history toward failure for reasons having nothing to do with the case.
  # Always fall back to a SUITE-level record of the run's ACTUAL outcome
  # (rc) when the extractor produced nothing, pass or fail alike.
  if [ "$_fwf227_saw_case" != 1 ]; then
    echo "fwf gate [#227]: GATE_CASE_EXTRACTOR is declared but produced no PASS/FAIL lines for this run — falling back to SUITE-level" >&2
    fwf_gate_history_report_case SUITE "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$_fwf227_branch" "$_fwf227_sha" "$_fwf227_base" "SUITE-level (extractor produced nothing)"
  fi
else
  fwf_gate_history_report_case SUITE "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$_fwf227_branch" "$_fwf227_sha" "$_fwf227_base" "SUITE-level (no GATE_CASE_EXTRACTOR declared)"
fi

# issue #447: the gate's verdict must not claim "lint ran and passed" when
# the wrapped command's lint step was itself SKIPPED (OOM-killed under
# concurrent box load, a RAM-admission timeout, or the linter simply
# absent -- test/run.sh's #418/#427 dispatch phrases every one of those
# "skip shellcheck (..."). rc alone can't distinguish that from a real
# clean lint: a skip never fails the suite, so rc is 0 either way, and
# #443/#445 showed the store recording a confident green on a tree three
# independent checks (macOS, the operator's own run, a second reviewer's
# gate) called red. Defaulted ON, unlike #237's FWF_GATE_CANARY_MARKER --
# that marker names a profile-specific case-id with no safe universal
# value; this one names THIS repo's own, already-established skip-message
# idiom, so a profile whose harness never emits it (or phrases it
# differently) simply never matches and pays nothing. A profile that wants
# it off, or phrases its own skip differently, overrides with its own
# value (including empty, which disables the check).
FWF_GATE_LINT_SKIP_MARKER="${FWF_GATE_LINT_SKIP_MARKER-skip shellcheck (}"
_fwf447_lint_skipped=0
if [ -n "$FWF_GATE_LINT_SKIP_MARKER" ] && grep -qF -- "$FWF_GATE_LINT_SKIP_MARKER" "$wrapped_out_capture" 2>/dev/null; then
  _fwf447_lint_skipped=1
  # AC (3): surfaced here, at gate time, so the implementer who just ran
  # this sees it immediately rather than discovering it later from a
  # verdict token or a second reviewer's contradicting gate -- the actual
  # cost this ticket was filed on (an hour lost to a green that meant
  # "didn't check", not "checked and clean").
  echo "fwf gate [#447]: lint was SKIPPED this run (matched '$FWF_GATE_LINT_SKIP_MARKER' in the wrapped command's output) -- this run's suite passing does NOT mean lint ran clean. Recording green-lint-skipped, not green." >&2
fi

rm -f "$wrapped_err_capture" "$wrapped_out_capture"

if [ "$want_e2e" = 1 ]; then
  unset FWF_E2E_PORT FWF_E2E_DATA_DIR FWF_E2E_SPEC
fi

# issue #237 AC (k): #211's convention applied to the WRITE side -- a gate
# that cannot demonstrate it has a path to red must not write a confident
# green. Opt-in and inert by default (FWF_GATE_CANARY_MARKER unset):
# FWF_GATE_CANARY_MARKER names a substring a profile's harness embeds in one
# deliberately-failing case's own case-id (test/run.sh's reference canary is
# below in this same PR). Only ever downgrades a candidate GREEN (rc=0) --
# a genuine RED already proves the suite can fail, so it is never
# second-guessed here.
_fwf237_verdict_downgrade=""
if [ -n "${FWF_GATE_CANARY_MARKER:-}" ] && [ "$rc" -eq 0 ]; then
  if [ -z "${GATE_CASE_EXTRACTOR:-}" ]; then
    echo "fwf gate [#237]: FWF_GATE_CANARY_MARKER is declared but GATE_CASE_EXTRACTOR is not -- the canary cannot be verified, recording UNKNOWN rather than a pass" >&2
    _fwf237_verdict_downgrade=unknown
  elif [ "$_fwf237_canary_seen_fail" != 1 ]; then
    echo "fwf gate [#237]: canary case (marker '$FWF_GATE_CANARY_MARKER') did not report FAIL this run -- the suite has no confirmed path to red, recording UNKNOWN rather than a pass" >&2
    _fwf237_verdict_downgrade=unknown
  fi
fi
_fwf237_verdict() { # prints this run's verdict: green|green-lint-skipped|red|indeterminate|unknown
  # issue #479 (AC 6, AC 7): checked FIRST, ahead of the plain `rc -ne 0 ->
  # red` line below -- an indeterminate run's rc IS non-zero (that is what
  # made it ambiguous in the first place), so this must short-circuit
  # before that line would otherwise claim it as a real, content red.
  # Deliberately NOT #237's `unknown`: that token is already taken for a
  # candidate-GREEN downgrade ("no confirmed path to red"); an
  # indeterminate run is a candidate-RED that cannot be vouched for --
  # conflating the two would make `unknown` mean two opposite things.
  [ "$_fwf479_indeterminate" = 1 ] && { echo indeterminate; return 0; }
  if [ "$rc" -ne 0 ]; then echo red; return 0; fi
  [ -n "$_fwf237_verdict_downgrade" ] && { echo "$_fwf237_verdict_downgrade"; return 0; }
  # issue #447: a lint-skip downgrade is independent of (and checked after)
  # #237's canary downgrade above -- both only ever apply to a candidate
  # GREEN, and #237's `unknown` (no confirmed path to red at all) is the
  # stronger finding when both happen to fire on the same run.
  [ "$_fwf447_lint_skipped" = 1 ] && { echo green-lint-skipped; return 0; }
  echo green
}
# issue #237 (k2): fingerprint of what actually ran, folded into every
# verdict record below so a later investigation can revoke every record a
# now-known-broken gate wrote, by fingerprint, without a manual timestamp
# hunt (the #242 incident's own unmet need).
_fwf237_fingerprint="$(_fwf_gate_fingerprint "$@")"

# issue #220 AC (r)/(r0): record a SHA-keyed, reviewer-readable verdict --
# see fwf_gate_verdict_record's own doc comment (lib.sh) for why this is a
# SEPARATE store from fwf_gate_tip_record just below, never the same file.
# Recorded alongside every fwf_gate_tip_record call (identical role/verdict/
# reason, just re-keyed by tip instead of role) so the two stores can never
# silently drift apart.
_fwf_gate_record_verdict() { # $1=tip/sha  $2=verdict  $3=reason(optional)
  fwf_gate_tip_record "$role" "$1" "$2" "${3:-}"
  fwf_gate_verdict_record "$1" "$role" "$2" "${3:-}" "$_fwf237_fingerprint"
}

if [ -n "$tip_cmd" ]; then
  tip_after="$(eval "$tip_cmd" 2>/dev/null)" || tip_after=""
  # A failed/empty re-read is the SAME uncertainty as a confirmed move -- we
  # genuinely don't know whether the ref changed, so this must fail closed to
  # STALE, never fall through to recording a real (and promotable) verdict.
  if [ -z "$tip_after" ]; then
    echo "fwf gate: could not re-read the tip after this run (ref transiently unreadable) — verdict is STALE, not promotable" >&2
    _fwf_gate_record_verdict "$tip_before" "stale"
    rc="$EX_STALE"
  elif [ "$tip_after" != "$tip_before" ] && [ "$want_tip_ancestry" != 1 ]; then
    echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) — verdict is STALE, not promotable" >&2
    _fwf_gate_record_verdict "$tip_before" "stale"
    rc="$EX_STALE"
  elif [ "$tip_after" != "$tip_before" ]; then
    # issue #254: "the ref changed" is the wrong question -- ancestry is.
    # Distinguish a clean "not an ancestor" (git exit 1) from "could not
    # determine" (any other non-zero -- shallow clone, missing objects): both
    # fail closed to STALE, but the operator's next action differs (AC h).
    git merge-base --is-ancestor "$tip_before" "$tip_after"
    anc_rc=$?
    if [ "$anc_rc" -eq 0 ]; then
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after), but $tip_before is still an ancestor -- verdict stands, promote it by its literal hash" >&2
      _fwf_gate_record_verdict "$tip_before" "$(_fwf237_verdict)"
    elif [ "$anc_rc" -eq 1 ]; then
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) and $tip_before is NOT an ancestor of $tip_after (history rewritten) — verdict is STALE, not promotable" >&2
      _fwf_gate_record_verdict "$tip_before" "stale" "not-ancestor"
      rc="$EX_STALE"
    else
      echo "fwf gate: tip moved during this run ($tip_before -> $tip_after) and ancestry could not be determined (git merge-base --is-ancestor exit $anc_rc — shallow clone or missing objects?) — verdict is STALE, not promotable" >&2
      _fwf_gate_record_verdict "$tip_before" "stale" "indeterminate-ancestry"
      rc="$EX_STALE"
    fi
  else
    _fwf_gate_record_verdict "$tip_before" "$(_fwf237_verdict)"
  fi
else
  # AC (r0): "a gate invoked WITHOUT --tip-cmd must still record its
  # verdict." No externally-supplied tip exists here, so the natural
  # identifier for "what was actually tested" is the invoking worktree's
  # own HEAD -- the code state the wrapped command just ran against. Only
  # fwf_gate_verdict_record fires (never fwf_gate_tip_record): the #202
  # skip-optimization marker is meaningless without a --tip-cmd to compare
  # against, and writing it here would let a --tip-cmd-less call for this
  # role clobber a --tip-cmd caller's skip state.
  verdict_head="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  fwf_gate_verdict_record "$verdict_head" "$role" "$(_fwf237_verdict)" "" "$_fwf237_fingerprint"
fi

exit "$rc"
