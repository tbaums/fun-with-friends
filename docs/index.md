# fwf 1.0 documentation

fwf runs a software factory on a GitHub repository: one supervisor performs
every write, and stateless agent seats do the work one job at a time.
Start at [`getting-started.md`](getting-started.md); the rest is reference.

## Start here

- [`getting-started.md`](getting-started.md) — install, first manifest, first run, reading the dash.
- [`design.md`](design.md) — why the harness is built this way.

## Reference

- [`manifest.md`](manifest.md) — every key of `.fwf/fwf.toml`, with defaults and types.
- [`verbs.md`](verbs.md) — every verb, its App identity, and what it refuses.
- [`seats.md`](seats.md) — floors, mirrors, worktrees, and the boundary of a seat.
- [`prompts.md`](prompts.md) — the job templates, verdict contract, placeholders and families.
- [`gates-and-promotion.md`](gates-and-promotion.md) — suites, the gate record, check-runs, promotion, the fence.
- [`github-apps.md`](github-apps.md) — registering the three Apps and their minimal permissions.

## Running a floor

- [`operations.md`](operations.md) — the meter, the run record, cost, the dash, the tmux layout.
- [`troubleshooting.md`](troubleshooting.md) — known gotchas and their fixes.
- [`releasing.md`](releasing.md) — cutting a release, the Linux asset, `release-check`.

## Also in the repository

- [`../CHANGELOG.md`](../CHANGELOG.md) — what shipped in each 1.0 version.

## Legacy

- [`legacy/README.md`](legacy/README.md) — fwf 0.x, the bash factory: archived, still indexed.

## See also

- [`getting-started.md`](getting-started.md), if you are starting from nothing.
