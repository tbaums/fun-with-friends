<title>Sleep-Bounded Concurrency Audit</title>

# Sleep-bounded concurrency audit (issue #247)

`test/run.sh` accumulated a family of assertions whose correctness depended
on a `sleep`, a fixed timeout, or an assumed ordering between concurrent
processes. The defect this ticket is about is not "uses a sleep" — it is
**an assertion the NULL STATE satisfies**: give it a perfect barrier and it
is still wrong, because "the property held" and "nothing happened yet" are
indistinguishable to it. #119's own race test is the opposite failure mode
(stops testing and reports a noisy FAILURE); the one that matters more is
the kind that stops testing and reports a silent PASS.

## Classification

Every hit is one of three buckets, marked at the site with `# issue #247
(A)/(B)/(C): <reason>`:

- **(A)** — timing is load-bearing and wrong. The assertion can silently
  stop testing its property. Fixed: replaced the sleep with a real
  synchronization primitive (bounded wait-for-condition, or continuous
  sampling through the full presence window).
- **(B)** — timing is present but not load-bearing (a settle/debounce, a
  hang stub, the correct bounded-wait pattern itself). Left as-is, with the
  marker stating why the next sweep should not re-examine it.
- **(C)** — timing cannot be removed (genuinely async, no observable
  completion signal). None found in this pass; the sweep so far has landed
  entirely in (A)/(B).

## Search shapes (AC a0)

`sleep`-proximity is one input, not the filter. Concrete shapes swept:

- bare `-le N` / `-ge 0` on a count with no paired lower bound
- `assert_eq "0" "$(... | wc -l)"` with nothing nearby proving the count
  was ever produced
- `[ -z ... ]` used as a *success* condition, where empty could mean either
  "correct" or "the read/render failed" (§ AC a5/a6 below)
- an assertion label containing "at most" / "no more than"
- (AC a8) a peak/max **inferred from point samples** — `sort -n ... | tail
  -1`, `grep -c '^N$'`, any counter sampled once and reused as continuous

## What was fixed

| Finding | Handle | Bucket | Fix |
|---|---|---|---|
| single-flight: `-le 1` satisfied by zero (the refresh is detached, so "nothing ran" and "held" were indistinguishable) | `single-flight: >=3 concurrent refreshes` | A | wait (bounded, loud on timeout) for the first call to land, then poll until the count stabilizes |
| the corpus-scan family: an empty `find` yields an empty accumulator, read as full compliance, for 6 "every template carries X" assertions | `tmpl_corpus_nonempty` | A | one shared guard, called before each of the 3 distinct corpora those 6 assertions scan |
| the 3 filtered corpus-scan assertions: `grep -qE 'gh pr (create|merge)'` itself can match nothing | `tmpl_filter_nonempty` | A | same shape, one shared guard asserting the filter matched at least one file |
| `assert_not_contains`: an empty haystack takes the pass branch | the helper itself | A | reject on empty haystack; surfaced 2 real instances relying on the old vacuous pass (#278 AC d/d2), routed to `assert_eq ""` per AC (a6) since they are legitimately-empty, not bugs |
| cargo-build e2e peak / double-reap race peak: a max inferred from a ONE-SHOT sample at registration | `n="$(ls "$counter_dir" \| wc -l \| tr -d ' ')"` (2 sites, same idiom copied) | A | continuous polling through the full presence window, backgrounded and decoupled from the fixed hold/release sleep (see the self-inflicted-flake note below) |
| the 4 hand-rolled `case ... in *X*) bad;; *) ok;; esac` sites AC (a5) names explicitly: `$SANI_OUT` (twice — the ~28-token leak loop and the bare-WIP check, one guard covers both), `$G0`, `$STYLEOFF`, `$GHCAP` — an empty/crashed producer makes each pass vacuously (qa2-caught in review of the first version of this PR) | `$SANI_OUT`/`$G0`/`$STYLEOFF`/`$GHCAP` | A | one `assert_contains` per site proving the producer actually ran (non-erased content / real diagnostic output — `--floor-only` genuinely refuses here on an unrelated, expected reason, so success is not the right proof / base command present / prompt actually rendered) placed immediately before each absence check |

**A bug found in the fix itself, worth recording for the next sweep too:**
the first version of the sampler fix looped the poll *in the same process*
as the `sleep "$hold"` it was meant to sample. Under genuine load, the
loop's own per-iteration subprocess forks (`date`, `ls`, `wc`, `tr`) could
make the total elapsed time exceed `hold`, delaying the unlink past the
true hold and manufacturing a holder that was never really concurrent —
reproduced once (peak read 3, sustained across 26 consecutive samples).
Fixed by backgrounding the poller and killing it once the unmodified,
fixed-cost `sleep "$hold"` completes, so polling overhead can never affect
release timing. **The lesson generalizes: a sampling loop's own cost is
itself a timing assumption, and belongs on the same suspicion list as the
`sleep` it replaces.**

## AC (a7): the `assert_not_contains`-family count, broken down

The heuristic count in #247's own body ("35 vacuous assertions") is
explicitly an upper bound and wrong in both directions — it is not repeated
here. What this PR actually inspected and disposed of:

| status | detail |
|---|---|
| **confirmed and fixed, direct helper call sites** | all real call sites of `assert_not_contains()` — the helper itself now rejects an empty haystack, so every one of them is sound by construction rather than needing per-site inspection (10 call sites were counted in the ticket's own filing; the current tree has 66 — a stale count, corrected here rather than repeated. All are covered by the single helper fix) |
| **confirmed and fixed, hand-rolled (not the helper)** | 4 — `$SANI_OUT` (×2 sites), `$G0`, `$STYLEOFF`, `$GHCAP`, the exact 4 the ticket names explicitly |
| **confirmed FALSE POSITIVE, already sound** | `$UT_ROLES` (per the ticket's own audit — properly paired by two preceding `assert_eq`), and the 12+ legitimately-empty sites at AC (a6) above (`assert_eq "" "$VAR"`, the correct positive form) |
| **routed under AC (a6), not converted** | 2 — `#278` AC (d)/(d2), surfaced by the `assert_not_contains` helper fix itself, legitimately expect total silence |
| **candidates outstanding** | not exhaustively re-audited beyond the 4 the ticket named and the direct helper call sites; the ~25–30 *other* hand-rolled `case`-shaped blocks the ticket estimated (not calling `assert_not_contains`, not one of the 4 named) have not been individually inspected in this PR |

## AC (d): runtime cost on a red run

The floor is red right now (per #286, tracked separately), so the failing
path is the one actually walked in CI today, and a bounded-timeout poll is
slow specifically on failure — every assertion that would have failed at a
fixed offset before now waits out its own timeout instead.

Fixes landed in this PR that replaced a fixed-time read with a bounded
poll, and their worst-case added wait if genuinely broken:

- `single-flight` (issue #243 area): up to 5s waiting for the first call to
  appear, plus up to 5s for the count to stabilize — **10s worst case**,
  versus the old fixed `sleep 1`.
- cargo-build e2e / double-reap race sampler: unchanged worst-case timeout
  — the poller is bounded by the SAME fixed `sleep "$hold"` (2s/2s/1s and
  1s respectively) it always was; this PR did not add a new timeout here,
  it fixed what happens *during* the existing one.
- `assert_not_contains` / `tmpl_corpus_nonempty` / `tmpl_filter_nonempty`:
  no polling added — these are single-pass checks, not bounded waits, so
  they add no timeout cost on a red run.

**If every timeout-bearing assertion above failed simultaneously in one
run** (the true worst case, not the expected one): +10s from
`single-flight`, no change from the others. Small in absolute terms next to
this suite's real-tmux sections (multi-minute today), but recorded per
AC (d)'s own instruction rather than left unstated.

## What was marked but intentionally not touched (B)

The 2 hang stubs and their reaper (simulate a genuinely hung `gh`/`claude`
process; not assertions at all), the never-block "returns instantly" check
that depends on them, the RED/GREEN fixed-resource pair (a ~2x fixed
margin, not a race the assertion could stop exercising), the
`cache created under $FWF_RUN` check (sleep-bounded but fails loud on a
miss — the safe direction), and `assert_log_eventually_contains` itself
(the correct pattern to copy). #119's race test is out of scope (fixed on
#245) but is listed here for a complete audit; it still shows a small
residual timing-window flake rate in this tree — a lead for the next sweep,
not re-fixed by this ticket.

## AC (a2): the standing check — attempted, not shipped

A test that fails when a new null-satisfiable or `sleep`-adjacent assertion
appears without a classification marker would turn this sweep from a
one-time fix into an invariant. It was attempted and not shipped, and here
is precisely why (per AC a2's own requirement — a vague "proved fiddly" is
not an acceptable substitute for this).

Grepping the 4 AC (a0) shapes against the current tree returns 32 raw
hits. Inspecting all 32 by hand: **zero are unclassified genuine
instances.** They decompose into:

- unrelated control flow (a `while [ "$i" -le 205 ]` loop counter, not an
  assertion at all)
- already-sound **paired** bounds — `[ "$REM" -gt 0 ] && [ "$REM" -le 100
  ]`, `[ "$X" -ge 1574 ] && [ "$X" -le 1585 ]` — the cooldown/timing-window
  pattern this ticket's own body cites as the CORRECT idiom to copy; a bare
  zero cannot satisfy a construct with an explicit floor
  a assertion label containing "at most" that is checking rendered PROMPT
  TEXT, not a count
- this ticket's own marker comments and corrected prose, which themselves
  contain the grep patterns being searched for

A mechanical version of this check, run today, would therefore need to
correctly exclude: paired-bound constructs (recognize the `-gt 0` floor on
the same logical `&&` chain), comments (vs code), and assertions whose
"needle" is prose rather than a count. That is not a false-positive rate a
proximity heuristic can bring to zero without real semantic understanding
of the surrounding construct — which is exactly the "classification is the
deliverable" judgment call this whole ticket exists to make, not something
a regex should silently re-derive. Building a check that is *itself*
unsound (either misses a real new instance behind a paired-bound-looking
false negative, or floods future PRs with noise on the 20+ already-sound
sites) would be a worse outcome than no check.

**What would make this tractable**: scoping the check to only the specific
handles already classified here (a closed list), asserting each still
carries its marker — catches marker rot (a classified site whose
surroundings changed, the "Known limitation" below) but not a genuinely
NEW instance, which is a different, harder problem. Left as a lead for
whoever next revisits this, not attempted here.

## Known limitation — markers are verdicts, and verdicts go stale

A marker reading `(B) — inside a bounded poll loop` is a claim about
surrounding code, and that code can change. Nothing here catches a `(B)`
site whose surrounding bounded-poll was later replaced by a fixed sleep —
the marker would keep asserting safety it no longer has, and would be
believed precisely because it looks deliberate. Not built for in this
ticket (per its own "not worth building for" note); recorded so it is the
first thing looked at when this file is next revisited.
