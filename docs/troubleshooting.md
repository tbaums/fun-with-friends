# Troubleshooting

The known gotchas and their fixes: stale worktrees, App push refusals, a verdict read mid-write, N-times loops against a deadline, `Cargo.lock` and `--locked`.
Each entry names the symptom you would actually see first.

Start with `fwf status` (its **needs you** list) and
`fwf why <pr> --log <floor>/run.jsonl`. Most refusals below are also recorded
as `refused` events.

## The loop will not start, or does nothing

**`fwf run: the manifest has no `issues` allow-list; refusing …`**
`fwf run` needs a non-empty `issues` list. List the issues you want worked.

**`fwf run: the `issues` allow-list [...] matches no open, eligible issue`**
Printed every tick. Every listed issue is closed, shipped, or parked by a skip
label. Widen the list.

**An issue on the allow-list is never sliced.** It is not signed off. An issue
becomes eligible when the record holds a `ready` event for it, not when the gate
label comes off. Run `fwf ungate --repo o/r --issue N --by NAME`, or let the
spec cycle sign it off with `delegate_ungate` set. The issue must also be
opened by the repository owner, unassigned and unclaimed. See
[`lifecycle.md`](lifecycle.md).

**A re-run of `fwf triage` changed nothing.** Triage records a GV verdict. The
planner waits for the `ready` event that only an un-gate writes, so
re-triaging an already-specced issue records a second verdict and nothing
else.

**A signed-off issue stopped being worked.** Someone put the gate label back
on. The loop records that as `gated`, and the issue needs a fresh
`fwf ungate`.

**`fwf ungate` worked but the loop still ignores the issue.** The manifest sets
`floor_dir` or a non-default `gate_label`. Hand-run verbs always record into
`~/.fwf/floors/<repo-name>` and use `product-wip`, so the `ready` event landed in
a record the loop does not read. See
[`configuration.md`](configuration.md#verbs-that-ignore-floor_dir).

**`fwf up: refusing to start a floor on a stale fwf`.** A newer release exists.
Run `fwf self-upgrade`, or set `FWF_ALLOW_STALE=1` to start anyway.

## The floor is parked

**`fwf run: PARKED — last meter reading is 420m old`.** The last `weekly=` line
in `~/.fwf-meter-log` is older than 45 minutes. Either your meter helper
stopped, or the line was stamped in another timezone. Stamps are read in the
floor host's local time; generate them with `date` on that host. See
[`operations.md`](operations.md#the-meter-and-its-brake).

**`fwf run: PARKED — weekly meter NN% ≥ PP%`.** Working as intended. It resumes
on the first tick after a reading below `park_at_weekly_pct`.

**The floor spent past the limit and never parked.** There is no
`~/.fwf-meter-log`, or no `weekly=` line in it. With no reading the brake does
nothing.

## Seats

**`seat-up: no OAuth token in Keychain` (exit 3), or a pane that says it is not
logged in.** The pane got no Claude token. Save a long-lived one:
`claude setup-token`, then write it to `~/.fwf/seat-token` with mode `0600`.
Then take the seat down and up again: `fwf seats --down` (once nothing is
Working), then `fwf seats --up`. A pane that is already running `claude` is
left alone by `--up`, so a logged-out pane has to go first.

**`seat-up: pane … did not reach 'claude' within 30s` (exit 4).** `claude` is
not on the `PATH` tmux uses, or it stopped at a prompt. Attach to the session
and look at the pane.

**A seat job fails at once with `No such file or directory`.** Before 1.0.28
the binary read the job prompts from the `prompts/` directory of the tree it
was **built** in, so a release asset, or a build whose checkout had moved,
could not find them (#719). Upgrade: `fwf self-upgrade`. The fix ships in
1.0.28 (1.0.27 was never published, #734): the prompts are compiled in and
written to `~/.fwf/prompts/` by each run, so the checkout is not needed.
`fwf doctor --assets` lists every job and where it is read from; it fails if
one is missing or empty, and names `HOME` if `HOME` is not set.

**A worktree commits as the wrong person.** `fwf doctor` lists it as `WRONG`.
Run `fwf seats --up`, which re-applies every seat's identity.

**A STALLED seat holds its seat id for both roles, for a while.** A stall is not
a dead job. The supervisor is the only thing that ever kills a pane, so a seat
past its deadline may still be finishing, and its issue or PR stays nobody
else's. Seat ids are shared across roles, so while `qa1` is Stalled, `impl1`
cannot be assigned either. The loop releases the seat by itself twenty minutes
after the stall. To call it dead sooner:

```bash
fwf release --seat 1 --role qa --by NAME
```

It refuses anything that is not Stalled, because a Working seat's job is live.
The released job is re-planned from scratch. A verdict that lands after the
release is ignored.

**Jobs keep stalling at the deadline.** Every job prompt carries
`{{DEADLINE}}`, and the seat is told that a partial result beats a stall. If
real work routinely needs longer, raise `job_timeout_secs`. If an impl seat is
called Stalled while it is still thinking, raise `stall_quiet_secs`, or set it
to `0`.

**A verdict was "not yet" for minutes, then the seat stalled.** The seat wrote
its JSON straight into the verdict path in pieces, or hand-typed invalid JSON.
A verdict counts only once the file parses, so a half-written one is "not yet"
until the deadline. The parse error and the raw text are on the loop's stderr.
The prompts tell the seat to write `<path>.tmp` and rename it.

## Pushes and branches

**`refusing to allow a GitHub App to create or update workflow … without
`workflows` permission`.** The branch touches `.github/workflows/`, and the
`impl` App lacks `workflows: write`. This is a permission to grant, not a
verdict on the code. The claim and the branch are kept, the push is retried
every tick, and `fwf status` lists it under **needs you**. Grant the
permission in the App's settings, then re-accept it on the installation.
`fwf doctor` warns about this. See [`github-apps.md`](github-apps.md).

**`fwf qa` says the head "does not exist after git fetch origin", or `mirror
upstream/<branch> is …, PR head is …`.** The branch was pushed to GitHub by
hand, and seats only see the mirror's `refs/heads/`. Fetch it in:

```bash
git -C /path/to/floor/mirror/mirror.git \
  fetch upstream "+refs/heads/impl1/*:refs/heads/impl1/*"
```

**`refs/claims/<n> exists upstream and this floor's record does not own it`.**
Another floor, or an earlier record, holds the claim. Leave it alone unless you
know it is dead.

## QA and merge

**`spec unavailable for #N: … QA seat not woken`.** QA is held to the spec. The
PR closes no issue, or the issue has no body and the floor has no
`verdict-spec-N.json`. The loop retries every tick, so a transient GitHub
failure heals by itself. A PR that sits un-reviewed with this refusal needs a
spec: give the issue a body, or run `fwf spec`, and make sure the PR body says
`Closes #N`.

**`QA approval rejected: …`.** The approval did not list every acceptance
criterion as `met`, `not_met` or `not_verifiable` with evidence, or it listed a
`not_met`. No review is posted, and QA is woken on the PR again. Nothing caps
these repeats yet (#716). Watch for a PR that keeps coming back.

**`merge refused ×N … not mergeable`.** The base moved after the claim was
taken, and the branch conflicts. The loop gives the owning seat a rebase round,
which counts against `rework_cap`. Past the cap, the PR is listed under
**needs you**.

**`PR #N hit the rework cap`.** QA, or a reviewer, asked for changes
`rework_cap` times. Close the PR or push a fix yourself.

**`fwf merge: no live claim ref for issue #N; refusing`.** The PR body does not
say `Closes #N`, or the claim was released. A merge needs the fence.

## Gates

**`fwf gate` with an abbreviated sha is refused.** Use the full 40 characters.

**`gate: workdir … is at X not Y; refusing to run`, verdict `Unknown`.** The gate
runs in a checkout that must already be at the sha. Check it out first,
detached (see [`gates-and-promotion.md`](gates-and-promotion.md)).

**There is no `gate-wt` on a fresh floor.** The loop creates it at its first
merge. To gate by hand before then:
`git clone /path/to/floor/mirror/mirror.git /path/to/floor/gate-wt`.

**`--venue systemd-run` ran with no memory cap.** The CLI accepts only
`--venue container`; every other value runs `local`, silently (#715). Set
`gate_venue = "systemd"` in the manifest for the loop's gates.

**A systemd gate came back `killed` with `systemd-run --scope refused`.** polkit
denied the scope. fwf passes `--no-ask-password`, so this is fast instead of
hanging on a password prompt (#684). Run as a user that may create scopes, or
use another venue. A `systemd-run … true` child alive for minutes is the
symptom of a regression of that fix.

**A gate re-run returns the old verdict instantly.** Verdicts are recorded per
sha and suite in `gate-wt/.fwfd/gate/`. Delete that file to run again.

## Releases

**`release-publish: Cargo.lock is stale`.** The version in `one/Cargo.toml`
moved without the lock. Run `cargo update -w` in `one/` and commit the lock
with the bump. A tag whose lock disagrees fails both CI build legs, which use
`--locked`. See [`releasing.md`](releasing.md).

**`release-publish: HEAD … is not origin/main`.** Releases are tagged at
`origin/main`, which only moves by `fwf promote`. Check out `main`, pull, and
run the script again.

**A tag exists but `release-check` says `NO release object`.** A tag is not a
release. Either `one-release.yml` is still running or it failed, leaving a
draft that `release-check` cannot see. Open the run for the tag (the script
prints its URL) and see [`releasing.md`](releasing.md#when-a-cut-fails-halfway).
Cut releases with the script, never with `git tag`.

## See also

- [`operations.md`](operations.md) — the rules that keep a floor out of this page.
- [`verbs.md`](verbs.md) — every verb's refusals.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
