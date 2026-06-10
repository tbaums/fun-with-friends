# The refactoring factory (#10) — design and research basis

Run it with:

```bash
fwf up --template refactor          # or FWF_TEMPLATE=refactor, or per-profile
fwf templates                       # list shipped templates
```

Same physical topology as the dev factory (N impl/qa pairs + conductor on the
floor; PM · GV · CAPTAIN in coordination), different semantics: every role is
re-prompted for **behavior-preserving structural change**. Templates live in
`templates/<name>/` — six role prompts plus an optional `template.sh` of
config defaults (the refactor template defaults to `FWF_PAIRS=2`).

## The research this encodes

The design follows the published consensus on multi-model refactoring systems
(see the research brief attached to issue #9, whose Part 2 is exactly this
problem; sources include Anthropic's multi-agent writeup, the SWE-Refactor
benchmark, and 2025–26 agentic-coding surveys):

> **Parallelize understanding and verification, serialize the editing, and
> make behavior-preserving verification the spine.**

Mapped to roles:

| Research finding | Where it lives |
|---|---|
| Surveying/review is the genuinely parallel phase of codebase work | PM fans out read-only survey subagents per module, findings written to the EPIC issue (artifact store), then synthesized into a ranked plan |
| Prioritize by change pressure, not aesthetics | PM ranks by **churn × complexity** with evidence (`git log` frequency × size/nesting); GV rejects "it's ugly" as a priority argument |
| Editing is the *least* parallelizable part; agents coordinate poorly in real time | Captain releases items in **dependency order**, pre-assigns via `ASSIGNED implN` (the #2 mechanism) as the norm, keeps blast radii disjoint, serializes when in doubt; template defaults to 2 pairs |
| Verification must be first-class, not a final rubber stamp | QA's behavior-contract review: **no edits to existing test expectations**, no smuggled behavior changes, characterization-tests-first ordering checked in the commit history, gate + static-analyzer pairing |
| Behavior preservation needs pinning before transforming | Refactorers **characterize first**: thin coverage → write tests that pin *current* behavior (bugs included), commit them first, watch them pass on unrefactored code |
| Long-horizon degradation: quality erodes over marathon sessions | One small item per claim, fresh loop cycle each; small mechanical steps, gate green at every commit; big-bang scope is GV-rejected |
| Big-bang rewrites are the failure mode | GV's standing reframe is the **strangler fig**: new shape behind a seam, migrate callers incrementally, delete the old last |
| Bug discovered mid-refactor must not ride along | Refactorers preserve the buggy behavior, characterize it, file a separate issue; captain surfaces the bug list to the human as a fix/defer decision |
| e2e as the behavior backstop | Conductor treats any e2e movement as a preservation breach until proven environmental |

## The role contract at a glance

- **PM (refactor planner)** — parallel survey → evidence-ranked plan → small
  gated items with: preservation invariants, honest blast radius, explicit
  `depends on #M` edges, out-of-scope (always: bug fixes).
- **GV (architecture critic)** — hard gate on specs: hunts hidden behavior
  changes, dishonest blast radius, missing dependency edges, big-bang scope;
  advisory on the captain's sequencing/batch plans.
- **Captain** — sequencing is the core job: ordered release, pre-assignment,
  small in-flight set, dup/overlap deconfliction; releases with proof of
  invisibility ("no user-visible changes" verified live).
- **Refactorers** — claim atomically; characterize first; one mechanical move
  per commit, gate green at each; never edit expectations; never fix bugs
  in-band; zero file overlap with in-flight PRs is a hard eligibility rule.
- **Verifiers** — diff-first behavior-contract check, then gate, then
  analyzer-delta vs base; merge only with invariants stated and held.
- **Conductor** — unchanged mechanics, stricter posture: red e2e = behavior
  drift until proven environmental.
