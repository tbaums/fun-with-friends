# The validation factory — design and basis

```bash
fwf up --template validate
```

Same topology as the dev/ideation factories, new product: instead of code or an
idea portfolio, the factory produces a **defensible GO / KILL / PIVOT verdict** on
a posited business+product idea — reached *cheaply*, by trying hard to **kill** it.
The input is a few sentences ("there's a gap in X"); the gap **may not actually
exist**, and finding that out before the human spends real conviction or capital
is the whole point. Work flows through the normal PR machinery as a falsification
**dossier** under `validation/<idea-slug>/`; the curated `VERDICT.md` reaches
`integration`.

## The funnel

A single idea is funneled deep through **three gates, run in order**, each with a
kill-gate. The captain tracks the active phase via a GATE CHECKLIST in the
hypothesis issue; the floor reads it to know what to work on.

1. **Gate 1 · Market reality** — does the problem (C1) and the gap (C2) actually
   exist, or is it well-trodden with big incumbents / not actually painful? Runs
   **cheap-first**: one fast premise scan before the deep-research budget is
   committed. Most ideas should die here.
2. **Gate 2 · Solution** — if the problem is real: what product solves it, and
   does the concept survive attack (C3/C4)?
3. **Gate 3 · Business** — if there's something to build: how/whether it becomes a
   business and the best path (OSS-first, wedge-then-expand, services-led), with
   the paths ranked pairwise (C4/C5).

Any gate that meets a **pre-registered kill criterion** short-circuits the funnel:
the dossier is preserved, the issue is closed with a verdict epitaph, and the
human can **override** by reopening with either the missing evidence or an
explicitly accepted risk.

## The principle this encodes

Every "validate my idea" tool dies the same way — **motivated reasoning toward
yes**. The whole design is built to *kill* the idea, not bless it:

| Failure it fights | Where it lives |
|---|---|
| Goalpost-moving to save a beloved idea | The PM **pre-registers kill criteria per gate** in the frame, before any analysis; the GV gates that they can actually fire |
| Confirmation bias / cheerleading | The red-team (qa) carries the **burden of disproof**; analysts lead with the disconfirming case; the GV runs a standing confirmation-bias sweep on every verdict |
| False confidence | Every finding carries an **evidence tier** (`[E:cited]`/`[E:inferred]`/`[A:assumption]`); the adjudicator's confidence is **bounded by the weakest load-bearing link**; a GO resting on an unproven assumption is a CONDITIONAL-GO with a named test |
| Repeating one objection | Each honing round (2–3) uses a **different attack lens**; diverse attacks catch failure modes a repeated one never will |
| Desk analysis that over-trusts itself | Every section must name the **cheapest disconfirming test** — the real-world experiment that would settle the riskiest assumption |
| Spending the big budget on a dead premise | **Cheapest-kill-first** ordering: deep research only after the cheap premise scan survives |
| Binary kill when the real win is next door | **PIVOT** is a first-class outcome: the stated idea dies, but the live adjacent opportunity is surfaced |
| Burying a "no" | A KILL is the **product**; state is preserved and the "what would change this" revive criteria are presented, not softened into a maybe |

## Role contract at a glance

- **PM (Hypothesis Framer)** — few-sentence idea → gated hypothesis brief:
  decomposed *falsifiable* claims (C1 problem · C2 gap · C3 solution · C4
  wedge/moat · C5 business), pre-registered kill criteria per gate, evidence bar,
  rubric. Owns frame corrections and folds in overrides.
- **GV (Grand Vizier / standing skeptic)** — hard gate on frames (are the kill
  criteria honest and able to fire?); standing confirmation-bias watch on every
  verdict; advisory on the captain's gate calls.
- **Analysts (impl, stance-diverse)** — per active gate, produce dossier sections
  leading with the disconfirming case; stance per id (Gate 1: incumbents /
  demand / timing). Evidence tiers + a cheapest-disconfirming-test on every one.
- **Red-team (qa)** — run the 2–3 honing rounds, a different attack lens each
  round; sharpest tooth is evidence-tier integrity; merge a section only once it
  has *survived* attack (a stress-tested KILL counts as much as a GO).
- **Adjudicator (conductor)** — sole writer of `VERDICT.md` + the assumptions
  ledger; computes each gate's GO/CONDITIONAL-GO/KILL/PIVOT with bounded
  confidence; pairwise-ranks business paths; promotes the dossier to integration.
- **Captain (facilitator)** — owns the funnel cadence and the GATE CHECKLIST,
  the cheap→deep escalation, the GO/KILL/PIVOT calls (advised by the GV), the
  state-preserving short-circuit, and the evidence-gated override.

## How the branch ladder maps

| dev factory | validation factory |
|---|---|
| feature PR → staging | dossier-section PR → staging |
| QA gate (tests) | red-team gate (survived attack + evidence-tier integrity) |
| conductor e2e → integration | adjudicator integrity check + `VERDICT.md` → integration |
| human releases to main | human decides GO/KILL/PIVOT; a KILL is a closed issue the human can reopen to override |

Scope default: **"should *we* build it"** — the founder-market-fit /
unfair-advantage / distribution lens is in. Autonomy default: auto-advance
through earned GO gates, **halt and surface on every KILL / PIVOT / conditional-GO
needing spend**.
