# Configuration

Everything fwf reads besides the manifest: the environment variables it
honours, and what lives under `~/.fwf/` and in each floor directory.

The manifest (`.fwf/fwf.toml`) is the launch input for a floor and has its own
page, [`manifest.md`](manifest.md). Nothing below changes what a floor does
with an issue; it changes where fwf looks for its credentials, its record and
its releases.

## Environment variables

| Variable | Read by | Default | Effect |
|---|---|---|---|
| `FWF_APPS_TOML` | every verb that mints an App token | `~/.fwf/apps.toml` | Path to the App credentials file. |
| `FWF_RUN_LOG` | `fwf why`, `fwf doctor`; `fwf dash` and `fwf release` when no manifest names a floor record that exists | `~/.fwf/run.jsonl` | The record those verbs read when they are not given `--log`. It does **not** move where the loop writes: `fwf run` always appends to `<floor>/run.jsonl`. |
| `FWF_ALLOW_STALE` | `fwf up` | unset | `fwf up` refuses to start a floor when the installed fwf is older than the latest release. Any non-empty value other than `0` turns that refusal into a warning. |
| `FWF_RELEASE_REPO` | `fwf up`, `fwf doctor`, `fwf self-upgrade`; `one/scripts/release-publish.sh` | `tbaums/fun-with-friends` | The repository whose releases are "latest", and where `self-upgrade` downloads from and `release-publish.sh` publishes to. Set it when you run a fork. |
| `FWF_VERSION` | `install.sh` only | unset | Install that published release instead of building the checkout, even where cargo exists, e.g. `FWF_VERSION=1.0.26 ./install.sh`. |
| `FWF_RELEASE_DIR` | `one/scripts/release-publish.sh` | a fresh temp dir | Where the release script stages the tarball. |
| `NO_COLOR` | `fwf dash` | unset | Any value turns colour off, as `--no-color` does. `TERM=dumb` does too. |
| `USER` | `fwf ungate`, `fwf release` | `operator` | The name recorded as the actor when `--by` is not given. |

`HOME` decides where every default path below lives.

The seat panes get their own environment, written by `fwf seats --up` into
`<floor>/home/env.sh`: `HOME` is the floor's `home/` directory,
`CLAUDE_CODE_OAUTH_TOKEN` is the seat's login, and `FWFD_SEAT` names the seat.
See [`seats.md`](seats.md).

## `~/.fwf/`

```
~/.fwf/
  apps.toml          App ids, installation ids and key paths (FWF_APPS_TOML)
  keys/              the three App private keys (*.pem, 0600)
  seat-token         optional: a long-lived Claude token for seat panes (0600)
  bin/               fwf-run, fwf-gate, fwf-qa: symlinks to the fwf binary
  prompts/           the seat job prompts, written from the binary by each run
  run.jsonl          the fallback record for `why`/`dash` (FWF_RUN_LOG)
  floors/<repo>/     one floor per repository, unless the manifest sets floor_dir
~/.fwf-meter-log     the meter log the brake reads (note: beside ~/.fwf, not in it)
```

- **`apps.toml`** has one table per App: `impl`, `qa` and `ops`, each with
  `app_id`, `installation_id` and `key` (a path; a leading `~/` is expanded).
  [`github-apps.md`](github-apps.md) shows the file.
- **`seat-token`** is read by the seat start-up script. With it absent, the
  script falls back to the access token in the macOS Keychain entry
  `Claude Code-credentials`, which rotates. On Linux there is no fallback, so
  the file is required.
- **`bin/`** holds the verb-named symlinks that `fwf run`, `fwf gate` and
  `fwf qa` re-execute through, so `ps -o comm=` shows `fwf-run`, `fwf-gate` and
  `fwf-qa` rather than three processes all called `fwf`. Each run re-points its
  link at the binary that is running. A failure here is a warning, never a
  stop.
- **`prompts/`** is `<family>/<file>` for every prompt the binary carries,
  rewritten once per process (#719). Edits there do not last: the next run
  overwrites them and removes files the binary does not carry.
- **`~/.fwf-meter-log`** is written by you, not by fwf. Its format and the
  brake are in [`operations.md`](operations.md#the-meter-and-its-brake).

## A floor directory

`<floor>` is the manifest's `floor_dir`, or `~/.fwf/floors/<repo-name>` when
it is unset.

```
<floor>/
  run.jsonl                 the run record: every event, append-only
  run.pid                   the pid of this floor's `fwf run`
  mirror/mirror.git         bare mirror of the repository; the seats' only remote
  wt-impl1, wt-qa1, …       one clone of the mirror per seat
  wt-gv1, wt-pm1            only when [models] names gv / pm
  gate-wt                   the gate worktree; the loop clones it at the first merge
  gate-wt/.fwfd/gate/       recorded gate verdicts, <sha>-<suite>.json
  gate-<sha8>-<suite>.log   output of each gate run
  verdict-*.json            each seat's verdict for its current job
  home/                     the seats' HOME
    .claude/settings.json   seat permissions and the push-guard hook
    .claude/push-guard.sh   the push policy
    .claude.json            onboarding and workspace trust, pre-accepted
    env.sh                  HOME, CLAUDE_CODE_OAUTH_TOKEN, FWFD_SEAT (0600)
    .fwf/seat-up.sh         start-up script, rewritten by every `fwf seats --up`
```

The verdict files are named after the job: `verdict-issue-<n>.json` (impl),
`verdict-pr-<n>.json` (QA), `verdict-rework-pr-<n>.json`,
`verdict-triage-<n>.json` (GV) and `verdict-spec-<n>.json` (PM). QA falls back
to the PM's `verdict-spec-<n>.json` when GitHub yields no spec; see
[`lifecycle.md`](lifecycle.md).

### Verbs that ignore `floor_dir`

`fwf run`, `fwf stop`, `fwf seats`, `fwf status`, `fwf doctor` and `fwf dash`
read the manifest and use its floor. The hand-run verbs do not: `ungate`,
`spec`, `triage`, `merge`, `gate` and `promote` always use
`~/.fwf/floors/<repo-name>`, and `slice`, `qa` and `mirror-init` do too unless
you pass `--floor`. They also use the gate label `product-wip` whatever the
manifest's `gate_label` says.

On a floor with a custom `floor_dir` or `gate_label`, a hand-run verb records
into a different `run.jsonl` from the loop. The loop never sees that record.
For example, the `Ready` event from `fwf ungate` lands in the default floor,
and the loop never sees the sign-off. Leave `floor_dir` and `gate_label` at
their defaults on any floor you intend to drive by hand.

## See also

- [`manifest.md`](manifest.md) — every key of `.fwf/fwf.toml`.
- [`operations.md`](operations.md) — the meter, the run record, stopping the loop.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
