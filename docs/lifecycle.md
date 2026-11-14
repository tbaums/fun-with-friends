# Lifecycle of an issue

The path one issue takes through a floor, from filing to `main`, and the labels
that steer it. Every step below is something `fwf run` does by itself on a
tick. The hand-run verb that does the same step is named beside it.

```
filed (gated) → GV triage → PM spec → GV sign-off → un-gate
  → slice (impl) → QA → merge to staging → post-merge gate → promote to main
```

## Labels

| Label | Who sets it | Meaning to the loop |
|---|---|---|
| `product-wip` (the manifest's `gate_label`) | you when filing, or GV on a not-ready verdict | Awaiting review. The spec cycle works these issues. A sign-off and an un-gate take the label off. |
| `idea`, `release-hold`, `tracking`, `build-epic` (default `skip_labels`) | you | Parked. Never triaged, specced or planned. |
| `discovery` | PM, when the spec says the deliverable is a proposal rather than code | Added only, never removed. It parks nothing unless you list it in `skip_labels`. |
| `needs-human` | the loop, after GV refuses the spec too many times | The spec cycle has given up on this issue. It stays gated. |
| `fast-track` | you, by hand | Skip review: the issue is eligible for an impl seat without a sign-off. The record notes the bypass once. |
| `claimed` | not set by fwf | An issue carrying it is never planned. |

Two words used below:

- An issue is **signed off** when the latest `issue` event in the run record
  says `ready`. Only `fwf ungate` and the delegated un-gate write that event.
  The missing gate label does not make an issue eligible; that event does.
- An issue is **eligible** for an impl seat when it is open, signed off (or
  `fast-track`), opened by the repository owner, unassigned, unclaimed, not
  parked by a skip label, and in the manifest's `issues` allow-list.

## 1. Filing

File the issue with the gate label on. An issue without it is not picked up by
the spec cycle, and is not eligible either until someone signs it off.

With `triage_new = true`, GV also reads every open, un-gated, unclaimed issue
the record has never judged, whether or not it is on the allow-list. If GV
finds one not ready, the loop adds the gate label and posts the reason. If GV
finds it ready, that is only a note, and the issue still needs an un-gate.

## 2. Triage, spec and sign-off (`auto_spec`)

Each tick, with `auto_spec = true` and both a `gv` and a `pm` seat configured,
the loop takes at most one step of this cycle per stage. `review_scope`
decides which gated issues it looks at. Skip labels always win.

1. **GV first pass** (`fwf triage`). GV reads the raw ticket. A not-ready
   verdict keeps the issue gated and posts the reason. The issue comes back to
   GV only after someone edits it. A ready verdict earns the issue a spec,
   nothing more.
2. **PM spec** (`fwf spec`). PM writes the spec into the issue's title and
   body. The spec includes the acceptance criteria QA will check. PM may add
   `discovery`, and posts its open questions as one comment. The gate label
   stays on.
3. **GV sign-off**. GV reads the spec back. If GV refuses it, the reason is
   posted and recorded, and PM revises the spec with that reason
   (`{{GV_REFUSAL_REASON}}`) on the next tick. PM gets at most two revisions.
   If GV still refuses, the loop adds `needs-human` and stops working the
   issue.
4. **Un-gate** (`fwf ungate`). After a ready sign-off:
   - with `delegate_ungate` unset, the issue waits for a human to run
     `fwf ungate`;
   - with `delegate_ungate = "NAME"`, the loop removes the label itself and
     records `NAME` as the actor, marked as delegated. It does this only for
     issues in `issues`. A signed-off issue outside the allow-list waits, and
     is un-gated on a later tick if you add it to `issues`.

If a human puts the gate label back on a signed-off issue, the loop records
`gated` and the issue loses its eligibility until it is un-gated again.

## 3. Slice: the impl seat (`fwf slice`)

The planner takes eligible issues oldest first. An issue whose last cycle was
refused goes to the back of the queue. An impl seat that still has an open PR
of its own does not start another issue.

For each issue it plans, the loop:

1. writes a claim, `refs/claims/<n>` at the base branch's tip. That sha is the
   **fence**;
2. wakes the impl seat with the family's `impl-job.md`. The seat creates
   `impl<seat>/issue-<n>-…`, makes the change, runs the `fast_suite` command
   given to it as `{{CHECK}}`, pushes to the local mirror, and writes an
   `implemented` verdict;
3. pushes that branch from the mirror to GitHub, and opens a draft PR as
   `impl`.

A `blocked` verdict releases the claim. If GitHub refuses the push, for
example because the branch touches `.github/workflows/` and the App lacks
`workflows: write`, the claim and the branch are kept. The push is retried
every tick, and the issue is never re-sliced while the push is owed.

A seat that passes `job_timeout_secs` is `Stalled`. An impl seat quiet for
`stall_quiet_secs` is called `Stalled` early. A stalled seat's job still
belongs to it, so if its verdict lands later the loop delivers it. Twenty
minutes after the stall the loop releases the seat (`fwf release` does it
sooner).

## 4. QA (`fwf qa`)

QA takes open PRs, drafts included, that have no review at their current head,
oldest first, one per idle QA seat. In the loop that means PRs that close an
allow-listed issue. Before waking the seat, the supervisor reads the issue the
PR closes (`Closes #N` in the PR body). The issue body is the PM spec, and it
goes into the job as `{{SPEC}}`, cut at 20,000 characters. If GitHub yields
nothing, the PM's `verdict-spec-<n>.json` on the floor is used instead.

**No spec, no QA.** If the PR closes no issue, or no spec can be found, the seat
is not woken and a `Refused` event says why. The loop tries again next tick.

QA's verdict:

- **Approve.** The verdict must list every acceptance criterion as `met`,
  `not_met` or `not_verifiable`, each with evidence. An approval with no
  well-formed list, or with any `not_met`, is rejected: nothing is posted and
  QA is woken on the PR again. An accepted approval is posted as an `APPROVED`
  review under `qa`, anchored to the head QA read, with the checklist in its
  body.
- **Request changes.** This posts a changes-requested review. Next tick, the
  impl seat that owns the branch gets a rework job (`impl-rework.md`, with the
  review as `{{REVIEW}}`) on the same branch. A changes-requested review from
  the repository owner or a login in `reviewers` counts the same way. Rework
  rounds per PR stop at `rework_cap`, and the PR then waits for a human.

## 5. Merge (`fwf merge`)

When a PR is approved at its current head, the loop marks it ready under `ops`
and merges it with the typed merge. The merge refuses unless:

- the claim for the closed issue is still live at the fence;
- the approval is from someone other than the author, at the exact head being
  merged;
- every check-run on that head has completed successfully.

The PR is squash-merged into `base_branch`, the claim is released, and the
record gets `merged` and `shipped`. If GitHub calls the PR not mergeable
because the base moved, the owning seat gets a rebase round, which counts
against `rework_cap`.

A shipped issue is never planned again, even though GitHub keeps it open until
`Closes #N` reaches the default branch.

## 6. Post-merge gate

Right after each merge, the loop runs `fast_suite` on the merge sha. It runs in
the floor's `gate-wt`, which the loop clones from the mirror the first time,
using the manifest's `gate_venue`. The verdict is recorded and posted as a
`fwfd/<suite>` check-run. A Red gate does not revert anything. It means that
sha cannot be promoted. See [`gates-and-promotion.md`](gates-and-promotion.md).

## 7. Promote (by hand)

The loop never moves `release_branch`. An operator runs:

```bash
fwf promote --repo o/r --from staging --to main --suite fast
```

It fast-forwards `main` to staging's tip, but only if that exact sha has a
recorded Green for that suite. Releases are cut from `main`; see
[`releasing.md`](releasing.md).

## See also

- [`verbs.md`](verbs.md) — each step's verb, its flags and its refusals.
- [`prompts.md`](prompts.md) — what each seat is told and what it returns.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
