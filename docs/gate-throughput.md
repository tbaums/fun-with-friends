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
   below) **+ C** (build concurrency bound — still open).
3. **Measure** — warm-cache always-on gate time, plus B's shadow log
   would-skip rate, both from the live floor.
4. **Flip B to enforcing** — only if the number justifies it, as one
   documented default change, with `FWF_GATE_FULL=1` as the kill switch from
   that point on. If the warm cache alone gets gate time under the bound, B
   is dropped and the classifier deleted instead.

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
sharing it risks stale-artifact leakage) unless builds are also serialized —
which is piece C, not yet built.

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

## Not yet built (future increments of this ticket)

- **A, the cross-worktree half** — a fixed-target-dir scheme so sccache can
  actually hit across worktrees, gated on piece C's concurrency bound (see
  "Follow-up path" above). What landed is the same-worktree win only.
- **C** — a floor-wide cap on concurrent cargo builds.
- Flipping B from shadow to enforcing (step 4 above) — gated on the
  measurement, not on this increment.
- The A→B measurement gate itself (warm-cache always-on gate time vs. the
  bound) — needs C (or the fixed-target-dir follow-up) in place first to be a
  fair measurement; today's cache only speeds up a wiped-and-rebuilt
  same-worktree gate, not the steady-state per-worktree case the bound is
  measuring.
