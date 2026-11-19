# Prompts

The job templates, the verdict contract, the placeholders the supervisor fills, and the template families.
The prompts carry the role judgment, so they are the part worth reading closely.

**The full guide is [`prompts/README.md`](../prompts/README.md)**, kept beside
the prompts it describes. A test fails the build if it misses a role or a
placeholder. This page is a summary and map of it.

## Where they are

```
prompts/<family>/<role>-job.md     roles: impl, qa, gv, pm
prompts/<family>/impl-rework.md    the impl seat's second job shape
```

The manifest's `template` key picks the family (default `dev`). A family only
overrides the roles whose judgment differs. Any job it does not define falls
back to `prompts/dev/`. The families are `dev`, `refactor`, `validate`,
`ideation`, `consulting`, `defect-report` and `user-testing`. The README's
table links each one.

The prompts are compiled into the binary. Once per process it writes them to
`~/.fwf/prompts/<family>/<file>` and reads them from there, so neither a
source build nor a release asset needs the checkout it was built from. That
copy is the binary's, not yours: every run overwrites it, and removes any file
the binary does not carry. To change a prompt, edit it under `prompts/` and
rebuild. `fwf doctor --assets` lists every job a family resolves to, with its
size, and fails if one is missing, empty or uses an unknown placeholder. See
[`verbs.md`](verbs.md).

## Placeholders

The supervisor fills exactly these, and a test refuses any prompt file that
uses another:

`{{SEAT}}`, `{{REPO}}`, `{{ISSUE}}`, `{{TITLE}}`, `{{BODY}}`, `{{BRANCH}}`,
`{{PR}}`, `{{HEAD}}`, `{{BASE}}`, `{{CHECK}}`, `{{REVIEW}}`, `{{DEADLINE}}`,
`{{GV_REFUSAL_REASON}}` (PM only: why GV refused the previous spec) and
`{{SPEC}}` (QA only: the issue's spec, read at dispatch).

What each one holds, per role, is in the guide.

## The verdict contract

Every job ends with the path of one verdict file. The seat writes JSON there:
first to `<path>.tmp`, then renamed. The supervisor reads it as data and does
every GitHub write itself. The `verdict` field picks the shape:

| `verdict` | From | Fields | What the supervisor does |
|---|---|---|---|
| `implemented` | impl, rework | `branch`, `head` (40-char sha), `summary` | pushes the branch upstream; the first time, opens the draft PR |
| `reviewed` | qa | `head`, `approve`, `notes`, `criteria` | posts the review under `qa`, anchored to `head`. An approval must list every acceptance criterion |
| `triaged` | gv | `ready`, `reason` | first pass, not ready: gates the issue and posts the reason. At sign-off, not ready: sends the spec back to PM. Ready: a note in the record |
| `specced` | pm | `title`, `body`, `discovery`, `questions` | writes the spec into the issue, adds `discovery` if asked, posts the questions |
| `blocked` | any | `reason` | releases the claim, or reports the refusal |

Each `criteria` entry is `{"criterion", "status", "evidence"}`, and `status` is
`met`, `not_met` or `not_verifiable`. A verdict that does not parse is "not
yet" until the deadline, then the seat is Stalled.

## What every job must say

Tests check every prompt in every family for these:

- it is a one-job prompt (`exactly ONE`);
- it offers the `blocked` verdict;
- it carries the deadline line, `Your job deadline is {{DEADLINE}}; push before
  it — a partial result beats a stall.`;
- it tells the seat its commit identity is already set, and never tells it to
  set one;
- it never tells the seat to run `gh issue` or `gh pr`;
- every QA job carries `{{SPEC}}` and asks for the criteria list.

## See also

- [`prompts/README.md`](../prompts/README.md) — the full guide: ground rules, every role, every placeholder, the families.
- [`seats.md`](seats.md) — how a job reaches a seat.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
