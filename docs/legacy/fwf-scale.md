# fwf scale — reconcile pairs on a live floor (issue #210)

## Problem

There was no way to change the number of impl/QA pairs on a **running**
floor without destroying in-flight work. `fwf up --pairs N` on a live floor
leaves the session untouched (issue #190 made that failure loud instead of
silent); the only path that actually applied a new count was `fwf up
--build-only`, which recreates the whole build session — killing every
implementer mid-task, orphaning open PRs.

`fwf scale --pairs N` reconciles a live floor to N pairs without disturbing
any pane it did not itself create or remove.

## Scale up

Creates only the missing `implN`/`qaN` panes — `fwf_create_role_pane`
(lib.sh), the same primitive `fwf-respawn.sh` already uses for recovery —
gives each a worktree (created if absent, reused if a larger floor already
provisioned it), launches claude via `fwf_claude_cmd` (sources
`$FWF_AUTH_ENV_FILE` fresh inside the new pane's own shell — never inherited
from the invoking shell, the exact #217/#143 gotcha), and arms it with
`fwf_arm_pane` followed by the same `fwf_verify_boot_ticks` boot health-gate
`fwf up` runs. Existing panes below the requested count are never touched:
not split, not killed, not re-armed, not even looked at.

## Scale down: only the highest index, and only if it's idle

The roster is contiguous `1..N` by construction — `lib.sh`'s `PAIRS` array
and `fwf_all_roles` both assume it. Removing "an idle pair" by index would
leave a gap: `impl3` a live pane holding real work no `fwf` tool can see, or
`impl2` a roster entry with no pane. So scale-down always targets the
**highest** index, and refuses if it holds an open PR (any branch matching
`implN/*`) or a live `CLAIM implN` — **even when a lower-indexed pair is
genuinely idle instead**. v1 never drains: a busy highest-indexed pair is a
flat refusal, not a wait, not a pick-a-different-one.

The worktree is **kept**, not deleted — cheap to retain, expensive to
recreate. A later scale-up reuses it automatically (the same
create-if-absent check a fresh `fwf up` already does).

## `--dry-run` and re-evaluation at mutation time

`--dry-run` prints the plan (panes to create, panes to remove, panes left
untouched, and why anything was refused) and mutates nothing. The naive
implementation — compute a plan once, hand it to the mutation path — has a
TOCTOU window: a pair idle when the plan printed could acquire a claim
before an operator confirms a real run. The real run **re-evaluates every
refusal condition immediately before mutating** and never acts on a cached
plan; a pair that became busy in that gap is refused at execution, with
nothing touched.

## Persistence is session-scoped, and says so

`fwf scale` never rewrites `FWF_PAIRS` in the profile. Success output states
this explicitly (`session-scoped only ... edit the profile to make N
permanent`) — a live-floor convenience command silently rewriting versioned
config would be a worse surprise than an explicit one-line notice, but an
operator who scales up, restarts, and silently loses the change is also
unacceptable, so the notice is mandatory rather than optional.

**The captain's own already-rendered prompt is a separate staleness
window.** Success output also states that the CAPTAIN pane still reflects
the OLD pair count until re-armed (`fwf respawn captain`) — issue #221's
`fwf dash` stranded-assignment surfacing is the safety net for that window.

## The roster ceiling: #210's original framing is stale

#210 was written assuming the captain's roster was a hardcoded literal
(`impl1-3`, repeated four times in `templates/dev/captain.tmpl`) and derived
a hard cap of 3 pairs from it, with the AC explicitly asking that the bound
be *derived*, not hardcoded, since #221 was expected to eventually dynamize
it.

**Verified against the current tree: #221 already did this.**
`templates/dev/captain.tmpl` now renders `__IMPL_ROSTER__`, substituted via
`_fwf_roster_range` (lib.sh) off the live `PAIRS` array — fully dynamic,
driven by the actual pair count. There is no longer an architectural
ceiling to derive from the captain's template at all.

`fwf scale` therefore refuses only above a plain sanity cap
(`FWF_SCALE_MAX_PAIRS`, default 20) against a typo'd huge N — not a
restatement of the old "roster hardcoded at 3" defect, and the refusal
message says so explicitly rather than silently keeping the number 3 as if
nothing had changed.

## Capacity and budget guardrails

Scale-up only (scale-down is never blocked by either):

- **Memory**: `fwf_free_ram_gb` (lib.sh) compared against
  `${#new pairs} * FWF_SCALE_RAM_PER_PAIR_GB` (default 2G/pair). An
  unmeasurable reading fails closed (refuses), same convention as this
  codebase's existing mem-admit checks.
- **Budget**: if `$BUDGET_HOLD_FILE`'s first line starts `HOLD` or
  `UNKNOWN`, scale-up refuses, naming the projected burn-rate change. This
  gives `fwf-budget-check.sh`'s sentinel its first *obliged* call site —
  every other consumer today is role-prompt prose ("if the file exists,
  read its first line"), a point-of-belief check obeyed only by an agent
  choosing to obey it. Without this, `fwf scale --pairs 3` would happily add
  two more metered agent loops in the middle of an active spend hold.

Both are bypassable with `--force`.

## `--force` is operator-only by convention, not by enforcement

The ticket asks for the capacity/budget override to be reachable only by
the human operator, citing #207's own reasoning: *"an override any seat can
pass is not a guardrail."* This codebase has **no existing technical
mechanism** that distinguishes an operator's own interactive shell from a
role's autonomous loop — both run as the same local user with the same
credentials. Per the ticket's own escape hatch ("if there is no such
mechanism today, say so in the PR rather than inventing one here"), this is
stated plainly rather than invented: no role-prompt template ever passes
`--force`, so no autonomous role reaches it today — but nothing in
`fwf-scale.sh` itself technically prevents one from doing so. Building a
real operator-vs-role distinction is a separate, larger piece of work
(likely shared with #213's own operator-signing-helper problem) and is out
of scope here.

## Deferred, explicitly

- **A true cross-script mutex with `fwf up`/`fwf down`.** The "scale
  invoked while up/down is in flight" edge case is covered only by
  `fwf scale`'s own re-evaluation at mutation time (see `--dry-run` above),
  not a real lock — `fwf-up.sh`/`fwf-down.sh` do not check any lock
  `fwf-scale.sh` could acquire. A genuine mutex spanning all three scripts
  is real, separate scope.
- **Any drain protocol for scale-down.** Explicitly out of scope per the
  ticket itself — "stop claiming and wait" is an undefined protocol with no
  natural timeout, and inventing one here would be maintained forever.
- **Scaling non-pair roles** (conductor, captain, pm, gv) or the
  coordination plane.
- **`--force`'s operator-only enforcement** (see above).

## Verifying

Real-tmux, stubbed-claude coverage lives in `test/run.sh`'s
`"fwf scale --pairs N (issue #210)"` section: pane PIDs byte-identical
across a scale-up, idempotency (zero pane churn scaling to the same count
twice), scale-down refusing on an open PR / a live claim (both, separately,
and the discriminating "refuses even though a lower index is idle" case),
`--dry-run` plan-equals-outcome, the capacity/budget guardrails and their
`--force` overrides, worktree reuse across a down-then-up cycle, and the
coordination session staying byte-identical throughout.
