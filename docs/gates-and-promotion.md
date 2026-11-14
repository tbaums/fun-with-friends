# Gates and promotion

Suites, the gate record, check-runs, `fwf promote`, and the fence.
How a commit earns its way from a branch to `main`.

## Suites

A suite is a name and a shell command in the manifest's `[suites]` table. Two
keys name suites:

- **`fast_suite`** is the suite the loop runs after every merge, and its command
  is the `{{CHECK}}` that impl, rework and QA jobs must pass in their own
  worktree before they answer.
- **`promote_suite`** must name a defined suite, and that is all it does today.
  `fwf promote` takes `--suite` on the command line and does not read it.

A floor that wants a slower suite to guard `main` names it in `--suite` and runs
it with `fwf gate` itself. The loop only ever runs `fast_suite`.

## One gate run

A gate run is one suite at one sha in one venue, and it ends in one verdict:

| Verdict | Means |
|---|---|
| `green` | The command exited 0. |
| `red` | It exited non-zero. `failed` is the failure count when the runner printed one (cargo, pytest, go and jest forms are recognised). |
| `killed` | The memory cap or `gate_timeout_secs` stopped it, or the venue could not run a trivial command at all. A `killed` verdict is never reported as `red`. |
| `unknown` | The gate did not run: most often, the workdir was not checked out at that sha. |

The command runs in a checkout of the sha under test, never in a seat's
worktree. Before it runs, the gate checks that the workdir's `HEAD` **is** that
sha. If it is not, the verdict is `unknown` and nothing is recorded.

**The record.** Every verdict except `unknown` is written to
`<workdir>/.fwfd/gate/<sha>-<suite>.json`. A second run for the same sha and
suite returns that verdict without running anything. To run it again, for
example after a `killed`, delete the file. The verdict is also appended to the
run record as a `gate` event, and the output goes to
`<floor>/gate-<sha8>-<suite>.log`.

**The check-run.** The verdict is posted to GitHub as a check-run named
`fwfd/<suite>` on that sha, under `ops`. The `fwfd` prefix is the binary's old
name, and it has not been renamed.

### Venues

| Venue | Runs | Memory cap |
|---|---|---|
| `local` | `bash -o pipefail -c CMD` in the workdir | none |
| `container` | Apple `container run --rm --memory <N>g -v <workdir>:/work … sh -c CMD` | `gate_memory_gb` |
| `systemd` | `systemd-run --scope --no-ask-password -p MemoryMax=<N>G -p RuntimeMaxSec=… bash -o pipefail -c CMD` | `gate_memory_gb` |

Every venue but `local` is checked before the suite runs: `container system
status` for the container venue, and a trivial `systemd-run --scope` with its
own 5-second limit for systemd. A venue that fails the check gives `killed`
with the reason, so a broken venue never reads as a failing suite.
`--no-ask-password` means a polkit denial comes back at once instead of
waiting for a password nobody will type.

The manifest's `gate_venue` accepts all three. **The `fwf gate` command line
accepts only `--venue container`.** Any other value, `systemd` and
`systemd-run` included, silently runs `local` with no memory cap. #715 tracks
the fix. Until it ships, use the manifest venue for capped gates.

## The post-merge gate

After every merge it makes, the loop:

1. clones `<floor>/gate-wt` from the mirror if it does not exist yet, and sets
   its identity to `fwf-gate`;
2. fetches, and checks out the merge sha detached;
3. runs `fast_suite` there in the manifest's venue;
4. records the verdict and posts the `fwfd/<suite>` check-run.

A `red` here does not revert the merge. It leaves that sha unpromotable.

To gate by hand, use the same worktree and check out the sha first:

```bash
git -C /path/to/floor/gate-wt fetch -q origin
git -C /path/to/floor/gate-wt checkout -q --detach <40-char-sha>
fwf gate --repo o/r --sha <40-char-sha> --suite fast \
  --cmd 'make test' --workdir /path/to/floor/gate-wt
```

On a fresh floor, `gate-wt` does not exist until the loop's first merge. To gate
by hand before then, create it yourself:

```bash
git clone /path/to/floor/mirror/mirror.git /path/to/floor/gate-wt
```

`--sha` must be the full 40-character sha. An abbreviated one is refused, not
resolved.

## Promotion

```bash
fwf promote --repo o/r --from staging --to main --suite fast
```

Promotion moves `to` to exactly the sha `from` points at, under `ops`. The loop
never promotes; promotion is always this command, run by an operator. In
order, it refuses when:

1. either branch does not exist;
2. `to` is not an ancestor of `from` (behind or diverged). If they are
   identical, nothing happens;
3. there is no recorded `green` for **that exact sha and suite** in
   `--workdir` (default `~/.fwf/floors/<repo-name>/gate-wt`). A green for the
   previous commit is not a green for this one;
4. `to` moved between the read and the write. Nothing moves, and the command
   never forces.

Each refusal is recorded as a `refused` event, and a promotion as a `promote`
event.

## The fence

A claim is the ref `refs/claims/<issue>` on GitHub, pointing at the base
branch's tip when the slice started. That sha is the fence: the commit the
seat's work was built on. The typed merge refuses unless the claim is still
live, and the merge releases it. A claim whose seat is gone, with no open PR
closing its issue, is reported as stale and left for an operator to release.

## Merge preconditions, in one place

`fwf merge` and the loop's merge both check, from GitHub at the moment of the
merge:

- the PR is open and not a draft;
- the issue it closes has a live claim at the fence;
- the newest review per reviewer at the current head includes an approval from
  someone other than the author, and no changes-requested at that head;
- every check-run on the head has completed successfully, if there are any.

The squash merge sends the head sha with the request, so GitHub refuses it if
the head moved in between.

## See also

- [`lifecycle.md`](lifecycle.md) — where the gate sits in an issue's path.
- [`releasing.md`](releasing.md) — cutting a release from `main`.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
