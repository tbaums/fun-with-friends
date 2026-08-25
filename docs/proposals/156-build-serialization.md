# #156 — Build serialization on a RAM-bound multi-agent box

**Type:** discovery (deliverable = this proposal + a shipped locally-testable
mechanism slice). **Status:** recommend BUILD, incremented.

## Problem

`fwf` runs N worktrees on one box. Several roles compile the same Rust PR
independently (impl self-check, qa re-review, conductor promotion-e2e), each a
multi-GB `cargo` build, plus each resident impl agent's `rust-analyzer`. On the
16 GB self-host box (`profiles/fun-with-friends.sh`: `FWF_PAIRS=1`,
`FWF_MIN_FREE_GB=25`) concurrent heavy builds swap-thrash the box to a halt —
the transom oversubscription incident (burn+factory OOM'd the box AND filled
`$HOME`) is the same failure in the sibling repo.

A first prototype — a box-wide `flock` held across the whole build — **failed
adversarial review**. This proposal chooses among three real strategies rather
than trying to "make that lock correct," because the review showed its fatal
flaw is *intrinsic to holding a lock across the build* (GV criterion 1).

## The three strategies

| | Strategy | What it does | Verdict |
|---|---|---|---|
| **a** | **SERIALIZE** | one correct box-wide lock held *across* the build | **rejected as primary** |
| **b** | **MEMORY-ADMISSION-CONTROL** | gate only the *start* on a free-RAM reservation; hold a lock only sub-second for admission | **CHOSEN (core)** |
| **c** | **REDUCE** | fewer redundant *compiles* + content-addressed caching (sccache / SHA-target) | **complementary, opt-in, measurement-gated** |

### Why (a) is rejected as primary — and what is kept from it

The failed prototype's fatal hole (**hole #1**): a single-pid kill
(`tmux respawn-pane -k`, SIGKILL) orphans the `cargo` child — reparented to
PID 1, still building multi-GB — **and** auto-releases the lock (the `flock` fd
closes on death). The next agent then starts a *second* build on top of the
still-running orphan. This is not a tuning bug; **it is intrinsic to holding a
lock across a long child the holder can be killed out from under.** Any
across-the-build lock has this shape.

Two further intrinsic tensions with (a):

- **#123 single-flight tension (hole #3).** A ~25 min conductor e2e holds the
  box lock; an impl gate then *blocks inside the wrapper while still holding its
  per-role gate lock* (`fwf_gate_lock_acquire`, `lib.sh`). The per-role lock has
  a 1800 s max-run ceiling (`FWF_GATE_LOCK_MAX_RUN_SECS`, `lib.sh`); a
  merely-*waiting* gate that crosses it is misread as wedged and a **second gate
  is stacked** — recreating the very pileup #123 fixed. The true bound is
  `wait + build < 1800 s`, **not** the `900 < 1800` a naive reading suggests —
  the max-run clock starts at lock-acquire, so the wait is charged against the
  same ceiling as the build. **This tension is NOT unique to (a):** (b) as first
  shipped inherited it, because the gate held its #123 lock across the up-to-900 s
  admission wait too. It is closed for (b) by releasing and re-acquiring the #123
  lock around that wait (BLOCKER 2, `fwf-gate.sh`) — see the holes table.
- **(a) still does the redundant compile 2–3×.** It serializes the thrash but
  does nothing about qa and conductor each compiling the same PR.

**Kept from (a):** its *process-group ownership* is the hole-#1 fix, and every
variant needs it. So we retain the kill-safe wrapper as a **shared
prerequisite**, not as an across-the-build lock.

### Why (b) is the core mechanism

Admission gates every heavy build's **start** on measured ground-truth free RAM
minus the summed live reservations, reserving the op-class's measured **peak**
(not current usage). It holds a **sub-second `mkdir` decision-mutex** only for
the atomic measure+reserve, **never across the multi-GB build.**

This structurally removes hole #1's mechanism: **no lock is held across the
build, so nothing auto-releases into an orphan.**

Hole #3 is **not** "dissolved by construction," as an earlier draft claimed —
that framing was wrong and is corrected here. `fwf_mem_admit` BLOCKS up to
`FWF_MEM_ADMIT_TIMEOUT` (900 s), and the gate holds its #123 per-role gate lock
across that wait. The real ceiling is therefore not `900 < 1800`; it is
`admission_wait + build_time < FWF_GATE_LOCK_MAX_RUN_SECS` (1800 s), because the
per-role lock's max-run clock starts at lock-acquire, not at build-start. A
~400 s admission wait ahead of a ~1500 s conductor e2e sums to 1900 s > 1800 s —
the reaper would misread that *progressing* gate as wedged (`rc=3`) and stack a
second. The fix (`fwf-gate.sh`) is to **release the #123 per-role gate lock
before the admission wait and re-acquire it after admission** — so the max-run
ceiling only ever times the actual build, never wait+build. Single-flight is
preserved: the build starts only after re-acquiring the lock, so two builds for
one role never run at once (a losing re-acquirer defers and frees its own
reservation). An un-admitted gate that times out still exits `EX_SKIPPED`
promptly, holding no lock.

Reserving the link **peak** answers (a)'s single strongest objection — that a
memory spike lands *minutes into* a build, after admission already said yes. By
reserving the measured peak up front, the box is sized for the spike before the
build starts, not for the build's quiet opening.

**The self-healing core:** admission re-measures *ground-truth* free RAM every
pass. Any untracked consumer — an orphaned cargo, a resident `rust-analyzer`, a
hand-run `cargo build` — lowers measured-free *directly*, so admission tightens
automatically without the mechanism having to know that consumer exists. This is
why (b) is robust to exactly the sources it cannot otherwise bound (criterion 2).

### Why (c) is complementary but not primary

REDUCE is real but must stay honest. `docs/gate-throughput.md` already **measured
0 % cross-worktree sccache hits today** (the Rust hash key includes
`CARGO_TARGET_DIR`, which #151 deliberately keeps per-worktree). So "artifact
sharing is off the table" is *too strong* (criterion 4) — but "sccache saves us
now" is also false. See the REDUCE section.

## The four holes, and how (b)+prerequisite close each

| Hole | The prototype's flaw | This design |
|---|---|---|
| **#1 FATAL** — single-pid kill orphans cargo + auto-releases lock → second build stacks on orphan | intrinsic to flock-across-build | **Kill-safe process-group wrapper** (`fwf-gate.sh`): the gate becomes a pgroup **leader**, cargo inherits the group. A trappable kill → trap releases + `kill -KILL -$$` takes cargo down *with* the lock. An untrappable single-pid SIGKILL → a **tree-aware reaper** SIGKILLs the stamped pgid when it drops the now-dead holder. **This covers the DEFAULT `FWF_MEM_ADMIT_ENABLE=0` path too:** the group-SIGKILL recovery is a SHARED helper (`_fwf_kill_orphan_group`, `lib.sh`), the #138 cargo-build **slot owner now records `pgid`/`pgleader`**, and its slot reaper group-kills the orphan tree before freeing the slot — so a SIGKILL to a default-path gate can no longer leave cargo orphaned while the next gate stacks a second build. Verified in `test/mem-admit-test.sh` on both paths. |
| **#2** — no bounded-wait / wedged-holder detection → a hung-but-alive holder freezes the box forever | absent | `fwf_mem_admit` mirrors the e2e-lock bounded-wait/report loop (`FWF_MEM_ADMIT_TIMEOUT=900`/`POLL=5`/`STALE_SECS=1800`/`REPORT_SECS=30`, same cadence as `lib.sh:1201`). Decision-mutex has its own dead-PID + stale backstop (`_fwf_mem_admit_reap_mutex`, reusing the cargo-slot exclusive `.reap` idiom, `lib.sh:1420`). |
| **#3** — blocking lock violates #123 single-flight → waiting gate exceeds 1800 s → reaper stacks a second gate | intrinsic to across-build lock | **Bounded by an explicit lock hand-off, NOT "by construction":** admission holds no lock across the *build*, but the gate DID hold its #123 per-role gate lock across the up-to-900 s admission *wait* — so the true ceiling is `admission_wait + build < FWF_GATE_LOCK_MAX_RUN_SECS` (1800 s), which a ~400 s wait + ~1500 s e2e violates. Fixed in `fwf-gate.sh`: the gate **releases** its #123 lock before the admission wait and **re-acquires** it after admission, so the max-run clock only ever times the build. A timed-out gate still exits `EX_SKIPPED` holding nothing. |
| **#4** — coverage gap: bare `cargo check`/`build` debugging, and each resident `rust-analyzer` + proc-macro server, bypass a profile-var wrapper | unaddressed | **Honestly partial** — see the RAM-sources table. Ground-truth measurement *absorbs* these (they lower measured-free) but does not *bound* them. RA cannot be caught by a PATH `cargo` shim because RA resolves `rustc` itself. Bounded only out-of-band. |

## GV must-address criteria

**(1) Framed as a strategy choice; is the fatal flaw intrinsic to an
across-build lock?** Yes — see "Why (a) is rejected." The orphan+auto-release is
intrinsic to holding a lock across a killable child; that is precisely what
makes (b)'s "no lock across the build" better-*shaped*, not merely better-tuned.

**(2) Enumerate ALL rustc/RAM sources; honest about what the mechanism can and
cannot bound.**

| RAM source | Routes through the gate wrapper? | Bounded by (b)? | How it's handled |
|---|---|---|---|
| `cargo build`/`test` launched by a gate (`--cargo-build`) | **yes** | **yes — reserved** | admission reserves the op-class peak; pgroup-owned so a kill reclaims it |
| rustc **link peak** (the spike minutes in) | yes (child of the above) | **yes — reserved as peak** | reserve the measured *peak*, not current usage |
| conductor e2e: cargo build + playwright chromium+webkit | yes (`--e2e --cargo-build`) | **partly** | cargo side reserved; browser side already serialized by the **e2e mutex** (`E2E_LOCK`, `config.sh`), not by this mechanism |
| **resident `rust-analyzer`** (per impl pane) | **no** — RA resolves `rustc` itself, never a PATH shim | **no — cannot bound** | *absorbed* by ground-truth measurement (lowers free directly); bounded only out-of-band: RA `numThreads`/`procMacro.enable`/`checkOnSave`, `FWF_PAIRS`, per-pane `ulimit`/cgroup |
| RA-spawned **proc-macro server** / its own rustc | no | no | same as RA — out-of-band only |
| hand-run `cargo check`/`build` in a pane (iterative debugging) | **no** | **no — cannot bound** | *absorbed* by ground-truth measurement; not reserved |
| orphaned cargo from a prior killed gate | n/a | **yes** | pgid reaper SIGKILLs it; and measurement absorbs it until the reap fires |

The distinction is the honest core of this proposal: **(b) RESERVES what routes
through the gate; it only ABSORBS (never bounds) rust-analyzer, proc-macro
servers, and hand-run cargo.** RA is likely the single biggest RAM source on a
multi-agent box, and this mechanism does *not* bound it — that is a deliberate,
stated limitation, not an oversight.

**(3) MEASURE per-op memory peaks before deciding — needs the real box.**
Acknowledged honestly: **the reservation numbers are provisional placeholders**
(`FWF_MEM_RESERVE_FAST_GB=2` / `BUILD=6` / `E2E=6`, `FWF_MEM_ADMIT_FLOOR_GB=8`,
`config.sh`) and are marked `PROVISIONAL — CALIBRATE ON BOX`. The Mac used to
build this **cannot** produce them: it has no multi-agent Rust box, no resident
RA fleet, no playwright webkit under contention. What must be measured on the
real box (see "Deferred to the box" below): rustc link peak vs cargo-test heap
vs playwright chromium+webkit vs a resident rust-analyzer's steady-state RSS.
The mechanism ships **opt-in / OFF** (`FWF_MEM_ADMIT_ENABLE=0`) precisely so it
cannot act on un-calibrated numbers until that run happens.

**(4) Reconsider "no artifact sharing possible" via content-addressed caching.**
"Off the table" is too strong. `sccache` keys by **hashed compiler inputs**
(sound), unlike #151's shared-*target*-dir which keys by crate name+version →
clobber → false-green (transom #151, verified). So *sound* sharing exists. But
`docs/gate-throughput.md` measured **0 % cross-worktree hits today** because the
sccache Rust key folds in the per-worktree `CARGO_TARGET_DIR`. The honest
position: keep the sound within-worktree sccache win (`fwf_cargo_sccache_configure`,
`lib.sh:469`, unchanged); treat a SHA-keyed shared target dir as a *documented,
measurement-gated, opt-in follow-up* — not primary savings.

**(5) Reconcile REDUCE with #168.** #168 already drops impl's e2e (conductor is
sole e2e authority). REDUCE must therefore target the **compile redundancy #168
does NOT touch: qa and conductor still each compile the same PR.** Defense in
depth is preserved — a browser/behavior regression must still not reach
release-green (cf. transom #928, an audio regression caught *only* by conductor
e2e), so this proposal does **not** remove conductor's independent e2e; it only
flags the duplicate *compile* as the REDUCE target, to be realized via the
SHA-target follow-up, not by deleting a verification lane.

## REDUCE lever (c) — kept honest, opt-in

- **Within-worktree sccache:** unchanged, sound, already shipped (`lib.sh:469`).
- **Cross-worktree SHA-keyed shared `CARGO_TARGET_DIR`:** the documented
  follow-up (`docs/gate-throughput.md:84`). Made sound by content-addressing at
  dir granularity — `$FWF_RUN/cargo-shared/$PROFILE/<git-SHA>`, **only for a
  clean tree**, fail-safe to the #151 private target otherwise; same SHA ⇒
  byte-identical source (unlike #151's name+version clobber), *and* serialized
  so two worktrees can't hold it at once. **Ship OFF by default**, gated on
  real-box measurement **and** a disk-prune reaper (per-SHA dirs accumulate —
  the transom oversubscription footgun: full `$HOME` refused restart). Do **not**
  claim it as primary savings; the repo already measured 0 % cross-worktree hits.

## What shipped in this increment (the locally-testable slice)

Grounded in verified files:

1. **Kill-safe pgroup wrapper** — `fwf-gate.sh`: a sentinel-guarded `exec perl …
   setpgid(0,0)` re-exec (macOS has no `setsid`) makes the gate a pgroup leader
   before any lock work; fail-closed if perl is absent unless
   `FWF_GATE_PGLEADER_ENABLE=0`. A `TERM/INT/HUP` trap releases the lock(s) then
   `kill -KILL -$$` (one syscall, whole group atomically).
2. **`fwf_free_ram_gb`** (`lib.sh`) — macOS sums reclaimable `vm_stat` page
   classes; Linux reads `MemAvailable`; unreadable ⇒ 0 (**fails closed**).
3. **`fwf_mem_admit` / `_release`** (`lib.sh`) — the strategy-(b) loop:
   sub-second decision-mutex → reap (+ SIGKILL orphaned trees) → measure → sum
   reservations → admit iff `free − reserved ≥ reserve + floor` → stamp entry
   (role/pid/**pgid**/**pgleader**/host/reserved_gb) → release mutex. Bounded
   wait; timeout ⇒ `EX_SKIPPED`, never a build failure.
4. **`fwf-gate.sh` wiring** — under `--cargo-build`, `FWF_MEM_ADMIT_ENABLE=1`
   uses admission (op-class reserve: e2e vs build); default keeps the #138
   semaphore as the safe fallback. Release wired into `_fwf_gate_release`.
5. **Config** (`config.sh`) — `MEM_ADMIT` + `FWF_MEM_ADMIT_*` + provisional
   `FWF_MEM_RESERVE_*` beside `E2E_LOCK`/`CARGO_BUILD_LOCK`; `FWF_MEM_ADMIT_ENABLE`
   OFF by default. The #138 `FWF_CARGO_BUILD_CONCURRENCY` semaphore is retained
   as the default fallback and, per BLOCKER 1's fix, its reap is **no longer
   tree-blind**: the slot owner records `pgid`/`pgleader` and the reaper
   group-SIGKILLs an orphaned build tree (via the shared `_fwf_kill_orphan_group`)
   before freeing the slot — so the DEFAULT path is safe against a single-pid
   SIGKILL regardless of the admission flag.
6. **Shared kill-safe recovery + default-path coverage** (`lib.sh`, BLOCKER 1) —
   the group-SIGKILL orphan-tree recovery is extracted into a SHARED helper
   `_fwf_kill_orphan_group` (the admission reaper's `_fwf_mem_admit_kill_group`
   is now a thin alias); `fwf_cargo_build_slot_acquire` stamps `pgid`/`pgleader`
   and its reaper calls the shared helper before `rm -rf "$slot"`. The DEFAULT
   `FWF_MEM_ADMIT_ENABLE=0` path is therefore protected identically to the
   admission path.
7. **Gate-lock hand-off across the admission wait** (`fwf-gate.sh`, BLOCKER 2) —
   the gate releases its #123 per-role gate lock before the up-to-900 s
   `fwf_mem_admit` wait and re-acquires it after admission (guarded by a
   `gate_lock_held` flag so the release trap never rm's a sibling's lock), so a
   merely-waiting gate is never misread as wedged and stacked.
8. **Ownerless decision-mutex backstop** (`lib.sh`, BLOCKER 3) —
   `_fwf_mem_admit_reap_mutex` now falls back to the mutex DIR's mtime when the
   owner file is absent (a SIGKILL between `mkdir` and the owner write), so an
   ownerless mutex ages out and is reaped instead of deferring ALL admissions
   forever.
9. **Test** — `test/mem-admit-test.sh`: 31 checks, **Mac-runnable, no factory /
   tmux / cargo / network**. Proves the free-RAM probe, admit/deny/reserve-sum,
   dead-holder reap, the **hole-#1 orphan-tree SIGKILL on BOTH the admission and
   the DEFAULT #138 slot paths**, the reap safety guards, that the gate is a
   pgroup leader, that **killing the gate takes the wrapped build down with it**
   (not orphaned), that the DEFAULT slot owner records `pgid`/`pgleader`, that
   the gate **releases its #123 lock during the admission wait** (BLOCKER 2), and
   that an **ownerless decision mutex is reaped via the dir-mtime fallback**
   (BLOCKER 3).

## Deferred to the real multi-agent box (cannot be validated on a Mac)

- **Criterion (3) — the reservation numbers.** Measure on the live box: rustc
  **link peak** RSS, `cargo test` heap, playwright **chromium+webkit** peak
  under contention, and a resident **rust-analyzer** steady-state RSS. Set
  `FWF_MEM_RESERVE_*` and `FWF_MEM_ADMIT_FLOOR_GB` from those, then flip
  `FWF_MEM_ADMIT_ENABLE=1`. Until then it ships OFF.
- **rust-analyzer behavior (#4/criterion 2).** Confirm on the box that RA + its
  proc-macro server resolve the toolchain themselves and never route through a
  cargo-PATH shim, and measure how much of total box RAM RA actually is per pane
  — to size the floor and the out-of-band RA settings (`numThreads`,
  `procMacro.enable`, `checkOnSave`, per-pane `ulimit`/cgroup).
- **SIGKILL orphan recovery under real cargo.** The test proves it with a
  `sleep` stand-in; confirm on the box that `respawn-pane -k` on a live gate
  leaves a real multi-GB cargo that the next admitter's pgid reaper actually
  SIGKILLs (and that measured-free recovers).
- **REDUCE cross-worktree SHA-target.** Measure real hit-rate + disk growth with
  the prune reaper before enabling; the repo measured 0 % cross-worktree hits
  today, so the payoff is unproven until re-measured under the SHA-target design.
- **End-to-end throughput.** Whether admission improves *wall-clock gate
  throughput* (vs the #138 semaphore) under the real N-worktree load — the only
  fair comparison is on the contended box.
