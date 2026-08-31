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

### `fwf ungate <n>`: the same un-gate, from the operator's own shell (issue #213)

`fwf dash` approve is the board's un-gate; `fwf ungate <n> [<n>...]` is the
same action run **on the operator's own machine**, for a stalled floor
noticed from a phone, an ssh session, or the concierge proxy rather than the
TUI. It performs the operator's own hand-rolled ritual as one verb — post
the anchored sentinel, remove `product-wip`, bust the gh read cache (#167)
so the un-gate is visible on the very next read, then run and show `fwf
authz <n>`'s verdict — and both paths call the same
`fwf_ungate_comment_body()` (`lib.sh`) so they can never drift in the
anchored format `fwf authz` actually keys on.

**The label is a convenience index for surveying, never the authorization —
the comment is.** Implementers survey issues *without* `product-wip`
(`templates/dev/captain.tmpl:6`), so after a `fwf ungate` run, label-off will
usually mean signature-present. That inference stays false: anyone can still
remove the label by hand, producing an issue that looks claimable while `fwf
authz` reports `HELD`. Issue #207's repository-side merge/promote/release
refusal is what makes that divergence harmless — it checks `fwf authz`, not
the label — which is why `fwf ungate` increases #207's value rather than
being independent of it.

Multiple issues each get their **own** comment naming their own issue number
— never one comment covering several, since `fwf authz <n>` matches a
sentinel bearing *that* issue's number specifically. One issue failing does
not abort or roll back the others; each is reported on its own line, and the
command exits non-zero if any failed. It is idempotent: an issue with no
`product-wip` no-ops rather than posting a second sentinel, so a retry after
a partial failure is always safe. `--via cli|concierge-proxy` (default
`cli`) records how the invocation happened, folded into the comment as
free text after the sentinel — `fwf authz` itself never depends on it, and
`fwf ungate --audit` lists every un-gate on the floor with its issue,
timestamp, and invocation path by reading the un-gate comments themselves,
never a separate log.

Like `fwf dash`'s approve, this posts a real comment and removes a real
label — **it is not a second authorization mechanism**. `fwf authz` remains
the sole oracle; this only automates a human posting the same signal by
hand.

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
fwf claim <issue-number> [role]
```

runs `fwf authz` first and branches on its verdict:

| Verdict | `fwf claim` |
|---|---|
| `AUTHORIZED` / `NOT-GATED` | proceed |
| `INDETERMINATE` | **warn** ("infrastructure" cause) and still proceed — claiming is cheap and reversible, so refusing on a mere read failure would manufacture the exact stall this exists to relieve |
| `HELD` / `INVALID` | **refuse**, exit 1, naming the verdict and a "policy" cause, plus the exact `fwf authz <n>` to run next |

### Claim-race adjudication (issue #462)

Before #462, the implementer template asked the agent to post a `CLAIM
implN` comment by hand, then re-check the thread itself to see if its
comment landed first — a PROSE compare-and-set. Two seats claiming the
same issue inside the loop-latency window (a few seconds apart, four
observed occurrences in one night) could both comply with that prose
perfectly and both proceed, because nothing there ever refused — the
ticket then sat unadjudicated until a human noticed, ~25 minutes each
time.

`fwf claim` now closes that race itself when `[role]` is given:

1. **Posts** `CLAIM <role>` (folding what used to be a separate, earlier
   `gh issue comment` call the agent ran by hand into this one tool
   call).
2. **Busts the ghcache** view of the issue's comment thread
   (`fwf-ghcache.sh invalidate issue <n>`, the same write-through
   primitive the operator-approve path already uses) before reading it
   back — a compare-and-set against a snapshot up to `TTL`-seconds stale
   is not a compare-and-set.
3. **Re-reads** the thread and finds the FIRST claim comment that is
   still LIVE, via `fwf_claim_liveness_blocks` (`lib.sh`) — the SAME
   liveness signal `fwf claim-liveness`, the conductor's build-plane
   guard, and `fwf scale`'s idle-impl check already use, so this fourth
   call site can never disagree with the other three about who currently
   holds a claim. An old, abandoned claim is not live, so it never
   blocks a fresh attempt — only a genuinely concurrent claim can.
4. If another seat's claim is that first live one, `fwf claim` **refuses**
   (exit 1, a "race" cause distinct from "policy"/"infrastructure") and
   posts a `STAND-DOWN #<n>: <role> — <winner> claimed first...` comment
   on the issue itself — the losing seat is TOLD on the thread, not
   silently dropped.

`[role]` is optional: omitted, `fwf claim <n>` behaves exactly as before
#462 (the caller is assumed to have already posted its own CLAIM comment
and re-checked it won) — this remains an ergonomic checkpoint, not a
control, skippable either way.

It also scans the issue body for a declared `## HARD PREREQUISITE(S)` /
`## HARD DEPENDENC(Y|IES)` heading (issue #370 widened the accepted
spellings to what this floor actually writes) and **warns, never
refuses**, on any named prerequisite that is not itself authorized — a
scan of a heading, not a schema; two independent attempts to derive this
from free prose (one reading, one writing) produced false positives in
most of their own spot checks, so an absent heading is reported as
exactly that — "no heading found" — never as "no prerequisites exist".

**Lifecycle and authorization, reported as two separate lines, never
merged (issue #370).** For each declared prerequisite, `fwf claim` now
also reports whether the referenced issue's *work exists at all* —
`OPEN`, `CLOSED (completed)`, or `CLOSED (not planned)` — alongside, but
never combined with, its `fwf authz` verdict. The reason: a `not_planned`
closure can still carry the gate label, so its authz verdict reads `HELD`
forever — indistinguishable from one merely awaiting a keypress unless
lifecycle is reported separately. The same `case` split now also gives
`INVALID` and `INDETERMINATE` their own distinct, loud lines instead of
folding both into the same "not yet clear" wording as a routine `HELD`.

**A second, weaker scan covers free-prose mentions.** Most prerequisites
on this floor are written in prose, not under a heading — the declared
scan above deliberately does not (and cannot) read that. Instead, `fwf
claim` separately scans the WHOLE body (fenced/indented code excluded, up
to `FWF_CLAIM_MENTION_CAP` distinct `#N` references, default 20, with an
explicit notice if the cap is hit) for any mentioned issue that is closed
`not_planned`, and prints it under an explicitly-labeled "weak signal"
heading — a lookup ("this body mentions #N, and #N was declined"), never
an inference about whether #N is actually depended on. A mention of an
issue that was never real (a typo, or a different identifier namespace
reusing the `#N` spelling, e.g. a transom message id) is a silent skip;
a genuine read failure renders loud instead, on the same "never let a
read failure collapse into silence" principle used throughout this file.

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
- **"Correctly left unrouted" still needs a signal, or it strands silently
  (issue #385).** `fwf pr-route-check sweep` — ENFORCED every captain tick,
  same as `flag-captain sweep` — raises a `needs-captain` flag on any open,
  non-draft, non-`implN/*` PR whose `fwf pr-reviewer` verdict stays
  `NO_MARKER` past a grace period (`FWF_PR_ROUTE_GRACE_SECS`, default 300s).
  It never guesses a reviewer itself (that would reintroduce #194's
  original defect) — only the signal is automatic; a human/captain still
  posts the `fwf-Reviewer:` comment, at which point the flag clears itself
  on the next sweep with no manual `--clear`.

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
