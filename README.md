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

Upgrading later is one command — `fwf upgrade` (ff-pulls a clone install;
downloads the latest release and re-links a tarball install; `--check` only
reports). Agents in a running factory keep their old prompts until respawned —
`fwf resume` re-arms everything on the new version.

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
re-injected every tick. Every role's tick also touches a step-0 **heartbeat**
(`~/.fun-with-friends/state/<profile>/heartbeat/<role>`) before doing any
work — a durable "this cycle started" signal, deliberately never the pane's
animation glyph (which stays looking alive even on a wedged role). `fwf
respawn <role>` waits for that heartbeat to advance after arming, for up to
the role's loop interval plus `FWF_RESPAWN_VERIFY_MARGIN` seconds (default
30) with one re-nudge, before reporting success — so a respawn can no longer
look "verified" while the role never actually ticks (issue #99).

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
  with you. It also manages cost autonomously: when the queue is empty it can
  **idle the whole floor** (`fwf down --floor-only`) without losing its own
  session, and bring it back (`fwf up --floor-only`) when work arrives — logged
  so `fwf dash` shows a calm **IDLE (captain)** state, never conflated with a
  crash (see [`docs/dash.md`](docs/dash.md)). `fwf down --floor-only` refuses
  to fire again within `FWF_FLOOR_COOLDOWN` seconds (default 300) of the last
  floor-up unless `--force` is passed — the deterministic guard against
  down→up→down token thrash. The
  role, workflows, and hard-won quality lessons live in
  [`templates/dev/captain.tmpl`](templates/dev/captain.tmpl).

The e2e lock (`~/.fun-with-friends/e2e.lock`, atomic `mkdir`) serializes e2e so
its single-port suite never collides — and it's shared by every role, not just
the conductor: implementers acquire the same lock for their own local e2e
self-verification runs before marking a PR ready (issue #65), since those
share the same fixed ports. The lock dir carries a holder-identity stamp
(role/PID/host/worktree/timestamp) so a role that dies mid-hold is recovered
automatically — a live holder is never reclaimed no matter how long it runs,
only a confirmed-dead one is broken immediately (`fwf_e2e_lock_acquire` /
`fwf_e2e_lock_release` in `lib.sh`).

## Factory templates

The pipeline above is the **dev** template — one of seven shipped factory
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
`FWF_TEMPLATE`) from the next section. Role prompts are the source of truth and
live in `templates/<name>/` (one directory per factory design).

## Commands

```
fwf suggest "<what you're trying to do>"            describe your goal; get a factory design back —
                                                    prebuilt or custom template + per-role models
fwf start <url|path> [--name N] [--yes] [--build]   clone → detect → confirm → provision → up
fwf init  <url|path> [--name N] [--yes]             clone → detect → scaffold profile
fwf provision [--build]                             create worktrees + dev data
fwf up [--floor-only]                               launch both sessions (--floor-only: rebuild just the
                                                    floor around a live captain)
fwf attach [coord|build]                            attach to coordination (default) or implementation
fwf captain [--print]                               copy/print the CAPTAIN prompt
fwf respawn <role>                                  hot-swap one pane (implN|qaN|conductor|pm|gv|captain);
                                                    recreates the pane if it closed entirely; waits for
                                                    the role's heartbeat to confirm the loop is really
                                                    ticking before reporting success (issue #99)
fwf stop | resume [--clear-only]                    graceful halt / clear sentinel + re-arm all roles
fwf down [--purge|--floor-only [--force]]           kill both sessions (--purge: remove worktrees too;
                                                    --floor-only: keep the captain running; refuses
                                                    within FWF_FLOOR_COOLDOWN secs of the last floor-up
                                                    unless --force)
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
fwf eval --role R --models M1,M2 [...]              role-level model evals, LLM-judged
                                                    (docs/eval-harness.md)
fwf shell [--rebuild]                               containerized toolchain sandbox (docs/containers.md)
fwf upgrade [--check]                               self-upgrade to the latest release (git clones
                                                    ff-pull; tarball installs download + re-link;
                                                    worktree installs refuse-with-guidance to their
                                                    main checkout — never pulled in place)
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
  `on` (every model that touched the work), `minimal` (link only, no model
  list), `off` (nothing). Defaults `on` for a normal GitHub-backed profile and
  `off` for `--issues local` (a repo you don't control, until you opt it in).
- **Release freeze:** ask the PM to "freeze for release" and it labels tickets
  that should wait with `release-hold` (implementers skip them, like
  `product-wip`), so in-flight work drains to a clean `integration` you can
  release. Authorize the PM to "lift the freeze" afterward.
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
  every role. `fwf up`/`fwf up --floor-only` arms a background WRITER
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
  armed) is visibly, not silently, off. `fwf down` (including `--floor-only`)
  stops the WRITER and clears any hold — a downed floor spends nothing, so
  there's nothing left to enforce against — but only a full `fwf down` also
  clears the baseline.

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
