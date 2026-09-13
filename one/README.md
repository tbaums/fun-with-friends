# fwf 1.0 — `fwf`

One Rust supervisor runs a software factory on a GitHub repository. It reads
the tracker, decides what to do next, wakes an idle Claude Code pane with
exactly one job, reads back a JSON verdict, and performs every GitHub write
itself under three narrow GitHub App identities. Seats never hold a GitHub
write token, never poll, never loop, and cost nothing while idle.

**Start at [`docs/getting-started.md`](../docs/getting-started.md).** The
documentation lives at the repository root, not in this crate — see
[`docs/index.md`](../docs/index.md) for the full index. This file is the
crate's own orientation and nothing else, so nothing is documented twice.

`fwf` IS 1.0: this crate's binary is the default command. The v0.42 bash tool
is `fwf-legacy` (same code, renamed). For one release the 1.0 binary also
installs as `fwfd`, its old name, so existing scripts and notes keep working;
the `fwfd/<suite>` check-run name and the `.fwfd/gate` state directory keep
theirs too. Both go next release.

## Layout

```
one/
  src/          fwf (types, log, github, poll, sched, seat, mirror, slice, qa,
                merge, gate, checks, promote, run, triage, spec, cost,
                manifest, profile, prompts, verbs)
  src/dash/     the board: dash.rs folds the record, floor joins the manifest
                and tmux, view draws the frame, panes the five tabs, tty the
                terminal
  prompts/      one-job prompts per family and role (dev, refactor, validate,
                ideation, consulting, defect-report, user-testing)
  manifests/    converted manifests for transom, baton, wholesome-swolesome
  scripts/      seat-up.sh, size-check.sh (+ baseline)
```

## Build and test

```
cargo build --release
cargo test
```

CI is [`.github/workflows/one-ci.yml`](../.github/workflows/one-ci.yml): test,
fmt + clippy, the size ratchet, and the docs link check.

## Where things went

| You want | Read |
|---|---|
| to install and make a first run | [`docs/getting-started.md`](../docs/getting-started.md) |
| every verb and what it refuses | [`docs/verbs.md`](../docs/verbs.md) |
| the three Apps and their permissions | [`docs/github-apps.md`](../docs/github-apps.md) |
| to cut a release | [`docs/releasing.md`](../docs/releasing.md) |
| why the harness is shaped this way | [`docs/design.md`](../docs/design.md) |
| what shipped in each version | [`CHANGELOG.md`](../CHANGELOG.md) |
| the 0.x bash factory | [`docs/legacy/README.md`](../docs/legacy/README.md) |

## See also

- [`docs/index.md`](../docs/index.md) — the fwf 1.0 documentation index.
