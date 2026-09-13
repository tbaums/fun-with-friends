# Proposal: robust concierge/supervisor liveness for the dead-man's switch (#157)

**Status: DISCOVERY.** This is a feasibility investigation + build-or-no-go
recommendation, not code.

## Key finding before anything else: fwf already has the exact pattern this needs, just not aimed at the concierge

This is not a green-field design problem. fwf's own repo already contains,
independently, every primitive the ticket's five GV criteria ask for — built
for a *different* liveness problem (floor-role wedge detection, #165/#147),
but structurally identical to the concierge-liveness problem:

- **A four-state classifier that never collapses "unknown" into "dead."**
  `fwf-pane-liveness.sh` (built on `fwf_wedge_verdict()`, `lib.sh:3646`)
  returns exactly `HEALTHY` / `WORKING` / `WEDGED` / `UNKNOWN` for a role
  pane, and is explicit that "callers MUST treat UNKNOWN as 'cannot confirm
  either way'" (`fwf-pane-liveness.sh:20-24`). `fwf_wedge_verdict` itself
  only returns `WEDGED` once BOTH signals (tick progress, token flow) are
  flat *and* the elapsed time clears `FWF_WEDGE_MIN_SECS` — a stale single
  signal alone never classifies as dead.
- **Existence-plus-progress, not existence alone.** The same script combines
  a tick counter (progress) with live token-usage flow (a second,
  independent progress signal) before calling anything WEDGED — this is
  GV criterion #4 ("Existence ≠ liveness — combine both") already built and
  shipped for roles.
- **Pull-based existence checks, not a stoppable pusher.** `tmux has-session
  -t "$sess"` is used at 12+ call sites across `fwf-up.sh`, `fwf-resume.sh`,
  `fwf-stop.sh`, and `lib.sh` (e.g. `lib.sh:1096`, `:1118`, `:1227`) as the
  standard way to ask "does this tmux session exist right now" — a derived,
  on-demand fact with no independent process that can die and silently
  desync from the thing it's supposed to represent. `_fwf_gate_owner_liveness`
  (`lib.sh:2311`) and `_fwf_e2e_owner_liveness` (`lib.sh:1618`) do the same
  for PIDs: `kill -0 "$pid"` on-demand, returning a distinct rc for
  same-host-dead vs. cross-host-indeterminate, never a boolean that hides
  the indeterminate case.
- **Reversible remedy before destructive remedy.** `fwf-supervise.sh` only
  ever *respawns* (`fwf-respawn.sh <role>`, a hot-swap of one pane) on a
  confirmed `WEDGED` verdict — never a `fwf down`-class action — and gates
  even that behind `FWF_SUPERVISE_AUTORESPAWN` (ships dark by default,
  `fwf-supervise.sh:26-28`) with a circuit breaker (`fwf_respawn_breaker_*`)
  to stop a respawn storm. On `UNKNOWN`, the code explicitly skips action
  (`fwf-supervise.sh:97-103`: "Unchecked, that ambiguity would eventually
  auto-respawn a role that..."). This is GV criterion #2's "reversible PARK
  + escalate" shape, already shipped and battle-tested, just for a smaller
  blast radius (one pane) than the ticket's (the whole factory).

So the discovery question is **not** "design a new liveness model from
scratch" — it's "does the existing model's shape transfer to the
concierge/supervisor, and what's the smallest way to reuse rather than
reinvent it?" That reframing matters for both criterion #4 ("evaluate
keying off #165's classifier rather than a bespoke tmux-existence check")
and #5 ("develop as ONE supervisory-liveness model with #174 and #165") —
both are satisfied for free if the design below is adopted, not layered on
after the fact.

## What's structurally different about the concierge (why this isn't a copy-paste)

`fwf-pane-liveness.sh` classifies a role that fwf itself spawned, inside a
tmux session fwf itself created, with a tick file fwf itself writes at that
role's own step 0. The concierge is upstream of all of that: it is the
process that runs `fwf up`, and the guard watching it (`transom-usage-guard.sh`)
lives **outside this repo** (grepped for `transom-usage-guard` and
`concierge` across the whole tree — zero hits; the only "concierge" match in
this codebase is an unrelated TMUX-socket-path parsing test fixture,
`test/run.sh:4761`). Two consequences for the design:

1. **No existing fwf primitive currently answers "does the concierge's tmux
   session/process exist."** `tmux has-session` is the right *shape* of
   check, but the concierge's session identity is operator/deployment
   specific (whatever tmux session or top-level PID the operator's
   orchestration runs under) — not one of fwf's own named sessions
   (`COORD_SESSION`/`BUILD_SESSION`, `lib.sh:219`). The design must accept
   that identity as configuration, not hardcode it.
2. **The concierge has no tick counter or token-usage stream fwf already
   reads**, unlike a role pane. A progress corroborator for criterion #4
   needs a *different* second signal than "tick advanced." The natural
   candidate already exists: `fwf-usage-data.sh`'s usage read (the same
   file `fwf-pane-liveness.sh` already sources) can report **any** recent
   Claude-session activity under the concierge's PID/session, which is a
   legitimate "is real work happening here" signal independent of any
   heartbeat file. Where usage data isn't available (concierge isn't a
   Claude Code session at all — e.g. a plain bash supervisor loop), the
   corroborator degrades to "does its PID's process/session still exist,"
   which is still strictly better than today (a lone heartbeat file with no
   corroboration at all).

## Design: `fwf_supervisor_liveness` — one shared primitive, two callers

Recommend adding **one new function to `lib.sh`**, shaped exactly like
`fwf_wedge_verdict`/`fwf-pane-liveness.sh` but generalized to accept an
existence probe rather than assuming a tmux role pane:

```
fwf_supervisor_liveness <existence-check-cmd> [<heartbeat-file>] [<max-heartbeat-age>]
  -> CONFIRMED_ALIVE | CONFIRMED_DEAD | UNKNOWN
```

- **CONFIRMED_ALIVE**: the existence probe succeeds (session/PID present).
  A stale or missing heartbeat file does NOT downgrade this — existence is
  the primary signal (criterion #3: pull over push), corroboration is a
  bonus, not a requirement, exactly as `fwf_wedge_verdict` treats tick
  progress as decisive on its own.
- **CONFIRMED_DEAD**: the existence probe fails cleanly (rc distinguishes
  "checked, absent" from "couldn't check" the same way
  `_fwf_e2e_owner_liveness` already distinguishes same-host-dead from
  cross-host-indeterminate) **and** the heartbeat (if any) is also stale
  past `max-heartbeat-age`. Both signals must agree on dead before this
  verdict fires — this is the actual fix for the incident: a live
  concierge with only a stopped *toucher* now shows existence=alive,
  heartbeat=stale, which is the next bullet, not this one.
- **UNKNOWN**: the existence probe itself can't be evaluated (e.g. `tmux`
  unreachable, permission error, cross-host) — same shape as
  `_fwf_e2e_owner_liveness`'s indeterminate rc. Never collapses to dead.

The 2026-07-18 incident maps directly onto this: existence probe (concierge
tmux session/PID) would have returned alive the whole time; only the
heartbeat file went stale. Under this classifier that state is explicitly
**not** `CONFIRMED_DEAD` (existence disagrees), so criterion #1's third
state does the actual work — the incident could not recur under this
design without BOTH the concierge process dying AND (moot at that point)
the heartbeat going stale.

### Consequence side (criterion #2): soften before escalating

Mirror `fwf-supervise.sh`'s respawn-breaker shape, one level up:

| verdict | first response |
|---|---|
| `CONFIRMED_ALIVE` | nothing |
| `UNKNOWN` | log + escalate (notify), never act — same as today's WEDGED-skip-on-UNKNOWN |
| `CONFIRMED_DEAD`, first observation | **PARK** (freeze new claims/spend, same reversible shape as #149's `BUDGET_HOLD`) + escalate; do NOT `fwf down` yet |
| `CONFIRMED_DEAD`, sustained past a second, longer confirmation window | `fwf down` (the genuinely-irreversible remedy, reserved for confirmed abandonment) |

This reuses a mechanism this repo already has a proven, tested shape for
twice over (`fwf-supervise.sh`'s respawn breaker; #149's `BUDGET_HOLD` file
gate) rather than inventing a third pattern.

## Where the pieces live (criterion #5 — one model, not three)

- **`fwf_supervisor_liveness`** (new, in `lib.sh`): the shared classifier.
  Callable by (a) `fwf-supervise.sh`/`fwf-pane-liveness.sh` for role panes
  (an easy, low-risk refactor — swap their bespoke tick/token combination
  logic to call through this generalized function with tick-read as the
  "existence" probe and token-flow as the heartbeat-equivalent corroborator,
  preserving today's exact HEALTHY/WORKING/WEDGED/UNKNOWN behavior at the
  call site) and (b) a **new, small `fwf supervisor-liveness` CLI
  subcommand** that `transom-usage-guard.sh` (external, unchanged repo)
  calls instead of reading its heartbeat file directly. fwf ships the
  primitive and a thin CLI wrapper; transom's shell script becomes a
  ~3-line diff (call the wrapper, act on its 3-state answer) rather than a
  rewrite — feasible to land without needing write access to transom's own
  repo/deploy in this ticket's scope.
- **#174** (closed, drift detection) stays a distinct concern — "is the
  concierge running stale code" is orthogonal to "is the concierge alive at
  all," and #174 already shipped its own detection-only mechanism. No
  overlap to reconcile; note it here only so a future reader sees the
  boundary was considered, not missed.
- **#165/#147** (closed, role-wedge detection) becomes the *pattern donor*,
  not a dependency — this ticket doesn't reopen or modify #165's shipped
  behavior, it lifts its shape into a shared function so both consumers
  stay provably consistent (single liveness authority, criterion #5)
  instead of two independently-maintained "which state means dead" tables
  drifting apart over time.

## Effort estimate

1. `fwf_supervisor_liveness()` in `lib.sh` (existence probe abstraction +
   3-state verdict, modeled directly on `fwf_wedge_verdict`) — small, this
   is mostly extracting an already-proven shape into a more general
   signature.
2. `fwf supervisor-liveness <probe-kind> <target> [heartbeat-file]` CLI
   subcommand wrapping it, for transom (and any other external caller) —
   small.
3. Refactor `fwf-pane-liveness.sh`/`fwf-supervise.sh` to call through the
   shared function instead of their current bespoke tick/token combination
   — small-to-medium; needs care to keep `test/run.sh`'s existing #165/#147
   assertions green unchanged (regression risk, not new-behavior risk).
4. PARK-before-`fwf down` escalation logic — medium; this is genuinely new
   behavior (today's dead-man's switch has no intermediate state at all),
   needs its own AC-level test coverage for "stale heartbeat + alive
   process → park, not reap" as the direct regression test for the incident.
5. `docs/` — this changes an operator-observable safety behavior (the
   dead-man's switch no longer reaps on a stale heartbeat alone), so the
   eventual build ticket's docs updates are load-bearing, not optional.

Rough total: **1-2 days** for a single implementer, split naturally as two
tickets — (1) `fwf_supervisor_liveness` + CLI wrapper + the #165/#147
refactor onto it (mechanical, regression-covered by the existing suite),
and (2) the PARK-before-reap escalation behavior itself (genuinely new,
needs new tests) — rather than one ticket, since (1) is safe to ship and
verify independently before (2) changes anything about when a factory
actually gets torn down.

## Recommendation

**Build it — and scoped as "generalize and reuse an existing, proven
primitive," not a new liveness subsystem.** All five GV sign-off criteria
map onto patterns this repo has already shipped and hardened for a sibling
problem (role-wedge detection): the third state, the reversible-before-
destructive escalation shape, the pull-over-push existence check, and the
existence-plus-progress corroboration are each already live code, not
hypothetical design choices. The one genuinely new piece — PARK before
`fwf down` for the *factory-wide* dead-man's switch — is a direct,
small-blast-radius reuse of #149's own reversible-hold shape. Recommend
filing as two build tickets in the order above so the safe, mechanical
refactor (unifying the liveness authority) lands and proves itself before
the new escalation behavior (which changes what "the factory got reaped"
means operationally) ships on top of it.
