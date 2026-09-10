# Thin slice: what a woken seat actually does

This is the M0 kill-criterion slice (T-08) for fwf 1.0: a real implementer
seat, woken by `fwfd`, turning one owner-authored, unlabelled issue into a
draft PR with no human in the loop after the un-gate. This document is
written from the seat's point of view.

## What it received

A prompt naming the issue number and its full body, plus:
- a working directory: a git worktree whose only remote (`origin`) is a
  local mirror — no GitHub token, no push access to GitHub;
- explicit ground rules: branch name to use, "Closes #N" commit trailer,
  push to `origin` only, and a verdict path to write the result to.

## What it did

- Created `impl1/issue-<N>-thin-slice` from the current HEAD.
- Made the exact change the issue asked for (this file) and nothing else.
- Committed with a message ending `Closes #<N>`.
- Pushed the branch to `origin` (the local mirror), then stopped.

## What it wrote back

A single JSON verdict, written atomically (`<path>.tmp` then `mv`) to the
path given in the job, and nothing else — the seat never calls `gh` and
never opens the PR itself:

```json
{"verdict":"implemented","branch":"impl1/issue-<N>-thin-slice","head":"<sha>","summary":"<one sentence>"}
```

The supervisor reads that file, opens the draft PR against `staging` under
the `fwf-impl` App identity, and stamps the body with `Closes #<N>` and
`fwf-Provenance: fwfd thin slice`. The event log records the full path:
claim(fence) → seat working → verdict → pr_opened.

## Run-loop proof (#566)

Second slice, no operator command between steps: `fwfd run` drove the
implementer cycle, the QA cycle and the merge on its own.

This seat received one job — implement issue #566 on branch
`impl1/issue-566-thin-slice`, append this section, commit with `Closes
#566`, publish the branch to the mirror, and stop. Same ground rules as
T-08, and it wrote back exactly one verdict, atomically:

```json
{"verdict":"implemented","branch":"impl1/issue-566-thin-slice","head":"<sha>","summary":"<one sentence>"}
```

The PR, the approval and the merge were the loop's, visible in `fwfd why`.

## Conductor-as-code proof (#568)

Third slice: `fwfd run` carried it past the merge. One job reached this
seat — issue #568 on `impl1/issue-568-thin-slice`, this section, `Closes
#568`, publish to the mirror, write one verdict, stop.

Everything after that verdict was the loop's: draft PR by fwf-impl[bot],
approval at head by fwf-qa[bot], squash merge by fwf-ops[bot], and a
`fwfd/fast` check-run posted on the new staging tip — no operator command
at any step, the whole chain visible in `fwfd why`.
