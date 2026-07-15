# The defect-report factory — design and basis

```bash
fwf up --template defect-report
```

A fwf factory template that answers the "skill-runner" thesis from issue
`#117` for one representative archetype: given a documented **skill** (a
house template + checklist + guardrails) and a found **defect**, does an
ensemble that folds the review loop *in* — gather → build → standard-gate →
receiver-edit → verify → deliver — produce a materially better **first-shot**
artifact than a single top-tier model running the same skill solo? This is
**Phase 1, archetype B (defect → report) only**; Phase 2 (the full
parameterized `(skill,target)` surface + archetype A, recording→status-sync)
is out of scope here and gated on Phase 1 actually winning its eval.

Built on the `validate` template (`FWF_TEMPLATE_BASE="validate"`) — the same
pre-registered-criteria, paired-debate, GV-hard-gate machinery, reframed from
"kill a business idea" to "drive one `(skill,target)` defect to a filable
report." Reuses the existing GV as the standard-gate rather than forking a
second one.

## The shape — a pipeline, not a funnel

```
(skill, target) request naming a DEFECT
      │
  contract loader (PM) ── derives a definition-of-done CHECKLIST from the
      │                    skill's OWN standard (one item per failure mode)
      │                    + an up-front feasibility/gather read ──► GV gates
      ▼
  builder (impl) ── re-confirms the source of truth, builds report.md,
      │              tags every fact by confidence
      ▼
  receiver editor (qa) ── R1 sanitization (zero tolerance) → R2 audience+scope
      │                    → R3 fact-tag integrity; merges once it survives
      ▼
  delivery formatter (conductor) ── dry-mode target exercise, checklist score,
      │                              round count + cost, promotes DELIVERY.md
      ▼
  captain ── the ONE human gate before anything touches the real target
```

Unlike `consulting`'s funnel (any phase can short-circuit the engagement),
this is a straight pipeline — one `(skill,target)` run, one report, one
delivery decision. `FWF_PAIRS` is pinned to 1 (no stance-diverse pairs; there
is nothing to diverge on for a single grounded report).

## The principle this encodes

Nine repeated failure modes motivated this ticket; each maps to a specific
stage so a regression on any one shows up as a failed checklist item, not a
vibe. See [`templates/defect-report/README.md`](../templates/defect-report/README.md#the-9-failure-modes--the-stage-that-catches-each)
for the full table. The two structural bets worth calling out here:

| Bet | Where it lives |
|---|---|
| A checklist *derived from the standard* beats a checklist *hand-authored per run* | The contract loader must trace each item to the skill's actual documented convention; the GV hard-gates that the derivation is real, not boilerplate |
| Confidence tags catch "assert instead of verify" *before* delivery | Every fact the builder writes is `[F:verified]`/`[F:inferred]`/`[F:unverified]`; the receiver editor's R3 round exists solely to catch a tag dressed up past its evidence |

Both bets are only claims until the eval below actually runs.

## Role contract at a glance

- **Contract loader (PM)** — `(skill,target)` request → gated run brief: the
  checklist + an up-front feasibility/gather read. Never gathers evidence or
  writes a report itself.
- **Builder (impl)** — re-gathers the source of truth every cycle (a stale
  feasibility read is not trusted), builds one grounded `report.md` per run.
- **Receiver editor (qa)** — three fixed lenses across up to 3 rounds
  (sanitization → audience/scope → fact-tag integrity); merges only once the
  report survives all three.
- **Delivery formatter (conductor)** — the only writer of `DELIVERY.md` and
  the facts ledger; exercises the real target in dry mode before any GREEN
  score; hard-capped at 3 verification rounds per run (fails closed on round
  4, never grinds unbounded).
- **Standard-gate (GV)** — hard-gates the checklist's derivation; standing
  pass on running work for asserted-not-verified items.
- **Captain** — the single human gate; also the eval's bookkeeper (round
  count, cost, checklist score per run), never the one who runs the
  comparison baseline inside a live build cycle.

## How the branch ladder maps

| dev factory | defect-report factory |
|---|---|
| feature PR → staging | report PR → staging (`runs/<run-slug>/report.md`) |
| QA gate (tests) | receiver-editor gate (survived 3-lens attack + fact-tag integrity) |
| conductor e2e → integration | delivery formatter's dry-mode verification + checklist score → integration |
| human releases to main | human clears the single delivery gate; the captain executes the delivery plan |

## Proving the thesis (the acceptance bar)

This config is not accepted on design quality alone — issue `#117`'s AC1
requires a **pre-registered, blinded comparison** against a single-top-tier-
model baseline running the identical skill, checklist, and human-gate
opportunity. The full protocol — sample size, effect-size threshold, blinding
procedure, the three adversarial fixtures (planted identifier, planted wrong
fact, a write-side-effect target), cost-as-axis reporting, and the bounded
fail-closed iteration cap — is committed in
[`templates/defect-report/README.md`](../templates/defect-report/README.md#proving-the-thesis--the-pre-registered-eval-protocol)
and scaffolded under
[`templates/defect-report/eval/`](../templates/defect-report/eval/README.md).
A losing tier in that comparison is a valid, reportable outcome, never
suppressed — see that section for the exact decision rule.

> **Never run two factories at once** (OOM on a single workstation), and run
> the eval's comparison arms as separate, standalone runs — never nested in a
> build or eval run.
