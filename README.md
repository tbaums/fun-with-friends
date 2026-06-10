# fun-with-friends

Point it at a git repo and it stands up a **multi-agent Claude Code dev factory**
for that repo: ten Claude sessions across two tmux sessions driving a full
**ideas → ship** pipeline — a **captain** you talk to, a **grand vizier** that
hardens the work, a product manager, three implementers, three QA reviewers, and
a conductor that gates end-to-end tests.

```bash
fwf start https://github.com/you/your-repo
```

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

- **PM** (loop): turns rough ideas into **draft** GitHub issues labeled
  `product-wip` (hidden from implementers) via back-and-forth, and on a loop
  refines those drafts from new comments. A draft isn't *ready* until the **grand
  vizier signs off** on it; then an explicit go-ahead removes the label and the
  issue enters the implementer queue.
- **GV — the grand vizier** (loop): the factory's strategic critic and
  idea-honer. It **hardens every PM spec** for real-user value, maintainability,
  and execution risk — posting concrete `GV-CHANGES` until it's top-notch, then a
  `GV-SIGNOFF` (a hard gate on the PM). It also **advises the captain** on plans
  and big calls — is now the right time, is this the right shape, is the swarm
  even the right tool for a cross-cutting refactor — advisory there, not a gate.
  It writes no code: it thinks, it doesn't authorize.
- **IMPL1–3** (generalists): each surveys open issues + in-flight PRs, skips PM
  drafts and any issue already resolved on a shared branch, picks the
  **lowest-collision, oldest** eligible issue, and **immediately opens a draft
  PR** (`Closes #N`) as a public claim before coding. One issue = one branch =
  one PR. They loop: address review feedback, wait while a PR is in review, or
  claim the next issue once one merges — never stalling idle.
- **QA1–3** (paired by branch prefix): review only `implN/*` PRs, run the fast
  gate, and **squash-merge green ones into `staging`** (preserving `Closes #N`).
  No e2e here — kept fast and parallel-safe.
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
  with you. The role, workflows, and hard-won quality lessons live in
  [`prompts/captain.tmpl`](prompts/captain.tmpl).

The e2e lock (`~/.fun-with-friends/e2e.lock`, atomic `mkdir`) serializes e2e so
its single-port suite never collides.

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
`FWF_BOOT_TIMEOUT`, `FWF_CLAUDE_CMD`, `FWF_WORKSPACE_BASE`, colors. Prompts are
templates in `prompts/` — the source of truth.

## Commands

```
fwf start <url|path> [--name N] [--yes] [--build]   clone → detect → confirm → provision → up
fwf init  <url|path> [--name N] [--yes]             clone → detect → scaffold profile
fwf provision [--build]                             create worktrees + dev data
fwf up [--floor-only]                               launch both sessions (--floor-only: rebuild just the
                                                    floor around a live captain)
fwf attach [coord|build]                            attach to coordination (default) or implementation
fwf captain [--print]                               copy/print the CAPTAIN prompt
fwf respawn <role>                                  hot-swap one pane (implN|qaN|conductor|pm|gv|captain)
fwf stop | resume [--clear-only]                    graceful halt / clear sentinel + re-arm all roles
fwf down [--purge|--floor-only]                     kill both sessions (--purge: remove worktrees too;
                                                    --floor-only: keep the captain running)
fwf shell [--rebuild]                               containerized toolchain sandbox (docs/containers.md)
fwf doctor | profiles | templates | version | help  (version also: -v, --version)
```

Use `--profile NAME` (or `FWF_PROFILE=NAME`) to pick among profiles; with only
one profile present it's selected automatically.

### Sizing, models, and factory templates

`start` / `provision` / `up` / `respawn` / `resume` / `down` also take:

```
--template NAME      factory design template: the role-prompt set the agents run.
                     Shipped: dev (default — the feature factory described above),
                     refactor (behavior-preserving refactoring factory; see
                     docs/refactor-factory.md), ideation (idea-portfolio factory;
                     see docs/ideation-factory.md). List them: fwf templates
--pairs N            number of implementer/QA pairs (default 3; refactor: 2)
--model M            model for every agent (claude --model M)
--impl-model M       per-role override; likewise --qa-model, --pm-model,
                     --gv-model, --captain-model, --conductor-model
```

All of these persist in a profile as `FWF_TEMPLATE`, `FWF_PAIRS`, `FWF_MODEL`,
`FWF_MODEL_<ROLE>`. A template may ship its own defaults (`template.sh`);
precedence is CLI/env → profile → template → stock.

## Notes & caveats

- **`--dangerously-skip-permissions`** runs in every pane: implementers push
  branches, QA merges to `staging`, the conductor merges to `integration`, all
  without prompts. `fwf up` clears the one-time bypass-accept screen. Run this
  only on repos and machines where that is acceptable.
- **The swarm never touches the default branch** — `staging` and `integration`
  are its only shared branches; you alone promote `integration → main`.
- **Per-tree build dirs can be large** (ten worktrees). Don't `--purge`
  between runs unless retiring the factory; keep builds warm.
- **Issue auto-close** requires the `Closes #N` text to ride a commit onto the
  default branch; the implementer puts it in the PR body and QA preserves it in
  the squash commit, so it closes when you promote `integration → main`.
- **Release freeze:** ask the PM to "freeze for release" and it labels tickets
  that should wait with `release-hold` (implementers skip them, like
  `product-wip`), so in-flight work drains to a clean `integration` you can
  release. Authorize the PM to "lift the freeze" afterward.

## Development

```bash
bash test/run.sh        # functional suite: detection, profile generation, dispatcher
shellcheck -S warning fwf *.sh lib/*.sh profiles/*.sh test/run.sh
```

CI runs both on every push to `main` and on PRs (Linux + macOS). Cutting a
release is documented in [`RELEASING.md`](RELEASING.md); see
[`CHANGELOG.md`](CHANGELOG.md) for what shipped in each version.

## License

[MIT](LICENSE) © 2026 Michael Tanenbaum
