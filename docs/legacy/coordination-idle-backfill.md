# Coordination-lane idle-backfill (issue #169)

## Problem

Throughput is bounded by a single build pair on a RAM-tight box where a
second build pair risks swap-thrash. But not all work needs the build
floor: a discovery proposal or a doc-only change only needs *writing*
capability, not *code-writing* capability — yet today it still consumes a
scarce implementer build-floor slot, because only implementers can commit a
file and open a PR. The coordination session (PM/GV/captain) is already up
and frequently idle between refinements, and its capacity is uncapped by
`FWF_PAIRS` — that capacity is nominally free.

## Why this is NOT "PM/GV write files"

The naive read of the ticket ("PM or GV produces the proposal.md / doc PR
from the coordination session") collides head-on with a load-bearing,
already-hardened constraint: PM's role prompt states *"you never write code
and never touch branches or PRs"*; GV's states *"you never touch branches or
PRs, never merge."* Blurring that boundary to let a coordination role commit
files would undercut the substantial authorization/enforcement work this
factory has invested in keeping roles crisp and auditable (#191, #207, #218,
#220 among them) — a role that can silently start writing files is a role
whose actions are no longer bounded by what its prompt says it does.

**Resolution:** PM/GV do the *substantive thinking* — investigating,
drafting, refining — entirely as **issue comments**, never touching a
branch, a file, or a PR. Once a draft is complete, an implementer's
*ordinary* claim-and-build cycle does the mechanical, fast step of
assembling the already-written comments into the target file. The slow part
(thinking) happens on the coordination lane, concurrently with build-floor
code work; the fast part (committing) still uses a build-floor slot, but
for a much shorter time than drafting-from-scratch would have taken.

This also sidesteps the ticket's own predicted collision with #146
(worktree-refresh treats a dirty/on-a-branch read-only worktree as an
anomaly): since PM/GV never touch a branch or file, their worktrees stay
clean throughout an idle-backfill pass. No reconciliation between the two
tickets is needed.

## The mechanism: comment checkpoints, hard preemption by construction

A coordination item is marked with the `coordination-only` label
(`COORD_LABEL`, config.sh). Implementer surveys exclude it
(`SURVEY_EXCLUDE_IMPL`) — implementers cannot claim it while it is still
being drafted, mirroring how `product-wip` gates a PM draft.

**Routing (by label combination, not a separate mechanism):**

| Labels | Routes to | Model |
|---|---|---|
| `coordination-only` alone | PM | chunked idle-backfill, any tick |
| `coordination-only` + `discovery` | GV | floor-down sustained pass |

- **PM idle-backfill** (doc-only / chunkable work): reachable only on a
  cycle where PM's ordinary WIP-draft duties found nothing to do — the
  step is the *last* thing checked, so any new PM duty on a later cycle is
  handled first, by construction. PM advances the OLDEST eligible
  candidate by exactly one bounded chunk, posted as `COORD-DRAFT (chunk
  N): <content>`.
- **GV floor-down pass** (from-scratch proposals needing one sustained
  sitting — chunking a from-scratch investigation across ticks would
  produce an incoherent proposal, per the ticket's own "work-type fit"
  reasoning): reachable only when GV's two hard/advisory duties found
  nothing to do this cycle **and** the build session (`tmux has-session -t
  <BUILD_SESSION>`) is down. The floor-down gate exists because the reason
  chunking was needed elsewhere (avoiding memory contention with the build
  floor) doesn't apply when there is no build floor to contend with — GV
  can spend a genuinely sustained sitting instead.

**Why "preemption" needs no interruption-detection code.** Both steps are
placed as the *last* item in an already-existing, per-cycle, do-one-thing
loop (this is the same discipline every role in this factory already
follows). A chunk is always written, posted, and complete *before* the
cycle ends — there is never a half-written, unpersisted state for a later
cycle's caretaker duty to interrupt. "Preemption" here is not runtime
interruption; it's that idle-backfill simply never *starts* on a cycle
where real duty exists, which is a strictly stronger guarantee (no partial
work to ever lose) than mid-cycle checkpointing would have been.

**Handoff.** A final `COORD-DRAFT: READY — <target path> — <summary>`
comment, followed by removing `coordination-only`, moves the issue into the
normal implementer queue. An implementer recognizes prior `COORD-DRAFT`
comments (implementer.tmpl step e0b) and assembles them into the named file
— light editing for flow only, since the investigation/drafting already
happened. This is the fast, mechanical step; it still uses a build-floor
slot, but briefly.

## Gate AC: honest status, not vacuously satisfied

The ticket's own acceptance criterion — *"Doc/proposal PRs take a
diff-scoped lightweight gate (confirmed against #138); a markdown-only PR
does NOT run the full cargo/e2e suite"* — is **not fully met by this PR**,
stated plainly rather than claimed:

- **#352** (merged) built the diff-scoped classifier for this repo's own
  `bash test/run.sh` and wired it into CI in **shadow mode** — it correctly
  *confirms* (via its accumulating log) that a doc-only diff classifies as
  SKIP-eligible, but it does not yet actually skip anything. A
  markdown-only PR still runs the full suite today.
- This is the same phased-rollout discipline #261 used for the Rust-suite
  classifier, and for the same reason: flipping a classifier to actually
  skip work before it has real accumulated shadow-log data risks a
  fail-open bug shipping unnoticed. **Bounded deferral, dated:** revisit
  flipping `#352`'s classifier to enforcing by **2026-09-28** (30 days from
  this PR) or after 20 real CI runs of the `test` job have accumulated in
  `.gate-bash-suite-shadow.log`, whichever comes first — same trigger shape
  as #261's own dated deferral in `docs/gate-throughput.md`.
- Until that flip happens, a doc/proposal PR produced by this ticket's flow
  pays the same full-suite gate time as any other PR. The throughput win
  this ticket delivers is entirely in NOT occupying a build-floor slot
  during the (usually much longer) *drafting* phase — the final commit step
  still queues normally.

## What this PR builds vs. defers

**Built:** the full idle-backfill + floor-down-pass mechanism (routing,
comment-checkpoint format, hard preemption by construction, implementer
handoff), the `coordination-only` label wired through the single-sourced
survey-exclusion mechanism (#255), and this doc.

**Deferred, explicitly:**
- Flipping `#352`'s shadow classifier to enforcing (see above — dated,
  tracked, not silent).
- A programmatic test that actually drives PM/GV through a real idle tick
  in this factory's live floor (this factory has no harness for scripting
  an agent's own reasoning) — coverage here is at the level this
  codebase's other role-behavior tickets use: asserting the rendered
  prompt text contains the correct routing, ordering, and label wiring
  (see `test/run.sh`'s "coordination-lane idle-backfill" section).
