# Proposal: event-driven handoff — nudge a downstream agent instead of waiting for its poll tick (#144)

**Status: RECOMMENDATION — hybrid, no-go on the nudge mechanism itself.** This
issue isn't labeled `discovery`, but its own "Deliverable" section asks for a
design note + recommendation before any prototype ("Prototype on one handoff
if the design holds up"), so that's what this PR ships. No code changes: the
design doesn't hold up as safe to build today, and the low-risk half of the
fix is an already-shipped, already-documented knob — see §4.

## Problem recap

The pipeline advances on per-role polling ticks (QA ~1m, conductor ~2m, GV
~3m, PM ~5m, impl ~2m — `config.sh`, all per-role env-overridable). When an
upstream agent hands off (e.g. implementer marks a PR ready → QA picks it
up), the downstream agent doesn't act until its own next tick, so a
ready handoff can sit idle for up to that interval. The issue also raises a
second, scarier failure mode: a tick that **doesn't fire at all** (a wedged
loop), where a ready handoff stalls "indefinitely until a human/supervisor
notices."

## 1. The "stalls indefinitely" half is already solved — by #165

`fwf-supervise.sh` (issue #165, merged since this ticket was filed) is a
steady-state wedge supervisor that runs independently of the polling loops
it watches: it snapshots each role's monotonic tick counter (#133) + token
flow (#95) every cycle, classifies HEALTHY / WORKING / WEDGED via the pure
predicate `fwf_wedge_verdict`, and — when `FWF_SUPERVISE_AUTORESPAWN=1` — hard
respawns a role classified WEDGED (tick AND tokens both flat past
`FWF_WEDGE_MIN_SECS`). This is exactly the missing piece the boot health-gate
(#133) didn't cover: #133 catches a role that never starts ticking; #165
catches one that goes stale mid-run.

**Consequence for #144:** the genuinely open-ended risk ("stalled
indefinitely until a human notices") is no longer open-ended — it's now
bounded by `FWF_WEDGE_MIN_SECS` + the supervisor's own poll cadence, with an
opt-in auto-recovery path. What #144's nudge idea would still buy, on top of
that, is shaving the **healthy-case** latency down from "up to one poll
interval" to "near-instant" — a real but much smaller win than the ticket's
framing suggested when it was filed.

## 2. Why a tmux send-keys nudge is not safe to ship today

The natural implementation — the upstream agent's `tmux send-keys`-pokes the
downstream pane directly, reusing `fwf_send_prompt`/`fwf_clear_composer`
(`lib.sh`) — has a real, currently-unmitigated hole: **there is no reliable
signal, anywhere in this codebase, for "is this pane idle at its prompt
right now, or is claude actively mid-turn?"**

- `fwf_clear_composer`'s Ctrl+U-based defense against the "wedged buffer"
  problem was built for STALE buffers between completed turns (a fresh pane,
  or the moment between one `/loop` cycle ending and the next prompt being
  typed) — never for interrupting a turn in progress. Every existing caller
  of `fwf_send_prompt` (arming, the boot-gate re-arm, the respawn re-nudge)
  only ever fires when the pane is known to be freshly launched or between
  cycles — not while the agent is actively generating.
- `pane_current_command` (tmux) reports the top of the pane's process tree —
  it stays `claude` whether the agent is idle-at-prompt or mid-response;
  tmux exposes no distinction.
- The tick/heartbeat signals (#99, #133) answer "did a new cycle start
  recently" and "is progress happening across a whole cycle" — neither
  answers "is the composer safe to type into this instant." A role deep into
  a single long-running cycle (e.g. a slow gate run) shows the exact same
  stale tick as one that's genuinely idle between cycles — precisely the
  ambiguity #165's classifier exists to resolve for the WEDGE question, but
  it resolves it on a multi-minute window, far too coarse to gate a
  millisecond-scale "is it safe to type right now" decision.

Nudging into an actively-generating pane is exactly the injected-message /
buffered-input wedge the issue's own "cons" section names as the top risk.
Building the anti-storm + idempotency + handoff-graph machinery the issue
also calls for is real, non-trivial work — and it would all be built on top
of a send-keys primitive whose core safety precondition (pane is idle) can't
currently be checked. That ordering is backwards: the missing idle-detection
signal is the actual blocker, not the graph/storm/idempotency layer around it.

## 3. A possibly-safer path exists, but is out of scope to investigate here

The pane environment (`ps eww` on a live agent pane) shows
`CLAUDE_CODE_MESSAGING_SOCKET` / `CLAUDE_CODE_BRIDGE_SESSION_ID` /
`CLAUDE_CODE_CHILD_SESSION` vars — Claude Code appears to have its own
session-bridging/messaging IPC, separate from the terminal. If that IPC has
a notion of "deliver this only when the session is idle" (or a safe
queuing/interrupt contract), it would sidestep the buffered-input risk
entirely and could be the real answer to this ticket. That's a Claude Code
product-surface question this implementer can't resolve from inside a bash
script — flagging it as a candidate follow-up discovery ticket (scoped
narrowly to "what does the messaging bridge actually guarantee, and can fwf
use it for a safe nudge") rather than guessing at its semantics here.

## 4. The low-risk lever already ships today

`FWF_QA_INTERVAL`, `FWF_CONDUCTOR_INTERVAL`, `FWF_GV_INTERVAL`,
`FWF_PM_INTERVAL`, `FWF_IMPL_INTERVAL` (README.md, config.sh) already let an
operator tighten any role's poll cadence per-profile, with zero new code and
zero new risk — directly shrinking the "dead minutes" the issue describes,
at the honest cost of more idle-poll cycles (and their token cost) between
real handoffs. This is already documented; no further code or docs change is
needed to make it available. Recommend this as the practical answer to the
latency half of the problem today.

## Recommendation

**Hybrid — do not build the nudge mechanism now.**

- The higher-severity half of the original problem (indefinite stall on a
  missed tick) is already solved by #165.
- The remaining latency win from event-driven nudging is real but bounded
  and modest (at most one poll interval per hop), and the send-keys
  implementation path has an unmitigated safety hole (no idle-detection
  signal) that the issue's own risk list predicted.
- The available lever for teams that want tighter latency today —
  `FWF_QA_INTERVAL`/`FWF_CONDUCTOR_INTERVAL`/etc. — already ships and is
  already documented.
- If Claude Code's messaging bridge (§3) turns out to offer a safe,
  idle-aware delivery contract, that would change this calculus — worth a
  narrowly-scoped discovery ticket if there's appetite, but not a
  blocking dependency for closing this one.

No prototype code accompanies this proposal — per the ticket's own
conditional ("prototype... if the design holds up"), the nudge design does
not hold up as safe to build today.
