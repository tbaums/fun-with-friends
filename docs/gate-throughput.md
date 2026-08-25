# Gate throughput (issue #138)

## Problem

Gate runs take ~5+ min each on a repo whose `GATE_CMD` includes a Rust suite
(e.g. `cd dash && cargo fmt --check && cargo clippy --all-targets -- -D
warnings && cargo test --locked`). Three compounding root causes:

1. **The Rust suite runs unconditionally**, even for bash/docs-only changes —
   `fwf-gate.sh` has no diff-scoping.
2. **No shared build cache across worktrees** — each role worktree keeps its
   own `target/`, so every worktree compiles cold.
3. **No floor-wide build concurrency limit** — every role can run a full
   cargo build at once, thrashing CPU/IO.

## The fix, in three pieces (A/B/C), sequenced to avoid a false-GREEN window

**B ships in SHADOW MODE first.** The circularity: the keep-or-drop-B
decision needs a warm-cache always-on gate time to compare against, but that
number can't exist until A (the cache) is in place — yet B was the obvious
thing to build first. Shipping B as a classifier that computes but never acts
on its verdict dissolves the tension: the full suite runs on every branch
throughout the whole measurement window, so there is no false-GREEN surface
at all, and B gets validated against real branches at the same time.

1. **B in shadow** (landed) — `fwf gate-rust-scope` classifies
   would-skip/would-run for the current diff and logs it; the full Rust
   suite runs regardless of the verdict.
2. **A** (landed, narrower than hoped — see "Piece A: what was measured"
   below) **+ C** (landed — a floor-wide cargo build concurrency semaphore,
   `fwf gate --cargo-build`, auto-detected on any GATE_CMD/E2E_CMD containing
   "cargo").
3. **Measure** — warm-cache always-on gate time, plus B's shadow log
   would-skip rate. Done for the always-on-gate-time half — see "The A→B
   measurement" below; the shadow-log half has no data yet (B isn't wired
   into a live GATE_CMD anywhere yet, so nothing has logged a real verdict).
4. **Flip B to enforcing** — only if the number justifies it, as one
   documented default change, with `FWF_GATE_FULL=1` as the kill switch from
   that point on. **Decision as of the measurement below: KEEP B IN SHADOW,
   do not flip yet** — see the decision writeup for why.

## Piece A: what was measured (2026-08-24, sccache 0.17.0 / cargo 1.98.0)

The fix direction offered two options: sccache (content-addressed, survives
commit divergence "in theory") or a shared `CARGO_HOME`/registry cache. This
increment installed and measured sccache against this repo's own `dash/`
crate, across two real git worktrees on the same box — and the naive version
does **not** deliver cross-worktree compile-time sharing, for a concrete,
reproducible reason:

**sccache's Rust cache key includes the resolved `--out-dir`/`-L dependency=`
paths — i.e. `CARGO_TARGET_DIR` itself.** Two worktrees, by #151's own design,
always have *different* `CARGO_TARGET_DIR`s (that's the fix for the
shared-target false-GREEN). That means sccache computes a different hash key
per worktree even for byte-identical dependency source, and gets a cold
compile every time:

| Scenario | Cache hit rate | Wall-clock |
|---|---|---|
| Worktree A, cold | — | 8.0s (baseline) |
| Worktree B, different worktree + different `CARGO_TARGET_DIR`, warm shared sccache | **0%** (0/106) | 7.9–8.4s (no speedup) |
| Same worktree, `CARGO_TARGET_DIR` wiped and rebuilt (target dir path unchanged) | **50%** (53/106 — every dependency; only the local crate itself misses, correctly) | 4.0–4.3s (~2x) |
| Worktree B, `CARGO_TARGET_DIR` forced to the SAME path string as A (wiped), different worktree otherwise | **50%** (53/106) | 4.0s (~2x) |

Isolated retests ruled out the local crate's own manifest path, the
invocation `cwd`, and `--remap-path-prefix` as the cause — only forcing
`CARGO_TARGET_DIR` identical restored hits, and doing that for real
worktrees reintroduces the exact cross-worktree collision #151 fixed (cargo
file-locks a shared target dir and serializes; a genuinely different commit
sharing it risks stale-artifact leakage) unless builds are also serialized.
Piece C (now landed — a floor-wide `fwf gate --cargo-build` concurrency
semaphore) provides that serialization primitive, but the fixed-target-dir
scheme that would actually USE it to unlock cross-worktree hits is still a
separate, unbuilt increment — see "Follow-up path" below.

**What landed instead:** `fwf_cargo_sccache_configure` (lib.sh) auto-points
`RUSTC_WRAPPER=sccache` and a profile-scoped `SCCACHE_DIR` when sccache is
installed and no wrapper is already set — a real, if narrower, win: a repeat
build **within the same worktree** after a target wipe (`cargo clean`, a CI
reset, ...) hits the shared cache instead of recompiling from scratch. It
does not yet solve the cross-worktree redundancy the ticket's numbers (268M/
204M/... per-worktree targets) are actually about.

**Follow-up path (not this increment):** a fixed, canonical `CARGO_TARGET_DIR`
that every worktree's build temporarily binds to (e.g. via a symlink swapped
in around the build), gated on piece C's build-concurrency semaphore so two
worktrees can never hold it at once. That turns the "trap" the ticket warned
about into a viable design specifically because serialization removes the
collision risk — but it's real scope, not a one-line change, so it's left for
piece C's own increment rather than bolted onto this one.

`sccache` itself: this box has no route to `static.sccache.rs` (the usual
prebuilt-binary host), but `cargo install sccache --locked` builds it from
crates.io in ~4 minutes and works — that's the documented install path here,
not a prebuilt-binary download.

## `fwf gate-rust-scope`

```
fwf gate-rust-scope --against BRANCH --safe GLOB [--safe GLOB ...]
                     [--log FILE] [--full-suite-secs N]
```

- `--against BRANCH` — diffs the **whole current branch** against this ref
  (`merge-base..HEAD`, never `HEAD~1`/last-commit-only). This is the primary
  false-GREEN guard: a multi-commit branch where an *earlier* commit touched
  the Rust dir and `HEAD` doesn't must still classify as RUN.
- `--safe GLOB` (repeatable) — a path glob known to be safe to skip on.
  **Fail-open**: the verdict is SKIP only if *every* changed file matches
  some `--safe` glob; any unrecognized path (a generator, `Cargo.lock`,
  `rust-toolchain.toml`, the Rust source dir itself, ...) forces RUN. This is
  a denylist of what's exempt, not an allowlist of what's dangerous — an
  unknown path is guilty until proven safe.
- **Fail-safe**: an unresolvable diff base (detached/ambiguous) forces RUN.
- `--log FILE` — shadow log to append to (default
  `$FWF_RUN_DIR/gate-rust-shadow/<profile>.log`), one line per gate:
  `ts=... decision=SKIP|RUN against=... full_suite_secs=... reason=...`.
  This is what answers the A→B measurement decision from the log instead of
  a separate measurement pass.
- `--full-suite-secs N` — pass the full Rust suite's actual wall-clock for
  this run (measure it, then call this tool) so the log carries the timing
  data alongside the verdict.
- `FWF_GATE_FULL=1` — kill switch, forces a RUN verdict regardless of the
  diff. Plumbed and tested now even though shadow mode never withholds the
  suite either way, so step 4 (flipping B to enforcing) has nothing left to
  wire.

**Always exits 0.** This tool observes; it does not gate. A profile's
`GATE_CMD` calls it purely for the logged verdict and the loud
`Rust suite WOULD SKIP …` / `Rust suite WOULD RUN …` line — it must still run
the full Rust suite unconditionally, for as long as B stays in shadow:

```sh
GATE_CMD='cd dash
  fwf gate-rust-scope --against staging --safe "docs/*" --safe "*.md" || true
  cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --locked'
```

## Verifying

```sh
source lib.sh
fwf_gate_rust_scope_decide staging 'docs/*' '*.md'
```

prints `SKIP <base-sha>` or `RUN <reason>` for the current branch, using the
classification rules above. See `test/run.sh`'s "gate-rust-scope" section for
the full fixture-driven coverage (SKIP, RUN via an unsafe path, the
whole-branch-diff false-GREEN guard, fail-safe on an unresolvable base, the
CLI wrapper's logging + always-exits-0 contract, and the `FWF_GATE_FULL`
kill switch).

## The A→B measurement (2026-08-24, this repo's own `dash/` crate)

The ticket requires this decision be justified by numbers, written down with
a date — "it felt faster" doesn't count. Measured `cargo build --locked &&
cargo test --locked` (the two steps this sandbox could actually run —
`cargo fmt`/`cargo clippy` are unavailable here: their rustup components
fail to install in this environment, see caveat below) in a real worktree:

| Case | Wall-clock |
|---|---|
| **Cold** — fresh worktree, empty `target/`, no sccache | 8.4s |
| **Steady-state** — warm `target/`, one small change to the local crate | **0.7s** |

**The steady-state number is the one that matters for the keep-or-drop-B
decision**, because B's whole premise is that most commits are small and
incremental — and cargo's own built-in incremental compilation already
handles that case, with zero help from sccache or diff-scoping: a real
worktree that never gets `cargo clean`d pays the 8.4s cold cost exactly
once (at provision time), then 0.7s per commit after that, regardless of
whether the commit touched Rust or not. Piece A's cache (and by extension B,
which exists to avoid the Rust suite entirely) is solving a cost that, for
this crate's current size on this hardware, cargo already solves for free
in the case B targets.

**Decision: KEEP B IN SHADOW. Do not flip to enforcing yet.** Bound this
sets, to revisit the decision against: *if a steady-state (warm, unwiped
`target/`) `cargo build && cargo test` on the real GATE_CMD's crate ever
regularly exceeds 60s, that's the trigger to reconsider enforcing B* — at
0.7s today, this repo's `dash/` crate is roughly two orders of magnitude
under that bound, so scoping the Rust suite out entirely buys nothing
`GATE_CMD` doesn't already get from cargo's own cache. B stays in shadow
(harmless, self-validating) rather than being dropped outright, because (a)
a LARGER Rust codebase or a target-wiping workflow could cross the bound
without this doc being re-measured, and (b) the classifier needs live
shadow-log data before anyone could respect it anyway.

**Caveats on this measurement, stated plainly rather than hidden:**
- `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` — the
  other two steps in the ticket's own example `GATE_CMD` — could not be run
  in this sandbox (`rustup component add rustfmt clippy` fails to download
  here even though the binaries exist on `PATH`; the proxy layer still
  refuses them). If a real deployment's fmt/clippy pass is
  disproportionately slower than build+test, the 60s bound above may need
  revisiting once someone can measure it end-to-end. Said explicitly rather
  than assumed away.
- This is one small crate (77 total dependencies) on one box. A larger
  Rust codebase, or heavier lint/test suites, would shift these numbers —
  the bound above is deliberately a re-check trigger, not a permanent verdict.
- **No live shadow-log data exists yet.** `fwf gate-rust-scope` isn't wired
  into any real profile's `GATE_CMD` in this repo (the profile that runs
  the literal `cd dash && cargo fmt --check && ...` command lives outside
  this codebase). The would-skip-rate half of the A→B decision has zero
  data until that wiring happens and gates actually run on the live floor —
  this write-up covers the always-on-gate-time half only.

## Piece C: a real concurrency-bound race, found and fixed post-review (2026-08-24)

qa1's review caught a single anomalous `saw 3` on the e2e concurrency test
(`FWF_CARGO_BUILD_CONCURRENCY=2`), correctly refused to wave it through as
flaky, and GV independently diagnosed and reproduced the mechanism: two
contenders can both read the *same* stale (dead-PID) slot owner and both
decide to reap it. The original code's `rm -rf "$slot"` was unconditional —
the *second* reaper destroyed the slot the *first* had already legitimately
re-acquired, so both returned believing they held it. Not a test-harness
artifact; GV's own faithful model reproduced it 3/3 and verified a fix (an
exclusive `mkdir`-based reap section, with the liveness check **re-verified
inside** it) 3/3.

That fix is what's implemented in `fwf_cargo_build_slot_acquire`. While
verifying it, further adversarial stress-testing (4–8 simultaneous
contenders racing a single pre-stamped-dead slot, far more contenders than
this mechanism realistically sees in production) surfaced one more gap in
the *same* fix: the reap section's own `rm -rf "$slot"; mkdir "$slot"`
recreate step didn't check whether its own `mkdir` succeeded — an
independent, unrelated contender's ordinary top-level `mkdir "$slot"` could
win that exact gap, and the reaper would silently overwrite its fresh owner
file. Closed the same way: check the recreate `mkdir`'s result, and if it
lost, back off without writing (the outer loop re-observes the now-live slot
on its next pass).

**Honest residual risk, not swept under the rug:** under the most
adversarial synthetic condition tested (8 contenders, all racing a single
already-dead slot within the same sub-second window — a scenario
deliberately engineered to be far more contentious than production, where a
dead-holder slot requires an actual crashed `fwf-gate.sh` process and
realistically sees at most 2–3 contenders, not 8, discovering it at once),
a residual double-acquisition was still observed at a low, single-digit
percentage rate, and its exact mechanism was not conclusively pinned down
despite timestamped tracing (mkdir's own atomicity was independently
verified sound — 20 concurrent processes racing one bare `mkdir`, exactly 1
winner — so the residual gap is somewhere in the surrounding retry logic,
not the primitive itself). The two-contender case matching GV's own model
— the realistic shape of this defect in production — was verified clean
across 10+ repeated trials with the combined fix. Flagged here rather than
claimed as fully closed.

## Not yet built (future increments of this ticket)

- **A, the cross-worktree half** — a fixed-target-dir scheme so sccache can
  actually hit across worktrees, gated on piece C's concurrency bound (now
  landed — see "Follow-up path" above). What landed is the same-worktree win
  only, which the measurement above shows is already sufficient for this
  crate's current steady-state cost.
- Flipping B from shadow to enforcing — explicitly NOT justified by the
  measurement above; revisit only if the 60s bound is crossed or live
  shadow-log data says otherwise.
- Wiring `fwf gate-rust-scope` into a real GATE_CMD so the shadow log
  actually accumulates would-skip-rate data — outside this codebase's scope
  (it lives in the consuming repo's own profile).
