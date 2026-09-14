# The job prompts

One file per (family, role). Each is the whole of what a seat is told on one
wake: the job, what it may not do, and the single JSON verdict it must write
back. They carry the role's judgment — what a good implementation is, what a
review must check, what makes a ticket ready — and nothing about coordination.

This guide is checked against the code by
`prompts::guide_covers_every_role_and_placeholder`: every role in `ROLES` and
every token in `PLACEHOLDERS` must appear below, and no token outside that list
may. Adding a role or a placeholder to `one/src/prompts.rs` without updating
this file fails the test.

## Why one job, one verdict

The obvious way to build an agent factory is a long-running loop per agent:
poll the tracker, claim work, do it, repeat. fwf 0.x worked that way. A looping
agent spends most of its tokens on coordination it is bad at — reading state it
does not need, re-deriving what it already knew, negotiating with siblings
through comment protocols, deciding whether to keep waiting — and it drifts: a
session running for hours carries a context it did not choose, and its
behaviour on hour six is not what you tested on hour one.

So the port removed coordination rather than translating it. There are no
claims, no heartbeats, no stop files, no marker comments and no "each cycle"
loops in these files, because a woken seat has nothing to coordinate with. It
receives one rendered prompt, does the job, writes one verdict, and stops. Its
context is the job. When the supervisor wakes it again it is a different job
with a fresh prompt, and the seat's earlier work is only scrollback in the same
pane.

What is left is judgment, which is the part worth writing carefully. The
supervisor holds all the state and makes every decision that must be right
every time — which issue is next, which commit the work must sit on, whether a
review counts, whether a merge is allowed — in code, with tests. A prompt is
where a lesson goes so that it is applied on every wake rather than remembered
by whoever is watching: "write the verdict with a real JSON serializer" is
there because a seat once hand-typed JSON with unescaped quotes.

## Ground rules

These hold for every prompt, and most are asserted by the test beside this
guide (`every_family_resolves_every_role_and_uses_only_known_placeholders` in
`one/src/prompts.rs`) rather than left to review:

- **No `gh`.** The test fails any prompt containing `gh issue` or `gh pr`.
  Seats have no GitHub token, so the command would fail anyway; the rule exists
  so a prompt never *asks* for something the seat cannot do.
- **No token, mirror only.** A seat's single remote is a bare mirror on the
  same machine, cloned over a `file://` URL. Every GitHub write is the
  supervisor's, performed as one of three App identities: `fwf-impl` opens and
  updates pull requests, `fwf-qa` posts reviews anchored to an exact commit,
  and `fwf-ops` merges, labels, records check-runs and cuts releases. Their
  permission sets are in `docs/github-apps.md`; `fwf-impl` and `fwf-qa` are
  `Contents: Read` and cannot write to a branch at all.
- **The deadline line.** Every job ends with the same sentence, naming
  `{{DEADLINE}}`, so a seat cuts a long proof short instead of parking on it.
  The test requires it verbatim.
- **The commit-identity line.** Every job states that the worktree already
  commits as this seat. The test requires that sentence verbatim *and* fails
  any prompt containing `git config user.name` or `git config user.email`:
  commit identity is the supervisor's to set, never the seat's to change.
- **No polling, no siblings.** Nothing in a prompt tells a seat to wait, watch,
  retry later, or read another seat's work. There is nothing to poll with.
- **One verdict, written atomically.** Every job instructs the seat to build
  the JSON with a real serializer, write it to `<path>.tmp`, and `mv` it into
  place as a separate step — so the supervisor can never read a half-written
  file. `read_verdict` in `one/src/seat.rs` parses it with `serde_json`; a file
  that does not parse becomes `SeatError::Malformed`, carrying the parse error
  and the first 400 characters of what the file actually held. A missing file
  is not an error — it means the seat has not answered yet.

## What the supervisor fills in

These are the twelve tokens in `PLACEHOLDERS`. A prompt may use only these; the
test names any other as an unknown placeholder, so a typo can never reach a
seat as literal text.

| token | what it holds |
|---|---|
| `{{SEAT}}` | which seat this is (`impl1`, `qa2`) |
| `{{REPO}}` | the `owner/name` being worked |
| `{{ISSUE}}` | the issue number |
| `{{TITLE}}` | the issue title |
| `{{BODY}}` | the issue body, as written |
| `{{BRANCH}}` | the branch the seat must create and use |
| `{{PR}}` | the pull request number under review |
| `{{HEAD}}` | the exact commit sha being reviewed or reworked |
| `{{BASE}}` | the branch the PR targets |
| `{{CHECK}}` | the repository's own check command, run before pushing |
| `{{REVIEW}}` | the review text an impl seat must answer (rework only) |
| `{{DEADLINE}}` | local `HH:MM` when this cycle ends |

## Roles

Four roles, matching `ROLES` in `one/src/prompts.rs`. A file is
`<family>/<role>-job.md`; a family that does not define one falls back to
`dev`.

### impl

Implement one issue and push a branch. The seat works in its own git worktree,
runs the repository's own check before pushing, and pushes only to the mirror —
the supervisor opens the pull request from the verdict, under `fwf-impl`.

Given `{{SEAT}}`, `{{REPO}}`, `{{ISSUE}}`, `{{TITLE}}`, `{{BODY}}`,
`{{BRANCH}}`, `{{CHECK}}`, `{{DEADLINE}}`.

Must never: run `gh`, open the PR itself, or push to the base branch.

```json
{"verdict":"implemented","branch":"<branch>","head":"<40-char sha>","summary":"<one sentence>"}
{"verdict":"blocked","reason":"<why you could not complete it>"}
```

`slice.rs` reads an `implemented` verdict and opens or refreshes the draft PR;
a `blocked` verdict releases the claim instead.

#### The rework job

`<family>/impl-rework.md` is the impl seat's *second* job shape, not a fifth
role: what it is woken for after QA requests changes on a PR it already opened
(#576). It is keyed on `{{REVIEW}}` — the review text it must answer — and also
receives `{{PR}}`, `{{HEAD}}` and `{{BASE}}` so it reworks the exact commit that
was reviewed. `rework_path` resolves it the same way as a role file, falling
back to `dev`, and `rework.rs` substitutes `{{REVIEW}}` before waking the seat.
It answers with the same two verdicts as `impl`.

### qa

Review one pull request and answer with an approval or a request for changes,
anchored to the head it actually read. The seat reads the diff and runs the
check; it never merges, and it never posts the review itself — `qa.rs` posts it
under `fwf-qa`, anchored to that commit, so an approval of an older head is not
an approval of this one.

Given `{{SEAT}}`, `{{REPO}}`, `{{ISSUE}}`, `{{TITLE}}`, `{{BODY}}`, `{{PR}}`,
`{{BRANCH}}`, `{{HEAD}}`, `{{BASE}}`, `{{CHECK}}`, `{{DEADLINE}}`.

Must never: merge, label, push, or approve its own work.

```json
{"verdict":"reviewed","head":"<the sha reviewed>","approve":true,"notes":"<what you checked>"}
{"verdict":"blocked","reason":"<why you could not review>"}
```

### gv

Judge whether an issue is ready to be built, and say concretely what is missing
if not. A not-ready verdict gates the issue under `fwf-ops`; only a human can
un-gate it again.

Given `{{REPO}}`, `{{ISSUE}}`, `{{TITLE}}`, `{{BODY}}`, `{{DEADLINE}}`.

Must never: edit the issue, apply the label itself, or decide on the human's
behalf when the question is a product decision.

```json
{"verdict":"triaged","ready":true,"reason":"<one sentence: why this is ready>"}
{"verdict":"triaged","ready":false,"reason":"<what is missing, concretely>"}
{"verdict":"blocked","reason":"<why you could not decide>"}
```

`triage.rs` reads it; the gate label and the reason are written under
`fwf-ops`.

### pm

Write the spec for a gated issue: the problem, the proposed behavior,
acceptance criteria, edge cases, what is out of scope. The gate stays on —
`spec.rs` writes the spec into the issue under `fwf-ops` and leaves the label
untouched, because writing a spec is not the decision to build it.

Given `{{REPO}}`, `{{ISSUE}}`, `{{TITLE}}`, `{{BODY}}`, `{{DEADLINE}}`.

Must never: un-gate, start implementing, or invent questions that do not change
what gets built.

```json
{"verdict":"specced","title":"<final title>","body":"<the full markdown spec>","discovery":false,"questions":[]}
{"verdict":"blocked","reason":"<why you could not spec it>"}
```

`questions` is for questions that change what gets built; `discovery` marks a
ticket that needs investigation before it can be specced at all. Both default
to empty/false when omitted.

## Families

The manifest's `template` key picks the family; `dev` is the default and the
fallback for any role a family does not define.

**`dev`** — building software on a real codebase, and the only family that
defines all four roles plus the rework job. Every other family inherits from
it. This is the one proven live.

**`refactor`** — behavior-preserving change: the structure of the code improves
and its observable behavior does not change at all. Characterize first, one
mechanical move per commit, and never edit an expectation to make a test pass.
Defines `impl` and `qa`; `gv` and `pm` fall back to `dev`.

**`validate`** — falsification dossiers for an idea, written under
`validation/<idea-slug>/` against pre-registered kill criteria. Evidence is
tiered explicitly (`[E:cited]`, `[E:inferred]`, `[A:assumption]`) and QA
red-teams the dossier rather than checking a diff. Defines `impl`, `qa`, `gv`.

**`ideation`** — one idea brief per wake, under `ideas/<challenge-slug>/`, with
the stance assigned by the issue rather than chosen by the seat. Defines
`impl`, `qa`, `gv`.

**`consulting`** — evidence sections for a diagnosis engagement, under
`findings/<engagement-slug>/`. The client's repository is read-only input named
in the engagement's `MANIFEST.md`: never branched, committed to, or written.
Roles are named by function, not by person. Defines `impl`, `qa`, `gv`.

**`defect-report`** — one receiver-ready defect report per run, under `runs/`,
with every claim a locator into a named source of truth (a log, a failing test,
a transcript). If the issue's feasibility read is FAIL the seat reports blocked
rather than building. Defines `impl` and `qa`.

**`user-testing`** — use the product as a real person with an assigned
archetype and goal, and keep a diary. Source-blind by construction: the seat's
worktree holds no product source, so it can only report what a user could see.
Defines `impl` (the persona) and `qa` (the researcher).

## Not prompts

The captain and the conductor of 0.x are code now, not roles: `fwf status`,
`fwf dash`, `fwf gate`, `fwf promote`. A `dev-sre` family was considered and
dropped — production operations is `fwf status`/`dash` plus the operator, not a
seat.

## Eval harness

`eval/run.sh` (0.x) drives prompts through `claude -p` against fixture
scenarios and an LLM judge. It has not been re-run on these one-job prompts:
it is metered, and the scenario fixtures still describe the looping protocol.
Porting the harness to feed a woken seat instead of `claude -p` is the open
piece of T-26.
