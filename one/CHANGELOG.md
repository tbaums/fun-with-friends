# Changelog — fwf 1.0 (`one/`)

## Unreleased

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
