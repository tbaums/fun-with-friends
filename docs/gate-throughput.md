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

1. **B in shadow** (this increment) — `fwf gate-rust-scope` classifies
   would-skip/would-run for the current diff and logs it; the full Rust
   suite runs regardless of the verdict.
2. **A + C** (cache sharing + concurrency bound) — future increment.
3. **Measure** — warm-cache always-on gate time, plus B's shadow log
   would-skip rate, both from the live floor.
4. **Flip B to enforcing** — only if the number justifies it, as one
   documented default change, with `FWF_GATE_FULL=1` as the kill switch from
   that point on. If the warm cache alone gets gate time under the bound, B
   is dropped and the classifier deleted instead.

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

- **A** — shared cargo build cache across worktrees (sccache or a shared
  registry/deps cache with per-worktree `target/`).
- **C** — a floor-wide cap on concurrent cargo builds.
- Flipping B from shadow to enforcing (step 4 above) — gated on the
  measurement, not on this increment.
