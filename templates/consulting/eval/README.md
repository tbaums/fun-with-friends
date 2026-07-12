# `consulting` — acceptance eval (SCAFFOLD)

The build's real gate is not a live engagement run — it is **three acceptance fixtures**.
This directory **scaffolds and documents** them; it does **not** ship full fixture
repos and does **not** run a factory (that is a separate, standalone step — never
nest factories: OOM on the 8-core box).

## Two different "evals" — don't confuse them

- The repo-level `eval/run.sh` (at the fwf root) is a **role×model** harness: it
  renders one role prompt through `fwf_render` and scores a single tick against a
  scenario rubric with an LLM judge. Useful for picking a model per seat; it does
  **not** exercise the whole 3-phase funnel. (You can add `consulting` role
  scenarios under `eval/scenarios/consulting/<role>/…` later — additive, out of
  scope here.)
- This directory's acceptance fixtures are **engagement-level**: each is a whole
  diagnosis run judged by its DOSSIER verdict against a known ground truth. That
  requires launching the `consulting` factory once per fixture and reading the
  emitted `DOSSIER.md` — hence "standalone, not nested," and why `run.sh` here is a
  **scaffold** that prepares + checks fixtures and prints the intended flow rather
  than launching anything.

## The three acceptance fixtures (from the brief)

| fixture | ground truth | the firm PASSES iff the dossier… |
|---|---|---|
| `fixtures/known-answer/` | a target repo + factory config with a **seeded, dated** regression cause on the bad side of a real boundary | names that seeded cause as a ranked survivor, citing its dated delta + matching fingerprint |
| `fixtures/no-decline/` | a target with **no** real decline (stable quality; any wobble within variance) | returns **NO REAL DECLINE / DRIFT / UNVERIFIABLE** — does **not** manufacture a collapse or convict a cause |
| `fixtures/reproducibility/` | either of the above, run **twice** | two independent runs **converge** on the same premise verdict (and, if declined, the same top-ranked cause) |

Each fixture directory holds:
- `MANIFEST.md` — the engagement manifest the firm consumes (target repo, tracker,
  factory-config location, claimed good-era ref, replay off). A **stub** here; the
  full seeded fixture repo is built in the standalone acceptance step.
- `expected.md` — the ground truth + the pass assertion the dossier is checked
  against (what a correct `DOSSIER.md` must and must not say).

## How `run.sh` would invoke them

`run.sh [fixture…]` (scaffold): for each named fixture (default: all three) it
(1) validates the fixture has `MANIFEST.md` + `expected.md`, (2) prints the
standalone command an operator runs to execute that engagement, and (3) prints the
assertion to check the resulting `DOSSIER.md` against `expected.md`. It **refuses to
launch a factory itself** — wiring the launch + the dossier-diff is the standalone
acceptance step, intentionally left to a human so no factory is nested inside a
build/eval run.

```
# standalone acceptance (run ONE fixture at a time, never nested):
#   1. build/seed the fixture's target repo + factory config
#   2. drop fixtures/<name>/MANIFEST.md at the findings-repo root
#   3. fwf --profile consulting up        # attach, run the funnel to a dossier
#   4. assert DOSSIER.md satisfies fixtures/<name>/expected.md
#   5. for reproducibility: repeat 3-4 and diff the two premise verdicts
```
