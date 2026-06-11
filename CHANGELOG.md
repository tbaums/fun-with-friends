# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-06-10

### Added
- **Comprehensive docs**: a hands-on **[tutorial](docs/tutorial.md)** covering
  the whole surface (driving the factory, floor lifecycle, sizing/models, all
  four templates, authoring custom templates, evals, the container sandbox),
  per-feature design docs under `docs/`, and a README overhaul (factory
  templates section, docs index, atomic-claim + floor-lifecycle pipeline
  updates).
- **Factory design templates** (`--template NAME`, `FWF_TEMPLATE`, `fwf
  templates`): a template is `templates/<name>/` — six role prompts plus an
  optional `template.sh` of config defaults. The classic factory moved to
  `templates/dev/` and stays the default. Templates can inherit prompt files
  from a base (`FWF_TEMPLATE_BASE`) and declare **extra roles/panes**
  (`FWF_EXTRA_ROLES="name:session:interval[:color]"`) honored by
  up/respawn/resume/provision/purge and the floor lifecycle. (#10, #17)
- **`refactor` template** — a behavior-preserving refactoring factory:
  planner ranks debt by churn×complexity evidence, refactorers characterize
  first and transform in gate-green mechanical steps (never editing test
  expectations, never fixing bugs in-band), verifiers run diff-first
  behavior-contract review, the captain sequences releases with pre-assignment
  as the norm. Research basis in `docs/refactor-factory.md`. (#10)
- **`ideation` template** — an idea-portfolio factory: stance-diverse
  generators (user-pain / analogy / constraint-inversion) diverge before
  reading the portfolio, critics harden feasibility while protecting novelty,
  a synthesizer clusters/cross-pollinates/ranks pairwise into
  `ideas/PORTFOLIO.md`, and the captain owns the diverge/converge cadence.
  Research basis in `docs/ideation-factory.md`. (#9)
- **`dev-sre` template** — dev + a dedicated prod-ops (SRE) pane implementing
  the captain-split contract (`docs/captain-split.md`): total ops ownership,
  upward-only reporting, deploy mechanics + live verification on the captain's
  instruction; the overridden captain does ZERO ops actions while it runs. (#4, #17)
- **Runtime sizing + models**: `--pairs N` and `--model M` /
  `--impl-model` / `--qa-model` / `--pm-model` / `--gv-model` /
  `--captain-model` / `--conductor-model` on
  start/provision/up/respawn/resume/down (persistable as `FWF_PAIRS`,
  `FWF_MODEL`, `FWF_MODEL_<ROLE>`; precedence CLI/env → profile → template →
  stock). (#7)
- **Floor lifecycle**: `fwf down --floor-only` idles everything except the
  captain pane (its session/context untouched); `fwf up --floor-only`
  recreates and re-arms only what's missing around the live captain. Both
  idempotent — the captain can now cycle the floor autonomously for token
  conservation. (#6)
- **Eval harness** (`fwf eval`): role-level model evals — the role's
  production prompt × a scenario fixture × candidate models, scored by an LLM
  judge against per-scenario rubrics; 6 scenarios shipped across the three
  template families; hermetic stub mode for CI. `docs/eval-harness.md`. (#8)
- **Atomic claim protocol**: implementers take a CLAIM-comment mutex
  (first-in-thread wins, stale claims expire) before branching, killing the
  duplicate-claim race; the captain pre-assigns (`ASSIGNED implN`) at
  high-contention moments like batch releases. (#2)
- **`fwf shell`** + `containers/Dockerfile`: a reproducible Linux toolchain
  sandbox (bash/tmux/git/gh/claude) with host auth injected at run time —
  including the macOS-Keychain extraction both gh and claude need.
  Containerization design doc in `docs/containers.md`. (#3)

### Fixed
- Prompt delivery now types in 1KB chunks with `--` option-parsing guards:
  role prompts past ~10KB hit tmux's `send-keys` argument limit ("command too
  long"), and a chunk boundary starting with `-` was parsed as a tmux flag. (#17)
- A profile's own `${FWF_PAIRS:-N}` default can actually fire now — the
  stock default moved behind profile/template loading. (#10)
- `scripts/package.sh` was broken by the `prompts/` → `templates/` move; the
  release tarball now ships `templates/`, `docs/`, the eval harness +
  scenarios, and `containers/Dockerfile`.

## [0.2.1] - 2026-06-05

### Changed
- The CAPTAIN now surfaces pending human decisions on EVERY loop tick: a numbered
  "⛔ NEEDS YOU" list (unanswered PM questions, GV escalations, GV-signed-off
  drafts awaiting a go-ahead, and its own blocked calls) printed under the status
  table — so a question parked in a GitHub thread never stays hidden from you.
  Its loop tick is now 2m (was 10m) to keep this timely.
- `fwf resume` now re-arms every role's loop for the active profile (respawns all
  panes) after clearing the STOP sentinel — no more hand-running a respawn loop.
  Pass `--clear-only` to clear the sentinel without touching panes; if the
  sessions aren't running it clears and points you at `fwf up`. The canonical
  role list now lives in one place (`fwf_all_roles`).

## [0.2.0] - 2026-06-05

### Added
- **Grand Vizier (GV)** — a new strategic critic / idea-honer role. It hardens
  every PM spec for real-user value, maintainability, and execution risk via
  concrete `GV-CHANGES` comments until top-notch, then posts a `GV-SIGNOFF` — a
  HARD GATE: a PM draft is not "ready" until the GV signs off. It also ADVISES
  the captain on plans and big calls (is now the right time, the right shape, is
  the swarm even the right tool for a cross-cutting refactor) — advisory there,
  not a gate. Bounded iteration (~3 rounds, then escalate one question). Runs
  read-mostly; critiques only via GitHub comments; writes no code and never
  authorizes — it thinks, the human authorizes.
- `fwf -v` / `fwf --version` as aliases for `fwf version`.

### Changed
- **Two-session architecture.** The factory now runs as a COORDINATION session
  (`PM · GV · CAPTAIN` — you attach here and talk to the captain) and an
  IMPLEMENTATION session (`impl1-3 · qa1-3 · conductor`, with the conductor a
  full-height 4th column). The two coordinate through the issue tracker + git,
  never across panes. `FWF_SESSION` is now a base name; `FWF_COORD_SESSION` /
  `FWF_BUILD_SESSION` derive from it. Added `FWF_GV_INTERVAL` / `FWF_CAPTAIN_INTERVAL`.
- **TEAM LEAD → CAPTAIN** (breaking). The orchestrator is renamed and now runs as
  a looped pane in the coordination session (previously a separate standalone
  session you ran by hand). It hones its plans and decisions with the GV before
  committing to them, but still confirms irreversible actions (deploys, releases)
  with the human. CLI: `fwf lead` → `fwf captain`; prompt: `prompts/lead.tmpl` →
  `prompts/captain.tmpl`.
- **PM** now treats a draft as ready only after the GV's `GV-SIGNOFF`, and folds
  `GV-CHANGES` into the spec like reviewer feedback — same single `product-wip`
  gate, no new label.
- `fwf attach` takes an optional target: `coord` (default) or `build`.
- Provisioning adds two worktrees: `captain` (warmed — it does releases + deep
  work) and `gv` (read-mostly).

## [0.1.7] - 2026-06-05

### Changed
- All swarm prompts now require a `Co-Authored-By: Claude <noreply@anthropic.com>`
  trailer on every commit (lead, implementer, qa, and the stop checkpoint),
  reversing the prior rule that forbade Claude attribution. The conductor
  (ff-only merges) and pm (issues/comments) author no commits and are unchanged.

## [0.1.6] - 2026-06-05

### Changed
- PM prompt: draft a first-pass spec for unspecced gated drafts — issues the
  human files directly on GitHub (empty or stub body) that never went through the
  pane-entry path — every cycle, independent of comment-newness.

## [0.1.5] - 2026-06-05

### Changed
- Harden tmux prompt delivery against wedged/garbled input buffers: clear each
  pane's composer with `Ctrl+U` before typing (launch, respawn, stop), and
  replace `fwf-stop`'s ineffective `Ctrl+A`/`Ctrl+K` clear (readline keys this
  TUI ignores). Launch claude with `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` for atomic
  redraws — configurable via `FWF_CLAUDE_ENV` (e.g. add `CLAUDE_CODE_NO_FLICKER=1`,
  or set it empty to disable).

## [0.1.4] - 2026-06-05

### Added
- `fwf lead` — copies the TEAM LEAD prompt (rendered for the active profile) to
  the clipboard, or prints it with `--print`, and tells you where to start the
  orchestrator session. The lead is a separate interactive session, not a grid
  pane, so this is how you stand it up.

## [0.1.3] - 2026-06-05

### Fixed
- `fwf` failed with `config.sh: No such file or directory` when launched via the
  `install.sh` symlink — it now resolves symlinks to find its real install dir.

### Changed
- The functional suite and CI lint only the repo's shipped scripts
  (`profiles/example.sh`), so a user's local or generated profile in `profiles/`
  can no longer turn the build red.

## [0.1.2] - 2026-06-05

### Changed
- TEAM LEAD prompt (`prompts/lead.tmpl`): always lead reports with a factory
  status table — in progress / queued / done in the last 24h — with Started,
  Completed, and Duration columns, plus how to source the timestamps.

## [0.1.1] - 2026-06-05

### Changed
- CI/release workflows: bump `actions/checkout` from v4 to v5 (v4 runs on the
  deprecated Node 20 runtime).

## [0.1.0] - 2026-06-05

First tagged release.

### Added
- **`fwf` launcher** — point it at a git repo and it stands up the 8-pane tmux
  swarm. `start`/`init` clone a URL (or adopt a local path), detect the
  toolchain, show the inferred commands for review, scaffold a profile, provision
  worktrees, and launch. Plus `provision`, `up`, `attach`, `respawn`, `stop`,
  `resume`, `down`, `doctor`, `version`, `profiles`, `help`.
- **Ecosystem auto-detection** (`lib/detect.sh`) for Rust, Node
  (npm/pnpm/yarn/bun), Go, and Python — proposing gate/build/e2e/dev commands,
  with Playwright/Cypress and typecheck/lint awareness.
- **Profile generation** (`lib/profile.sh`) with a fail-closed gate when the
  ecosystem is unknown, so QA never silently merges on an undetected repo.
- **Per-repo workspace** under `~/.fun-with-friends/workspaces/<name>` so eight
  worktrees stay out of `$HOME`.
- **bash 3.2 floor guard** (the scripts are 3.2-clean, so macOS's stock bash
  works) and a `doctor` preflight for tmux/git/gh/claude.
- **Functional test suite** (`test/run.sh`, 42 checks) and CI: lint
  (`shellcheck -S warning` + `bash -n`) plus the suite on Linux and macOS, and a
  tag-driven release workflow that packages a generic tarball.
- **TEAM LEAD orchestrator prompt** (`prompts/lead.tmpl`) — the interactive role
  the human drives the project from.
- MIT license, release runbook (`RELEASING.md`), and an URL-first README.

[Unreleased]: https://github.com/tbaums/fun-with-friends/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tbaums/fun-with-friends/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tbaums/fun-with-friends/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tbaums/fun-with-friends/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/tbaums/fun-with-friends/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tbaums/fun-with-friends/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tbaums/fun-with-friends/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/tbaums/fun-with-friends/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/tbaums/fun-with-friends/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/tbaums/fun-with-friends/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tbaums/fun-with-friends/releases/tag/v0.1.0
