# Changelog — fwf 1.0 (`one/`)


## 1.0.8 — 2026-09-16

The run loop no longer re-gates an issue it just un-gated.

- **Delegated un-gate re-gated the issue from a stale payload in the same tick** (#664, PR #666) — `reconcile_regated` now ignores a Snapshot polled at or before the issue's latest Ready/Claimed event, so a same-tick delegated un-gate is no longer read as "the gate label is back" and the issue is planned in the tick that signed it off. Observed on the transom floor 2026-09-16 (every signed-off ticket sat for 6+ ticks until a manual `fwf ungate`). Tests split into `run/tests_regate.rs` to respect the 1,000-line rule.

## 1.0.7 — 2026-09-15

Scheduler hardening after the first day of automated GV→PM→GV, plus the devbox latest-release check.

- **Gated-issue review honours `skip_labels`; new `review_scope`** (#652, PR #654) — skip-labelled issues are never woken; `review_scope = "all-gated" | "allow-list"` (default all-gated) lets a single-ticket floor stay scoped.
- **A first-pass GV READY no longer skips the post-spec sign-off** (#655, PR #657) — sequence is now triage → spec → sign-off → un-gate; a spec nobody reviewed can no longer be un-gated.
- **Delegated un-gates are attributed** (#645, PR #658) — `delegate_ungate` un-gates carry a `(delegated)` marker in the issue comment and run record; `fwf up` prints the delegate.
- **`fwf doctor` shows installed vs latest; new `fwf self-upgrade`** (#653, PR #659) — checksum-verified atomic install of the matching release asset; `fwf up` refuses on a known-stale binary (`FWF_ALLOW_STALE=1` to override); unreachable GitHub is a warning, never a hang.
- **Re-gate reconciliation, refusal back-off, claim-ref release** (#656, PR #661) — a `product-wip` re-applied after a Ready record gates the issue again; a refusing slice releases its claim ref and no longer starves the allow-list.
- **install.sh downloads `v<version>` assets** (#660, PR #662) — the pre-#641 `one-v` URL 404'd on every fresh install; install.sh and `self-upgrade` now share the tag spelling.
- Closed by decision: #646 (discovery tickets do reach PM/GV — keep `discovery` out of `skip_labels`), #107, #166, #161, #611.

## 1.0.6 — 2026-09-15

Core-9 burn-down, every ticket through GV triage → PM spec → GV sign-off.

- **Scheduler drives gated issues through GV→PM→GV automatically** (#629, PR #647) — a `product-wip` allow-listed issue is triaged, specced and re-triaged by the loop; un-gate stays human-only (`fwf ungate --by`). Delegated sign-off split to #645, discovery policy to #646.
- **No ticket is impl-eligible without a PM spec + GV READY sign-off** (#630, PR #651) — eligibility now requires the review, not just the missing gate label.
- **Repo root tidied** (#622, PR #648) — the 49 `fwf-*.sh` scripts plus `lib.sh`/`config.sh` move to `bin/`; every caller repointed (QA caught the one miss in `lib/version_check.sh`).
- **dash: golden real-record test** (#627, PR #649) — `log::read_all → fold → render` exercised end-to-end on a real run record.
- **dash: `--help` prints help** (#628, PR #650) — no longer renders a board for the wrong floor on an unknown flag.
- Closed as already shipped in earlier merges: #623 (retire the 0.x bash tool), #624/#625/#626 (dash width, stale RED alerts, `--watch` default), #602/#604/#621.

## 1.0.5 — 2026-09-14

- **Branch push token minted from the impl App with `workflows: write`** (#636) — branches touching `.github/workflows/` push again.
- **one-release.yml triggers on `v*` tags** (#641) — Linux assets build for every release; the legacy `one-v*` trigger is gone.

## 1.0.3 — 2026-09-13

The docs release. Nothing in the supervisor's behavior changes; the repo now reads as fwf 1.0's front door instead of 0.x's, and the prompts are where a reader lands first.

- **Prompts front and center (#605, PR #614).** `one/prompts/` moved to repo-root `prompts/` with history intact, a tracked `one/prompts -> ../prompts` compatibility symlink for one release, `prompts.rs::ROOT` repointed past the symlink, and a Prompts section at the top of the README. The one-ci path filters and size-check follow the move.
- **`docs/design.md` (#606, PR #615).** Why the harness is built this way — one supervisor, many stateless seats; one job, one verdict; refusals in code, not habits — landed as written, with the opening quoted in the README.
- **Repo hygiene (#608, PR #616).** `SECURITY.md` (what the three App identities can and cannot do, seats hold no token, how to report), issue-template config, dependabot for `one/Cargo.toml`, and the 0.x workflows renamed `legacy CI` / `legacy release` so the badge row cannot be mistaken.
- **1.0-first docs tree (#609, PR #618).** Every 0.x page and proposal moved unchanged to `docs/legacy/` behind a deprecation banner and index; `one/docs/github-apps.md` and `one/RELEASING.md` promoted to `docs/`; the 1.0 changelog is now the root `CHANGELOG.md` (0.x's is `docs/legacy/CHANGELOG-0.x.md`); `docs/index.md` links the tree with stubs for pages not yet written; `scripts/link-check.sh` runs in one-ci over `docs/**`.
- **README rewrite (#610, PR #619).** Text lockup, badges (one CI, latest one-v* release, crate version, license, prompts · 4 roles · 7 families), what it does, a ten-minute start run verbatim, the prompts, "enforced, not asked", the 1.0 verbs, the design opening, and a legacy pointer. No contributor docs by design.
- **`prompts/README.md` guide (#612, PR #620).** One section per real role (`impl`, `qa`, `gv`, `pm`), the placeholders each receives, the verdict JSON contract the supervisor parses, one paragraph per family, the ground rules every prompt inherits, and why one job / one verdict — with a test that fails if a role or placeholder goes undocumented.
- **Operator notes.** `one/Cargo.lock` is bumped with the version this time (#604: 1.0.2's Linux job refused a stale lock). Hand-merged and loop-merged PRs diverged main/staging mid-batch; reconciled in e09ae71. Three slices touched `.github/workflows/` and needed a hand push (#602). Rework's `--force-with-lease` is blocked by the seat deny hook (#621).

## 1.0.2 — 2026-09-12

- **A release is one command (#584).** Both 1.0 cuts were hand-made, macOS-only,
  with no guarantee `release-check` ever ran. `one/scripts/release-publish.sh
  <notes.md>` now refuses a dirty tree and a version already tagged here or on
  the remote, runs the same gate CI runs, builds release, stages
  `<bin>-<version>-macos-arm64/` (binary named from `Cargo.toml`, plus README,
  RELEASING, CHANGELOG), tars it with a `.sha256`, publishes with one `gh release
  create` — tag and release together, so nothing can race a release that does not
  exist — and proves the result with `release-check --expect 2`. The tag push
  runs the new `one-release.yml` on `ubuntu-latest`, which adds the
  `linux-x86_64` pair by upload only, failing loudly if the release is not there.
  Four assets, and `install.sh` fetches exactly those names.

- **Factory commits are authored by the seat that wrote them (#590).** Seat
  worktrees had no identity of their own, so git guessed one from the machine —
  the same author for every seat, indistinguishable from a human's local commit.
  `fwfd seats --up` now sets `user.name`/`user.email` to `<seat>` /
  `<seat>@fwf.local` in each worktree on every run, so a drifted or inherited
  identity is corrected and not merely created; the gate worktree gets
  `fwf-gate`, stamped where the loop clones it. `fwfd doctor` grew a seat-identity
  section (and moved into `verbs.rs`): it reports what every worktree the manifest
  names commits as, flags the ones that are wrong, and exits non-zero. What pushes
  and opens the PR is unchanged — that stays `fwf-impl[bot]`.

- **Every seat is told when its cycle ends (#589).** A flake-fix spec asking for
  "run the suite 20× back-to-back" had seats starting a 50-minute loop against a
  40-minute `job_timeout_secs` and then idling on the shell — three human
  interrupts on transom in one night. Job prompts now carry one line, the same in
  all 21 of them: "Your job deadline is {{DEADLINE}}; push before it — a partial
  result beats a stall." `slice`, `qa`, `spec`, `triage` and `rework` fill it from
  `seat::now() + timeout` as local `HH:MM` via `seat::local_hhmm`. Information,
  not enforcement: the sharper backstops (a PM rule on repeat-run criteria, a
  finalize nudge from the loop) are still open.

- **`fwfd status` knows who holds what (#588).** "claimed" came from
  `IssueView.claim`, which the poller fills only for issues carrying a `claimed`
  GitHub label — and nothing applies that label, so transom's #1268 read as
  `ready` with `claimed 0` while `refs/claims/1268` was live and impl1 was
  working it. The new `log::claimed_issues` replays the run record instead (the
  latest `Claimed` per issue that no `Ready`/`Shipped`/`Gated`/`Closed` took
  back), and status drops those from eligible/ready and prints
  `claimed #N → impl<seat> (fence …)`. The seat list now comes from
  `Manifest::seats()` — every seat the manifest defines, `gv` and `pm` included,
  the same set `fwfd seats` brings up.

- **A verdict is a file that parses, not a file that exists (#587).**
  `wait_verdict` read the verdict the moment the path appeared and failed hard on
  a partial read: `fwfd spec` died with `verdict malformed: …` seconds before
  transom #1268's file was complete, and a seat that hand-typed its JSON with an
  unescaped quote (`triage #579`) failed the same way. A read or parse failure is
  now "not yet" and polling continues; only the deadline decides, and it says
  Stalled — printing the parse error and the raw text, so the bad file is
  diagnosable — which every verb already turns into a non-zero exit. All 20 job
  prompts now spell the rule out: build the JSON with a real serializer, write
  `<path>.tmp`, never `<path>`, then `mv` as a separate step.

- **Every wake gets its own tmux buffer and job file (#586).** The paste buffer
  was named `fwfd-<seat>` and the job file `fwfd-job-<pid>-<seat>.txt`, but
  tmux's buffer namespace belongs to the server and the temp dir is shared: the
  loop's GV wake and a hand-run `fwfd spec`, both seat 1, raced and one's
  `paste-buffer -d` deleted the other's buffer (`tmux: no buffer fwfd-1`), while
  two tests in one `cargo test` process deleted each other's job file on ubuntu
  CI. Both names now carry a per-wake token (seat, pid, an in-process counter
  and a nanosecond stamp), so no lock is needed for either.

- **GV triage honours `skip_labels` (#585).** `triage_candidates` read the gate
  label but not the manifest's skip list, and it runs before the tick's own
  skip-label filter, so on a `triage_new` floor every parked `idea` / `tracking`
  / `needs-human` ticket was offered to the GV seat — which then labels and
  comments on it (transom's #374). The skip labels are now part of the same
  eligibility predicate, where the gate label already was.

- **Per-cycle tokens are a window, and now there are tests that say so (#581).**
  Transom's impl seat recorded 7M → 22M → 58M → 95M tokens in over four cycles,
  which reads like a cumulative counter. It was not: `cost`'s time window was
  already exact, and two new tests hold it there — one over a single growing
  transcript spanning two cycles (byte-exact, boundary turn included, a silent
  seat summing to zero), one over two sequential recorded cycles of the same seat
  asserting what lands in the run record. The growth is real, because every
  request re-reads the conversation the seat has grown, so `dash` now says so
  where the numbers are: the Usage ledger and each seat's per-cycle line call
  in/cycle an upper bound rather than a per-task price.

- **The loop and the slice agree on which seat is free (#579).** `PrView` carries
  the PR's `author`, and "one PR in flight per impl seat" counts only PRs this
  floor opened (`…-impl[bot]`) — the 0.x factory used the same `impl<n>/` prefix,
  so legacy draft #540 had been holding seat 1 since July. `SliceConfig` gains
  `seat`, set from the `WakeImpl` the loop is dispatching, so `slice`'s own
  eligibility recheck asks about that seat instead of a hardcoded 1: the real
  cause of "run plans it, slice refuses it, three ticks running" on #574. And a
  refusal no longer scrolls away — `fwfd status`'s needs-you carries the newest
  refusal per still-open, unclaimed issue, once, with how many times it repeated.

- **A refused PR is rework, not a parked floor (#576).** `sched::plan` gains
  `Action::Rework`: an open PR with a CHANGES_REQUESTED review anchored at its
  head, on a branch that names an idle impl seat, wakes that seat on its own
  branch with the review body as the job (`prompts/<family>/impl-rework.md`, new
  `{{REVIEW}}`) — no new claim, no new PR. The worktree is realigned to the head
  QA reviewed (a dirty tree refuses the round), and the reworked branch is pushed
  upstream under a lease on that same head. Rounds are capped by the new manifest
  key `rework_cap` (default 2) and counted from the run record; at the cap nothing
  is woken and nothing is closed — `fwfd status` and the dash say "PR #N hit the
  rework cap", which is the one case a human has to clear.

## 1.0.1 — 2026-09-12

The board is back. Built by the fwf 1.0 floor on its own repo (#574 → PR #580: Opus impl, Sonnet QA, fast gate, `fwfd promote`), 41 minutes seat time.

- **`fwfd dash` is a board again (#574).** Header (repo, `base → release`, loop
  state, version, meter freshness), five tabs — Seats / Issues / PRs / Decisions
  / Usage — with a needs-you banner, bordered panes, a detail pane that follows
  the selection, colour by state, and keyboard nav (`1`-`5`, `j`/`k`, `g`/`G`,
  `r`, `q`) under `--watch`. Live seats come from the `kind: seat` transitions
  (Idle / Working with job, elapsed and deadline / Reported / Stalled, with the
  pane name and tmux liveness), the queue from `kind: issue` + the manifest's
  allow-list, the pipeline from `kind: pr` / `gate` / `promote` (draft → QA →
  approved@head → merged → gate → promoted). Source of truth is still the
  append-only `run.jsonl`: no GitHub poll, no TUI crate. The old ledger is
  tab 5, unchanged.

## 1.0.0 — 2026-09-12

First release. Proven unattended on three customer repos; cut after the transom soak.

- **Transom soak (2026-09-11/12):** six `product-wip` bugs (#1259, #1261–#1265) → Sonnet PM
  specs (1.7M tokens in each vs 4.7M on Opus) → un-gated by proxy → Opus impl / Sonnet QA →
  typed merges → post-merge fast gates (4 green, 2 flakes filed: transom #1268, #1271) →
  `fwfd promote` on the recorded Green → transom v0.52.0 released and deployed. 0 stalls.
- **Found by the soak, filed:** #574 dash regression vs the 0.x board; #575 `slice` branches
  from a stale worktree HEAD instead of the fence sha (one PR needed a hand rework);
  #576 no rework action on `ChangesRequested` (the loop idles with 0 actions).
- **Operational notes:** the loop logs only to `run.jsonl` (stdout is quiet); `seats --down`
  kills the whole tmux session, so run gates and releases in their own sessions; the
  transom e2e promote suite now runs `npm ci` first.
- Everything under the former “Unreleased” heading:

- Overnight run on two private repos (diaspective 10/10, baton 1/1, 0 stalls). Fixes found by it:
  ops undrafts PRs (impl cannot on private repos); `FinishPr` merges any PR already approved
  at head; GraphQL errors surfaced; tokened (scrubbed) mirror fetch for private upstreams;
  one PR in flight per impl seat; gate refuses a workdir at the wrong sha; brake parks on a
  stale meter; `{{CHECK}}` carries the repo's own check into every seat prompt; `skip_labels`;
  `fwfd seats --up/--down`, `fwfd ready`, `fwfd dash` meter line; `triage_new` (off).

## one/m0, 2026-09-09

- M0: crate, four state enums with `Unknown`, append-only JSONL run record,
  `why`; three GitHub Apps; GitHub client with narrowed installation tokens;
  fake GitHub for contract tests; tmux seat waker (bracketed paste, atomic
  verdict files); canary for deny hooks under `dontAsk`.
- M1: ETag poller + pure scheduler (proptest); claim refs as fencing tokens;
  local bare mirror per repo; QA cycle with reviews anchored to the head;
  typed merge; manifest (`.fwf/fwf.toml`, ≤25 keys, `issues` allow-list);
  per-cycle cost from the seat's own transcript.
- M2: gate runner (local / Apple container / systemd-run, `bash -o pipefail`,
  venue preflight); check-runs; promotion by literal SHA; `release-check`.
- M3: GV triage + human `ungate`; `status`; conductor-as-code (gate after
  merge); one-job prompts for seven template families; PM `spec` cycle;
  `dash` from the run record; meter brake; profile → manifest converter;
  hosted CI (test / fmt+clippy / size ratchet).
- Proven live on fun-with-friends: PRs #565, #567, #569 (impl → QA → merge →
  gate → check-run), triage/un-gate on #570, spec on #571.
