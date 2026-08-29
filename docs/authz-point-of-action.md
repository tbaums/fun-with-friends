# Authorization at the point of action (issue #207)

## Problem

`fwf authz` makes the authorization *signal* unforgeable (#191/#215/#218).
It leaves *enforcement* as an agent reading a verdict and choosing to
comply — still prose-mediated trust, one layer out. On 2026-08-24 a forged
`CAPTAIN-NOTICE` file asserted an issue was authorized and that an
`INDETERMINATE` verdict was "a TOOLING DEFECT, not a gate." Nothing in the
system stopped an agent from believing it. This ticket makes the gate
refuse **at the point of action**, so a forged notice becomes inert: it can
persuade an agent completely, and the action still refuses.

## The stale citation, corrected

#207's own text asserts *"the merge path is not an `fwf` path"* and cites
QA hand-composing `gh pr merge --squash --delete-branch` inline. **That was
true when #207 was written; it no longer is.** Issue #136 (merged this
session, after #207 was filed but before it was built) introduced `fwf
merge <n>`, wired into `templates/dev/qa.tmpl` as *the* command QA's role
prompt instructs it to run instead of hand-composing `gh pr merge`. That is
the real, already-adopted chokepoint #207's own AC(l) asks for — no new
verb, no adoption problem, the same shape #207's own "INTERIM: the `gh`
shim" section asked for a different command.

## What's built

`fwf-merge.sh`, right after it resolves the PR's linked issue(s)
(`_fwf_pr_ctx_pr_linked_issues`, already multi-issue-aware from #136's own
"multiple issues -> picked the lowest" handling) and *before* composing the
squash body or merging:

- Calls `fwf authz <n>` for **every** linked issue (not just the one #136
  picks for the context fold) — checking only the first is a plausible bug
  and a real hole, named explicitly in #207's edge cases.
- Classifies by `fwf authz`'s own exit code (AC c):
  - `0` (AUTHORIZED) or `12` (NOT-GATED, #215) → proceed.
  - `2` (INDETERMINATE) → refuse, message names it **INFRASTRUCTURE**, not
    policy — the oracle itself could not be read.
  - `10` (HELD) / `11` (INVALID) → refuse, message names it **POLICY** — the
    oracle read fine and said no.
  - Any other exit → refuse, fail-closed, named as unexpected.
- Refuses unless **every** closed issue passes (AC: the multi-issue edge
  case) — a PR closing two issues where only one is authorized still
  refuses.
- Every refusal is also raised as a `needs-captain` flag (#113's existing
  mechanism — `fwf flag-captain <issue> --role qa --reason "..."`) on the
  blocking issue, naming the PR, the verdict class, and the exact retry
  command. The captain's per-tick sweep already reads this — a refusal is
  loud and addressed to a human-facing role from the first occurrence, not
  a silently-retried loop (AC g's underlying concern, satisfied via an
  existing channel rather than new state).
- **AC (e), reproduced as a test:** a `CAPTAIN-NOTICE`-shaped file asserting
  authorization, sitting in shared state, changes nothing — `fwf-merge.sh`
  never reads it; only `fwf authz`'s own verdict decides.
- **AC (d), regression:** `fwf gate` is untouched by this change — a `HELD`
  issue's PR can still run the full gate to prepare a fix while waiting.
- **AC (i):** `NOT-GATED` proceeds everywhere this check runs.
- **AC (k), informational:** when a PR has no linked issue at all and its
  branch name references a number, the (pre-existing, #136) refusal message
  now names that number as a hint — not a gate change, since #136 already
  refuses unconditionally either way (see below).
- **AC (l), the discriminating test:** `test/run.sh` drives the refusal
  through `fwf-merge.sh` directly — the real script `fwf merge <n>` execs
  into, the same one `templates/dev/qa.tmpl` instructs a seat to run — never
  a test-constructed wrapper.

## AC (j) — superseded, not built as specified

#207's AC (j) asks: *"An unlinked PR merge proceeds AND is counted"* — the
`"the unlinked-PR hole"` section frames this as the ticket's most likely
real-world defeat, since omitting `Closes #N` walks straight through the
guarded path.

**This scenario cannot reach the authz check at all via `fwf merge`.**
#136's `fwf-merge.sh` — already shipped, already the real call path per the
correction above — refuses **unconditionally** when a PR has no resolvable
linked issue, for an unrelated but strictly stronger reason (a squash-merge
body needs an issue to fold context from). Every PR that reaches this PR's
new authz-check loop is *guaranteed* to have at least one linked issue
already. This closes the underlying concern (a merge silently skipping
enforcement because it names no issue) more completely than "proceed and
count" would have — it cannot happen at all via the real path, so there is
nothing to count. I did not relax #136's existing refusal to reintroduce
the scenario #207's AC(j) wanted to merely observe.

## Honesty requirement (AC h) — stated plainly, in these words

**A CLI check is mechanical only if the CLI is the only path. It is not.**

1. **Every seat holds full `gh` credentials.** A seat can bypass `fwf
   merge` entirely and call `gh pr merge` (or the raw GitHub API) directly
   — this check has no way to intercept that. It raises the cost of an
   unauthorized merge from *zero* to *deliberate*; it does not make one
   impossible. (The `ghguard` shim's own `gh`-mode branch passes every
   command straight through with no interception today — closing that
   specific gap, by adding a `pr merge` case there too, is real future
   work, not claimed as done here.)
2. Unlike #207's original framing, the **unlinked-PR bypass is closed**
   (see above) rather than merely observed — but that closure rests on
   `fwf merge` staying the actual call path. If a future change ever makes
   `fwf-merge.sh` tolerate a PR with no linked issue for some other reason,
   this authz check's coverage would have the same gap #207 originally
   described, silently.

## Deferred, explicitly

- **AC (f) / (g): a literal `fwf dash` counter for blocked-on-authz
  refusals.** `fwf-dash-data.sh` has no existing surface for `needs-captain`
  flags at all today (checked directly — no matches). Piggy-backing this
  ticket's refusal on that flag mechanism gives real, working, per-tick
  human-addressed visibility (see above) without inventing new dash state,
  but it is not literally "a distinct dash state with a count." Building
  that is a separate, real increment against `fwf-dash-data.sh` /
  `fwf-dash.sh`, not bundled here.
- **The `ghguard` shim's `gh pr merge` interception** named in #207's own
  "INTERIM" section — `fwf merge` is the now-adopted primary path (see
  above), so the shim path is lower-priority defense-in-depth rather than
  the primary chokepoint #207 originally scoped it as.
- **Root-owning the shim / #216's workflow-neutering question / #220's
  repository-side required-context** — out of scope, per #207's own
  sequencing (a separate, larger design already tracked there).
