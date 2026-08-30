# macOS CI runs locally, not on GitHub

GitHub-hosted macOS runners are **not** used by this repo. `ci.yml`'s matrix is
`[ubuntu-latest]` and `dash-targets.json` no longer lists `darwin-arm64`.

## Why

Hosted macOS runners queue unpredictably. On the v0.36.0 cut the
`dash binary (darwin-arm64)` job sat **queued without ever starting for over 20
minutes**, while the identical `cargo build --release` took **9 seconds** on the
operator's own Apple Silicon Mac. Every merge and every release sat behind a job
that had not begun.

That is not a one-off. A macOS job that may or may not be scheduled is not a
gate — it is a coin flip that blocks the pipeline, and reviewers end up waiting
on it instead of reviewing.

## What did NOT change

**The BSD coverage.** It moved to real hardware; it was not dropped. This matters
more than it sounds: in a single day, six distinct macOS-only defect families
were found once the suite could finally *finish* on macOS —
`ps -o etimes` (#332), `date -j -f` missing `-u` (#337 A), `awk IGNORECASE`
(#337 D), GNU-only `touch -d` (#304), BSD `wc` padding (#284), and
`lsof -F c` naming (#337 B). Every one was invisible to a Linux runner **by
construction**: the code works there, so no Linux test can go red.

A seventh joined the family later: GNU-only `timeout` in `test/run.sh` itself
(#431) returned `127` (command not found) on macOS from #416 onward, so every
macOS run reported `EXIT=1` for a reason that had nothing to do with the code
under test — a guard that fails on everything has stopped discriminating, the
same as one that never fails. Fixed with a shell-implemented bound
(`test/run.sh`'s own `_portable_timeout`) rather than a skip, so the assertion
it guards stays at full strength on both platforms.

## How to run it

```sh
scripts/mac-ci.sh              # current worktree
scripts/mac-ci.sh origin/staging   # any ref, in a throwaway worktree
```

Isolated `FWF_RUN_DIR` and `TMUX_TMPDIR`, so it never touches a live factory's
locks or panes.

**A run only counts if it prints a summary line.** The script refuses to report
a pass without one, because a suite that dies mid-run looks identical to a slow
one — exactly how a truncated log got reported as green twice before this was
enforced.

## Releases

`release.yml` publishes the tarball, both Linux binaries and the checksums.
The Mac binary is attached afterwards, from a Mac:

```sh
scripts/mac-release-asset.sh          # defaults to v$(cat VERSION)
```

It folds its checksum into the published file rather than replacing it, so the
CI-produced Linux lines survive verbatim. **`fwf dash` resolves its prebuilt
binary from the release assets**, so skipping this step means macOS users fall
back to building from source. Run it on every cut.

## When to use which

| ticket | oracle |
|---|---|
| macOS-only, or any `ps` / `date` / `awk` / `stat` / `touch` / `wc` / path behaviour | `scripts/mac-ci.sh` — **nothing else** |
| everything else | ubuntu CI |

Never accept a green Linux gate as evidence on a macOS-only ticket. It cannot
observe the failure in either direction, and agents have burned multiple
20-minute cycles learning that the hard way.
