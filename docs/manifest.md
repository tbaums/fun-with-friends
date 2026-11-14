# The manifest

Every key of `.fwf/fwf.toml`: its type, default, and effect.
The reference you keep open while editing a manifest.

The manifest is the one launch input of a floor. It lives in the repository
being worked, at `.fwf/fwf.toml`; every verb that reads it takes
`--manifest PATH` to point elsewhere. `fwf init-manifest` prints a complete
example, and `fwf up` validates the file and prints the floor plan it implies.

## Rules of the file

- **A missing manifest is a refusal.** No verb guesses one.
- **At most 25 top-level keys.** A table (`[suites]`, `[models]`) counts as one
  key. A file with more is refused with `manifest has N top-level keys; the
  limit is 25`. The schema below has 28 keys, so a manifest cannot set all of
  them. Leave out the ones whose default you want.
- **Unknown keys are ignored, not refused.** A misspelt key keeps its default
  silently, and it still counts toward the 25. `fwf up` prints the values that
  matter, so read its first line after every edit.
- **Scalars first, tables last.** In TOML, every key after `[suites]` belongs
  to `[suites]`.

## Keys

### Repository and branches

| Key | Type | Default | Effect |
|---|---|---|---|
| `repo` | string | **required** | `owner/name` on GitHub. Anything else is refused. |
| `base_branch` | string | `"staging"` | Where seats branch from and where PRs merge. The seat worktrees are cloned at this branch, so it must exist. |
| `release_branch` | string | `"main"` | Must differ from `base_branch`. Shown by `fwf up` and the dash. The loop never writes to it: promotion is `fwf promote`, run by hand. |

### Which issues are worked

| Key | Type | Default | Effect |
|---|---|---|---|
| `issues` | array of integers | `[]` | The allow-list. `fwf run` **refuses to start** while it is empty. The loop only plans impl and QA work for these issues and their PRs. |
| `gate_label` | string | `"product-wip"` | The label that marks an issue as awaiting review. The spec cycle works issues that carry it, and `fwf ungate` removes it. Hand-run verbs always use `product-wip` (see [`configuration.md`](configuration.md#verbs-that-ignore-floor_dir)). |
| `skip_labels` | array of strings | `["idea", "release-hold", "tracking", "build-epic"]` | An issue carrying any of these is never triaged, specced or planned. Setting the key replaces the whole list. |
| `owner_only` | boolean | `true` | Shown by `fwf status`: only issues the repository owner opened count as eligible there. `fwf run` plans owner-authored issues only, whatever this says. |
| `triage_new` | boolean | `false` | Each tick, wake GV once for every open, un-gated, unclaimed issue the record has never judged. The allow-list does not apply. A not-ready verdict adds the gate label and a comment, so this writes to real issues. Needs a `gv` seat. |
| `auto_spec` | boolean | `true` | The spec cycle on gated issues: GV first pass, PM spec, GV sign-off. Needs `gv` and `pm` in `[models]`. Without them that half is skipped, with a warning at startup. |
| `review_scope` | `"all-gated"` or `"allow-list"` | `"all-gated"` | Which gated issues the spec cycle may spend GV and PM wakes on: every open gated issue, or only those in `issues`. Any other value is refused. |
| `delegate_ungate` | string | unset | Unset: after GV signs a spec off, the issue waits for a human `fwf ungate`. Set to a name: the loop un-gates under that name, and the comment and record say it was delegated. The delegated un-gate never reaches outside `issues`. |

### Seats

| Key | Type | Default | Effect |
|---|---|---|---|
| `pairs` | integer 1–8 | `1` | How many impl/QA seat pairs: `impl1`/`qa1` … `implN`/`qaN`. |
| `session` | string | `"fwf-one"` | The tmux session that holds the seat panes. A seat's target is `<session>:<role><n>`. |
| `models` | table, role → model | `{}` | The model per seat role, passed to `claude --model`. An `impl` or `qa` seat with no entry gets `opus`. A `gv` or `pm` seat exists **only** if its role is named here. |
| `template` | string | `"dev"` | The prompt family under `prompts/` (`dev`, `refactor`, `validate`, `ideation`, `consulting`, `defect-report`, `user-testing`). A role the family does not define falls back to `dev`. |
| `job_timeout_secs` | integer | `1800` | The deadline of every seat job the loop starts: impl, QA, rework, GV and PM. Past it the seat is `Stalled`. |
| `stall_quiet_secs` | integer | `900` | An impl seat whose worktree and pane have both been quiet this long is called `Stalled` before its deadline. `0` turns the early stall off. |
| `rework_cap` | integer | `2` | Rework rounds per PR: after QA or a named reviewer requests changes, or after GitHub refuses a merge as not mergeable. Past the cap the PR waits for a human, and `fwf status` lists it under **needs you**. |
| `reviewers` | array of logins | `[]` | Logins besides the QA App whose changes-requested review earns a rework round. The repository owner always counts. |
| `floor_dir` | path | `~/.fwf/floors/<repo-name>` | Where the floor's record, mirror, worktrees and seat home live. Read [`configuration.md`](configuration.md#verbs-that-ignore-floor_dir) before changing it. |

### The loop and the meter

| Key | Type | Default | Effect |
|---|---|---|---|
| `poll_interval_secs` | integer | `60` | Sleep between ticks, and between re-reads of the meter while parked. |
| `park_at_weekly_pct` | integer 0–98 | `85` | The loop parks, waking no seat, while the last meter reading's weekly % is at or above this. Over 98 is refused. See [`operations.md`](operations.md#the-meter-and-its-brake). |

### Gates

| Key | Type | Default | Effect |
|---|---|---|---|
| `suites` | table, name → shell command | `{}` | The gate suites. Each command runs in a checkout of the sha under test: `bash -o pipefail -c` in the `local` and `systemd` venues, `sh -c` in the container. An empty command is refused. |
| `fast_suite` | string | `"fast"` | Must name a suite in `[suites]`. After every merge, the loop runs this suite on the merge sha. Its command is also the `{{CHECK}}` that impl, rework and QA jobs are told to pass. |
| `promote_suite` | string | `"fast"` | Must name a suite in `[suites]`. That is all it does today. `fwf promote` takes `--suite` on the command line and does not read this key. |
| `gate_venue` | `"local"`, `"container"` or `"systemd"` | `"local"` | Where the loop's post-merge gate runs. `local`: `bash` in the gate worktree, no memory cap. `container`: Apple `container run` with `alpine:latest`. `systemd`: a `systemd-run --scope` with a memory cap. Any other value is refused. |
| `gate_memory_gb` | integer | `8` | The memory cap for the `container` and `systemd` venues. |
| `gate_timeout_secs` | integer | `1800` | Wall-clock limit of one gate run. A run killed by it is `Killed`, not `Red`. |

## A minimal manifest

```toml
repo = "your-org/your-repo"
issues = [42]

[suites]
fast = "make test"

[models]
impl = "opus"
qa = "opus"
gv = "sonnet"
pm = "sonnet"
```

This is one impl/QA pair on `fwf-one`, branching from `staging`, with GV and PM
seats for the spec cycle. Issue #42 is worked once it has been signed off.
`fwf init-manifest` prints every key with its default; its `[suites]` are fwf's
own, so replace them with your repository's.

`fwf init-manifest --from-profile profiles/x.sh --repo owner/name [--session S]`
converts a 0.x profile instead, and refuses to print one that does not
validate.

## See also

- [`lifecycle.md`](lifecycle.md) — what the loop does with these settings, step by step.
- [`configuration.md`](configuration.md) — environment variables and the `~/.fwf` layout.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
