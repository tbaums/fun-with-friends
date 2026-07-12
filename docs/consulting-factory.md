# The consulting factory — design and basis

```bash
fwf up --profile consulting up          # advisory: writes only to its own findings repo
```

Same falsification machinery as the [validation factory](validate-factory.md),
pointed at a different question: instead of a GO/KILL verdict on a *future* idea,
it delivers a **defensible diagnosis of a *past* one** — did an agent-built
software pipeline's **shipped quality actually regress**, and if so **why** — then
proposes CLEAR, COMPREHENSIVE, DIRECTLY-APPLICABLE fixes. The client's "quality
collapsed" is a **hypothesis on trial, not a fact**: `no real decline / drift /
unverifiable` is a first-class win, never a failed engagement. Work flows through
the normal PR machinery as a falsification **dossier** under
`findings/<engagement-slug>/`; the curated `DOSSIER.md` reaches `integration`.

It is **advisory**: `FWF_REPO` is the firm's own findings repo, and the client
repo named in the engagement `MANIFEST.md` is **read-only input the floor never
writes**. You re-point the firm per client with the manifest, not by editing the
template. Built on `validate` (`FWF_TEMPLATE_BASE="validate"`); the Phase-3 replay
capability follows the seam cut by [`user-testing`](user-testing.md) — a pool of
runners against a target they don't modify.

## The funnel

A single premise is funnelled deep through **three phases, run in order**, each
able to end the engagement. The captain tracks the active phase as a PHASE STATE
in the engagement issue; the floor reads it to know what work is legal this cycle.

1. **Phase 1 · Premise gate** — did shipped quality actually decline? A pre-
   registered premise (P1 decline is real · P2 there is a datable boundary · P3
   expectation held constant) is scored against a **boundary-significance bar that
   is a real number**, committed to writing *before any evidence is seen*. Most
   "collapses" resolve here — to a real decline, or to **drift** (degradation with
   no datable boundary), **no real decline** (within historical variance), or
   **unverifiable / confounded** (the axis that would settle it was never
   instrumented). The last three are rewarded nulls.
2. **Phase 2 · Cause tournament** — only if the premise clears. Closed-set
   elimination: each candidate cause must **name a dated delta on the bad side of
   the boundary whose fingerprint matches** the degradation, and beat the null and
   confounders on tiered evidence. Regressions are multi-causal, so survivors
   **coexist**, ranked by causal strength (score capped by the weakest tier).
3. **Phase 3 · Empirical replay** — OFF by default; a human enables it. A single
   API-pinned runner `git restore`s the good-era prompts/models and re-runs real
   briefs to try to **disconfirm** each surviving cause with artifacts, degrading
   gracefully to correlational attribution when the good era is un-replayable.

Any phase that meets a pre-registered kill/null condition **short-circuits**: the
dossier is preserved, the issue is closed with a verdict epitaph, and the human
can override by reopening with new evidence or an accepted risk.

## The principle this encodes

Every "why did our quality drop?" post-mortem dies the same two deaths —
**manufacturing a collapse that isn't there** (hindsight + a cadence spike reads
as decline), or **excusing a real one** as noise. The design is built to fire in
*both* directions and be laundered in neither:

| Failure it fights | Where it lives |
|---|---|
| Goalpost-moving once the data arrives | The framer **pre-registers** the premise, the boundary-significance *number*, and the rubric before any evidence is seen; the GV gates that the bar can fire both ways |
| Manufacturing a boundary out of drift | A **significance gate** (the boundary must clear a pre-registered threshold) + a rewarded **"this is drift"** output |
| "More shipping / more scrutiny" misread as "worse building" | Count axes are **scrutiny-normalized** — a rise that merely tracks a step-change in review/issue-filing volume does not count as decline |
| Convicting the signal that *seeded* the investigation | A cited-evidence bar: a cause must name a **dated delta whose fingerprint matches**, not restate the alarm |
| Laundering "we can't tell" into "we're fine" | **Unverifiable / confounded** is a distinct outcome from **no real decline**; an un-instrumented axis caps confidence and is reported as an open gap, never as health |
| The pool self-certifying as complete | A mandatory **other/unknown** contender + a **coverage gate** (no premise verdict until all six lenses + other/unknown are covered) + a late-seeding window |
| False balance on an obvious one-sided decline | A **summary-judgment fast-path** (the judge may short-circuit) paired with a **GV under-call audit** of that call |
| False confidence | Every finding carries an **evidence tier** (`[E:cited]`/`[E:inferred]`/`[A:assumption]`); the verdict's confidence is **bounded by the weakest load-bearing link** |
| A diagnosis that becomes archaeology | The near-standing recommendation is an **always-on quality instrument** so the *next* diagnosis is telemetry, not reconstruction |

## The six-lens evidence bench

The premise gate is worked as a **claimable pool** of six lenses plus a mandatory
seventh contender — each pair claims the next uncovered lens and stays blind to
the others until adjudication, so the conclusions are independent:

**model** (role→model map changes, silent swaps) · **prompt** (role/gate/rubric
edits) · **orchestration** (topology, cadence, handoffs, session logs) ·
**process** (human-in-the-loop: brief quality, review depth, gate discipline) ·
**codebase** (the target's own regressions, complexity, flaky tests) ·
**metrics** (the timeline itself — cadence, re-fix trail, broken-release markers)
· **other/unknown** (owns the unseeded-cause hypothesis; keeps the pool honest).

## Role contract at a glance

- **Framer / Registrar (PM)** — turns the client brief + evidence `MANIFEST.md`
  into the **pre-registered engagement frame** (premise, boundary bar, six-lens
  coverage gate, evidence tiers, rubric), committed before any evidence; keeps it
  gated until the GV signs off. Never gathers evidence.
- **Lens-specialist (impl)** — claims one of six lenses, blind to the others;
  produces a tier-tagged section leading with the **disconfirming** case ("this
  lens is innocent / the decline is imagined"). `impl1` doubles as the Phase-3
  replay-runner when enabled.
- **Citation-cop / Red advocate (qa)** — paid to defend the null; attacks every
  evidence tag and load-bearing claim, merges a section only once it has survived.
- **Judge / Synthesizer (conductor)** — sole writer of `DOSSIER.md` + the
  assumptions ledger; enforces the coverage gate, adjudicates the premise and the
  tournament against the pre-registered rubric, promotes to integration.
- **Standing skeptic (GV)** — hard-gates the frame (can the bar fire both ways?);
  audits **both** over-call (a manufactured boundary) and under-call (a real
  decline buried under false balance).
- **Captain (phase-state orchestration)** — tracks the funnel phase (not a linear
  build checklist), makes the phase calls advised by the GV, and owns the
  state-preserving short-circuit and the evidence-gated override.

## How the branch ladder maps

| dev factory | consulting factory |
|---|---|
| feature PR → staging | lens-section PR → staging |
| QA gate (tests) | red-advocate gate (survived attack + evidence-tier integrity) |
| conductor e2e → integration | judge integrity check + `DOSSIER.md` → integration |
| human releases to main | human decides; a rewarded null is a closed issue the human can reopen with new evidence |

## Pointing it at an engagement

Stand up a firm-owned findings repo once (`staging` + `integration` branches,
cloned to `FWF_REPO`). Per client, drop a `MANIFEST.md` at its root naming the
sources **by type** — target repo (read-only), tracker, factory config +
role→model map (first-class evidence, since the target is agent-built), the
claimed good-era boundary to test, and the OFF-by-default switches for
orchestration logs and Phase-3 replay. The role prompts read the manifest and
discover sources by type; they never assume literal client paths. See
[`templates/consulting/README.md`](../templates/consulting/README.md) for the full
runbook and the three acceptance fixtures under `templates/consulting/eval/`.

> **Never run two factories at once** (OOM on a single workstation), and run a
> real engagement as a separate, standalone factory — never nested in a build or
> eval run.
