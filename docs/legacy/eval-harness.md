# The eval harness (#8) — which model for which role, with evidence

```bash
fwf eval --role implementer --models claude-sonnet-4-6,claude-haiku-4-5-20251001
fwf eval --role qa --template refactor --models claude-opus-4-8,claude-sonnet-4-6 --trials 3
fwf eval --role captain --scenario needs-you --models default --judge-model claude-opus-4-8
```

## What it measures and how

The unit under test is **a role prompt × a model**: the harness renders the
role's *production* prompt (the same `fwf_render` + template path `fwf up`
uses), confronts it with a **scenario** — a fixture of the exact command
outputs an agent would observe on one loop tick — and asks the candidate
model (`claude -p --model M`, no tools) what it would do this cycle. An LLM
**judge** then scores the response 0–10 against the scenario's **rubric**,
with hard pass/fail conditions for the discipline violations that matter
(merging on a red gate, fixing a bug inside a refactor, branching before the
atomic claim…). Output: a markdown report with per-trial scores and mean per
model, plus full transcripts, under `eval/results/<ts>-<template>-<role>/`.

This follows the published eval guidance for agentic systems (the research
brief on #9): start small (~a handful of cases, grow toward ~20), judge
**end-state** (the action the agent commits to, not its turn-by-turn path),
use LLM-as-judge against an explicit rubric, and keep transcripts for
inspection.

## What ships (6 scenarios; adding more is a directory)

| template/role | scenario | the discipline it probes |
|---|---|---|
| dev/implementer | `claim-race` | atomic-claim protocol: yield to a live claim, supersede a stale one, claim before branching (#2) |
| dev/qa | `red-gate` | red gate → exact-output changes-request + repro branch; never merge, never fix their code |
| dev/captain | `needs-you` | status table first; surface BOTH pending human decisions; no self-authorized un-gating |
| refactor/implementer | `bug-found` | preserve the buggy behavior, characterize it, file separately; never fix in-band |
| refactor/qa | `expectation-edit` | catch a behavior change smuggled past a *green* gate via a test-expectation edit |
| ideation/implementer | `anchoring` | diverge before reading the portfolio; stance fidelity; no `Closes #N` on a challenge |

A scenario is just `eval/scenarios/<template>/<role>/<name>/scenario.md`
(observed state) + `rubric.md` (points + hard pass conditions). The judge
prompt, response format, scoring extraction, and report are the harness's
job; rubrics stay pure content.

## Factory *configurations*

Configuration questions decompose onto this harness today: a template change
IS a different role prompt (so `--template refactor --role qa` evaluates the
refactor verifier, not the dev QA), and the `--pairs`/model-mix question is
"which model clears the bar per role" × cost — read the per-role means and
staff accordingly (e.g. haiku-class clearing `qa/red-gate` at 8+ means cheap
verifiers are safe; a model failing `implementer/claim-race` must not run on
a contended floor). Whole-factory *simulation* (a live swarm on a sandbox
repo, judged on end-state throughput/quality) is deliberately out of scope
for v1 — it is an order of magnitude more tokens per data point and needs
hermetic gh/repo sandboxing first; the containers work (#3) is the natural
substrate when it's wanted.

## Hermetics & knobs

- `FWF_EVAL_CLAUDE_CMD` — substitute command for `claude` (the test suite runs
  the whole harness against a stub; no tokens burned in CI).
- `FWF_EVAL_RESULTS_DIR` — report location (default `eval/results`, gitignored).
- `FWF_EVAL_TIMEOUT` — per-call hard timeout, seconds (default 300; the
  harness has its own portable watchdog since macOS lacks `timeout`).
- `--models default` runs the CLI's default model (no `--model` flag).
- Every call's prompt, response, judge verdict, and stderr are saved per
  trial — the report is a summary, the transcripts are the evidence.
