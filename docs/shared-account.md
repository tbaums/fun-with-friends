# The shared-GitHub-account reality

Every role in a factory (PM, GV, captain, every implN/qaN pair, the
conductor) can authenticate as the **same** GitHub account (`gh auth status`
resolves to one identity for all of them). Two consequences fall directly out
of that, and both are load-bearing enough that role prompts work around them
explicitly rather than assuming normal multi-user GitHub semantics:

## 1. Formal PR reviews don't work

`gh pr review <n> --approve` / `--request-changes` fails with "Can not
request changes on your own pull request" whenever the PR's author and the
reviewer are the same account — which, on a shared account, is *always*.
qaN's role prompt therefore never calls `gh pr review`; it **merges directly**
(`gh pr merge --squash --delete-branch`) once its gate is green, and signals
"changes requested" as a plain PR comment instead (see below). The formal
`reviewDecision` / `mergeStateStatus` review fields stay permanently empty on
this account — no role should ever read them as "no changes requested".

## 2. Author-based disambiguation doesn't work

Because the comment-author field is identical for every role, you cannot
tell qaN's comments apart from implN's by *who posted them*. Any protocol
that needs qa and impl to signal different things to each other must
disambiguate by **marker string**, never by author — and each role must be
disciplined about which markers it is permitted to emit, since that
discipline is the *only* thing preventing a role from mistaking its own
comment for the other side's signal.

## The qa↔impl review-state protocol (issue #82)

This is the concrete instance of rule 2. It mirrors the PM↔GV
`GV-SIGNOFF`/`GV-CHANGES` convention (`docs/tutorial.md`) one level down the
pipeline:

| Marker (first line of a plain PR comment) | Posted by | Meaning |
|---|---|---|
| `QA-CHANGES-REQUESTED: #<pr>` | qaN only | gate is red / docs missing / UI broken — details + an optional `qaN/repro-<pr>` branch follow |
| `QA-APPROVED: #<pr>` | qaN only | gate is green, merging now |
| `IMPL-ADDRESSED: #<pr> <sha>` | implN only | acknowledges a fix pushed in response to a `QA-CHANGES-REQUESTED` |

implN is a **hard rule** never to emit a line starting with `QA-` at the
start of a comment — that asymmetry, not the (identical) author field, is
what makes self-trigger impossible.

Rather than have every impl/qa role hand-parse the PR thread from prose
(fragile, and drifts as prompts are edited independently), the parsing lives
in one tested helper:

```
fwf pr-review-state <pr-number>
```

which prints exactly one line:

- `CHANGES_REQUESTED <repro-branch|none>` — the latest `QA-*` sentinel is an
  unanswered `QA-CHANGES-REQUESTED`.
- `AWAITING_REVIEW` — implN has already responded (a newer `IMPL-ADDRESSED`
  comment, or — if none exists yet — a newer commit push), or no `QA-*`
  sentinel exists at all.
- `APPROVED` — the latest `QA-*` sentinel is `QA-APPROVED`, or the PR is
  merged/closed.
- `NONE` — not a usable PR number.

Rules the helper applies (`fwf-pr-review-state.sh`, tested in
`test/run.sh`):

- **Last `QA-*` sentinel wins** — a later `QA-APPROVED` supersedes an earlier
  `QA-CHANGES-REQUESTED`, and a fresh `QA-CHANGES-REQUESTED` after an
  `IMPL-ADDRESSED` re-activates the fix path.
- **Column-0-only** — a sentinel counts only at the very start of a comment
  body. A `QA-CHANGES-REQUESTED` string appearing mid-comment (e.g. quoted
  inside an `IMPL-ADDRESSED` acknowledgement) never matches.
- **Newer-than-addressed** — a `QA-CHANGES-REQUESTED` is "active" only if it
  postdates implN's response. implN's latest `IMPL-ADDRESSED` **comment**
  timestamp is the primary signal (a clean comment-vs-comment compare); the
  PR's newest commit `committedDate` (what `gh pr view --json commits`
  exposes) is only a fallback for when no `IMPL-ADDRESSED` exists yet, because
  an amended/rebased/cherry-picked commit's `committedDate` can predate the
  actual push and would otherwise misread a genuinely-newer fix as an
  unanswered request.

### How each role uses it

**implN**, before it may report a PR "awaiting qaN review — idle": run
`fwf pr-review-state <n>`. `CHANGES_REQUESTED` means fix it and post
`IMPL-ADDRESSED`; `AWAITING_REVIEW`/`APPROVED` means idle is correct.

**qaN**, before it may idle on a PR it has an open `QA-CHANGES-REQUESTED`
on: run `fwf pr-review-state <n>`. `AWAITING_REVIEW` means implN has
responded — re-review now (never idle waiting for a fix that already
landed); `CHANGES_REQUESTED` (its own, unanswered) means idle is correct.

This closes the deadlock from both sides at once: an impl that only checked
the (permanently empty) formal review API would report "awaiting review"
forever even after qa posted a plain-comment request, and a qa that only
posted its request and never re-checked would never notice implN's fix — the
respawn-safe fix is that the durable PR thread is the source of truth for
both directions, not a role's local memory of what it last saw.
