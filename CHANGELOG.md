# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/tbaums/fun-with-friends/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/tbaums/fun-with-friends/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tbaums/fun-with-friends/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tbaums/fun-with-friends/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/tbaums/fun-with-friends/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/tbaums/fun-with-friends/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/tbaums/fun-with-friends/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tbaums/fun-with-friends/releases/tag/v0.1.0
