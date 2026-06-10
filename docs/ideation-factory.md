# The ideation factory (#9) — design and research basis

```bash
fwf up --template ideation
```

Same topology, new product: instead of code, the factory produces **ranked,
comparison-ready idea portfolios**. Ideas are markdown briefs under `ideas/`
in the target repo, flowing through the same PR machinery; the curated
portfolio (`ideas/PORTFOLIO.md`) is what reaches `integration`.

## The research this encodes

From the research brief attached to issue #9 (Part 1: multi-agent
orchestration lessons) plus the established ideation/brainstorming
literature:

| Finding | Where it lives |
|---|---|
| Parallelism pays off on *divergent* work; Anthropic's multi-agent system won on breadth-first tasks | Generation is the wide phase: 3 generator/critic pairs by default; convergence (synthesis/ranking) is a single serialized role |
| Group brainstorming anchors on early ideas; nominal (independent) groups outperform interacting ones in idea production | **Diverge first, read the portfolio second**: generators produce 8–12 raw candidates *before* looking at anyone else's merged ideas |
| LLM idea sets suffer low diversity (mode collapse) | **Stance-diverse generators by id**: user-pain-first / analogy-transfer / constraint-inversion; the GV runs a standing monoculture sweep on the portfolio |
| Deferred judgment; quantity breeds quality (Osborn) | Raw candidate generation is censor-off; the critic's merge bar is "comparison-ready", explicitly *not* "guaranteed winner"; critics are instructed to protect the weird ones |
| LLM-generated ideas skew novel-but-infeasible (human-judge studies) | The critic's highest-value move is feasibility *hardening*: every brief needs a smallest-real-version and a testable riskiest assumption |
| Build on others' ideas ("yes-and") — but without clobbering | Generators never edit others' briefs; they extend in new briefs crediting the source; the synthesizer files explicit `combine:` requests |
| Pairwise comparison beats absolute scoring for judgment reliability | The synthesizer ranks within clusters head-to-head, then orders clusters |
| Evaluate end-state, not turn-by-turn; subagents write to an artifact store | Briefs and PORTFOLIO.md are the artifacts; challenge issues hold the thread; the captain reports portfolio state, not agent chatter |
| Converge deliberately (diverge/converge is a cadence, not a phase you fall into) | The captain owns the rhythm with explicit signals: diverge while batches surprise; converge when 3 consecutive batches land in existing clusters or TOP PICKS are stable across two promotions |

## Role contract at a glance

- **PM (challenge framer)** — fuzzy prompt → gated challenge brief: HMW at the
  right altitude, constraints marked HARD/SOFT, success criteria, deliberate
  rubric weights, a diversity check that all three stances can engage. Owns
  frame corrections mid-flight (comments, never re-gating).
- **GV (strategic critic)** — hard gate on frames (altitude, constraint
  honesty, rubric deliberateness); standing portfolio-diversity sweep;
  advisory on the captain's convergence calls.
- **Generators (impl)** — stance per id; diverge independently; develop 1–3
  briefs per batch PR with a fixed brief template (concept, who, why-now,
  novelty vs named prior art, feasibility path + riskiest assumption,
  builds-on, open questions). No `Closes #N` — challenges outlive batches.
- **Critics (qa)** — rubric review per batch (novelty honesty, feasibility
  hardening, impact, clarity); dup check against portfolio + open PRs; merge
  at comparison-ready; concede when the generator argues back and wins.
- **Synthesizer (conductor)** — sole writer of PORTFOLIO.md: cluster,
  cross-pollinate (combine: requests), rank pairwise, integrity-check (every
  brief indexed, links resolve, no undeclared dups), promote to integration.
- **Captain (facilitator)** — owns divergence/convergence cadence; presents
  TOP PICKS as decisions with a recommendation; drives winner handoff (e.g. a
  dev-factory issue set from the winning brief); floor lifecycle for token
  conservation between challenges.

## How the branch ladder maps

| dev factory | ideation factory |
|---|---|
| feature PR → staging | idea-batch PR → staging |
| QA gate (tests) | critic gate (rubric) |
| conductor e2e → integration | synthesizer integrity check + PORTFOLIO.md → integration |
| human releases to main | human picks winners; captain drives handoff |
