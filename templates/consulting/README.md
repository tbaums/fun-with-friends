# `consulting` — the diagnosis firm (a 3-phase falsification funnel)

A fwf factory template that diagnoses whether an **agent-built software pipeline's
shipped quality actually regressed** and, if so, **why** — then proposes CLEAR,
COMPREHENSIVE, DIRECTLY-APPLICABLE fixes. It treats "quality collapsed" as a
**hypothesis to verify, not a fact**: `"no real decline / drift / unverifiable"`
is a first-class win.

Built on the `validate` template (`FWF_TEMPLATE_BASE="validate"`) — same falsification
machinery (pre-registered criteria, evidence tiers, paired analyst/red-team debate,
pairwise ranking, the advisory `FWF_REPO`=findings-repo wiring) — with all six role
prompts reframed for diagnosis. The Phase-3 replay capability follows the seam cut by
`templates/user-testing/` (a pool of runners against a target they don't modify).

## The shape — a funnel, not a panel

```
client brief + MANIFEST.md
      │
  framer/registrar  ── pre-registers premise (P1-P3), boundary-significance BAR,
      │                six-lens coverage gate, evidence tiers, scoring rubric
      │                (BEFORE any evidence is seen) ──► GV hard-gates the frame
      ▼
  PHASE 1 · PREMISE GATE   ◄── the engagement can END here
      │   six-lens bench (model·prompt·orchestration·process·codebase·metrics)
      │   + mandatory "other/unknown" contender, each hardened by a red advocate
      │   Blue: "real decline + boundary"   Red (paid): "variance/expectation/imagined"
      │   judge scores vs the pre-registered rubric · ties → null
      ├─► DRIFT / NO REAL DECLINE / UNVERIFIABLE ──► short-circuit: deliver the null dossier
      ▼   (DECLINE CONFIRMED)
  PHASE 2 · CAUSE TOURNAMENT   closed-set elimination
      │   each contender must name a DATED DELTA on the bad side whose fingerprint
      │   matches, and beat the null + confounders on tiered evidence
      │   survivors COEXIST, ranked by causal strength (score capped by weakest tier)
      ▼
  PHASE 3 · EMPIRICAL REPLAY   (OFF by default; human-enabled)
      │   single API-pinned impl1: git-restore old prompts/models, re-run real briefs,
      │   try to DISCONFIRM each cause · degrades gracefully when un-replayable
      ▼
  judge assembles DOSSIER.md ──► GV audits under-call AND over-call ──► captain presents ──► human decides
```

## Role remap (fwf archetype filename → reframed job)

| file | archetype | reframed job |
|---|---|---|
| `pm.tmpl` | framer | **framer/registrar** — frames from MANIFEST.md; PRE-REGISTERS premise, boundary bar, rubric before evidence |
| `implementer.tmpl` | analyst | **lens-specialist** (one of six lenses, blind to the others) + Phase-3 **replay-runner** (impl1 only) |
| `qa.tmpl` | red-team | **citation-cop / Red advocate** — enforces evidence tiers, paid to defend the null |
| `conductor.tmpl` | adjudicator | **judge/synthesizer** — adjudicates premise gate + tournament, assembles the dossier |
| `gv.tmpl` | standing skeptic | **standing-skeptic sign-off** — hard-gates the frame; audits BOTH under-call and over-call |
| `captain.tmpl` | orchestrator | **phase-state orchestration** — tracks the funnel phase, not a linear build checklist |

## Pointing the firm at an engagement

The firm is **advisory**: `FWF_REPO` is the firm's own findings repo; the client
repo is **read-only input the floor never writes**. You re-point it per client with
an **evidence MANIFEST**, not by editing the template.

1. **Stand up the findings repo** (once): a firm-owned repo (e.g.
   `<your-org>/consulting-findings`) with `staging` + `integration` branches, cloned to
   `FWF_REPO` (see `profiles/consulting.sh`). Everything the firm writes lands here.
2. **Write `MANIFEST.md`** at the root of `FWF_REPO`. It lists THIS engagement's
   sources **by type** (never as paths the template assumes):

   ```markdown
   # Engagement manifest
   - engagement-slug: <target>-YYYY-MM
   - target repo:      /path/to/<target-repo>    (READ-ONLY input)
   - target tracker:   <org>/<target-repo>
   - factory config:   the fwf <target> profile + template + role→model mapping
   - claimed good era: <a green pre-collapse release tag/date>  ← the boundary to test
   - orchestration logs: OFF   (privacy: slice by timeline; never ingest whole .jsonl/memory)
   - phase-3 replay:   OFF     (a human enables; single API-pinned impl1 only)
   ```

   The same fields may also be exported as `FWF_EVIDENCE_*` on the launch (see the
   profile). The role prompts read `MANIFEST.md` and discover sources by type:
   timeline from git+changelog+issues; the re-fix trail from linked/duplicate
   issues; the good/bad boundary; and — since the target is agent-built — the
   factory config + role→model mapping.
3. **Launch** (never while another factory is running — OOM on the 8-core box):
   ```
   fwf --profile consulting up
   ```
   Attach to the captain, hand it the client brief, un-gate the frame once the GV
   signs it off.

## What it emits — the dossier (`findings/<engagement-slug>/DOSSIER.md`)

- **Premise verdict (up front):** did quality actually decline, on which axes, by
  how much, with the pre-registered metrics + the boundary test? `no real decline /
  drift / unverifiable` is legitimate.
- **Executive answer (if the premise holds):** the ranked surviving cause(s), plainly.
- **Evidence:** the boundary, the dated deltas + fingerprints, the tournament
  outcomes, and any replay experiments — each tagged by evidence tier.
- **Ranked recommendations:** each CLEAR (what to change) · COMPREHENSIVE (the
  failure *class*) · DIRECTLY APPLICABLE (the exact file / prompt / role / gate /
  model, and how) · expected impact · rough effort · how we'll know it worked.
  In scope: codebase, factory prompts/roles/gates, models, orchestration + human-in-
  the-loop, and (near-standing) an **always-on quality instrument** so the next
  diagnosis is telemetry, not memory-archaeology. Un-replayable cause → a
  going-forward **model-pinning** recommendation.
- **Open gaps:** what it needed but couldn't get, and what was un-replayable, honestly.

## Structural guarantees + residual-risk mitigations (baked in)

- **Pool incompleteness** (tournament) → mandatory **"other/unknown" contender** +
  a **coverage gate** (judge won't adjudicate Phase 1 until all six lenses +
  other/unknown are covered) + a late-seeding window.
- **No-boundary manufacturing** (bisection) → a **significance gate** (a
  pre-registered number the boundary must clear) + a **rewarded "this is drift"**
  output.
- **False balance** (red/blue) → a **summary-judgment fast-path** (judge may
  short-circuit an overwhelming one-sided decline) + a **GV under-call audit**.
- **Un-replayable drift** (phase 3) → **graceful degrade** to correlational
  fingerprint attribution + a **model-pinning** recommendation.

## Verify / acceptance

Coherence checks and the three acceptance fixtures (known-answer seeded regression,
no-decline falsification, reproducibility) are scaffolded under
[`eval/`](eval/README.md). Run a real engagement as a **separate,
standalone** factory run — never nested inside a build/eval run.
