# fun-with-friends

Point it at a git repo and it stands up a **multi-agent Claude Code dev factory**
for that repo: ten Claude sessions across two tmux sessions driving a full
**ideas → ship** pipeline — a **captain** you talk to, a **grand vizier** that
hardens the work, a product manager, three implementers, three QA reviewers, and
a conductor that gates end-to-end tests.

```bash
fwf start https://github.com/you/your-repo
```

The same machinery runs other **factory designs** too: a behavior-preserving
**refactoring** factory, an **ideation** factory that produces ranked idea
portfolios instead of code, and a **dev-sre** variant with a dedicated prod-ops
pane — pick one with `fwf up --template <name>`. The floor is sized and modeled
at runtime (`--pairs`, `--model`, per-role overrides), and a built-in **eval
harness** (`fwf eval`) tells you which model is good enough for which role.
New here? Start with the **[tutorial](docs/tutorial.md)**.

That one command clones the repo, detects its toolchain (Rust / Node / Go /
Python), shows you the test/build/e2e commands it inferred, scaffolds a profile,
provisions git worktrees, and launches the factory.

It runs as **two tmux sessions**. You attach to **coordination** and talk to the
captain; the **implementation** floor builds. They coordinate only through the
issue tracker and git — never across panes.

```
coordination  (you talk to the captain)
┌──────────────┬──────────────┬───────────────┐
│ PM (pink)    │ GV (purple)  │ CAPTAIN (blue) │
└──────────────┴──────────────┴───────────────┘

implementation  (the build floor)
┌──────────────┬──────────────┬──────────────┬────────────────────┐
│ IMPL1 (red)  │ IMPL2 (green)│ IMPL3 (teal) │                    │
├──────────────┼──────────────┼──────────────┤  CONDUCTOR (gold)  │
│ QA1  (red)   │ QA2  (green) │ QA3  (teal)  │                    │
└──────────────┴──────────────┴──────────────┴────────────────────┘
```

Each implementer shares its **paired QA's color** (one hue per column). The
**active pane** is highlighted hard: bright white bold border + an inverted
`[ ▶ ACTIVE ◀ ]` title bar, every other pane dimmed.

## Requirements

macOS or Linux (the UX is a tmux grid; Windows needs WSL). You need:

| Tool | Why |
|---|---|
| [`tmux`](https://github.com/tmux/tmux) | the 10-pane factory (two sessions) |
| `git` (≥ 2.x) | worktrees, one per agent |
| [`gh`](https://cli.github.com/) (authenticated) | issues + pull requests |
| [`claude`](https://www.anthropic.com/claude-code) | a Claude Code session in every pane |
| `bash` ≥ 3.2 | macOS's stock 3.2 is fine — the scripts are 3.2-clean |

Check everything at once:

```bash
fwf doctor
```

## Install

```bash
git clone https://github.com/tbaums/fun-with-friends
cd fun-with-friends
./install.sh          # symlinks `fwf` onto your PATH (~/.local/bin by default)
fwf doctor
```

Or just run `./fwf` directly from the clone — `install.sh` only puts it on your PATH.

Upgrading later is one command — `fwf upgrade` (fetches tags and ff-merges a
clone install to the latest release tag; downloads the latest release and
re-links a tarball install; `--check` only reports). Agents in a running
factory keep their old prompts until respawned — `fwf resume` re-arms
everything on the new version.

## Quick start

```bash
fwf start https://github.com/you/your-repo   # clone, detect, confirm, provision, launch
fwf attach                                    # watch coordination (talk to the captain)
fwf attach build                              # watch the implementation floor
fwf stop                                      # graceful halt: agents commit WIP and idle
fwf down                                       # tear down both tmux sessions (keep worktrees)
```

`fwf start` pauses to show the detected commands so you can review or edit the
generated profile before anything runs. Pass `--yes` to skip the prompt, or
split the steps:

```bash
fwf init https://github.com/you/your-repo     # clone + detect + scaffold profile only
$EDITOR profiles/your-repo.sh                  # tweak gate/build/e2e if you like
fwf --profile your-repo provision --build      # create worktrees + warm builds
fwf --profile your-repo up                      # launch
```

## The pipeline

Every looped role is armed the same way: its full role prompt is delivered
once at launch and persisted to `~/.fun-with-friends/prompts/<profile>-<role>.prompt`,
then its loop fires a one-line tick on the role's interval — an agent that has
compacted re-reads its role from that file instead of having the whole prompt
re-injected every tick. Every role's tick runs `fwf tick <role>` at step-0,
before doing any work: this bumps a **monotonic per-role loop-tick counter**
(`~/.fun-with-friends/state/<profile>/tick/<role>`) and refreshes a
**heartbeat** file (`.../heartbeat/<role>`). The two answer different
questions and neither is the pane's animation glyph (which stays looking alive
even on a wedged role): the heartbeat mtime is a recency signal ("a cycle
started recently"), while the counter is the reliable liveness signal the
mtime cannot be — because a wedged role, a healthy-but-mid-long-task role, and
an intentionally parked one all present an equally-stale mtime, whereas the
counter *strictly increases* once per real iteration, so comparing two samples
reads **working** (advancing) vs **parked/wedged** (static) unambiguously.

Two automated checks lean on this signal (issue #133):

- **Boot health-gate.** `fwf up` no longer declares the floor up the instant
  claude launches in each pane — *process-alive is not loop-alive*: the `/loop`
  arm can silently fail to register and the role then sits forever without
  claiming a ticket. After arming, the gate confirms **every** role fired a
  real first tick (its heartbeat advanced past the pre-arm epoch), **re-arms**
  any laggard once, and **hard-respawns** (kill pane → relaunch → re-arm →
  re-verify) any role that still won't loop — so a wedged boot self-recovers
  with no manual `fwf respawn`. Per-role window is the loop interval plus
  `FWF_BOOT_VERIFY_MARGIN` (default 45s); set `FWF_SKIP_BOOT_GATE=1` to bypass
  for a deliberately parked bring-up.
- **`fwf respawn <role>`** waits for the tick/heartbeat to advance after arming,
  for up to the role's loop interval plus `FWF_RESPAWN_VERIFY_MARGIN` seconds
  (default 30) with one re-nudge; if that soft re-nudge doesn't produce a tick
  it **escalates once** to a hard kill+relaunch of the pane and re-verifies,
  before reporting success — so a respawn can no longer look "verified" while
  the role never actually ticks (issues #99, #133).

`fwf stub-sweep` auto-closes claim-only **draft** PRs (zero changed files —
the claim commit *is* the mutex) left untouched past `FWF_STUB_GRACE_SECS`
(default 15m), reaping the orphan stub a dead boot loop opens before it dies
(issue #133).

An implementer treats its own open draft PR — even one that's still just the
empty `claim #<num>` commit — as the current cycle's work to resume (checkout
+ re-read the issue), never a satisfied "one PR in flight" slot to idle
behind; a draft that genuinely can't progress escalates to the captain
instead of stalling silently (issue #99).

- **PM** (loop): turns rough ideas into **draft** GitHub issues labeled
  `product-wip` (hidden from implementers) via back-and-forth, and on a loop
  refines those drafts from new comments. A draft isn't *ready* until the **grand
  vizier signs off** on it; then an explicit go-ahead removes the label and the
  issue enters the implementer queue. (A third label, `idea`, parks a ticket
  you want kept for later — every role skips it until you remove the label.)
- **GV — the grand vizier** (loop): the factory's strategic critic and
  idea-honer. It **hardens every PM spec** for real-user value, maintainability,
  and execution risk — posting concrete `GV-CHANGES` until it's top-notch, then a
  `GV-SIGNOFF` (a hard gate on the PM). It also **advises the captain** on plans
  and big calls — is now the right time, is this the right shape, is the swarm
  even the right tool for a cross-cutting refactor — advisory there, not a gate.
  It writes no code: it thinks, it doesn't authorize.
- **IMPL1–3** (generalists): each surveys open issues + in-flight PRs, skips PM
  drafts and any issue already resolved on a shared branch, and picks the
  **lowest-collision, oldest** eligible issue. Claiming is **atomic**: the
  implementer posts a `CLAIM implN` comment, re-checks that the first claim in
  the thread is its own (losers yield with zero wasted work; stale claims
  expire after 15 minutes), and only then branches and opens a draft PR
  (`Closes #N`). One issue = one branch = one PR, and a behavior-changing PR
  **updates its own docs in the same PR** (definition of done). They loop: address review
  feedback, wait while a PR is in review, or claim the next issue once one
  merges — never stalling idle. The captain can pre-assign with `ASSIGNED
  implN` comments when releasing a batch.
- **Discovery / exploration tickets** (`discovery` label): not every ticket is a
  code build. When the question is *should we / how would we / is it worth it*,
  the PM drafts a **discovery** ticket whose deliverable is a written **proposal**
  (`docs/proposals/<n>-<slug>.md` — an investigation plus a build-or-no-go
  recommendation), not code. The GV signs it off as *correctly scoped* — which is
  **not** "build it"; the go-ahead drops the `product-wip` gate but keeps
  `discovery`, so an implementer picks it up and **produces the proposal** instead
  of mis-building it as code (QA gates the proposal's substance, not tests). A
  proposal that recommends building spawns a new build ticket through the normal
  flow. This is the path for GV-signed-but-not-buildable tickets, so a scoped,
  approved exploration no longer stalls in `product-wip` limbo with no role to
  produce it. **Cross-machine note:** this flow lives in the *templates*, which
  ship in the repo — a box only has it once its install is current, so run `fwf
  upgrade` (then `fwf resume`/`fwf respawn <role>` to re-arm running panes) on
  each machine. `fwf up` also warns automatically if the box is behind the latest
  release, so a stale machine can't silently run the old flow.
- **QA1–3** (paired by branch prefix): review only `implN/*` PRs, run the fast
  gate, and **squash-merge green ones into `staging`** (preserving `Closes #N`);
  they also **request changes on a behavior-changing PR whose diff didn't update
  its docs**, so docs ride with the change. A green gate isn't the final word:
  QA is also the **"GV of the artifact"** — calibrated to the change's size, it
  reads load-bearing diffs adversarially, sanity-checks the impl's tests would
  actually catch a regression, tries to break the change with its own
  edge-case test, and checks the artifact against the source ticket's full
  intent, not just its headline ask. No e2e here — kept fast and parallel-safe.
- **CONDUCTOR** (owns e2e and the gate into `integration`): when `staging` is
  ahead, acquires the e2e lock, runs the **full e2e suite** on `staging`, and on
  green ff-merges **`staging → integration`**. It **never touches the default
  branch**.
- **CAPTAIN — you talk to it** (interactive + loop, in the coordination
  session): the factory's orchestrator and your technical co-pilot. Drop an idea
  or a feature and it drives it to shipped. Plans and scopes work into ready
  issues (**honing the plan with the grand vizier first**), shepherds both
  sessions (respawns wedged agents, deconflicts duplicate claims, briefs the PM
  via issue comments, approves drafts once the GV has signed off), does the hard
  or deadline-critical work directly, runs a prod-health caretaker heartbeat, and
  **releases `integration → main`** when you choose — landing the `Closes #N`
  commits on the default branch and **auto-closing the issues**. It hones its own
  work with the GV but still confirms irreversible actions (deploys, releases)
  with you. It also manages cost autonomously, and does so **per plane,
  independently**: the **build floor** (impl/qa/conductor, `--build-only`)
  idles whenever the claimable queue is empty and nothing is in flight; the
  **PM** pane (`--pm-only`) idles whenever no `product-wip` draft needs
  grooming — each evaluated on its own workload, so a long build stretch with
  no grooming pending can idle the PM while the floor stays up (or vice
  versa). `fwf down --floor-only` / `fwf up --floor-only` remain as an alias
  for `--build-only` + `--pm-only` together (today's original all-or-nothing
  behavior, unchanged). The **GV never idles** — it stays reachable on demand
  for a gate or verification the whole time the captain is up. Every idle is
  logged per-plane to the same `floor-events.log` (issue #85, extended by
  #105); `fwf dash` itself still reads only the **build** plane's state as
  its calm **IDLE (captain)** badge (v1 — PM-plane idle isn't surfaced there
  yet), never conflated with a crash (see [`docs/dash.md`](docs/dash.md)).
  Each
  plane enforces its own deterministic cooldown — `fwf down --build-only`
  refuses within `FWF_BUILD_COOLDOWN` seconds (default 300, alias of the
  legacy `FWF_FLOOR_COOLDOWN`) of that plane's last up, and `--pm-only`
  refuses within `FWF_PM_COOLDOWN` seconds (default 300) — the deterministic
  guard against down→up→down token thrash. Each plane also refuses to idle at
  all if doing so would strand work (an open PR, a promotion-in-flight, or a
  ticket CLAIMED but not yet pushed as a PR blocks `--build-only`; an
  ungroomed `product-wip` draft blocks `--pm-only`), even with `--force`. The
  claim-window case (issue #147) defers to the SAME shared pane-liveness
  signal `fwf supervise` uses (`fwf-pane-liveness.sh`, built on issue #165's
  wedge classifier) — a claimant whose pane is HEALTHY/WORKING, or whose
  liveness can't yet be confirmed, blocks; WEDGED (a live pane that stopped
  progressing) ALSO blocks — it's `fwf supervise`'s own respawn target, not
  the idle guard's, so tearing down the floor under it would only be a
  softer version of the founding incident. Only a claimant whose pane is
  CONFIRMED ABSENT (no matching tmux pane at all — `fwf_role_pane_alive`)
  lets the idle proceed. Claim age is a fallback ONLY for a claimant with no
  liveness signal recorded at all (`FWF_CLAIM_LIVENESS_FALLBACK_SECS`,
  default 900s/15m). The
  role, workflows, and hard-won quality lessons live in
  [`templates/dev/captain.tmpl`](templates/dev/captain.tmpl).

  **Per-plane `up`/`down` flag matrix** (issue #155 — `--coord-only` is the
  non-destructive mirror of `--build-only`, for standing up just coordination
  from a cold/fully-down state, e.g. to groom the `product-wip` backlog
  before spinning up the build floor at all):

  | flag | `fwf up` brings up | `fwf up` requires already up | `fwf down` tears down | always survives |
  |---|---|---|---|---|
  | *(none, full)* | coord (PM+GV+Captain) + build floor | neither session | both sessions entirely | — |
  | `--build-only` | build floor | coord (a live captain to build around) | build floor only | Captain, GV, PM |
  | `--pm-only` | PM pane (+GV self-heal check) | coord (a live captain) | PM pane (+ any extra coord role) | Captain, GV |
  | `--coord-only` | PM+GV+Captain, from cold | *(refuses if already up — no-op, not an error)* | *n/a — up-only flag* | build floor (never touched) |
  | `--floor-only` | build floor + PM pane together | coord (a live captain) | build floor + PM pane together | Captain, GV |

  `--floor-only` is a back-compat **alias** for `--build-only` + `--pm-only`
  together, not a synonym for "just the build floor" — despite the name, it
  also brings up/tears down the PM pane. **Captain and GV are the only panes
  every flag leaves untouched** — no `down` path, floor-only included, ever
  tears down either.

Every `__GATE__`/`__E2E__` a role runs is rendered as a call to `fwf gate`
(issue #123), the one shared guarded launcher every tick-driven gate/e2e
invocation routes through — qa's fast-gate review, an implementer's own gate
validation, and the conductor's promotion e2e all go through the same code,
not a per-role copy:

- **Per-role single-flight lock** (`~/.fun-with-friends/state/<profile>/gate-lock/<role>`,
  atomic `mkdir`): a role whose own PRIOR gate is still running does not
  launch a second — `fwf gate` exits `75` and the role skips that tick rather
  than stacking runs (the observed failure mode: 8 concurrent `test/run.sh`
  processes, none finishing, because a role kept relaunching without checking
  whether its last one had exited). Fail-closed: if the lock's liveness can't
  be determined, it also skips rather than risking a stack. A live holder
  past `FWF_GATE_LOCK_MAX_RUN_SECS` (default 1800s) is treated as wedged and
  reaped, so a crashed gate can never wedge the role permanently
  (`fwf_gate_lock_acquire` / `fwf_gate_lock_release` in `lib.sh`).
- **Floor-wide e2e lock** (`~/.fun-with-friends/e2e.lock`, atomic `mkdir`,
  issue #65) — taken ADDITIONALLY when `fwf gate` is called with `--e2e`
  (every `__E2E__` render; `__GATE__` does not need it, since the fast gate
  isn't meant to share ports with anything). Serializes e2e-class runs across
  DIFFERENT roles so a single-port harness never collides — conductor's
  promotion e2e and an implementer's own local e2e self-verification (before
  marking a PR ready) share this same lock. The lock dir carries a
  holder-identity stamp (role/PID/host/worktree/timestamp) so a role that
  dies mid-hold is recovered automatically — a live holder is never reclaimed
  no matter how long it runs, only a confirmed-dead one is broken immediately
  (`fwf_e2e_lock_acquire` / `fwf_e2e_lock_release` in `lib.sh`).

- **The caller's environment, not the gate's** (issue #175) — `fwf gate`
  resolves a profile of its own to build those lock paths, and doing so sets
  `FWF_PROFILE`/`FWF_PAIRS`/`FWF_REPO` in its shell. Those values are the
  GATE's, not the wrapped command's, so the gate snapshots the caller's real
  environment BEFORE resolving and restores it verbatim before handing over: a
  var the caller had keeps its ORIGINAL value, one the caller lacked is left
  unset rather than blanked. Without this the wrapped command inherits an
  ambient profile it never asked for and which silently overrides any fixture
  env it pins for itself — `test/run.sh` measured 41 otherwise-passing tests
  going RED, so the gate was false-RED on every cycle and no implementer could
  reach green. A CORRECT inherited value overrides a fixture exactly as
  destructively as a wrong one: this is about provenance, not validity, which
  is why a `GATE_CMD` does not need an `env -u FWF_*` guard of its own
  (`_fwf_gate_env_restore` in `fwf-gate.sh`).

- **Tip-triggered, not just timer-triggered** (issue #202) — the conductor's
  promotion e2e renders as `__PROMOTE_GATE__` (a distinct macro from
  `__E2E__`, which implementers also use for their own local self-verification
  and has no shared ref to key on) and adds `fwf gate`'s `--tip-cmd 'CMD'`:
  CMD (e.g. `git rev-parse origin/staging`) is checked BEFORE the lock is
  ever taken, and a tick that finds the watched ref unchanged since the last
  COMPLETED gate for that role never acquires it — `fwf gate` exits `75`
  exactly like a busy lock. If the ref moves DURING the run, the result is
  for a superseded tip and must never read as promotable, so the run exits
  `76` instead, regardless of the wrapped command's own exit code. State is
  persisted BY THE GATE SCRIPT itself on exit (`~/.fun-with-friends/state/<profile>/gate-tip/<role>`),
  never by a role's memory — a captain-authored prompt guard with the same
  intent had silently stopped firing because nothing ever wrote its marker.
  `FWF_GATE_FORCE=1` forces a re-run of an otherwise-skippable unchanged tip
  (`fwf_gate_tip_unchanged` / `fwf_gate_tip_record` in `lib.sh`).

Both locks are released by `fwf gate`'s own `EXIT` trap the moment it exits —
success, failure, or a kill — so no role has to manage them by hand; see
`fwf gate` in `fwf help` and `fwf-gate.sh`.

- **`fwf tick`'s heartbeat trusts the worktree, not ambient env** (issue #182)
  — `fwf tick <role>` has no `--profile` flag, so any ambient `FWF_PROFILE` it
  sees can only be leftover env from an unrelated shell, never a deliberate
  pin; blindly trusting it can silently write a live role's heartbeat under
  the WRONG profile's state dir, which makes health-gate/respawn see that
  role as DEAD and risks an unwanted respawn that discards in-flight
  progress. `fwf-provision.sh` now drops a `.fwf-profile` marker at the root
  of every worktree/scratch dir it creates, naming the profile it was
  provisioned for; `fwf tick` prefers that marker over ambient `FWF_PROFILE`
  whenever one is present (a mismatch is logged as a warning, not silently
  swallowed). Outside a provisioned worktree — no marker to consult — `fwf
  tick` falls back to today's ambient/single-profile resolution, but warns if
  the ambient profile has no live tick activity while another profile
  demonstrably does (the swarm is running elsewhere and this heartbeat is
  likely about to land in a phantom dir).

## Factory templates

The pipeline above is the **dev** template — one of eight shipped factory
designs. A template re-aims every role's prompt (and optionally the topology)
while reusing all the machinery: tmux grid, branch ladder, labels, floor
lifecycle, stop/resume.

| Template | The factory's product | Doc |
|---|---|---|
| `dev` (default) | shipped features (the pipeline above) | this README |
| `refactor` | behavior-preserving structural improvement — characterize-first refactorers, behavior-contract verifiers, a planner that ranks debt by churn×complexity, a captain that sequences instead of parallelizing | [docs/refactor-factory.md](docs/refactor-factory.md) |
| `ideation` | ranked idea portfolios under `ideas/` — stance-diverse generators, feasibility-hardening critics, a synthesizer that clusters and ranks pairwise into `PORTFOLIO.md` | [docs/ideation-factory.md](docs/ideation-factory.md) |
| `dev-sre` | dev + a dedicated prod-ops (SRE) pane; the captain does zero ops while it runs | [docs/captain-split.md](docs/captain-split.md) |
| `user-testing` | ranked usability findings — 3 source-blind personas (9 in deep-sweep mode) drive a real browser like whacky humans, a researcher dedupes their diaries into a top-10 report graded against ground truth, a captain gates what graduates | [docs/user-testing.md](docs/user-testing.md) |
| `validate` | a defensible GO / KILL / PIVOT verdict on a posited business+product idea — falsification dossier under `validation/<slug>/`, curated `VERDICT.md` | [docs/validate-factory.md](docs/validate-factory.md) |
| `consulting` | a defensible diagnosis of whether an agent-built pipeline's shipped quality regressed and why — a 3-phase falsification funnel (premise gate → cause tournament → replay) writing a `DOSSIER.md`; advisory, reads the client repo, writes only its own findings repo | [docs/consulting-factory.md](docs/consulting-factory.md) |
| `defect-report` | a filed, receiver-ready defect report per `(skill,target)` run in one pass — checklist derived from the skill's standard, grounded facts, adversarial sanitization, dry-mode delivery verification, one human gate; Phase 1 (archetype B) of the parameterized skill-runner config, gated on a pre-registered eval beating a single-model baseline | [docs/defect-report-factory.md](docs/defect-report-factory.md) |

```bash
fwf templates                       # list what's shipped
fwf up --template refactor          # or FWF_TEMPLATE=refactor, or set it in a profile
```

Not sure which design fits? Describe the goal and let it advise you —
including per-role model picks and a custom-template sketch when nothing
prebuilt fits:

```bash
fwf suggest "I inherited a legacy app with no tests; make it safe to change"
```

A template is just `templates/<name>/` — six role prompts plus an optional
`template.sh` of defaults. Templates can **inherit** prompts from a base
(`FWF_TEMPLATE_BASE="dev"` — override one file, not six) and **declare extra
panes** (`FWF_EXTRA_ROLES="sre:coord:2m:colour208"`). Authoring your own is
covered in the [tutorial](docs/tutorial.md#7-build-your-own-template).

## Auto-detection

`fwf init`/`start` inspects the clone and proposes four commands, then writes
them into `profiles/<name>.sh` for you to review:

| Command | Used by | Detected from |
|---|---|---|
| `GATE_CMD` | QA (fast gate before merge to staging) | `cargo test` · `npm/pnpm/yarn test` (+ typecheck/lint) · `go test ./...` · `pytest` |
| `BUILD_CMD` | provision (warm each worktree) | `cargo build` · the repo's `build` script · `go build ./...` |
| `E2E_CMD` | conductor (gate into integration) | a `test:e2e`/`e2e` script · Playwright or Cypress dep |
| `DEV_UI_HINT` | implementers (live UI) | the repo's `dev`/`start` script |

Package managers are picked from the lockfile (`pnpm-lock.yaml`, `yarn.lock`,
`bun.lockb`, else npm). When the ecosystem is **unknown**, the generated
`GATE_CMD` is **fail-closed** — it errors — so QA never silently merges
everything until you fill it in.

## Targeting a repo manually

Everything repo-specific lives in `profiles/<name>.sh`. Copy
[`profiles/example.sh`](profiles/example.sh), fill in the paths and commands, and
launch with `fwf --profile <name>`:

| Profile var | Meaning |
|---|---|
| `FWF_REPO` | path to the application repo |
| `WT_PREFIX` | worktree name prefix (`ex` → `ex-impl1`, `ex-qa1`, …) |
| `WT_BASE` | where worktrees live (default keeps them out of `$HOME`) |
| `STAGING_BRANCH` | impl PR target; QA fast-gates + merges here |
| `INTEGRATION_BRANCH` | conductor e2e-promotes here; your release source |
| `DEFAULT_BRANCH` | released by you; the swarm never touches it |
| `GATE_CMD` / `BUILD_CMD` / `E2E_CMD` | the commands above |
| `E2E_SETUP_CMD` | one-time e2e dep install in the conductor tree |
| `DEV_UI_HINT` | live-UI command shown to implementers (`__DATA__` → tree's data dir) |
| `data_dir()` / `seed_data()` | isolated per-tree dev data (no-ops by default) |

Generic knobs live in `config.sh` (all `FWF_*` env-overridable): `FWF_SESSION`
(base name; `FWF_COORD_SESSION`/`FWF_BUILD_SESSION` derive from it),
`FWF_QA_INTERVAL`, `FWF_CONDUCTOR_INTERVAL`, `FWF_PM_INTERVAL`, `FWF_GV_INTERVAL`,
`FWF_CAPTAIN_INTERVAL`, `FWF_IMPL_INTERVAL`, `FWF_WIP_LABEL`, `FWF_HOLD_LABEL`,
`FWF_DISCOVERY_LABEL` (default `discovery`),
`FWF_BOOT_TIMEOUT`, `FWF_CLAUDE_CMD`, `FWF_WORKSPACE_BASE`, colors — plus the
sizing/model/template knobs (`FWF_PAIRS`, `FWF_MODEL`, `FWF_MODEL_<ROLE>`,
`FWF_TEMPLATE`) from the next section. Every seat launches with Claude Code's
`Concise` output style by default (`FWF_OUTPUT_STYLE`, passed via `--settings`;
set to `""` to opt a floor back out). Role prompts are the source of truth and
live in `templates/<name>/` (one directory per factory design).

## Commands

```
fwf suggest "<what you're trying to do>"            describe your goal; get a factory design back —
                                                    prebuilt or custom template + per-role models
fwf start <url|path> [--name N] [--yes] [--build]   clone → detect → confirm → provision → up
fwf init  <url|path> [--name N] [--yes]             clone → detect → scaffold profile
fwf provision [--build]                             create worktrees + dev data
fwf up [--build-only|--pm-only|--floor-only|--coord-only]
                                                    launch both sessions (--build-only: rebuild just the
                                                    build session, around a live captain — requires an
                                                    existing coordination session; --pm-only: rebuild just
                                                    the PM pane (GV, which never idles, is left alone) —
                                                    also requires an existing coordination session;
                                                    --floor-only: both together; --coord-only: bring up
                                                    coordination (PM/GV/Captain) from cold, leaving any
                                                    build floor — up, down, or absent — untouched; a
                                                    no-op if coordination is already up). Refuses to
                                                    launch (loud error, never a silent $HOME pane) if the
                                                    profile hasn't been provisioned yet — run `fwf
                                                    provision` or `fwf start` first (issue #142)
fwf attach [coord|build]                            attach to coordination (default) or implementation
fwf captain [--print]                               copy/print the CAPTAIN prompt
fwf respawn <role>                                  hot-swap one pane (implN|qaN|conductor|pm|gv|captain);
                                                    recreates the pane if it closed entirely; waits for
                                                    the role's heartbeat to confirm the loop is really
                                                    ticking before reporting success (issue #99)
fwf stop | resume [--clear-only]                    graceful halt / clear sentinel + re-arm all roles
fwf down [--purge|--build-only|--pm-only|--floor-only [--force]]
                                                    kill both sessions (--purge: remove worktrees too;
                                                    --build-only: kill only the build session;
                                                    --pm-only: kill only the PM pane; --floor-only: both
                                                    together — each refuses within its own
                                                    FWF_BUILD_COOLDOWN/FWF_PM_COOLDOWN secs of that
                                                    plane's last up, and refuses (even with --force) if
                                                    idling it could strand work; GV is never torn down)
fwf issues <create|list|view|edit|comment|close|reopen|export>
                                                    the local issue tracker (--issues local):
                                                    gh-shaped CLI over a markdown store
fwf dash                                            read-only status board + decision inbox (Rust
                                                    TUI; prebuilt binary auto-downloaded on first
                                                    run — docs/dash.md)
fwf usage [--clear-hold]                            per-role token usage + an estimated $ equivalent,
                                                    read from each role's own Claude Code session
                                                    transcripts, plus budget-enforcement status
                                                    (read-only; also a dash tab). --clear-hold lifts
                                                    a BUDGET_HOLD by hand.
fwf gate <role> [--e2e] -- <cmd...>                 the shared guarded gate/e2e launcher every
                                                    __GATE__/__E2E__ render calls (issue #123); exits
                                                    75 rather than stacking a second run when <role>'s
                                                    own prior gate is still in flight
fwf flag-captain <n> --role R --reason TEXT         raise a persisted "needs-captain" flag on issue/PR
  fwf flag-captain <n> --clear [--note TEXT]        <n> for the captain's per-tick sweep to pick up
  fwf flag-captain sweep                            (issue #113) — see docs/needs-captain.md
fwf eval --role R --models M1,M2 [...]              role-level model evals, LLM-judged
                                                    (docs/eval-harness.md)
fwf shell [--rebuild]                               containerized toolchain sandbox (docs/containers.md)
fwf upgrade [--check]                               self-upgrade to the latest release (git clones
                                                    fetch tags + ff-merge to the release tag; tarball
                                                    installs download + re-link; worktree installs
                                                    refuse-with-guidance to their main checkout —
                                                    never merged in place)
fwf doctor | profiles | templates | version | help  (version also: -v, --version)
```

Use `--profile NAME` (or `--profile=NAME`, or `FWF_PROFILE=NAME`) to pick among
profiles; with only one profile present it's selected automatically. `--profile`
works before OR after the subcommand (`fwf --profile NAME dash` and
`fwf dash --profile NAME` both work) — if given in both spots, the later one
wins.

### Sizing, models, and factory templates

`start` / `provision` / `up` / `respawn` / `resume` / `down` also take:

```
--template NAME      factory design template: the role-prompt set the agents run.
                     Shipped: dev (default — the feature factory described above),
                     refactor (behavior-preserving refactoring factory; see
                     docs/refactor-factory.md), ideation (idea-portfolio factory;
                     see docs/ideation-factory.md), dev-sre (dev + a dedicated
                     prod-ops pane; see docs/captain-split.md), user-testing
                     (source-blind persona usability trials; see
                     docs/user-testing.md), validate (GO/KILL/PIVOT idea
                     validation; see docs/validate-factory.md). A template can
                     declare EXTRA roles (FWF_EXTRA_ROLES) and inherit prompts
                     from a base (FWF_TEMPLATE_BASE). List them: fwf templates
--pairs N            number of implementer/QA pairs (default 3; refactor: 2)
--model M            model for every agent (claude --model M)
--impl-model M       per-role override; likewise --qa-model, --pm-model,
                     --gv-model, --captain-model, --conductor-model
--budget-usd N       RECOMMENDED hard budget ceiling, in estimated dollars;
                     unset = unlimited (default, opt-in). Enforced against the
                     same per-model price table `fwf usage` shows (cache-read
                     priced at its true, far-cheaper rate — no unit
                     guesswork), as a DELTA since this run's `fwf up` (see
                     "Token budget enforcement" below). Mutually exclusive
                     with --token-budget (setting both is an error).
--token-budget N     hard ceiling on combined RAW token spend across every
                     role (back-compat); unset = unlimited (default, opt-in).
                     Counts cache-read tokens, which dominate real runs by 2-3
                     orders of magnitude — prefer --budget-usd unless you
                     specifically want a raw-token ceiling. See "Token budget
                     enforcement" below.
```

```
--issues gh|local    issue-tracker backend (alias: --local-issues). Use local
                     for repos you don't control: the whole gated-spec / claim
                     / approval flow runs over a markdown store OUTSIDE the
                     repo (one file per issue under ~/.fun-with-friends/
                     issues/<profile>/{open,closed}/), driven by `fwf issues` —
                     and the factory NEVER touches the remote: provision
                     installs a pre-push guard blocking every push unless a
                     human authorizes that one push with FWF_ALLOW_PUSH=1, and
                     every pane gets a fail-closed `gh` wrapper that blocks
                     mutating gh commands (reads pass through) unless that one
                     invocation is authorized with FWF_ALLOW_GH=1;
                     branches, reviews, merges, and promotion are fully local,
                     and only the captain — on your explicit, per-instance
                     word — pushes or opens an upstream PR, with its body
                     mined from the local reasoning (`fwf issues export`).
                     Issue refs become LI-N so nothing links upstream.
```

`--issues local` also works on a repo with **no `origin` remote at all** —
`fwf up`/`fwf provision` degrade gracefully (a loud warning, not a silent
`set -e` abort) and keep the staging/integration ladder purely local (issue
#141). A fresh `git init` repo with no remote is enough; no bare/dummy origin
needed.



All of these persist in a profile as `FWF_TEMPLATE`, `FWF_PAIRS`, `FWF_MODEL`,
`FWF_MODEL_<ROLE>`, `FWF_ISSUES`. A template may ship its own defaults
(`template.sh`); precedence is CLI/env → profile → template → stock.

## Notes & caveats

- **`--dangerously-skip-permissions`** runs in every pane: implementers push
  branches, QA merges to `staging`, the conductor merges to `integration`, all
  without prompts. `fwf up` clears the one-time bypass-accept screen. Run this
  only on repos and machines where that is acceptable.
- **The swarm never touches the default branch** — `staging` and `integration`
  are its only shared branches; you alone promote `integration → main`.
- **Per-tree build dirs can be large** (ten worktrees). To stop each worktree
  carrying its own multi-GB compile cache, a profile can export a shared
  `CARGO_TARGET_DIR` so every tree builds into one dir — dependencies (the bulk)
  dedupe to a single copy; only first-party crates rebuild on branch switches.
  Watch for cargo's build-lock serializing concurrent builds across panes.
- **Disk-pressure guard:** `fwf up` refuses to start (or cycle the floor) when
  free space is below `FWF_MIN_FREE_GB` (default `50`, set `0` to disable). On a
  shared host a full disk fails not just builds but prod writes — it once wedged
  a release. Don't `--purge` between runs unless retiring the factory; keep
  builds warm.
- **Passing secrets/creds to agent panes:** a NEW tmux pane inherits the tmux
  *server's* environment from whenever the server itself first started, not
  the shell that just ran `fwf up` — the classic tmux gotcha. So exports set
  right before `fwf up` silently never reach panes whenever the server
  already existed (issue #143). `FWF_PANE_ENV` (comma/space-separated var
  NAMES, e.g. `FWF_PANE_ENV=MY_API_KEY`) forwards each named var's current
  value into every pane reliably, regardless of server age: their values are
  snapshotted to a private, `chmod 600` file outside the repo
  (`~/.fun-with-friends/state/<profile>/pane-env.sh`), which every pane
  sources fresh right before `claude` launches — never typed into a pane's
  visible scrollback, never committed. Regenerated on every `fwf up`/`fwf
  respawn`, so re-running always forwards the latest value.
- **Issue auto-close** requires the `Closes #N` text to ride a commit onto the
  default branch; the implementer puts it in the PR body and QA preserves it in
  the squash commit, so it closes when you promote `integration → main`.
- **PR body context-fold + built-with credit:** every PR that closes a ticket
  gets a mechanically-extracted, sanitized "Context & rationale" fold (the
  ticket's problem/decisions/alternatives/acceptance-criteria/testing
  sections, plus any linked `docs/proposals/<n>-*.md`) folded into the squash-
  merge commit and PR body — no fwf-internal vocabulary (role/seat names,
  worktree/gate jargon, `LI-N`), no invented rationale, fail-closed if
  anything survives sanitization (`fwf pr-context <n> [<n>...]` — see `fwf
  help`). Alongside it, a reviewer-facing "🏭 Built with fun-with-friends +
  Claude" credit line (distinct from — and coexists with — the `fwf-
  Provenance:` machine trailer). `FWF_CREDIT=on|minimal|off` controls it:
  `on` (full line + every distinct model that touched the work, one entry per
  seat's *actual* model — a mixed-model profile lists every model, a
  single-model profile legitimately collapses to one), `minimal` (drops the
  "(a multi-agent Claude Code dev factory)" aside but keeps the same full
  model list — the disclosure bar isn't a coverage knob), `off` (nothing). A
  seat left on the CLI default (no override, no floor default) is omitted
  from the list rather than shown blank. Defaults `on` for a normal
  GitHub-backed profile and `off` for `--issues local` (a repo you don't
  control, until you opt it in).
- **Release freeze:** ask the PM to "freeze for release" and it labels tickets
  that should wait with `release-hold` (implementers skip them, like
  `product-wip`), so in-flight work drains to a clean `integration` you can
  release. Authorize the PM to "lift the freeze" afterward.
- **Branch reconcile** (`fwf reconcile`, issue #114): keeps `staging`/
  `integration` from going stale after a release or a direct-to-`main`
  change — the failure mode where the swarm keeps building on a base that's
  missing just-shipped prior art. Classifies each branch against `main` by
  ancestry into one of five states and acts accordingly: **behind** (a strict
  ancestor of `main`) is fast-forward-reconciled automatically; **ahead**
  (`main` is a strict ancestor of the branch — the normal state between
  releases, since the conductor promotes onto it before a release ships) is a
  no-op, never a false alarm; **diverged** (each side has a commit the other
  lacks) halts loudly and names the SHAs — it never auto-merges, rebases, or
  force-pushes; **equal** is a clean no-op; and an unfetchable/unclassifiable
  branch fails closed as **suspect**. Wired into two places: the release
  workflow's last step (`.github/workflows/release.yml`, so it can't be a
  forgotten manual step — see `RELEASING.md`) and the captain's per-tick
  stale-base guard, run before assigning any ticket. `fwf reconcile [--branch
  NAME ...] [--against BRANCH]` — defaults to `staging`+`integration` against
  `main`; exits non-zero iff some branch is unsafe to build on right now.
- **Upgrade staleness check:** `fwf up` and `fwf doctor` check (never blocking —
  the network call, if any, always runs detached in the background) whether a
  newer fwf release exists and warn if you're behind. `fwf doctor` reports one
  of three states: up to date, out of date (with the upgrade command), or
  *could not check* (a dead/unreachable checker never masquerades as "you're
  current"). The check surfaces on the `fwf dash` header too — see
  `docs/dash.md`. Cache lives at `$FWF_RUN/upgrade-check/` (shared across every
  profile on the machine), refreshed at most once per `FWF_VERSION_CHECK_WINDOW`
  seconds (default 12h). `FWF_ACK_VERSION=vX.Y.Z` silences the banner/warning
  for that specific release only — a newer release re-arms it even if you
  acknowledged an earlier one. `FWF_SKIP_VERSION_CHECK=1` is the full kill
  switch for offline/air-gapped use — it disables the check entirely (no cache
  read, no network, ever), not just the banner.
- **Token budget enforcement** (`--budget-usd N` recommended, or `--token-budget
  N` for a raw-token ceiling; opt-in, unset = unlimited): caps spend across
  every role. Any `fwf up` invocation (full, `--build-only`, `--pm-only`, or
  `--floor-only`) arms a background WRITER
  (`fwf-budget-check.sh --loop`, ~60s cadence, zero network calls — it only
  re-reads the local transcripts `fwf usage` already reads) only when a
  ceiling is set; every role checks a sentinel at its own step-0 and, if held,
  commits WIP and idles until the next tick — it never cancels a role's loop,
  so it resumes automatically once the hold clears, no respawn needed.
  Enforcement is a within-one-poll-interval guarantee (`FWF_BUDGET_CHECK_INTERVAL`,
  default 60s), not an instant stop at exactly `N` — set the cap with headroom.
  Setting both `--budget-usd` and `--token-budget` is an error (no silent
  pick-one). `--budget-usd` reuses the per-model price table `fwf usage`
  already computes — it prices cache-read at its true, far-cheaper rate, so a
  dollar ceiling is already correctly cache-read-weighted with no down-weight
  factor to invent; an unpriced model fails the whole run closed to UNKNOWN
  rather than silently costing it \$0.
  **Per-run baseline:** a genuinely fresh `fwf up` (not a `--floor-only`
  bounce, not `fwf-respawn.sh` — both preserve the existing baseline)
  snapshots current cumulative usage as this run's baseline; every check
  after that enforces the *delta* since that snapshot, not the lifetime
  cumulative total — so reusing a profile's worktree paths after `fwf down
  --purge` doesn't inherit a prior run's billions of tokens as if spent just
  now. A full `fwf down` (with or without `--purge`) clears the baseline so
  the next full `fwf up` starts a fresh one; a missing/corrupt baseline, or a
  cumulative read that comes back *below* the recorded baseline (a transcript
  rotation/prune), fails closed to UNKNOWN rather than guessing.
  Three states, written ONLY by the WRITER (roles only ever read it, and the
  sentinel's first-line token — `HOLD`/`WARN`/`UNKNOWN` — is stable regardless
  of unit): **HOLD** (this-run spend ≥ ceiling — needs an operator to raise
  the ceiling or run `fwf usage --clear-hold`), **WARN** (≥
  `FWF_TOKEN_BUDGET_WARN_PCT`, default 80%, of the ceiling — noted, not
  paused), and **UNKNOWN — FAIL-CLOSED** (a role's usage reader or the
  baseline broke — pauses the whole factory rather than risk silently
  under-counting spend; textually distinct from HOLD so a Claude Code
  transcript-schema change is never misread as "over budget"). `fwf usage`
  and the dash Usage tab both show an explicit **ARMED (ceiling N) / NOT
  ARMED** line, this-run-vs-cumulative spend, and the current hold, so a
  budget set mid-run without a re-`fwf up` (the only place the WRITER gets
  armed) is visibly, not silently, off. `fwf down` (including `--build-only`/
  `--floor-only`) stops the WRITER and clears any hold — a downed build floor
  spends nothing, so there's nothing left to enforce against — but only a
  full `fwf down` also clears the baseline.

## Learn more

- **[Tutorial](docs/tutorial.md)** — hands-on walkthrough of everything: first
  factory, day-to-day driving, floor lifecycle, sizing/models, the shipped
  factory templates, authoring your own template, evals, the container sandbox.
- [docs/refactor-factory.md](docs/refactor-factory.md) — the refactoring
  factory's design and research basis.
- [docs/ideation-factory.md](docs/ideation-factory.md) — the ideation factory's
  design and research basis.
- [docs/captain-split.md](docs/captain-split.md) — when (and when not) to run
  the `dev-sre` variant.
- [docs/eval-harness.md](docs/eval-harness.md) — how `fwf eval` works and how
  to add scenarios.
- [docs/user-testing.md](docs/user-testing.md) — the user-testing factory:
  personas, quick vs deep sweeps, target-app guardrails.
- [docs/validate-factory.md](docs/validate-factory.md) — the validate factory's
  design and research basis.
- [docs/dash.md](docs/dash.md) — the `fwf dash` status board: what it shows,
  keys, binary resolution, and the per-role token/$ Usage tab (`fwf usage`).
- [docs/gh-read-cache.md](docs/gh-read-cache.md) — the GitHub read cache that
  keeps a floor from hammering the API.
- [docs/shared-account.md](docs/shared-account.md) — running every role on
  one GitHub account: why formal PR reviews don't work, and the
  `QA-CHANGES-REQUESTED`/`QA-APPROVED`/`IMPL-ADDRESSED` marker protocol
  (`fwf pr-review-state`) that replaces them.
- [docs/needs-captain.md](docs/needs-captain.md) — the persisted
  `needs-captain` flag any role raises on an issue/PR (`fwf flag-captain`),
  swept by the captain every tick so it can't go unseen (issue #113).
- [docs/containers.md](docs/containers.md) — the containerization design and
  `fwf shell`.

## Development

```bash
bash test/run.sh        # functional suite (~370 tests): detection, profiles, dispatcher,
                        # floor lifecycle, sizing/models, templates, eval harness
shellcheck -S warning fwf *.sh lib/*.sh profiles/example.sh templates/*/template.sh eval/run.sh test/run.sh
```

CI runs both on every push to `main` and on PRs (Linux + macOS). Cutting a
release is documented in [`RELEASING.md`](RELEASING.md); see
[`CHANGELOG.md`](CHANGELOG.md) for what shipped in each version.

## License

[MIT](LICENSE) © 2026 Jamie Tanenbaum
