# 0.x → 1.0 parity inventory (#623)

The gate before the bash tool is deleted. One row per legacy artifact at the
repo root — all 47 `fwf-*.sh`, plus `lib.sh` and `config.sh` — against fwf 1.0's
24 subcommands (`container cost dash doctor gate init-manifest merge
mirror-init probe promote qa ready release-check review run seats slice spec
status triage ungate up version why`) and the internal mechanisms behind them.

Verdicts:

- **equivalent** — 1.0 answers this concern. The answer is named: a verb, or the
  module that does it. A different shape counts, as long as the concern is met.
- **dead** — the concern only exists in 0.x's architecture (ten persistent panes,
  each with its own loop, all writing to GitHub), and is stated as such.
- **gap** — genuinely needed, not yet in 1.0. Must land before deletion.

**There are zero `gap` rows.** Nothing in the table blocks deletion.

Verb names were not trusted as evidence: only 5 of the 47 have an exact-name 1.0
sibling. Each row below was decided from what the script's own header says it
does, against the 1.0 code that covers that concern.

## The table

| 0.x script | verdict | 1.0 answer, or why it is dead |
|---|---|---|
| `fwf-auth.sh` | equivalent | `scripts/seat-up.sh` injects the seat's token from `~/.fwf/seat-token` (or the Keychain) through a 0600 env file the pane sources; `fwf seats --up` is the operator entry point. |
| `fwf-authz.sh` | equivalent | Authorization is structural in 1.0: `sched::issue_eligible` plans only OWNER-authored, un-gated, unassigned issues, and un-gating is a human act recorded as `Kind::Human` by `fwf ungate`. |
| `fwf-backfill-context.sh` | dead | A one-shot recovery written for a specific 0.x incident (its own header: "issue #212: recover the 16…"). Nothing recurring. |
| `fwf-branch-policy.sh` | dead | 0.x needed an audit that GitHub's branch protection was configured, because ten panes could each push. In 1.0 the supervisor is the only writer: `mirror::PROTECTED` refuses `staging`/`main` outright and `promote` refuses without a recorded Green for the exact sha. Repo-side protection remains an operator setting (see [`../gates-and-promotion.md`](../gates-and-promotion.md)), not a script. |
| `fwf-budget-check.sh` | equivalent | `cost.rs` measures each cycle from the seat's own transcript and `run.rs`'s meter brake parks the floor at the manifest's `park_at_weekly_pct`; `fwf cost` reports it. |
| `fwf-claim-liveness.sh` | equivalent | A claim is `refs/claims/<n>` plus the record: `log::claimed_issues` says who holds what, and `sched::Action::ReleaseClaim` releases a claim whose seat is not working it. |
| `fwf-claim.sh` | equivalent | `mirror::create_claim_ref` — an expect-empty compare-and-swap whose sha is the fence — is the checkpoint, taken by `slice::claim` before any seat is woken. |
| `fwf-dash-act.sh` | dead | 1.0's dash is read-only by design; the write side is separate verbs a human runs (`fwf ungate`, `fwf merge`, `fwf promote`), each recorded as a `Human` event. |
| `fwf-dash-data.sh` | equivalent | `dash::fold` folds the run record into the board; the record is the only source. |
| `fwf-dash-remote.sh` | dead | 0.x split data collection from display across machines. 1.0's dash reads one local append-only file. |
| `fwf-dash.sh` | equivalent | `fwf dash`. |
| `fwf-down.sh` | equivalent | `fwf seats --down` (`verbs.rs`), which kills the tmux session and refuses while the record says a seat is still Working. |
| `fwf-flag-captain.sh` | equivalent | The captain is code in 1.0, not a seat: everything only a human can clear is the `needs you` list (`dash::needs_you`, `fwf status`). |
| `fwf-gate-promote.sh` | equivalent | `promote.rs` refuses a promotion without a recorded Green for the exact sha — the obligation is the code path, not a wrapper around it. |
| `fwf-gate-revoke.sh` | dead | The record is append-only and gate verdicts are per-sha: a later run supersedes an earlier verdict rather than revoking it, and `promote` reads the latest for that sha. |
| `fwf-gate-rust-scope.sh` | dead | A shadow-mode experiment for one 0.x profile ("SHADOW MODE", its own header). |
| `fwf-gate.sh` | equivalent | `fwf gate` / `gate.rs`: run a manifest suite on a sha, record the verdict, post the check run. |
| `fwf-gate-tip.sh` | equivalent | The gate tip is in the record; `fwf status` and `fwf dash` print it, `gate.rs` writes it. |
| `fwf-gate-verdict-watchdog.sh` | equivalent | `run.rs::gate_after_merge` gates the new base tip after every merge, and a Red or Killed verdict reaches `needs you` (#625). |
| `fwf-ghcache.sh` | dead | It existed because ten pollers hit the API concurrently. 1.0 has exactly one poller, and `poll.rs` carries its own ETag cache. |
| `fwf-issues.sh` | dead | A local gh-shaped tracker for offline work. 1.0 reads GitHub itself (`poll.rs`, `github.rs`) and treats an unreadable tracker as `Unknown` rather than substituting a local one. |
| `fwf-local-ci.sh` | equivalent | `fwf gate` runs the manifest's suite on this box and records the verdict. |
| `fwf-merge.sh` | equivalent | `fwf merge` (`merge.rs`), which re-checks every precondition — approval at head by the QA App, gate green — before the typed merge. |
| `fwf-operator-decision.sh` | equivalent | The artifact is the run record: `needs you` states what only a human can clear, and each human act lands as a `Kind::Human` event that `fwf why` can replay. |
| `fwf-pane-liveness.sh` | equivalent | `seat::window_exists` and the dash's per-seat live column; a pane whose foreground command is not `claude` is refused by `seat::wake` and logged. |
| `fwf-pr-assign-reviewer.sh` | equivalent | The scheduler assigns: `sched::plan` wakes a QA seat for a PR with no review at its head, and `qa.rs` posts the review as the QA App. |
| `fwf-pr-checks-honored.sh` | equivalent | `checks.rs` reads the check runs and `merge.rs` refuses a merge whose checks are not honoured. |
| `fwf-pr-context.sh` | equivalent | The supervisor renders the context into the one job it types: `{{TITLE}}`, `{{REVIEW}}`, `{{HEAD}}`, `{{CHECK}}` (`slice.rs`, `rework.rs`, `prompts/`). |
| `fwf-provision.sh` | equivalent | `fwf seats --up` + `scripts/seat-up.sh`: mirror, worktree clone, per-seat identity, warm pane. Idempotent. |
| `fwf-pr-reviewer.sh` | equivalent | `poll.rs` reads reviews with their author; the QA App's login (`-qa[bot]`) is what `sched::pr_approved_at_head` counts. |
| `fwf-pr-review-state.sh` | equivalent | `types::PrState` is that single source of truth, folded from the poll snapshot. |
| `fwf-pr-route-check.sh` | equivalent | `sched::is_floor_pr` — a PR on an `impl<n>/…` branch that this floor's impl App did not author is not its seat's work. |
| `fwf-reconcile-guard.sh` | equivalent | `promote.rs` re-reads both refs and refuses anything that is not the fast-forward it was asked for; there is no separate guard to bolt on. |
| `fwf-reconcile.sh` | equivalent | `fwf promote --from staging --to main --suite e2e`, refused without a recorded Green. |
| `fwf-release-ci-gate.sh` | equivalent | `scripts/release-publish.sh` runs the same gate CI runs before it will cut anything, and `fwf release-check` proves the release object exists. |
| `fwf-respawn.sh` | equivalent | `fwf seats --up` is idempotent and leaves a live pane alone; a dead pane is refused by `seat::wake`, logged, and brought back by the same command. |
| `fwf-resume.sh` | dead | There is no STOP sentinel to clear in 1.0: the loop is a process. Stop it, start it. An interrupted run is reconciled at the next start by `log::reconcile_stale_working`. |
| `fwf-scale.sh` | equivalent | The manifest's `pairs` says how many impl/qa seats exist; `fwf seats --up` reconciles the floor to it. |
| `fwf-shipped.sh` | equivalent | `IssueState::Shipped { pr, sha }` in the record, written when the PR that closes an issue merges. |
| `fwf-stop.sh` | equivalent | Stop `fwf run`; `fwf seats --down` refuses while the record says a seat is Working (`--force` to override). No WIP round-up is needed because a seat's work is a branch on the mirror, not pane state. |
| `fwf-suggest.sh` | dead | A 0.x onboarding toy ("describe what you're trying to do; get a factory design back"). Nothing depends on it. |
| `fwf-supervise.sh` | equivalent | `fwf run` — poll → plan → act, one tick at a time, single-threaded so every GitHub write is serialised. The "wedge" it supervised was ten independent loops; there is one now. |
| `fwf-ungate.sh` | equivalent | `fwf ungate`. |
| `fwf-up.sh` | equivalent | `fwf up` / `fwf seats --up`. |
| `fwf-usage-data.sh` | equivalent | `cost.rs` aggregates per-role token and dollar cost from the seats' own transcripts. |
| `fwf-usage.sh` | equivalent | `fwf cost`, plus the dash's Usage tab. |
| `fwf-worktree-refresh.sh` | equivalent | `slice::align_seat_worktree` fetches and detaches the seat's worktree onto the fence before every wake, and refuses a dirty tree rather than cleaning it. |
| `lib.sh` | dead | 0.x's shared shell helpers. Nothing in 1.0 sources it. |
| `config.sh` | equivalent | Configuration is the manifest: `manifests/*.toml`, read by `manifest.rs`, created by `fwf init-manifest`. |

Counts: 38 equivalent, 11 dead, 0 gap.

## The nine flagged scripts

The ticket asked for extra scrutiny on nine with no obvious 1.0 sibling. All nine
are resolved above: `fwf-auth` (seat-up token injection), `fwf-authz`
(`sched::issue_eligible` + the recorded human un-gate), `fwf-provision`
(`fwf seats --up`), `fwf-respawn` (same, idempotent), `fwf-supervise`
(`fwf run`), `fwf-budget-check` (`cost.rs` + the meter brake),
`fwf-operator-decision` (`needs you` + `Kind::Human`) — equivalent; and
`fwf-resume` (no STOP sentinel exists) and `fwf-ghcache` (one poller, ETags in
`poll.rs`) — dead, for architectural reasons stated in the table.

## Operational check: what is on PATH, and what the floor runs

Run on the fwf floor host, 2026-09-14 23:0xZ. The loop was running (it is what
woke the seat that wrote this); no other cycle was in flight.

- The live supervisor is **1.0**, invoked by path, not through `PATH`:
  `./target/debug/fwf run --manifest manifests/fun-with-friends.toml` (pid 241031,
  from `ps`). Its run record — `~/.fwf/floors/fun-with-friends/run.jsonl` — is
  1.0's append-only JSONL, and every event in it was written by this binary.
- `fwf` on `PATH` is **`/usr/local/bin/fwf` → `/home/factory/fun-with-friends/fwf`,
  a dangling symlink**: that target has not existed since #583 renamed the
  dispatcher to `fwf-legacy`. So `fwf` from a shell on this host currently fails
  with "command not found" rather than running the bash tool.
- No 0.x process was running (`ps` shows no `fwf-*.sh`, no `fwf-legacy`).

**Conclusion for the deletion ticket:** nothing on this host executes the 0.x
tool, so removing it cannot take a floor down. Two things to do along with the
deletion, in either order: re-point `PATH` at the 1.0 binary (`install.sh` does
this — it installs `fwf` into the prefix), and remove the stale
`/usr/local/bin/fwf` symlink. Re-run this check at idle on any other live floor
before deleting there; the method is the three commands above (`ps`, `readlink
-f "$(command -v fwf)"`, and a glance at the floor's `run.jsonl`).

## Recommendation on #622

**Close #622.** It proposed moving the 50 root artifacts into `bin/`; with zero
parity gaps the deletion ticket removes them instead, and the root-clutter
complaint that prompted #622 is answered for free. Nothing in this table asks for
a fallback: there is no `gap` row to keep #622 alive for.

## What this ticket does not do

The deletion itself — the root scripts, `fwf-legacy`, `test/run.sh`, the 0.x CI
steps, and the fate of `docs/legacy/` — is the immediate follow-up, deliberately
separate so that nobody deletes mid-inventory. This page is the gate it has to
pass, and it passes.
