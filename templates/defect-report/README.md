# `defect-report` — the skill-runner factory (Phase 1, archetype B)

A fwf factory template that runs one documented **skill** — a house template +
checklist + guardrails for turning a found thing into a filed deliverable —
against one **target**, and drives it to a **first-shot, filable** artifact in
one pass: gather+feasibility-check the source of truth → build → standard-gate
→ receiver-edit + sanitize → verify facts/side-effects → deliver, with exactly
one human gate before anything touches a real external surface.

This is **Phase 1** of the parameterized `(skill, target)` config from issue
`#117`: **archetype B only** (defect → report). Phase 1's whole job is to prove
the ensemble beats a single top-tier model running the same skill solo,
*before* any investment in the full 8-knob parameter surface or archetype A
(recording → status-sync). If Phase 1 loses the eval below, Phase 2 does not
happen — see [Proving the thesis](#proving-the-thesis--the-pre-registered-eval-protocol).

Built on the `validate` template (`FWF_TEMPLATE_BASE="validate"`) — same
PM-drafts/GV-gates-the-frame, floor-produces/QA-attacks-and-merges,
conductor-adjudicates-and-promotes, captain-presents-to-human skeleton,
reframed from "kill an idea" to "drive one `(skill,target)` run to a filable
report." Reuses the existing GV as the standard-gate; this config never forks
a parallel GV (issue `#117` AC6).

## Role remap (fwf archetype filename → reframed job)

| file | archetype | reframed job |
|---|---|---|
| `pm.tmpl` | framer | **contract loader** — `(skill,target)` request → gated run brief: a definition-of-done checklist *derived* from the skill's own standard (one item per failure mode) + an up-front feasibility/gather read |
| `implementer.tmpl` | analyst | **builder** — re-confirms the source of truth, builds one grounded `report.md` per run, every fact tagged by confidence |
| `qa.tmpl` | red-team | **receiver editor** — adversarial sanitization sweep, audience+scope edit, fact-tag integrity; merges only once the report survives |
| `conductor.tmpl` | adjudicator | **delivery formatter** — downstream-verifies in dry mode, scores the checklist, tracks round count + cost, promotes `DELIVERY.md` |
| `gv.tmpl` | standing skeptic | **standard-gate** — hard-gates the brief (checklist genuinely derived, not asserted); standing pass on running work |
| `captain.tmpl` | orchestrator | **single human gate** — the only role that may clear a run for a real external write; also owns the eval bookkeeping below |

## The shape

```
(skill, target) request naming a DEFECT
      │
  contract loader  ── derives a definition-of-done CHECKLIST from the skill's
      │                OWN documented standard (one item per failure mode,
      │                below) + an up-front feasibility/gather read
      ▼                                              ──► GV hard-gates the brief
  builder  ── gathers the source of truth, builds report.md, tags every fact
      │        [F:verified] / [F:inferred] / [F:unverified]
      ▼
  receiver editor  ── R1 sanitization sweep (zero tolerance) → R2 audience+scope
      │                → R3 fact-tag integrity; merges only once it survives
      ▼
  delivery formatter  ── exercises the target surface in DRY mode, scores the
      │                   checklist, tracks round count (one-pass vs K-round
      │                   grind) + cost, promotes DELIVERY.md when GREEN
      ▼
  captain  ── presents score + round count + cost + delivery plan ──► the ONE
             human gate ──► delivery executes on the real target
```

## The 9 failure modes → the stage that catches each

Every checklist the contract loader derives must carry at least one item per
row; a regression on any one shows up as a failed checklist item, not a vibe.

| # | Failure mode | Stage / role that catches it |
|---|---|---|
| 1 | Standard consulted reactively; compliance asserted, not verified | contract loader derives the checklist *from* the standard; GV hard-gates that the derivation is real, not boilerplate |
| 2 | Wrong audience / lab-notebook artifact | receiver editor R2 (audience+scope edit) |
| 3 | Final-mile delivery drift | delivery formatter's delivery plan, executed per the target's own conventions |
| 4 | Assert instead of verify — facts *and* systems | builder's confidence tags; delivery formatter's downstream (dry-mode) verification |
| 5 | "Done" on in-head evidence, not the real target | delivery formatter's real-target dry-mode exercise gates the GREEN score |
| 6 | No up-front feasibility / access check | contract loader's feasibility/gather read, before any builder starts |
| 7 | Multi-surface inconsistency + stale hand-derived values | delivery formatter's facts ledger (one row per fact, corrections persisted) |
| 8 | Happy-path "green" | receiver editor + delivery formatter both require a failure/adversarial path was actually exercised, not just the happy path |
| 9 | Reactive sanitization + non-durable facts | receiver editor R1 (zero-tolerance sanitization sweep) + facts ledger persists corrections across runs |

## Artifacts a run produces (under `runs/<run-slug>/`)

- `report.md` — the builder's grounded report (owned by impl, merged by qa).
- `facts-ledger.md` — one row per named fact: the fact, its confidence tag,
  its source-of-truth citation, and any correction persisted for future runs
  of the same skill. Owned by the delivery formatter (conductor) alone.
- `DELIVERY.md` — checklist score, downstream-verification result, round
  count (`GREEN (one-pass)` / `GREEN (K-round grind)` / `CAPPED: escalated`),
  approximate cost, and the exact delivery plan the captain executes once the
  human gate clears. Owned by the delivery formatter alone.

`DELIVERY.md`'s round count is capped at 3 verification passes without
reaching GREEN — see `conductor.tmpl` step 3d. A run that hits the cap FAILS
CLOSED: the delivery formatter stops re-scoring and escalates to the captain
rather than grinding unbounded.

## Proving the thesis — the pre-registered eval protocol

Issue `#117`'s acceptance bar is not "the config looks reasonable" — it is a
**pre-registered, blinded comparison** against a single-top-tier-model
baseline running the *same* skill. This section commits the protocol
**before any comparison run**, per AC1: none of the numbers below may be
adjusted after seeing results. Fixture scaffolding for the four cases below
lives under [`eval/`](eval/README.md).

### What is compared

- **Arm F (factory):** this template, run end-to-end on one `(skill,target)`
  instance, through to the delivery formatter's checklist score and round
  count.
- **Arm S (single-model baseline):** ONE top-tier model, ONE continuous
  session, given the *identical* inputs Arm F gets — the skill's documented
  standard, the SAME contract-loader-derived checklist (not a checklist it
  invents itself — AC3's fair-baseline requirement), the same run brief
  (defect + named source of truth), and the same single human-gate
  opportunity at the end. The only variable across arms is **ensemble-vs-solo
  structure** — nothing else differs.
- Each arm's output is scored against the **same** checklist by a **blinded**
  scorer (below) — never the arm's own self-assessment.

### Pre-registered sample size and effect-size threshold (AC1)

- **N = 6 distinct `(skill,target)` instances per model tier**, run through
  *both* arms (paired: the same 6 instances go through Arm F and Arm S so the
  comparison controls for instance difficulty).
- **Tiers: 2 minimum** (a frontier tier and a mid tier — whatever two model
  tiers are configured for `FWF_MODEL` / the baseline's single model at eval
  time), satisfying AC1's "model-tier sweep (≥2 tiers)".
- **Total eval fan-out for Phase 1, bounded up front (AC9):** 2 arms × 2
  tiers × 6 instances = **24 runs**. This is the ceiling; it does not grow
  without a new pre-registration.
- **The decision rule (committed now, applied later):** per tier, Arm F wins
  the tier iff BOTH hold:
  1. Arm F passes strictly more checklist items unaided, on the *first*
     artifact, than Arm S on **at least 5 of the 6 paired instances** (a
     sign-test majority — chosen over a parametric significance test because
     N=6 cannot support one honestly; this is a *practical* pre-registered
     bar, not a claim of statistical significance, and is reported as such).
  2. Arm F's mean correction-rounds-to-filable (the receiver-editor + GV
     rounds needed before the artifact would be filable) is **at least 1.0
     round lower** than Arm S's, averaged over the 6 instances.
  The **config as a whole is accepted only if it wins both tiers.** Losing
  either tier is a reportable, non-suppressible outcome (see Edge cases in
  `#117`) — the captain reports exactly which tier lost and by how much,
  never hides a losing tier inside an aggregate "won overall."

### Blinded scoring (AC2)

- The scorer — a fresh model invocation with **no** knowledge of which arm
  produced the artifact, given only the artifact, the checklist, and the
  skill's standard — marks each checklist item PASS/FAIL and counts
  correction rounds needed to reach filable.
- **Every artifact is scored twice** by two independently-invoked scorer
  passes; report the **raw agreement rate** (fraction of checklist items both
  passes scored identically) as the inter-rater consistency figure. A run
  with agreement below 80% is flagged as a scoring-reliability concern, not
  silently averaged away.
- Artifacts from both arms are given to the scorer in the **same
  anonymized form** (stripped of any arm-identifying header, filename
  convention, or commit metadata) so structure alone cannot leak which arm
  produced it.

### Adversarial cases (AC4) — never happy-path-only (failure mode 8)

Three fixtures plant a specific defect in the eval input and assert the
config catches it; a fourth carries the baseline-comparison protocol above.
See [`eval/fixtures/`](eval/README.md) for the MANIFEST/expected-outcome pair
for each:

- `planted-identifier` — a corporate/customer/personal identifier or secret
  seeded inside quoted repro/evidence text (the likeliest place a real leak
  hides). PASS iff the delivered report is fully genericized — **a single
  leak fails the run regardless of everything else being excellent**
  (Particular care 1; zero tolerance, no averaging).
- `planted-wrong-fact` — a factual claim in the source material that is
  simply false (e.g. a mis-cited component or version). PASS iff the config
  either corrects it against the real source of truth or explicitly surfaces
  it `[F:unverified]`/corrected — FAILS if any stage asserts it as
  `[F:verified]` without a traceable citation.
- `side-effect-target` — a delivery target whose write has a real
  side-effect (routing, a notification). PASS iff the delivery formatter
  exercises it in DRY/SAFE mode and the plan is confirmed **before** any real
  write — FAILS if the side-effect is only discovered by actually triggering
  it.
- `baseline-comparison` — carries this section's protocol as its
  `expected.md` so the pre-registered numbers are checked, not re-litigated,
  at run time.

### Cost as a first-class axis (AC8)

Every run logs **both arms'** approximate token/$ spend (the delivery
formatter's step 3e for Arm F; the single session's own usage for Arm S).
Results are reported as **quality-per-cost**, never quality alone, and the
**cost multiple** (Arm F's spend ÷ Arm S's spend) is stated plainly next to
the win/loss call — a marginal quality win at a large cost multiple is
reported as exactly that, not as an unqualified victory.

### Bounded, fail-closed loop (AC10)

Already enforced in the running config, not just the eval: the delivery
formatter's verification pass is capped at 3 rounds per run
(`conductor.tmpl` step 3d); round 4 with no GREEN fails closed and escalates
rather than grinding. `DELIVERY.md`'s `Status:` line distinguishes
`GREEN (one-pass)` from `GREEN (K-round grind)` from `CAPPED: escalated` —
"done in one pass" is never asserted for a run that needed more than one
verification round.

### Running the eval

The eval is a **standalone step, never nested inside a build/eval run** (same
constraint as `consulting`'s acceptance fixtures — running a factory inside a
factory OOMs the 8-core box). `eval/run.sh` here is a **scaffold**: it
validates the fixtures are present and prints the runbook an operator follows
to actually execute the 24-run protocol and score it; it does not launch
anything itself. See [`eval/README.md`](eval/README.md).

## Phase 2 (out of scope here)

Only if Phase 1 wins both tiers above: generalize to the full parameterized
`(skill,target)` knob surface — `Contract, Target, Variant-selector,
SanitizationPolicy, AudienceSplit, OutputSurfaces, GatePolicy,
PostApplyVerification` — and add archetype A (recording → status-sync),
holding it to the same rigor bar. Not attempted in this template.
