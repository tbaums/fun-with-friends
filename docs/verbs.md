# Verbs

Every `fwf` verb, the App identity it acts under, and what it refuses.
A refusal is a normal outcome here, so each verb documents its own.

## Verbs execute: there is no `--help`

`fwf` with no verb, or `fwf --help`, prints the usage summary. That is the only
help there is. **Verbs do not parse `--help`.** Unknown flags are ignored, and
a verb that needs no arguments does its job. `fwf dash --help` is the one
exception: it prints dash's usage line.

| You type | What happens |
|---|---|
| `fwf run`, `fwf run --help` | Starts the supervisor loop for `./.fwf/fwf.toml`. |
| `fwf seats`, `fwf seats --help` | Brings every seat up: mirror, worktrees, panes. Only `--down` does anything else. |
| `fwf stop` | Sends SIGTERM to the loop of `./.fwf/fwf.toml`. |
| `fwf self-upgrade` | Replaces the installed binary with the latest release. |
| `fwf up`, `fwf doctor`, `fwf status` | Read-only, but they mint App tokens and call GitHub. |
| `fwf dash` | Read-only: draws the board from the record. |

Any other verb run without its required flags prints the usage and exits `2`.
This page is the flag reference. The source is `one/src/main.rs` and
`one/src/verbs.rs`.

Conventions below: `o/r` is `owner/name`; a `tmux-target` is
`<session>:<role><n>`, e.g. `fwf-one:impl1`. Defaults are given in brackets.

## Exit codes

`0` success. `1` a refusal or a failed step: the verb prints what and why, and
most refusals are also recorded as `Refused` events. `2` bad or missing
arguments, an unreadable manifest, or a missing `apps.toml` or App.

## Read-only and setup

### `fwf version`
Prints `fwf X.Y.Z`. `fwf --version` is the same verb. No identity.

### `fwf up [--manifest PATH]`
Validates the manifest, prints the floor plan (repo, branches, gate label,
pairs, session, venue, suites, floor directory, and the delegate if one is
set), mints a narrow token for each of `impl`, `qa` and `ops`, and prints each
impl/QA seat's pane command.
- Refuses (exit 1) when the installed fwf is older than the latest release,
  unless `FWF_ALLOW_STALE=1`. An unreachable GitHub is a warning, not a
  refusal.
- Exit 2 with no manifest or no `apps.toml`; exit 1 if any App is missing or
  cannot mint.

### `fwf doctor [--manifest PATH] [--assets]`
What this host can do: installed against latest release, the fallback record
path, the embedded seat scripts, the floor, what every seat worktree and
`gate-wt` commit as, and a token minted from every App in `apps.toml`. It warns
when `impl` or `ops` lacks `workflows: write`. Read-only. Exit 1 when an App
cannot mint or a worktree commits as the wrong identity. A missing manifest is
reported, not a failure.

`--assets` checks only what the binary carries, and needs no manifest, no Apps
and no network. It writes the embedded prompts to `~/.fwf/prompts/` and lists
each family's `impl`, `qa`, `gv`, `pm` and rework job after the `dev`
fallback, with the file it resolved to and its size, then the embedded
`seat-up.sh` and `seat-push-guard.sh`. Exit 0 only when every one is non-empty
and uses no unknown placeholder. With `HOME` unset it exits 1 and says so.

### `fwf status [--manifest PATH]`
One screen: record age and loop pid, seats, eligible and claimed issues, PRs
with review state, recent events, and **needs you** (approved drafts, PRs at
the rework cap, refused pushes, refusals the loop keeps repeating). Acts as
`impl`, read-only.

### `fwf dash [--manifest PATH] [--log PATH] [--watch SECS] [--once] [--tab T] [--no-color]`
The five-tab board (`seats`, `issues`, `prs`, `decisions`, `usage`, or `1`–`5`),
folded from the run record. No GitHub calls. On a terminal it redraws every
5 s (`--watch` changes that) and takes `1`–`5`, `j`/`k`, `g`/`G`, `r`, `q`.
`--once`, or output to a pipe, prints one frame labelled as a snapshot. The
record is `--log`, else the manifest's `<floor>/run.jsonl` if it exists, else
`FWF_RUN_LOG` / `~/.fwf/run.jsonl`. Refuses unknown flags and unknown tabs.

### `fwf why <pr> [--log PATH]`
Every event in the record that mentions that PR, in order. **The default record
is `FWF_RUN_LOG` or `~/.fwf/run.jsonl`, not the floor's**: pass
`--log <floor>/run.jsonl`. Exit 1 if nothing mentions the PR.

### `fwf cost --floor DIR --seat impl1 [--since EPOCH]`
Messages and tokens (input, cache-read, cache-create, output) for one seat, read
from its own Claude transcript under `<floor>/home`. No identity.

### `fwf init-manifest [--from-profile FILE --repo o/r [--session S]]`
Prints the example manifest. With `--from-profile`, it converts a 0.x profile
instead and refuses to print a result that does not validate. `--session`
defaults to `fwf-<name>`.

### `fwf probe <role> <api-path>`
GETs one REST path with a token from that App, with the installation's full
permissions, and prints the status and the first 200 characters of the body.
For checking what an App can see.

### `fwf release-check --repo o/r --tag vX.Y.Z [--expect N]`
Refuses unless the tag has a GitHub release object with at least `N` assets
[4]. "A tag is not a release": a tag with no release object is exit 1. Acts as
`ops`, read-only.

### `fwf self-upgrade [--to X.Y.Z] [--force]`
Downloads the release asset for this host (`macos-arm64` or `linux-x86_64`)
from `FWF_RELEASE_REPO`, verifies it against the published `.sha256`, and
atomically replaces the running binary. With no `--to` it takes the latest
release. Refuses (exit 1) when already at that version (unless `--force`),
when there is no asset for this host, or when the download or checksum fails.
In every refusal the binary is untouched. A running loop keeps its old image
until it restarts. Uses an `ops` token for the version lookup when one is
available.

### `fwf mirror-init --repo o/r [--floor DIR]`
Creates or refreshes the bare mirror at `<floor>/mirror/mirror.git` and prints
the `file://` URL seats use. It fetches anonymously, so it works for a public
repository only. `fwf seats --up` fetches a private one with an `ops` token.

## The floor

### `fwf seats [--up | --down] [--manifest PATH] [--force]`
Up (the default): creates or refreshes the mirror, clones one worktree per seat
at `base_branch`, sets each worktree's commit identity, rewrites the seat
scripts under `<floor>/home/.fwf/`, and starts a pane for every seat that is
not already running `claude`. Idempotent. Uses an `ops` read token for the
mirror. Exit 1 if any seat failed.
Down: kills the tmux session. Refuses while the record says a seat is Working,
unless `--force`.
See [`seats.md`](seats.md).

### `fwf run [--manifest PATH] [--once]`
The supervisor loop: poll, plan, act, sleep `poll_interval_secs`. `--once` runs
one tick. Acts as all three Apps. It writes `<floor>/run.pid`.
Refuses to start:
- when the manifest's `issues` allow-list is empty (exit 2);
- beside a live loop for the same floor (exit 1). A dead pid is reclaimed;
- without an `[impl]` or `[qa]` App.

Once running, it parks without waking any seat while the meter is at or over
the limit or the last reading is stale. See
[`operations.md`](operations.md#the-meter-and-its-brake) and
[`lifecycle.md`](lifecycle.md).

### `fwf stop [--manifest PATH]`
SIGTERM to exactly the pid in `<floor>/run.pid`, and nothing else. Never a
sibling `fwf gate` or `fwf qa`. Removes a stale pidfile. No identity.

### `fwf release --seat N --role impl|qa [--by NAME] [--manifest PATH] [--log PATH]`
Frees a **Stalled** seat now: it appends an `Idle` event plus a `Human` event
naming `--by` [`$USER`], so the seat id is assignable again for both roles. The
loop does the same by itself 20 minutes after a stall. Refuses (exit 1) any seat
the record does not show as Stalled: Working, Idle, Gone, or never seen. Record
only, no identity.

## Moving one issue by hand

These are the steps the loop takes, one at a time. Each re-checks its own
preconditions and refuses rather than guesses. Read
[`configuration.md`](configuration.md#verbs-that-ignore-floor_dir) first: these
verbs use `~/.fwf/floors/<repo-name>` and the label `product-wip` whatever the
manifest says.

### `fwf triage --repo o/r --issue N --seat tmux-target [--timeout SECS] [--template F] [--expect CMD]`
Wakes the GV pane with the family's `gv-job.md` [`dev`] and waits [600 s]. A
not-ready verdict adds the gate label and posts the reason, under `ops`. A
ready verdict is a note in the record, and the issue still needs an un-gate.
Refuses a pull request, an issue it cannot read, a pane not running
`--expect` [`claude`], and a blocked or stalled seat.

### `fwf spec --repo o/r --issue N --seat tmux-target [--timeout SECS] [--template F] [--expect CMD]`
Wakes the PM pane with `pm-job.md` and waits [900 s]. Under `ops` it writes the
spec into the issue (its title and body), adds `discovery` when the PM asks, and posts the open
questions as one comment. The gate label is left alone. **Refuses an issue that
is not gated**, so an approved issue is never rewritten under a builder. Also
refuses a pull request and a blocked or stalled seat.

### `fwf ungate --repo o/r --issue N [--by NAME]`
The human sign-off. Removes the gate label under `ops` (a label already gone is
fine), posts a comment, and records `Ready` plus a `Human` event naming `--by`
[`$USER`]. `Ready` in the record, not the missing label, is what makes the
issue eligible.

### `fwf slice --repo o/r --issue N --seat tmux-target [options]`
One impl cycle. It takes a claim (`refs/claims/<n>` at the base tip, the fence)
and wakes the impl pane with `impl-job.md`. After the seat's verdict, it pushes
the seat's branch from the mirror to GitHub and opens a draft PR. Acts as
`impl`.
Options: `--base` [`staging`], `--timeout` [1800], `--stall-quiet` [900],
`--template` [`dev`], `--check CMD` (fills `{{CHECK}}`; empty unless given),
`--floor DIR`, `--expect` [`claude`], `--dry-run` (stop after planning).
Refuses an issue the scheduler would not plan (not signed off and not
`fast-track`, claimed, assigned, closed, not owner-authored), an issue already
implemented whose push is still owed, a seat that is not idle, and a
`refs/claims/<n>` that already exists upstream and is not this floor's. A blocked
verdict releases the claim.

### `fwf qa --repo o/r --pr N --seat tmux-target [options]`
Wakes the QA pane with `qa-job.md` and the issue's spec, and posts its verdict
as a review under `qa`, anchored to the head it reviewed.
Options: `--seat-no` [1], `--timeout` [1200], `--template` [`dev`],
`--check CMD`, `--floor DIR`, `--expect` [`claude`].
Refuses a PR that is not open, a mirror whose copy of the branch differs from
the PR head, a PR whose issue has no spec (`spec unavailable …`, and no seat is
woken), and an approval without a well-formed per-criterion checklist or with a
`not_met` (`QA approval rejected: …`, and nothing is posted).

### `fwf review --repo o/r --pr N --by qa|impl|ops [--changes] [--body TEXT]`
Posts an approval, or a changes-requested review with `--changes`, under the
named App, anchored to the PR's current head. GitHub itself refuses an App
approving its own PR.

### `fwf ready --repo o/r --pr N [--by APP]`
Marks a draft PR ready for review under `--by` [`impl`]. On a private
repository the `impl` App may be refused. The loop uses `ops` for this.

### `fwf merge --repo o/r --pr N`
The typed squash-merge, under `ops`. It reads the fence from the live
`refs/claims/<issue>` of the issue the PR closes, and refuses without one.
Then, from GitHub's own objects at that moment, it requires: the PR open and
not a draft; an approval at the current head by someone other than the author,
with no changes-requested at that head outranking it; and every check-run on
the head completed and successful. The merge carries the head sha, so GitHub
refuses it if the head moved. On success it releases the claim and records
`Merged` and `Shipped`.

### `fwf gate --repo o/r --sha SHA --suite NAME --cmd 'SHELL' --workdir DIR [options]`
Runs one suite at one sha, records the verdict and posts a `fwfd/<suite>`
check-run under `ops`. Exit 0 only on Green.
Options: `--venue` (`container` selects Apple `container`; **any other value,
including `systemd-run` and `systemd`, runs `local` with no memory cap**, see
#715), `--image` [`alpine:latest`, container only], `--memory` [8 GB],
`--timeout` [1800 s].
Refuses an sha that is not the full 40 hex characters. If the workdir's
checkout is not at that sha, it does not run and reports `Unknown`. A verdict
already recorded for that sha and suite is returned without running again. See
[`gates-and-promotion.md`](gates-and-promotion.md).

### `fwf promote --repo o/r --from BRANCH --to BRANCH --suite NAME [--workdir DIR]`
Fast-forwards `to` to the sha `from` points at, under `ops`. Requires `to` to be
an ancestor of `from` and a Green verdict for exactly that sha and suite,
recorded in `--workdir` [`~/.fwf/floors/<name>/gate-wt`]. Never forces.

## See also

- [`lifecycle.md`](lifecycle.md) — the order the loop runs these in.
- [`troubleshooting.md`](troubleshooting.md) — what a refusal usually means.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
