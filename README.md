# fun-with-friends

A generic, **repo-agnostic** multi-agent dev swarm for Claude Code. Eight
interactive Claude sessions in a tmux grid drive a full ideas→ship pipeline:

```
┌──────────────┬──────────────┬──────────────┬────────────────────┐
│ IMPL1 (red)  │ IMPL2 (green)│ IMPL3 (teal) │ PM (pink)          │  ← top row
├──────────────┼──────────────┼──────────────┼────────────────────┤
│ QA1  (red)   │ QA2  (green) │ QA3  (teal)  │ CONDUCTOR (gold)   │  ← bottom row
└──────────────┴──────────────┴──────────────┴────────────────────┘
```

Each implementer shares its **paired QA's exact color** (one hue per column).
The **active pane** is highlighted hard: bright white bold border + an inverted
`[ ▶ ACTIVE ◀ ]` title bar, with every other pane's border dimmed.

## The pipeline

- **PM** (interactive + `/loop`): turns your rough ideas into **draft** GitHub
  issues labeled `product-wip` (hidden from implementers) via back-and-forth, and
  on a loop reviews those drafts for your new comments and refines the issue body.
  When you're happy, **you remove the label** and the issue enters the implementer
  queue automatically.
- **IMPL1–3** (generalists): each surveys open issues + in-flight PRs, skips PM
  drafts (`product-wip`) and any issue **already resolved on `integration`**
  (`git log origin/integration --grep "(#N)"`), and picks the **lowest-collision**
  eligible issue — **oldest first** to break ties — then **immediately opens a
  draft PR** (`Closes #N`) as a public claim before coding. One issue = one branch
  = one PR. They act autonomously (never pausing to ask "shall I proceed"). They
  also run on a **loop**: each cycle they address review feedback, wait while a PR
  is in review, or — once it merges — claim the next issue, so an implementer
  never stalls idle "awaiting review".
- **QA1–3** (1-minute `/loop`, paired by branch prefix): review only `implN/*`
  PRs, run the fast gate, and **squash-merge green ones into `staging`**
  (preserving `Closes #N`). No e2e here — kept fast and parallel-safe.
- **CONDUCTOR** (loop, owns e2e and the gate into `integration`): when `staging`
  is ahead of `integration`, acquires the e2e lock, runs the **full e2e suite**
  on `staging`, and on green ff-merges **`staging → integration`**, making
  `integration` a clean, e2e-passed release source. It **never touches `main`**.
- **You** (a separate session): release `integration → main` when you choose —
  which lands the `Closes #N` commits on the default branch and **auto-closes the
  issues**. Features never reach `main` while you're cutting a release.

The e2e lock (`~/.fun-with-friends/e2e.lock`, atomic `mkdir`) serializes e2e so
its single-port suite never collides. The conductor is the only e2e runner by
default, so it rarely contends — the lock is the safety net.

## Quick start

```bash
# one-time per repo: create worktrees + dev data, warm builds (slow, GB-scale)
FWF_PROFILE=transom ~/fun-with-friends/fwf-provision.sh --build

# launch the grid, claude in every pane, prompts delivered
FWF_PROFILE=transom ~/fun-with-friends/fwf-up.sh
tmux attach -t friends

FWF_PROFILE=transom ~/fun-with-friends/fwf-respawn.sh conductor  # hot-swap one role's pane (after editing a prompt)
FWF_PROFILE=transom ~/fun-with-friends/fwf-stop.sh          # graceful: every agent commits WIP + cancels its loop, then idles
FWF_PROFILE=transom ~/fun-with-friends/fwf-resume.sh        # clear the stop sentinel (then fwf-respawn roles to re-arm)
FWF_PROFILE=transom ~/fun-with-friends/fwf-down.sh           # stop the tmux session (keep worktrees)
FWF_PROFILE=transom ~/fun-with-friends/fwf-down.sh --purge   # also remove worktrees + dev-data
```

## Targeting another repo

Everything repo-specific lives in `profiles/<name>.sh`. Copy `profiles/transom.sh`,
set the path + commands, and launch with `FWF_PROFILE=<name>`:

| Profile var | Meaning |
|---|---|
| `FWF_REPO` | path to the application repo |
| `WT_PREFIX` | worktree name prefix (`tx` → `tx-impl1`, `tx-qa1`, …) |
| `STAGING_BRANCH` | impl PR target; QA fast-gates + merges here (`staging`) |
| `INTEGRATION_BRANCH` | conductor e2e-promotes here; your release source (`integration`) |
| `DEFAULT_BRANCH` | released by you in a separate session; swarm never touches it (`main`) |
| `GATE_CMD` | fast gate QA runs (tests + typecheck) |
| `E2E_CMD` | full e2e the conductor runs |
| `BUILD_CMD` | warm-build command per worktree |
| `E2E_SETUP_CMD` | one-time e2e dep install in the conductor tree |
| `DEV_UI_HINT` | live-UI command shown to implementers (`__DATA__` → tree's data dir) |
| `data_dir()` / `seed_data()` | isolated per-tree dev data (omit if the repo has none) |

Generic knobs live in `config.sh` (all `FWF_*` env-overridable): `FWF_SESSION`,
`FWF_QA_INTERVAL` (default `1m`), `FWF_CONDUCTOR_INTERVAL` (default `2m`),
`FWF_PM_INTERVAL` (default `5m`), `FWF_WIP_LABEL` (default `product-wip`),
`FWF_HOLD_LABEL` (default `release-hold`),
`FWF_BOOT_TIMEOUT` (default `45`s — how long launch/respawn waits for claude to
boot before sending a prompt), `FWF_CLAUDE_CMD`, colors. Prompts are templates in
`prompts/` — the source of truth; placeholders (`__ID__`, `__STAGING__`,
`__INTEGRATION__`, `__DEFAULT__`, `__GATE__`, `__E2E__`, `__LOCK__`, `__REPO__`,
`__DEVUI__`, `__WIP_LABEL__`, `__PM_INTERVAL__`) are substituted at launch.

## Notes & caveats

- **`--dangerously-skip-permissions`** in every pane (by request): implementers
  push branches, QA merges to `integration`, the conductor merges to `main`, all
  with no prompts. `fwf-up.sh` clears the one-time bypass acceptance screen.
- **Per-tree `target/` is GB-scale** — eight worktrees. Don't `--purge` between
  runs unless retiring the swarm; keep builds warm.
- **`/loop` dependency** for QA + conductor. If unavailable, the prompt still runs
  as a single pass — re-send it to re-check.
- **Issue auto-close** requires the `Closes #N` text to ride a commit onto the
  default branch; the implementer puts it in the PR body and QA preserves it in
  the squash commit, so it closes when you promote `integration → main`.
- The swarm **never touches `main`** — `staging` and `integration` are its only
  shared branches; you alone promote `integration → main` and cut releases.
- **Graceful stop:** `fwf-stop.sh` broadcasts a commit-WIP-and-halt instruction to
  every pane and drops a `STOP` sentinel that looping agents also self-check, so
  nothing keeps working mid-flight. `fwf-resume.sh` clears it; re-arm with
  `fwf-respawn.sh`.
- **No duplicate-claim conflicts:** implementers skip issues already resolved on
  `integration` (the lesson from #93/#101) and prefer the oldest, lowest-collision
  ticket.
- **Release freeze (drain before a release):** ask the PM to "freeze for release"
  and it proposes a cutoff, then labels the tickets that should wait with
  `release-hold` — implementers skip those (like `product-wip`), so in-flight work
  drains to a clean `integration` you can release. After the release, authorize the
  PM to lift the freeze: it removes `release-hold` from the next batch but **keeps
  `product-wip`** on anything still in feedback, so un-vetted drafts aren't released
  for implementation by accident.
