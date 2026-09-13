# Proposal: factory metrics + observability for optimization (#321)

**Status: PARTIAL BUILD.** Not the general "observability layer" or periodic
AI-analysis pass this ticket sketches — that scope does not survive contact
with what artifacts actually exist. Two narrow, cheap additions are
recommended as a follow-up build ticket; everything else in the original
five-question scope is a reasoned no-go, with the reason named per item.
This satisfies (g)'s own instruction that a short, targeted list is the
strongest possible outcome, not a schema-first design.

## 0. What already exists (AC e2) — read before proposing anything new

Two working instruments already answer part of this, and nobody had run
them:

```
$ ./fwf-ghcache.sh metrics
hit=211 revalidated=0 charged=51 window=3600s

$ ./fwf-ghcache.sh headroom
remaining=5000 limit=5000 reset=1788048322
```

(Run `2026-08-29T23:06Z`, this worktree.) `metrics` answers "how much GitHub
API spend is this floor generating" — for the canonical-topic and
per-item-view fetch paths specifically (see the bound below). `headroom`
answers "how close to quota exhaustion are we" — cheaply, on the same TTL
discipline as the rest of `ghcache`, and it already refuses to fabricate
(`headroom_report`, `fwf-ghcache.sh:684-697`: prints `UNKNOWN` and returns 1
rather than a confident zero when the refresh fails).

**Two caveats verified from source, neither obvious from the file, both
capable of misleading anyone who skips them:**

- **`kind=revalidated` has zero occurrences on the live log.** Checked
  directly: `wc -l metrics.log` → 3371 records; `hit`=2741, `charged`=630,
  `revalidated`=0. The kind is genuinely emitted (`_metric revalidated` at
  the `304` branch, `fwf-ghcache.sh:217` and `:445`) — its absence here does
  not mean the classification is broken, it means this floor's read
  pattern essentially never produces a conditional-revalidation hit under
  the current TTL. Anyone computing a hit-rate from `hit` vs `hit+charged`
  should know the third term is real but currently silent, not dead code.
- **`metrics.log` is a rolling window, pruned on ~1-in-20 writes rather than
  every write** (`fwf-ghcache.sh:147-151`, deliberately: `tail`+`mv` on
  every free hit would turn the cheap path into the expensive one). There
  is no all-time rate and no fixed window boundary — which is exactly why
  `metrics`' own output states its window (`window=3600s`) rather than
  leaving it implicit. A rate quoted without that window is not a
  measurement.

**`headroom`'s semantics were characterized before being used as a metric
(mandatory per this AC), and the answer is: exclude it as a consumption
signal.** Four consecutive reads through the *real* `gh` binary
(`/usr/bin/gh`, not the `ghcache` shim on `PATH` — conflating the two would
measure the cache, not the API):

```
t=1788044769 used=0 remaining=5000 reset=1788048369 delta=3600
t=1788044770 used=0 remaining=5000 reset=1788048369 delta=3599
t=1788044770 used=0 remaining=5000 reset=1788048370 delta=3600
t=1788044770 used=0 remaining=5000 reset=1788048370 delta=3600
```

`used` stayed `0` across four calls that were themselves real API requests,
and `reset − now` held at ≈3600 continuously rather than counting down to a
fixed hourly boundary. This independently reproduces the same anomaly the
GV and PM each found (and each briefly mis-explained — see below), on a
fresh run, hours later. **What is NOT established is why** — a fronting
proxy, an unmetered token class, and a sliding rather than fixed window are
all consistent with the observation, and this proposal does not assert a
cause it has not measured. **`headroom` is therefore excluded as a
consumption metric on this deployment** — not because it is broken, but
because "remaining=5000, used=0" cannot currently be related to actual
spend. Per this AC, concluding that and excluding it is a complete,
successful answer, not a failed investigation.

*(Worth recording for the next person who reasons about this: the GV's and
PM's own correction-of-record for this same finding was `reset − 3600 ≈
now`, checked as a sanity test — and that check passes at every instant by
construction, so running it and citing it as evidence proves nothing. It
was corrected only by making a live call and watching `used` refuse to
move. Any check this proposal or a future one specifies has to name the
observation that would have refuted it, not one that cannot fail.)*

**Bound, stated because it directly affects (e):** `metrics` counts the
canonical-topic fetch path (`fwf-ghcache.sh:195-234`) and
`ensure_view_resource` (`:429-450`) only. Verified structurally: `tier1()`
(`:617-660`), the fetching fallback for `issue view` / `pr view` / `pr
diff`, makes three `real_gh` calls and contains zero `_metric` calls —
grepped directly, not inferred. **Every genuine, quota-consuming read on
that path is invisible to `metrics`.** This matters specifically because
that path is one of the busiest on the floor: every role runs `fwf authz`
before claiming, and #207 (merged) makes `fwf merge` call `fwf authz` for
every linked issue of every PR. `metrics`' under-report grows exactly as the
authorization path gets busier. Instrumenting `tier1` is not proposed
here — that is a change to shipped `ghcache` code owned by whoever owns it,
and a discovery proposal characterizes what exists rather than fixing it.
Whether closing that gap is worth it is the one clear finding this section
produces (see §5).

A third existing artifact, found while investigating (e2)'s "what already
exists" instruction and directly relevant to two of the six rows below:
**`fwf_gate_history_record`/`fwf_gate_history_summary`** (`lib.sh:2747-2822`,
built for #227). Every gate run appends `ts=… verdict=PASS|FAIL
branch=… sha=…` to a per-case-id rolling log (window 20, same
self-trimming discipline as `ghcache`'s metrics log), and a summary
function turns that into `total`/`failed`/`last_green`/`branch_total`/
`branch_failed`, returning rc 1 (never a fabricated `0%`) when a case has
never been recorded. I have used this mechanism's own output directly, more
than once, in this session: `fwf gate`'s SUITE-level report already prints
lines like `history (last 20 runs, ALL branches): 7/20 failed (last green
3m ago)` and `==> FLAKY: passed 13/20 recent runs` — this is #227, live,
already answering part of question 5.

**A fourth, checked and found NOT to carry what row 6 needs:** the local-CI
per-SHA verdict store (`~/.fun-with-friends/local-ci/<sha>` +
`<sha>.log`, written by `fwf-local-ci.sh`, the replacement for the
now-disabled-on-GitHub CI path). Read directly:

```
$ cat ~/.fun-with-friends/local-ci/592b62e7b15fb3a2206f905d7e848fd0fc1cc950
red 2 failed
```

The verdict file records pass/fail and a failure count — **no timing field
at all.** The GitHub-Actions-era shadow log this repo used to have
(`fwf-gate-rust-scope.sh --full-suite-secs`, still readable in
`.github/workflows/ci.yml:75-76,163-164`) did capture full-suite wall-clock
per run, cached across ephemeral runners — but that path is CI-side and,
per the operator's own current direction, GitHub Actions is not the gate of
record any more; `fwf-local-ci.sh` is, and it does not currently carry the
timing field forward. This is the most concrete, checkable gap the
investigation found, and it is what §5's recommended build item closes.

## 1. The evidence table (AC a) — six rows, six answers, no omissions

| # | Signal | Artifact it derives from | Threshold / comparison | Decision it triggers |
|---|---|---|---|---|
| 1 | Wall-clock per ticket stage (claim→implement→gate→review→merge→promote→release) | **Partially available, not as one artifact.** Claim comment `createdAt` (`gh issue`), PR `createdAt`/`mergedAt` (`gh pr`), promotion event (no artifact — see row 6), release tag timestamp (`git log --tags`) each exist individually via `gh`/`git`, but nothing joins them by ticket today; the join key (issue number appearing in a claim comment, a PR title, and a commit subject) is consistent enough to script but is not itself a stored artifact. | A per-stage duration exceeding its own historical median for that stage. | Flag the dominant stage as the next optimization target, replacing the ticket's own "suspicion: gate runs, unverified" with a number. |
| 2 | Seat utilization (productive vs blocked-on-peer vs idle-for-lack-of-work) | **Not detectable from existing artifacts as a historical series.** `fwf dash`'s role-state classifier (UNKNOWN/BUSY/STALE/DOWN/floor_idle, backed by tick-watch + gate-lock + heartbeat state) is a real, already-shipped *point-in-time* query — I exercised its test suite this session and it correctly distinguishes a role holding its own gate lock (BUSY) from a genuinely stale one. But nothing samples it on an interval and persists the series, and "blocked-on-peer" specifically (vs. "idle, no ready issues") is not written to any artifact at all — an implementer's own idle/blocked reasoning lives in its chat transcript, not in git or GitHub. | — | **Not detectable without new instrumentation.** Building it would mean a new periodic sampler of `fwf dash`'s existing classifier, which is a real, scoped build — but a different one than "read existing artifacts," and out of this proposal's recommendation. |
| 3 | Right `FWF_PAIRS` for a given box | **Partially available.** `fwf-ghcache.sh metrics`/`headroom` (§0) answer the API-spend half directly and cheaply, right now, with no new code. CPU/RAM saturation is not captured by any factory artifact today — the ticket's own "load ~1.0 for a full day" figure came from the host, not from fwf. | Sustained seat idle (row 2, once it exists) alongside headroom staying far from exhaustion, or the reverse. | Raise or lower `FWF_PAIRS` — but #190/#210 already make this a live-floor-safe operation; this row only informs *when*, not *whether it's safe*. |
| 4 | Which gate assertions cost the most time, and which are flaky | **The flaky half is fully solved already** — #227's `fwf_gate_history_summary` (verified above, in production use this session). **The per-assertion timing half does not exist**: `test/run.sh` has no internal per-section or per-assertion timer; the coarsest available signal is the whole-suite duration (row 6, and not currently captured there either — see §0's fourth artifact). | Per-case fail rate over the rolling 20-run window (already computed by #227). | Already actionable today via `fwf gate`'s own report — this row needs zero new code, only wider use of what shipped. |
| 5 | Is a given verdict trustworthy | **Fully available, shipped, and in active use** (#227, same mechanism as row 4). Directly quoted from this session's own gate runs: `history (last 20 runs, ALL branches): 9/20 failed (last green 18m ago)` / `==> FLAKY: passed 11/20 recent runs — a red here does not by itself mean this branch broke it`. | Failure rate over the rolling window vs. the current run's own result. | Already wired into `fwf gate`'s SUITE-level report; no build needed. |
| 6 | Gate wall-clock (the ticket's own "the big one") | **Judged on attribution, per (b), not on detection.** No artifact currently persists per-run duration on the local-CI path (§0, fourth artifact) — the GitHub-Actions-era shadow log did, but that path is being retired. Detecting "gate takes 20 minutes" needs no instrument at all; *attributing* the 17–53 min (avg ~36) promotion-cycle range specifically to gate reruns, as opposed to conductor re-running against a moved staging tip, requires a persisted duration **and** a persisted reason-for-rerun, neither of which exists yet. | A run's duration relative to its own rolling median, cross-referenced against whether the promotion cycle it belonged to also hit the operator's newly-shipped CI-first short-circuit (see note below). | This is the row the §5 build item targets directly. |

**Note bearing directly on row 6's urgency:** the promotion-cycle timing
problem the ticket's table cites (17–53 min, avg ~36, against a 2 min
design; 3 of 7 verdicts STALE) is largely the conductor re-running the full
suite when it did not need to. A same-day operator change (E2E_CMD now
asks CI for the tip SHA's verdict first, and only falls through to a full
local run when CI hasn't already reported) directly targets that exact
symptom, independent of this ticket, and was live on this box before this
proposal was written. That does not make row 6 uninteresting — it changes
what "attribution" should measure going forward: whether the short-circuit
is actually being hit, not just whether the fallback run is slow.

## 2. #211, honored where it actually binds (AC c, c1)

#211's binding text is *"forces the caller to handle"* an unknown, not
merely *"renders as unknown."* The two shipped mechanisms this proposal
leans on already clear that bar at the point of a single read:
`headroom_report` returns rc 1 and prints `UNKNOWN` rather than a
plausible-looking zero; `fwf_gate_history_summary` returns rc 1 (no output)
for a never-recorded case rather than a fabricated 0% failure rate, and
every caller of it is written to branch on that rc.

Where this actually bites is aggregation, which is exactly where #211 says
it binds and where a naive metrics layer fails silently: **any mean or rate
computed over a series that contains an unknown interval must itself report
unknown or its own coverage, not silently drop the unknown term and average
the rest.** Concretely, if a future build item computes "mean gate duration
this week" over N runs and M of them have no duration recorded (a run from
before the field existed, or one that crashed before writing it), the
result must be reported as `mean=X (coverage M/N)`, never as `mean=X` alone
— a mean over 4 of 6 samples is a different measurement wearing the
original's name. This is a design constraint stated here for whoever builds
§5's item, not a new mechanism to build now.

## 3. Headline metric / counter-metric pairing (AC d)

- **Throughput (PRs merged / hour)** is a fine diagnostic and a gameable
  target: splitting work finer raises it without improving anything.
  Counter-metric: **merged-PR diff size distribution** (lines changed,
  already computable from `gh pr list --json additions,deletions` with no
  new code) — a throughput rise driven by shrinking PR size rather than
  faster real work shows up here before anyone has to argue about it.
- **Gate wall-clock (once §5 lands)** is gameable by narrowing what the
  gate covers. Counter-metric: **post-merge revert / follow-up-fix rate**
  (a later commit whose subject references the same issue number) — a
  faster gate that is quietly missing things shows up as more follow-up
  fixes per ticket, not as more red gates.

Both counter-metrics are named now, before either headline number becomes a
target for anyone to optimize against — that ordering is the point of this
AC, not the specific pairing chosen.

## 4. The decisions this data drives, or it's #122 again (AC f)

Restating §1 as decisions, since a schema with no obliged decision is
exactly what #122 was closed for:

- Row 4/5 (flaky vs broken, per-case trust): **already wired to a
  decision** — `fwf gate`'s own report already tells an implementer whether
  a red is "FLAKY, does not by itself mean this branch broke it" or a
  fresh, unprecedented failure. No new decision to add.
- Row 6 (gate duration, attributed): drives **whether the CI-first
  short-circuit is actually reducing wall-clock**, and secondarily whether
  a specific slow *section* of `test/run.sh` (real-tmux fixtures were the
  visibly slow part in this session's own gate runs) is worth isolating or
  parallelizing.
- Row 3 (pairs sizing): drives **raising `FWF_PAIRS` when headroom stays
  far from exhaustion and seats are starved** — but only once row 2 exists,
  which this proposal does not recommend building (see §1, row 2).
- Row 1 (full stage breakdown) and row 2 (seat utilization) and the
  AI-enhanced periodic-analysis pass: **no proposed decision survives
  contact with what's derivable today at low cost.** A full stage
  breakdown needs a new join across artifacts with no stable key; seat
  utilization needs a new periodic sampler most of whose signal (blocked
  vs. idle) doesn't exist as an artifact at all yet. Building either now
  would be exactly the "schema, then hope for decisions later" shape #122
  was closed for.

## 5. Recommendation (AC g, g0)

**PARTIAL BUILD.** File a new, separately-scoped build ticket for exactly
two items, both cheap, both closing a gap this investigation actually
found rather than a hypothesized one:

1. **Persist gate wall-clock in the existing local-CI verdict artifact.**
   `fwf-local-ci.sh` already writes one small verdict file per SHA
   (`~/.fun-with-friends/local-ci/<sha>`, currently `red|green N failed`);
   add a duration field to the same line. This is the cheapest possible
   change that makes row 6 attributable instead of merely suspected, and it
   rides an artifact that already gets written on every run — no new
   storage, no new schedule, no new API calls.
2. **Surface `fwf-ghcache.sh metrics` and `headroom` in the captain's
   existing per-tick report**, rather than leaving them as commands nobody
   runs. Both are free, already TTL-cached, and already honor #211 at the
   single-read layer (§0, §2). This is a wiring change, not new
   instrumentation.

**NO-GO on everything else in the original scope**: a full per-ticket
stage-timing pipeline (row 1), seat-utilization sampling (row 2),
per-assertion gate timing (row 4's second half), and the periodic
AI-enhanced analysis pass. Each is named with its specific blocking reason
in §1/§4 above, not a blanket "too hard" — row 1 lacks a stable join key,
row 2 lacks any artifact for the blocked-vs-idle distinction, per-assertion
timing needs an instrumentation change to `test/run.sh` itself that this
discovery ticket's scope does not cover. If any of these individually
becomes worth doing later, it should be filed as its own ticket naming the
specific decision it drives — the same discipline #122 and this proposal
were both held to.

**This closing note is the process obligation (g0) on whoever routes this
ticket, not something this proposal can discharge itself**: the PR body
above states the recommendation; the issue's closing comment should
restate build (for the two items in this section) vs. no-go (for
everything else) explicitly, so the decision is an artifact someone wrote
rather than an inference from a merged file.

## Out of scope (unchanged from the ticket)

Building the metrics layer itself — this document is discovery. Extending
or redesigning `ghcache`'s metrics (including the `tier1` gap named in §0)
is a separate, explicitly-scoped decision for whoever owns `ghcache`, not
an implicit yes from this proposal.
