# fwf 1.0 — `fwfd`

One Rust supervisor runs a software factory on a GitHub repository. It reads
the tracker, decides what to do next, wakes an idle Claude Code pane with
exactly one job, reads back a JSON verdict, and performs every GitHub write
itself under three narrow GitHub App identities. Seats never hold a GitHub
write token, never poll, never loop, and cost nothing while idle.

```
issue ──GV triage──▶ gated ──human `fwfd ungate`──▶ eligible
  ──impl seat──▶ branch on the local mirror ──ops push, impl PR──▶ draft PR
  ──QA seat──▶ review under fwf-qa (anchored to the head) ──▶ typed merge under fwf-ops
  ──gate (bash -o pipefail, memory-capped venue)──▶ check-run ──▶ promote by literal SHA
```

Status: M0–M3 done and proven live on this repository (`docs/BUILD-LOG.md`);
M4 (soak, head-to-head, cutover) is next. Nothing here is wired into the
v0.42 `fwf` command yet.

## Requirements

- macOS or Linux, `tmux`, `git`, a Rust toolchain (stable).
- A Claude subscription; the seats are ordinary interactive `claude` panes.
- Three GitHub Apps installed on the repository (`docs/github-apps.md`):
  `impl` (pull_requests:write), `qa` (pull_requests:write), `ops`
  (contents, issues, checks: write). Keys in `~/.fwf/keys/`, ids in
  `~/.fwf/apps.toml`.

## Ten-minute start

1. Build and check the Apps:
   ```
   cd one && cargo build --release && cargo run --quiet -- doctor
   ```
2. Write the manifest into the customer repo (or convert a v0.42 profile):
   ```
   fwfd init-manifest > .fwf/fwf.toml
   fwfd init-manifest --from-profile profiles/transom.sh --repo tbaums/transom > .fwf/fwf.toml
   fwfd up            # validates, mints every App, prints the floor plan
   ```
3. Create the local mirror and the seats (one impl + one QA per pair):
   ```
   fwfd mirror-init --repo owner/name
   git clone --branch staging ~/.fwf/floors/<name>/mirror/mirror.git ~/.fwf/floors/<name>/wt-impl1
   git clone --branch staging ~/.fwf/floors/<name>/mirror/mirror.git ~/.fwf/floors/<name>/wt-qa1
   one/scripts/seat-up.sh ~/.fwf/floors/<name>/home ~/.fwf/floors/<name>/wt-impl1 fwf-<name> impl1 opus
   one/scripts/seat-up.sh ~/.fwf/floors/<name>/home ~/.fwf/floors/<name>/wt-qa1   fwf-<name> qa1   opus
   ```
   Seats authenticate from `~/.fwf/seat-token` (`claude setup-token`); the
   per-floor HOME holds the deny hooks and nothing else.
4. Put the issue numbers you want worked in the manifest's `issues = [...]`
   allow-list (`fwfd run` refuses an empty one), then:
   ```
   fwfd run --once     # one tick: poll → plan → act
   fwfd run            # the loop
   fwfd status         # one screen: seats, issues, PRs, needs-you
   fwfd dash --watch 30
   ```

## The verbs

| verb | what it does | identity |
|---|---|---|
| `up`, `doctor`, `status`, `dash`, `why <pr>`, `cost` | read-only: validate, mint, one-screen status, the board from the run record, one PR's timeline, measured tokens | – |
| `run [--once]` | the supervisor loop; only allow-listed issues; parks on the meter brake | all three |
| `spec --issue N` | PM seat writes a spec into a **gated** issue; gate untouched | ops |
| `triage --issue N` | GV seat judges an issue; not-ready ⇒ gate label + reason | ops |
| `ungate --issue N --by NAME` | the one human decision, made mechanical and recorded | ops |
| `slice --issue N` | wake an impl seat; push its branch; open the draft PR | ops, impl |
| `qa --pr N` | wake a QA seat; post its verdict as a review anchored to the head | qa |
| `merge --pr N` | typed squash-merge: approval at head by a non-author, fence, checks | ops |
| `gate --sha S --suite X` | run a suite in a venue (local / Apple container / systemd), record a verdict, post a check-run | ops |
| `promote --from A --to B` | fast-forward by literal SHA, only on a recorded Green | ops |
| `release-check --tag vX` | refuse unless the tag has a release object with the expected assets | ops |

`fwfd <verb>` with no arguments prints the exact flags.

## What is enforced, not asked

- **Seats cannot write to GitHub.** No token in the pane; `gh` and `curl`
  disallowed; deny hooks under `--permission-mode dontAsk`; the only remote is
  a local bare mirror; `staging`/`main` pushes refused by the mirror layer.
- **Every write is typed.** Issue / PR / Seat / Gate states are enums with
  `Unknown` first-class; a merge needs an approval anchored to the exact head
  by a non-author, a live claim fence, and green checks; a promotion needs a
  recorded Green for the exact SHA; a release needs a release object.
- **Nothing is inferred from pane text.** Seats answer with one JSON verdict
  file written atomically; a missing verdict is `Stalled`, never guessed.
- **Only humans un-gate.** A model can gate an issue; only `fwfd ungate`
  makes it eligible, and the run record names who.
- **The meter brakes the floor.** `run` parks at `park_at_weekly_pct` from
  the last real reading in `~/.fwf-meter-log`.
- **The record is append-only.** `~/.fwf/floors/<name>/run.jsonl` is the
  source for `why`, `status`, `dash`, and cost; `fwfd` never edits it.

## Layout

```
one/
  src/          fwfd (types, log, github, poll, sched, seat, mirror, slice, qa,
                merge, gate, checks, promote, run, triage, spec, dash, cost,
                manifest, profile, prompts, verbs)
  prompts/      one-job prompts per family and role (dev, refactor, validate,
                ideation, consulting, defect-report, user-testing)
  manifests/    converted manifests for transom, baton, wholesome-swolesome
  scripts/      seat-up.sh, size-check.sh (+ baseline)
  docs/         github-apps.md, BUILD-LOG.md, CUTOVER.md
  RELEASING.md  CHANGELOG.md
```

Tests: `cargo test` (97, including proptest properties and a fake GitHub);
CI: `.github/workflows/one-ci.yml` (test, fmt+clippy, size ratchet).
