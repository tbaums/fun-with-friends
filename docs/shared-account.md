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
via `fwf merge <n>` (issue #136 — composes the crafted squash body itself,
and since #207, also refuses the merge unless every issue the PR closes is
`fwf authz`-AUTHORIZED or NOT-GATED) once its gate is green, and signals
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
| `QA-CHANGES-REQUESTED: #<pr>` | qaN only | gate is red / docs missing / UI broken / adversarial artifact review found a real gap (issue #119) — details + an optional `qaN/repro-<pr>` branch follow |
| `QA-APPROVED: #<pr>` | qaN only | gate is green and (for load-bearing changes) the calibrated adversarial artifact review passed — merging now |
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

## The operator un-gate authorization signal (issue #150, anchored per #218)

A third instance of rule 2, one level up the pipeline: a human operator's
approval to build a gated ticket is also just a comment on the shared
account, so a role cannot trust label state or another pane's on-screen text
as "the human approved this" — a role once hallucinated a confirmation out of
another pane's autosuggest ghost text, re-gated four approved tickets, and
closed three PRs on the strength of it. The fix is the same shape as
`QA-*`/`GV-*`: a durable, greppable marker, checked by one tested helper
instead of hand-parsed prose.

```
fwf authz <issue>
```

prints one of five verdicts, each with both a distinct **exit code** and a
human-readable line naming a concrete next action:

| Verdict | Exit code | Meaning |
|---|---|---|
| `AUTHORIZED` | 0 | An anchored, correctly-referenced sentinel is present — safe to proceed, do not re-gate. |
| `HELD` | 10 | No anchored sentinel. Routine, expected, boring — hold and ask. |
| `INVALID` | 11 | A sentinel-**shaped** line sits at column 0 but is malformed (no parseable issue reference, or names a different issue than the thread it's in). Security-relevant — a forgery attempt or a botched operator action — and surfaced on `fwf dash`'s decisions panel, not only here. |
| `INDETERMINATE` | 2 | The thread could not be read — an *availability* failure, not an authorization one. Fail closed: treat exactly like `HELD`. |
| `NOT-GATED` | 12 | This issue never carried the gate label — there is nothing to un-gate (issue #215). **Not the same as `AUTHORIZED`**: it means no gate was ever applied, not that a human approved anything. Determined from label *history*, not current label state, so an issue that WAS gated and later un-gated still resolves `HELD`/`AUTHORIZED` as before — only a currently-ungated issue with NO gate history at all (or one whose only gate episode's un-gate predates the sentinel mechanism, 2026-08-12) reaches this verdict. An unreadable label history fails closed to `HELD`, noting the read failure. |

**Column-0-per-comment, like `QA-*`/`GV-*` — but per LINE, not just the first
line of the comment**, and with one more step: fenced (` ``` `/`~~~`) and
indented code regions are stripped BEFORE the column-0 check runs. A fence at
column 0 is the natural way to *document* the sentinel's format — every doc
describing the un-gate flow shows the payload that way — so content inside
one must never itself authorize, regardless of where it sits. The matcher
also tolerates up to two leading `*`/`_` characters (a markdown bold/italic
opener): the real operator un-gate comments on this floor are posted as
`**OPERATOR-UNGATE #<n>** — ...`, measured from live threads before deciding
this, not assumed — a strict byte-0 requirement would silently `HELD` every
currently-authorized ticket.

The verdict keys on the **comment thread only, never the issue body** — a
ticket can legitimately contain the sentinel's literal text in its own body
while *specifying* this mechanism, and that must never self-authorize it.

**A security oracle must not emit a string that satisfies its own matcher:**
none of `fwf authz`'s own output ever prints the literal sentinel — every
occurrence, including a quoted matched line in an `AUTHORIZED` verdict, is
defanged (`OPERATOR-UNGATE` → `OPERATOR[-]UNGATE`) before printing. That is
what stops a `HELD`/`INVALID` message — or this doc's own examples — from
later being pasted back into a thread and satisfying the matcher it was
reporting on.

**The mechanical check is a floor, not a ceiling.** A role that distrusts an
`AUTHORIZED` verdict still holds and says why — that override is conformant
behaviour, not a bug to be refactored away.

An operator un-gates via `fwf dash`'s approve action, which posts the
anchored sentinel and removes the gate label in one step; see `docs/dash.md`.

## `fwf claim`: a fail-FAST checkpoint at intent-formation time, not a control (issue #243)

`fwf authz` above is the SOLE oracle; `fwf claim <issue>` is not a second
one — it is the ergonomic half of a fix split from issue #207 (which keeps
the actual enforcement checkpoint at merge/promote/release, refused
repository-side). Without it, an implementer discovers a `HELD` issue is
not authorized only at merge — after the work is already done, the most
expensive possible moment to learn it, and exactly the pressure that
produced the forged `CAPTAIN-NOTICE` incident this floor has already lived
through once.

**Stated everywhere a reader might stop, not only here**: `fwf claim <n>`
can simply be skipped — an agent that never runs it is not blocked by it.
Its value is making the authorized path the *easy* path; `fwf authz`'s
repository-side companion (#207) is what actually binds. `fwf claim --help`
and every refusal/success message repeat this, deliberately, because the
terminal is where a reader concludes a check was passed — not the docs.

```
fwf claim <issue-number>
```

runs `fwf authz` first and branches on its verdict:

| Verdict | `fwf claim` |
|---|---|
| `AUTHORIZED` / `NOT-GATED` | proceed |
| `INDETERMINATE` | **warn** ("infrastructure" cause) and still proceed — claiming is cheap and reversible, so refusing on a mere read failure would manufacture the exact stall this exists to relieve |
| `HELD` / `INVALID` | **refuse**, exit 1, naming the verdict and a "policy" cause, plus the exact `fwf authz <n>` to run next |

It also scans the issue body for a declared `## HARD PREREQUISITE` heading
(the convention `#135` already uses) and **warns, never refuses**, on any
named prerequisite that is not itself authorized — a scan of a heading, not
a schema; two independent attempts to derive this from free prose (one
reading, one writing) produced false positives in most of their own spot
checks, so an absent heading is reported as exactly that — "no heading
found" — never as "no prerequisites exist".

On success it creates the claim artifact and nothing else: an empty
`claim #<n>: <title>` commit — no branch create/switch (issue #177: git
allows one worktree per branch, and a verb that switches branches inherits
that contention; one that only commits does not). The caller is expected
to already be on the branch it wants this commit on.

Refusals append to a durable, bounded rolling log
(`$FWF_STATE_DIR/claim-refusals.log`) that `fwf dash` reads as a count — a
plain file read, never a fresh `fwf authz` per candidate issue per render
(issue #239 already measured that per-render cost as the dash's dominant
term) — rendered as a red "N blocked on authz" header badge, distinct from
`FLOOR IDLE` (calm, deliberate) and absent entirely once the queue drains.

**Recorded exclusions** (issue #243 AC e2/e3): `templates/dev/pm.tmpl:29`
mentions "implementers can claim #N now" — that is PM narrating to the
human that the gate is off, not a call site that itself performs a claim,
so no `fwf claim` wiring belongs there. `_local-issues/implementer.tmpl`
keeps its own atomic CLAIM-*comment* protocol (the comment IS the claim;
there is no separate empty-commit artifact), a different mechanism this
issue does not touch. `consulting/implementer.tmpl` and
`user-testing/implementer.tmpl` don't reference the `claim #<n>: <title>`
issue-claiming convention at all — `consulting`'s "claim" is a specialist
picking a lens/section, an unrelated sense of the word — so neither needed
adoption.

## Reviewer routing: the `fwf-Reviewer:` marker (issue #194)

`gh pr edit --add-reviewer` is not usable here either, for the same reason
formal reviews don't work (rule 1 above): every seat authenticates as the
same account, so GitHub's reviewer-assignment machinery is structurally
meaningless on this account. Reviewer routing therefore reuses the marker
pattern rule 2 established, one level up the pipeline: **who reviews a PR is
an explicit, recorded fact, never re-derived from the PR's branch name.**

Inferring the reviewer from a `headRefName` prefix (qaN reviews only
`implN/*`) works for the common case but has no answer for a `captain/*`,
`gv/*`, `pm/*`, or `conductor/*` branch — and those are sanctioned (the
captain template's direct-build escape hatch, used for meta-property
verification, deadline-critical fixes, or avoiding an e2e collision). A PR
on one of those branches was invisible to every QA's branch-prefix survey:
not lower priority, structurally unreachable. Worse, when it did eventually
merge, it merged with no reviewer able to see it — an unreviewed merge by
construction, not by anyone's choice.

**Mechanism:**

- At PR creation, the body carries a first-column line: `fwf-Reviewer:
  qaN` (or `none`), written by `fwf pr-assign-reviewer <head-branch>`.
  Assignment is deterministic and keyed off the CONFIGURED seat roster —
  never a live/liveness view: an `implN/*` branch always routes to `qaN`
  (today's pairing, unchanged); any other branch routes to the
  least-loaded configured QA seat, ties broken by lowest seat index; zero
  QA seats configured routes to `none`. Liveness is deliberately absent
  from the decision — a seat being briefly down (respawn, budget hold)
  must not permanently skew where its next PR routes.
- QA's survey resolves each PR's CURRENT assignment with
  `fwf pr-reviewer <n>`, which returns `qaN`, `none`, `NO_MARKER` (no
  marker was ever written — the migration case, see below), or `UNKNOWN`
  (the PR itself couldn't be read this cycle — never collapsed into
  `NO_MARKER`, since a transient read failure misreading an explicitly
  assigned PR as unassigned would silently strip its routing).
- **Precedence**, when both a body marker and comment markers exist: any
  comment marker beats the body marker; among comment markers, the newest
  wins; the body marker is only the creation-time default. Re-routing a
  PR (e.g. the assigned seat was removed from the profile) is done by
  posting a fresh `fwf-Reviewer: qaN` comment — never by editing the body.
- **Migration is permanent, not a transitional shim.** A PR opened before
  this marker existed, or opened by hand outside `fwf pr-context`/`fwf pr-
  assign-reviewer` entirely, has no marker (`NO_MARKER`). QA's survey
  falls back to the branch-prefix rule ONLY in that case, so a human PR on
  an `implN/*` branch still routes to `qaN` as it always did, and a human
  PR on any other branch is correctly left unrouted rather than guessed at.

**Commands:**

```
fwf pr-assign-reviewer <head-branch>   # decide a NEW PR's reviewer (write side)
fwf pr-reviewer <pr-number>            # resolve a PR's CURRENT reviewer (read side)
```

Both are pure/tested helpers (`fwf-pr-assign-reviewer.sh`,
`fwf-pr-reviewer.sh`) — no role should hand-parse a PR body/comment thread
for a `fwf-Reviewer:` line itself, for the same reason `fwf pr-review-state`
exists: the parsing rules (precedence, the unreadable-vs-empty distinction)
are easy to get subtly wrong reimplemented ad hoc, and drift is worse than
a shared dependency.
