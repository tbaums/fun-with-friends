# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.3] - 2026-06-18

### Added
- **Test coverage for the `fwf dash` data layer** (#52, #53). The bash provider
  (`fwf-dash-data.sh`) — the dash's read/derivation logic, previously untested —
  is now sourceable and covered: `captain_sequences_releases` by template, a
  `decisions_json` regression for #51 (gated + GV-SIGNOFF surfaces in dev, not
  refactor), and `activity_json` PR bucketing + role/issue branch parsing (with
  stubbed `di_read`/`gh_pr`). Added Rust unit tests for the Activity-tab pure
  functions (`checks_glyph`, `activity_row_line`, `activity_summary`,
  `Activity::flat`). (Remaining gaps tracked in #54 render/golden snapshots and
  #55 key-handling/`run_action`.)

### Changed
- **Running-template resolution is now opt-in** (`FWF_USE_RUNNING_TEMPLATE`, set
  by the dash) so the machine's persisted run-state can't leak into tests or
  ordinary commands; they keep the dev default. Refines #51.

## [0.11.2] - 2026-06-18

### Fixed
- **`fwf dash` reflects the running factory's template; refactor Decisions tab
  no longer shows false "needs you" rows** (#51). The dash defaulted the template
  to `dev`, so a running `refactor` factory was labelled "dev" and its gated +
  GV-SIGNOFF items appeared as human go/no-go decisions — but in refactor the
  captain sequences those releases. `fwf up` now persists the active template
  (`$FWF_RUN/template`, cleared by `fwf down`); `lib.sh` resolves it when none is
  set, so read-only tools show what's actually running. In captain-sequenced
  templates the Decisions tab no longer infers a human decision from gated +
  GV-SIGNOFF (genuine release decisions and the needs-you banner are unchanged;
  dev behaviour is unchanged).

## [0.11.1] - 2026-06-18

### Fixed
- **`fwf dash` blockquote callouts are legible again** (#50). Detail-pane
  blockquotes (the `> **GATED …**` / `> **Metrics note:**` callouts) were
  styled `DarkGray` — ANSI bright-black, near-invisible on dark terminals.
  They now use the terminal's default foreground (can't be low-contrast on
  any theme), keeping italic for distinction.

## [0.11.0] - 2026-06-17

### Changed
- **`fwf dash` Activity rows now lead with the issue, not the PR** (#40). The
  Activity tab keyed on PR number (merged rows led with `#PR`) while the Issues
  tab keys on issue number, so the two didn't line up. Every Activity row now
  leads with the **issue** (`#497 …`) with the PR as an explicit `· PR N` tag;
  rows with no linked issue lead with `PR N`.

### Added
- **`fwf dash` "REVIEW → main" group** (#40). Open PRs straight to the default
  branch (outside the staging/integration factory pipeline — often human-authored
  with no linked issue) now appear in their own group, so a direct-to-main PR is
  findable instead of showing nowhere.

## [0.10.1] - 2026-06-16

### Fixed
- **`fwf dash` needs-you banner fired permanently** (#40). The captain prints
  "⛔ NEEDS YOU — nothing right now" as a standing status line every tick, so
  matching that substring lit the banner always. It now triggers only on an
  active interactive selection menu ("Enter to select" footer) — present solely
  while the captain is actually awaiting your choice.

## [0.10.0] - 2026-06-16

### Added
- **`fwf dash` surfaces "CAPTAIN NEEDS YOU"** (#40). The Decisions tab only knew
  the gh label protocol (gated issue + `GV-SIGNOFF`), so the dash could read "0
  decisions" while the captain was blocked on an in-pane decision (a "NEEDS YOU"
  state or interactive menu — e.g. a ship/release call). The data provider now
  reads the captain pane directly and emits `needs_you {active, summary}`; the
  dash renders an unmissable full-width red **⛔ CAPTAIN NEEDS YOU — <question> ·
  attach: tmux attach -t friends-coord** banner below the tabs, on every tab.
  Derived-first (pane read), independent of the gh labels.

## [0.9.0] - 2026-06-16

### Added
- **`fwf dash` Activity tab — live factory motion** (#40). A new landing section
  that answers "what's the factory *doing*", derived from PRs against the
  integration targets: **BUILDING** (draft PRs — an implementer still working,
  per role + issue + CI state), **IN TEST / REVIEW** (ready PRs handed to QA, with
  an aggregate check glyph ✓/●/✗), and **MERGED (recent)** (promotions to
  staging/integration with time). Selecting a row loads that PR's full detail
  (body + checks + comments) in the preview via the lazy-detail worker (the detail
  provider tries the issue view, then falls back to `gh pr view`). Sections are
  now `1 Activity / 2 Roles / 3 Decisions / 4 Issues`. Data stays in bash
  (`activity_json`, gh-only); the binary renders.

### Fixed
- Dash footer's Decisions legend showed the old `n` for reject; corrected to `x`.

## [0.8.1] - 2026-06-16

### Fixed
- **`fwf dash` showed every role "down" when displayed in a different tmux than
  the factory** (#40). The dash may run inside a separate tmux session (e.g. to
  forward the mouse wheel to the TUI), but `fwf up` puts the factory on tmux's
  default socket. Role detection used the inherited `$TMUX`, so it queried the
  wrong server and read every pane as down even with the swarm live. The data and
  action layers now `unset TMUX`, so pane liveness is read — and role/captain
  controls are driven — on the factory's socket regardless of where the dash is
  shown. Board data (issues/decisions, from `gh`) was unaffected.

## [0.8.0] - 2026-06-16

### Added
- **`fwf dash` — a read-only status board** (#40, milestone 1). A compiled
  Rust + ratatui TUI (new `dash/` crate) that shows the factory at a glance:
  roles (← tmux pane liveness), pipeline (← git branch deltas), prod, and the
  human-gated decision list (← the `product-wip` + `GV-SIGNOFF` label
  protocol). Derived-first, so it works with the factory parked, and overlays
  the captain's `status.json` when fresh. Three sections (Roles / Decisions /
  Issues) with a scrollable, lightly-markdown-styled detail preview. Keyboard
  model from the prior-art research — **no F-keys**: `j`/`k` + arrows nav,
  `Tab`/`Shift-Tab` + `[`/`]` + `1`/`2`/`3` section switch, `PgUp`/`PgDn` +
  `Ctrl-u`/`Ctrl-d` (and mouse wheel) preview scroll, `Ctrl-r` refresh, `?`
  help, `q` quit. The data layer stays in bash (`fwf-dash-data.sh`, the gh-dash
  model) so the gh/local backend abstraction and profile resolution remain in
  one tested place; the binary is purely the renderer. Builds on first run
  (`cargo build --release`); CI gains a cargo build/test/clippy/fmt job.
  Replaces the retired fzf prototype (PR #41).
- **`fwf dash` actions — the decision inbox + controls** (#40, milestone 2).
  On the proven read-only foundation: **`y`** approve (un-gates by removing the
  WIP label + posts the go-ahead) / **`x`** reject on a decision, **`c`**
  comment (inline text field) and **`o`** open (browser for gh, detail for
  local) on decisions and issues, **`r`** respawn / **`s`** stop on a role, and
  **`t`** to send a line to the captain from anywhere. Mutating actions confirm
  first (or take typed text in an inline modal) and run on a worker thread, so
  a slow gh call never freezes the board; the result lands in a colour-coded
  status line and the board auto-refreshes. The write side stays in bash too
  (`fwf-dash-act.sh`) behind the same gh/local abstraction, with an
  `FWF_DASH_DRYRUN` seam (prints the constructed command instead of running it)
  that both the hermetic tests and cautious operators use; in local-issues mode
  writes route to the local store and never reach gh (the #34 guard).
- **`fwf dash` detail threads + scroll/mouse polish** (#40, milestone 3, from
  UAT feedback). The detail pane now shows the selected row's **full thread
  (body + comments)**, lazily fetched for that row only on a dedicated worker
  thread (the per-tick board snapshot stays cheap); after you comment / approve
  / reject it re-pulls so your just-posted comment shows at once. `n`/`p` scroll
  the detail pane (reject moved off `n` to **`x`**); the launcher enables tmux
  `mouse on` for the session so the wheel works wherever the dash is stood up.
  The detail provider pulls the thread as JSON (`gh`'s `view --comments` is
  TTY-only and emits nothing as a subprocess).

## [0.7.1] - 2026-06-13

### Fixed
- **Browser-MCP preflight false-negative** (#42). The `user-testing` preflight
  detected the Playwright MCP with a live `claude mcp list` probe, which opens a
  connection to each server — so a registered-but-momentarily-unconnectable MCP
  read as "not registered" and scared the operator into a needless re-install
  (seen during a wide sweep: the MCP was ✔ Connected yet the probe reported it
  missing). Detection now reads the config registry directly (`~/.claude.json`
  `mcpServers`, user scope or any project; override with `CLAUDE_CONFIG` /
  `UT_BROWSER_MCP_NAME`), which is authoritative for "registered" and independent
  of transient connectivity.

## [0.7.0] - 2026-06-13

### Added
- **`user-testing` factory template** (#42). A versioned template whose instance
  is 3 personas + 1 researcher + captain — whacky, unscripted, **source-blind**
  users who drive the product like real humans (not like an LLM writing tests),
  a researcher who dedupes their diaries into a ranked top-10 findings report,
  and a captain who grades the trial against ground truth and gates which
  findings graduate to real tickets.
  - **Personas are structurally source-blind**: they get NO worktree — only a
    browser (Playwright, used interactively as hands) against a profile-declared
    `UT_APP_URL`, plus a throwaway scratch dir for diary + screenshot evidence.
    An agent that has read the code can't un-know the intended flow, so the blind
    run is enforced by construction, not just by prompt.
  - **Persona contract**: character card + assigned goal (never a script),
    EXPECT → ACT → OBSERVE think-aloud per step, a screenshot after every action,
    at least one mobile-viewport persona, and a hard ban on writing test files or
    assertions. The researcher writes a report doc for human grading (trial one
    does not auto-file) and may read the target's tracker only AFTER sessions end.
  - **Prod-target refusal**: a trial runs only against an isolated scratch/UAT
    instance — fwf refuses a prod-looking `UT_APP_URL` (fail-closed allow-list;
    a human overrides one launch with `FWF_UT_ALLOW_TARGET=1`).
  - **Browser provisioning** (trial-one learning): personas drive a real browser
    via a Playwright MCP. `fwf provision`/`up` now run a preflight for the
    `user-testing` template — if the `playwright` MCP is missing they print the
    exact one-time setup (`npx playwright install firefox` +
    `claude mcp add playwright …`) and keep going, or install it with
    `FWF_UT_SETUP_BROWSER=1`. Browser defaults to **Firefox** (`UT_BROWSER`).
  - **Per-persona app isolation** (trial-one learning): `UT_APP_URL_<id>` gives
    each persona its own app instance, avoiding the shared-backend bleed that was
    the scorecard's #1 false-signal source. Each per-persona URL is prod-guarded
    too. The researcher prompt now quarantines cross-session bleed rather than
    reporting it as a finding.
  - **Coverage beat**: the persona prompt nudges at least one desktop persona to
    open every nav destination and try the app's keyboard shortcuts (incl. Help)
    once across a session — as curiosity, not a scripted sweep — closing the
    coverage-gap recall misses without losing the unscripted spirit.
  - **Runbook**: [`docs/user-testing.md`](docs/user-testing.md) — the full
    trial sequence (browser setup → profile → provision → up → conclude/grade),
    the prod-target guard, per-persona isolation, and every knob.
- **Worktree-less and suppressible roles in the engine** (#42). Two additive,
  default-empty knobs a template may declare: `FWF_NO_WORKTREE_ROLES` (a role
  gets a throwaway scratch dir instead of a git worktree) and
  `FWF_SUPPRESS_ROLES` (a stock role the factory does not launch/provision/arm —
  matched by tag or family). `user-testing` uses them to repurpose impl1-3 as
  source-blind personas and suppress qa/conductor/gv. Every existing template is
  byte-for-byte unaffected (the knobs short-circuit when empty).

## [0.6.3] - 2026-06-12

### Changed
- **Loop ticks no longer re-inject the full role prompt** (#38). Arming now
  delivers the rendered role prompt ONCE (and persists it to
  `~/.fun-with-friends/prompts/<profile>-<role>.prompt`), then starts the
  loop with a one-line tick that tells the agent to re-read the file if it
  has compacted and run one cycle — ~284B per tick instead of the full
  multi-KB prompt (the captain's 2-minute loop was re-pasting ~6.4KB every
  tick). Cuts context burn and compaction churn for every role, and ends
  the "something keeps pasting into my pane" confusion. fwf-up and respawn
  share the new `fwf_arm_pane`.

## [0.6.2] - 2026-06-12

### Fixed
- **`fwf respawn <role>` now recovers a pane that closed entirely** (#36).
  Previously a fully-gone pane (claude-update crash, OOM kill, accidental
  close) was unrecoverable: respawn required a live labeled pane and
  `fwf up` refused around existing sessions — a dead captain beside a live
  floor needed hand-rolled tmux surgery. Respawn now creates + labels a
  fresh pane when the role's pane is missing (qaN tucks back under its
  paired IMPLN; coordination panes re-balance; the build grid is left
  un-flattened) and arms it normally. Pane label/color composition moved
  to shared lib.sh helpers so launched and recovered panes are
  indistinguishable across all templates.

## [0.6.1] - 2026-06-12

### Security
- **Local-issues mode now hard-guards `gh` writes, not just pushes** (#34).
  A real incident showed the gap: with the tracker local, an agent that
  resolved the wrong backend (the #30 ordering bug, fixed in 0.6.0) or that
  simply couldn't find `fwf` on a pane's non-login PATH fell back to real
  `gh` and wrote issues/labels/comments onto a company repo. Now, in
  `--issues local`, every pane launches with a guard directory first on
  PATH containing (a) a `gh` wrapper that fail-closed blocks every mutating
  command — `issue/pr/label/... create|comment|edit|merge|close`, `api`
  with non-GET methods, unknown verbs — unless a human authorizes that
  single invocation with `FWF_ALLOW_GH=1` (reads pass through), and (b) an
  `fwf` symlink so the local-issues CLI is always resolvable and the
  fallback is never needed. Installed by provision and re-asserted by every
  `fwf up`; the captain's upstream-PR duty now uses `FWF_ALLOW_GH=1`
  alongside `FWF_ALLOW_PUSH=1`.

## [0.6.0] - 2026-06-12

### Fixed
- **Profile-persisted `FWF_TEMPLATE`/`FWF_ISSUES` actually win now** (#30).
  config.sh pre-filled both before the profile loaded, so the documented
  `${FWF_TEMPLATE:-ideation}` idiom silently launched the dev factory.
  Defaults now apply in lib.sh after profile+template sourcing (same fix
  FWF_PAIRS got in #10), and `fwf up` prints the resolved
  `template · issues · pairs · profile` line BEFORE any pane boots, so a
  mismatch is visible immediately.

### Changed
- **Each factory design now looks like itself** (#31): non-dev templates get
  template-bearing session names (`friends-ideation-coord/-build` — dev keeps
  the classic names), role-display pane labels (`GEN1 · IMPL1 · diverge →
  idea briefs`, `SYNTH · CONDUCTOR · portfolio synthesis`, `FRAMER · PM`;
  refactor wears `REFAC`/`VERIF`/`PLANNER`), a persistent `[template]` tag in
  the tmux status bar, and a template-aware launch summary. Canonical role
  tokens stay in every label, so respawn/floor matching is unaffected.
  Templates set their identity via `FWF_DISPLAY_*`/`FWF_DESC_*` in
  template.sh. NOTE: a non-dev factory launched on ≤0.5.1 uses the old
  session names — bring it down with the old version (or set
  FWF_COORD_SESSION/FWF_BUILD_SESSION) before upgrading.
- LICENSE/README copyright unified to Jamie Tanenbaum; private-project
  examples in docs/containers.md generalized (pre-public audit).

## [0.5.1] - 2026-06-11

### Security
- **Local-issues mode never touches the remote** (#28). Previously
  `--issues local` still pushed branches to origin (staging/integration at
  provision; work branches + PRs from the floor) — unacceptable against
  repos whose remote the operator doesn't control. Now: provision creates
  the branch ladder **locally only** and installs a **pre-push guard** in
  the repo blocking every push (from any worktree) unless a human
  authorizes that single push with `FWF_ALLOW_PUSH=1`; the guard is removed
  by a gh-mode re-provision. The floor flow is fully local — implementers
  hand off via `READY-FOR-REVIEW` comments instead of PRs, QA squash-merges
  into local staging on a detached-checkout discipline, the conductor
  promotes locally without fetch/pull/push — and the captain is the sole,
  explicitly-human-authorized exception for pushing or opening an upstream
  PR (body mined from the local issue reasoning).

### Fixed
- gh-mode re-provision on a repo that previously ran local mode removes the
  guard *before* pushing the ladder (it used to block itself).

## [0.5.0] - 2026-06-11

### Added
- **Local issues backend** (`--issues local` / `--local-issues` /
  `FWF_ISSUES`, #26): run the factory against repos whose GitHub
  issues/labels you don't control. The whole bus (gated specs, GV sign-offs,
  atomic claims, approvals, freezes) runs over a markdown store OUTSIDE the
  repo — one self-contained file per issue under
  `~/.fun-with-friends/issues/<profile>/{open,closed}/`, status as the
  directory, labels as a header line, comments appended in lock-serialized
  order (the CLAIM mutex carries over). Driven by the new **`fwf issues`**
  CLI (gh-shaped: create/list/view/edit/comment/close/reopen/export, with
  `--json`/`--jq` and gh-style `--search`), so every role prompt works
  verbatim via two render-time rewrites (`gh issue` → `fwf issues`,
  `#N` → `LI-N` — nothing ever links upstream issue numbers). PRs still go
  to GitHub; the captain closes shipped issues at release and mines the
  store (`fwf issues export`) when writing PR bodies, changelogs, and docs.
  `fwf provision` touches no GitHub labels in this mode.

## [0.4.1] - 2026-06-11

### Added
- **`fwf upgrade [--check]`** — self-upgrade to the latest GitHub release.
  Git-clone installs ff-pull (refusing on a dirty tree); tarball installs
  download the release next to the current dir and re-run its `install.sh`
  to re-point the symlink (old dir kept for rollback). Reminds you that a
  running factory keeps its old prompts until `fwf resume`/`respawn`.
  `FWF_UPGRADE_REPO` targets a fork.

## [0.4.0] - 2026-06-11

### Added
- **`fwf suggest "<goal>"`** — the factory-design advisor (#23): describe what
  you're trying to do and get back a prebuilt-or-custom template
  recommendation, the exact launch command, per-role model picks with
  rationale (menu in `FWF_MODEL_MENU`), a complete `template.sh` sketch when
  custom is warranted, and the `fwf eval` commands that would verify the
  riskiest picks. Reads the installed template catalog dynamically; needs no
  profile.
- Extra roles now honor `FWF_MODEL_<NAME>` (e.g. `FWF_MODEL_SRE`) instead of
  only the floor-wide model default.

### Fixed
- The portable timeout watchdog (eval harness + suggest) no longer orphans
  its `sleep`, which held captured-stdout pipes open and could block callers
  for the full timeout.

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

[Unreleased]: https://github.com/tbaums/fun-with-friends/compare/v0.6.3...HEAD
[0.6.3]: https://github.com/tbaums/fun-with-friends/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/tbaums/fun-with-friends/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/tbaums/fun-with-friends/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/tbaums/fun-with-friends/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/tbaums/fun-with-friends/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/tbaums/fun-with-friends/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/tbaums/fun-with-friends/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/tbaums/fun-with-friends/compare/v0.3.0...v0.4.0
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
