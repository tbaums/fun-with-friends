# one/ — fwf 1.0 (`fwfd`)

The rebuild proposed in *fwf One* (2026-09-09): one Rust supervisor that owns
every authority-bearing action, wakes idle Claude Code panes only when there is
work (no `/loop` polling, no `claude -p` seats), keeps GitHub's typed objects as
the only coordination state, gates in containers, and promotes by literal SHA.
Seats hold read-only tokens and push to a local mirror.

This directory is developed on the `one/*` branches alongside the v0.42.x tree
it replaces. Nothing here is wired into `fwf` yet.

## Status — M0

| ticket | state |
|---|---|
| T-00 v0.42.10 security fix (#562) | PR open on the v0.42.x tree |
| T-01 crate skeleton, four enums, event log, `why` | this directory |
| T-02 three GitHub Apps (impl, qa, ops) | needs Jamie |
| T-03 GitHub client | not started |
| T-04 fake GitHub | not started |
| T-05 fake seat pane | not started |
| T-06 seat waker + verdict reader | not started |
| T-07 canary + 10-cycle cost comparison | not started |
| T-08 thin slice (kill criterion) | not started |

## Build and test

```
cd one && cargo test && cargo run -- doctor
```

## Week-0 findings (2026-09-09)

- macOS 26.5.1, 16 GB. Claude Code 2.1.266 exposes `--setting-sources`,
  `--disallowedTools`, `--permission-mode`, `--json-schema`, `--bare`.
- Apple `container` 1.4.1 installed (`brew install container`; kernel via
  `container system kernel set --recommended`, kata 3.32.0). First run of
  `alpine` with `--memory 512m`: boot ≈ 9 s cold, guest `MemTotal` 614184 kB —
  the cap is honoured. The transom `cargo test` benchmark is still to do.
- Canary (deny hook under `dontAsk`, per-floor HOME): prepared, not yet run.
- GitHub Apps: see `docs/github-apps.md`; blocked on Jamie.
