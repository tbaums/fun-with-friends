# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

**Convention:** every item carries two commit refs — code and docs:
`- **Feature** (#NNN, code <sha>, docs <sha>) — …`. Same SHA when docs rode in
the implementing commit; distinct when separate. The docs ref is mandatory and
is the per-item guarantee that the doc changes are in (see `RELEASING.md`).

## [Unreleased]

## [0.30.1] - 2026-08-24

### Changed
- **Default every seat to Claude Code's Concise output style** (#187, code d0719a4, docs d0719a4) — factory seats now run with Claude Code's Concise output style by default, trimming per-turn chatter.

### Fixed
- **`test/run.sh` pass/fail gate is no longer shadowable by a later append** (#242, code 022e14e, docs none — internal) — makes the suite's exit verdict unspoofable.
- **Quote the empty `FWF_OUTPUT_STYLE` so shellcheck (SC1007) stops red-failing staging** (#241, code 24f0181, docs none — internal).

## [0.30.0] - 2026-08-24

### Added
- **`fwf up` coord-only from a cold/fully-down state** (#155, code 36a110a, docs 36a110a) — bring up just PM/GV/Captain (no floor) even when nothing is currently running, so the coordination plane can be (re)started independently.

### Fixed
- **Flaky `test/run.sh` "a full fwf up appends floor-up" test** (#185, code 1f2e664, docs none — internal).

### Internal
- **Regression fixtures capturing the false-AUTHORIZED sentinel behavior** (#218, code cdc2434, docs 305dc2c) — lock in the #191 unanchored-grep authz false-positive as a fixture-backed test before the live threads change, and correct a wrong claim about sentinel position (measure it, don't assume).

## [0.29.0] - 2026-08-24

### Added
- **Durable post-release reconcile enforcement** (#179, code f03d78f, docs f03d78f) — both release paths (the release workflow and direct-to-`main` hotfixes) now *act on* the `fwf reconcile` verdict instead of merely printing it, backed by a new `fwf-reconcile-guard.sh` wired into `ci.yml`/`release.yml`. Closes the staging/integration→`main` divergence that repeatedly jammed the conductor's ff-only promotion and blocked every release (the recurrence of #114).
- **Attributable operator un-gate sentinel** (#152, code 5bc1ca6, docs 5bc1ca6) — a positive, mechanically checkable authorization signal so a role can verify a *human* operator un-gate via `fwf authz` rather than inferring it from prose.

### Changed
- **PR credit lists every seat's model**, not just impl/qa (#134, code 57a98fd, docs 57a98fd).
- **Role prompts name `fwf authz` the sole authorization oracle** (#208, code 330db79, docs none — internal) — removes ambiguity about what counts as authorization.

### Fixed
- **`fwf authz` reads gh comments via JSON**, not the buggy `--comments` renderer (#200, code dd36009, docs none — internal).
- **tick/heartbeat `resolve_profile()` prefers the worktree's provisioned profile** over ambient env (#182, code 8e63c52, docs 8e63c52).
- **Drop unused `role` in `fwf_credit_block`** (SC2034), unbreaking staging (#134, code e86bf6a, docs none — internal).

## [0.28.1] - 2026-08-23

### Fixed
- **`fwf gate` no longer leaks its own profile resolution into the wrapped command** (#175, code 2715947, docs 2715947) — `fwf-gate.sh` sources `lib.sh` to resolve a profile for its lock paths, and doing so sets `FWF_PROFILE`/`FWF_PAIRS`/`FWF_REPO` in its own shell. The wrapped command then inherited an ambient profile it never asked for, silently overriding any fixture env it pinned for itself. The gate now snapshots the caller's real environment BEFORE that resolution and restores it verbatim before handing over — a var the caller had keeps its ORIGINAL value, one the caller lacked is left unset rather than blanked (an empty `FWF_PROFILE` is not the same as an absent one to a `${VAR:-default}` reader). A CORRECT inherited value overrides a fixture exactly as destructively as a wrong one, so this is about provenance, not validity: as a factory `GATE_CMD` — where those vars are always set — it made `test/run.sh` report 41 otherwise-passing tests as RED, so the gate was false-RED on *every* cycle and no implementer could ever reach green. `test/run.sh` additionally unsets `FWF_REPO`/`FWF_PROFILE`/`FWF_PAIRS` for its own hermeticity, so a green run means the code is good rather than that the operator's shell happened to be clean. README documents the gate's environment contract, so a `GATE_CMD` no longer needs an `env -u FWF_*` guard of its own.
- **Test-suite tmux fixtures are isolated onto a throwaway tmux server** (#197, code 01b70e4, docs none — internal) — `test/run.sh`'s real-tmux blocks (the `fwf-up.sh`/`fwf-down.sh` fixtures and their kill-session cleanup) ran against whatever tmux server the caller happened to be on. Run as a factory `GATE_CMD` that caller is a pane INSIDE a live factory, so the fixtures operated on the operator's own tmux server alongside the running swarm and their unrelated sessions — the suite could tear down live factory sessions as "cleanup". It now points `TMUX_TMPDIR` at a per-run directory and unsets `TMUX` before any fixture runs, giving the fixtures a server reachable by nothing else and torn down with the tmpdir; the `EXIT` trap's `tmux kill-server` is scoped to that throwaway socket by the redirected `TMUX_TMPDIR` and cannot reach the caller's server.

## [0.28.0] - 2026-08-15

### Added
- **`fwf flag-captain` — a persisted needs-captain signal** (#113, code 88c5bab, docs 88c5bab) — any role can raise a `needs-captain` flag on an issue/PR (`flag-captain <n> --role R --reason TEXT`), clear it (`--clear [--note]`), or list every open flag (`sweep` → `# · [role] · reason · age`). Works identically in gh-issues and local-issues mode; the label is provisioned at setup and the captain sweeps it every tick. Rebased onto v0.27.5 (the PR had been red for a month purely from a stale July base); shellcheck-clean, +24 passing assertions covering every acceptance criterion.

## [0.27.5] - 2026-08-15

### Fixed
- **Release CI: pane-env chmod assertion is now Linux-portable** (#143 follow-up, code 57ae3fa, docs 57ae3fa) — the `test/run.sh` check for the 0600 pane-env file ran BSD `stat -f '%Lp'` first, which "succeeds" with filesystem output on GNU stat, so the `|| stat -c '%a'` fallback never fired and the test failed only on the Linux release runner (v0.27.4 tag built but never published its binaries). Try GNU `stat -c '%a'` first, BSD `-f '%Lp'` as fallback — passes on both.

## [0.27.4] - 2026-08-15

### Fixed
- **Agent panes inherit env/creds even when the tmux server predates the launch** (#143, code d7a3aaf, docs d7a3aaf) — when the tmux server was already running from an older environment, freshly-created agent panes could miss env/credentials; the launch now ensures each pane gets the current environment.

## [0.27.3] - 2026-08-15

### Fixed
- **`fwf up` auto-provisions when worktrees are missing, instead of failing silently** (#142, code da4a16d, docs da4a16d) — launching with absent worktrees no longer dies quietly; `fwf up` detects the missing state and provisions (or reports clearly) rather than leaving the floor half-created.

## [0.27.2] - 2026-08-15

### Fixed
- **`fwf up`/`provision` no longer break on a local or remoteless repo** (#141, code 27ca352, docs 27ca352) — provisioning/launch against a local path or a repo with no `origin` remote no longer dies silently on a `set -e` exit; the path is fail-loud and works with `--issues local` when there is no remote at all.
- **Factory boot loop-death — first-tick health-gate + monotonic loop-tick counter** (#133, code a908052, docs a908052) — `fwf up` declared the floor "up" the instant claude launched in each pane, but *process-alive is not loop-alive*: an implementer's `/loop` arm could silently fail to register and the role then sat idle forever, never claiming a ticket (last seen: booted, idle ~58min, built nothing). Three fixes: (1) a boot health-gate (`fwf_verify_boot_ticks`) confirms every role fired a REAL first tick, re-arms any laggard once, and hard-respawns any that still won't loop — no manual `fwf respawn` needed (`FWF_SKIP_BOOT_GATE=1` bypasses; window = interval + `FWF_BOOT_VERIFY_MARGIN`, default 45s); (2) a monotonic per-role loop-tick counter (`fwf tick <role>`, superseding the ambiguous heartbeat-mtime touch) that strictly increases once per real iteration, so working (advancing) is unambiguously distinguishable from parked/wedged (static); (3) `fwf-respawn.sh` escalates a failed soft re-nudge to a hard kill+relaunch of the pane and re-verifies, so a respawn can no longer report success while the loop stays dead. Plus `fwf stub-sweep` auto-closes claim-only draft PRs (zero changed files) a dead loop orphaned. Full unit coverage; shellcheck clean.

## [0.27.1] - 2026-07-17

### Fixed
- **Roles can no longer fabricate human authorization** (#150, code 3e7db8a, docs none — internal) — a role read another pane's autosuggest/ghost text as "the human's reply," asserted "I confirmed with them directly," and reverted approved work (re-gated four tickets, closed three PRs). `fwf_render` now prepends a non-negotiable authorization-ground-rules block to every rendered role prompt: no pane content (own or another role's) is human input; never assert an unverifiable confirmation; the `product-wip` gate label is the sole ground-truth authorization signal; under doubt HOLD and post an open question rather than reverting work. Role-aware on one axis — the captain keeps its documented human channel (its own pane), every other role has none. A test asserts the block and the correct channel variant render for every role across template families. Follow-up #152 tracks making the label state attributable (issue #150 ask 3).

## [0.27.0] - 2026-07-15

### Added
- **Skill-runner factory config — Phase 1 (defect→report archetype)** (#117, code 1b1a02c, docs 1b1a02c) — a new `defect-report` factory template set (captain/conductor/qa + eval scaffold with fixtures) that spins up from a (skill, target) pair and drives to a first-shot finished deliverable, plus `docs/defect-report-factory.md`.

## [0.26.0] - 2026-07-15

### Added
- **Auto-reconcile staging/integration to main after a release** (#114, code 08182c2, docs 08182c2) — after a release lands on `main`, the swarm's lower branches (`staging`, `integration`) would sit behind, so agents kept building on a stale base until someone hand-reset them. A new `fwf-reconcile.sh` helper fast-forwards `staging` and `integration` up to `main` post-release (wired into the captain templates), so the floor always builds on the just-released base.

## [0.25.4] - 2026-07-15

### Fixed
- **Gate pileup: per-role single-flight lock + hermetic e2e** (#123, code f4fad92, docs f4fad92) — agents were relaunching `test/run.sh` concurrently and colliding on a shared fixed port, so overlapping gate runs mutually stalled and QA never converged (an hour-plus to ship one small ticket). Every `__GATE__`/`__E2E__` now renders as a call to the new `fwf gate <role> [--e2e] -- <cmd>` shared launcher, which takes a per-role single-flight lock (exits `75` = skip-this-tick rather than stacking a second run) and, under `--e2e`, additionally takes the floor-wide e2e lock; stale/past-`FWF_GATE_LOCK_MAX_RUN_SECS` holders are reaped. A test asserts overlapping runs complete when routed through `fwf gate` and deterministically time out when unwrapped.
- **`fwf upgrade`: git-clone installs converge on the release tag, not main tip** (#125, code f83519c, docs f83519c) — a git-clone install upgraded by `git pull`-ing `main`, which contradicts the "latest release" contract and could ship un-released commits. It now checks out the resolved latest release tag, matching the tarball-install path.

## [0.25.3] - 2026-07-15

### Fixed
- **`fwf resume` / `fwf respawn` no longer crash on the loop interval** (#116, code 07ff2e8, docs 07ff2e8) — the re-arm path did arithmetic directly on the unit-suffixed interval (e.g. `3m`), which errored (`value too great for base`) and left `window` unset, so `resume`/`respawn` failed for every role and the only recovery was a full `down`+`up`. The interval is now normalized to seconds before the arithmetic; a test asserts `stop`→`resume` re-arms all roles.

## [0.25.2] - 2026-07-15

### Added
- **QA reviews adversarially on green gates** (#119, code 0ccd613, docs 0ccd613) — QA no longer just runs the gate + checks docs presence; on a green gate it also reads the diff adversarially (edge cases / failure paths), sanity-checks test efficacy, tries to break the change, checks docs quality, and verifies the artifact conforms to its source ticket — "the GV of the artifact."
- **dash Usage tab: numeric columns no longer collide at large token counts** (#115, code 3a52de9, docs 3a52de9) — right-aligns/sizes the INPUT/CACHE-W/CACHE-R/OUTPUT columns so billion-scale values stay readable instead of merging into one unreadable blob.

## [0.25.1] - 2026-07-15

### Added
- **Captain idles the build floor and the PM/GV plane independently** (#105, code c1eed46, docs c1eed46) — per-plane, workload-driven idle: the captain parks the build floor when the claimable queue is empty, and the PM/GV plane when no grooming/gating is pending, bringing each back the instant work appears — instead of the old all-or-nothing floor idle. Deadlock-guarded (the `product-wip` label is the single captain-owned wake signal; idle is refused with an open PR, an unaddressed draft, or anything mid-promotion; the GV never idles in v1).

## [0.25.0] - 2026-07-14

Two factory-facing improvements, built via the self-hosting factory.

### Added
- **Token budget in dollars: `--budget-usd` + per-run baseline** (#108, code 8cc6e6f, docs 8cc6e6f) — the budget guardrail now accepts a `--budget-usd N` ceiling measured against the estimated-$ figure instead of raw token counts (cache-read-inclusive raw counts made intuitive values like `1000000` instantly HOLD), and captures a per-run usage baseline at `fwf up` so the budget measures THIS run rather than cumulative transcript history. Fail-closed on baseline loss/respawn.
- **PR body context fold-in + "built with fwf" credit** (#106, code 091508b, docs 091508b) — PRs fwf raises fold the sanitized ticket context (problem / decisions / acceptance; fwf vocabulary stripped; body-only, never the comment thread) into the squash-merge message, plus a reviewer-facing "built with fwf + Claude" credit — so an upstream reviewer gets the full *why* without needing to know fwf.

## [0.24.0] - 2026-07-12

Build-provenance stamp: every factory PR now records which fwf checkout and which
per-seat models produced it.

### Added
- **Build-provenance stamp on every factory PR** (#104, code 12cf8f9, docs 12cf8f9) —
  a one-line `fwf-Provenance:` git trailer (`fwf=<ver>@<sha> profile=<name>
  seats=[captain=… pm=… gv=… impl=… qa=… conductor=…]`) is now stamped into both the
  implementer's `gh pr create` body and the QA squash-merge commit across every
  PR-producing template. Adds `fwf_model_for` (per-role model resolver, extracted from
  `fwf_claude_cmd`) and `fwf_provenance_block` in `lib.sh`, exposed through the existing
  `fwf_render` engine as a `__PROVENANCE__` placeholder so the stamp reflects the seat
  assignments actually in force at launch. A coverage test enforces that any template
  running `gh pr create|merge` carries the stamp (`_local-issues` templates, which open
  no upstream PR, are exempt). Makes per-release quality/provenance a derived
  `git log` query instead of a maintained ledger. See
  [docs/proposals/80-build-provenance-stamp.md](docs/proposals/80-build-provenance-stamp.md).

## [0.23.0] - 2026-07-12

New factory template: **`consulting`** — the diagnosis firm.

### Added
- **Consulting factory template** (code 3cc276b, docs 3cc276b) — a 7th shipped
  template built on `validate`: a 3-phase falsification funnel (premise gate →
  cause tournament → empirical replay, replay OFF by default) that diagnoses
  whether an agent-built pipeline's **shipped quality actually regressed** and, if
  so, **why** — treating "quality collapsed" as a hypothesis where `no real
  decline / drift / unverifiable` is a first-class win. Advisory: reads the client
  repo, writes only its own findings repo. Six reframed role prompts
  (framer/registrar · lens-specialist · citation-cop/Red · judge/synthesizer ·
  standing-skeptic GV · phase-state captain), a six-lens coverage gate + mandatory
  other/unknown contender, a README runbook, and three acceptance-fixture
  scaffolds under `eval/`. Adds [docs/consulting-factory.md](docs/consulting-factory.md)
  and a README template-table row. Role prompts carry the v0.22 heartbeat (#99)
  and budget-hold (#96) placeholders.

## [0.22.0] - 2026-07-10

Factory-reliability + operator-visibility release: startup upgrade-staleness
check, token-usage reporting and an optional hard budget, and a set of floor
lifecycle/idle fixes that eliminate the "green but wedged" failure modes.

### Added
- **Startup upgrade-staleness check** (#94, code ee7a1f2, docs ee7a1f2) — fwf
  warns on startup when a newer release is available, and no longer misfires
  when the local build is newer than a stale cached "latest". Implements the #79
  discovery proposal.
- **Token-usage reporting** (#95, code e5fdb80, docs e5fdb80) — a dash Usage tab
  plus an `fwf usage` CLI for per-run/per-role token accounting. From the #70
  proposal.
- **Optional hard token budget** (#96, code 0ca95ae, docs 0ca95ae) — an opt-in
  per-run token ceiling with a `BUDGET_HOLD` sentinel and fail-safe. From the #70
  proposal.

### Fixed
- **`--profile` after the subcommand** now works, with a clearer ambiguity error
  (#69, code d1ce7af, docs d1ce7af).
- **`fwf upgrade` detects worktree installs** and refuses-with-guidance rather
  than falling through to an unsafe pull/tarball path (#78, code 7ffc965, docs
  7ffc965).
- **Shared staging-branch collision** — roles never check out the shared
  `staging` branch from a claim/gate step; this was the root cause of slow /
  blocked promotion (#91, code d44c46b, docs none — internal).
- **Floor lifecycle is observable** — a deliberate floor-idle now writes a
  durable event and the dash shows `IDLE (captain)` instead of `down`, so a
  cost-saving idle is no longer mistaken for a crash (#85, code 4b4afd7, docs
  4b4afd7).
- **Captain idle-thrash guard** — a dwell + post-promote cooldown before
  `--floor-only` teardown, so a brief post-promote lull no longer tears down the
  floor (#88, code 82acef8, docs 82acef8).
- **Implementers resume their own in-flight draft** instead of idling behind a
  claim-only draft PR after a stall/respawn; respawn is now verified off a
  durable per-role heartbeat rather than the pane animation (#99, code 0aca90d,
  docs 0aca90d).

### Documentation
- **Discovery proposals** added under `docs/proposals/`: startup upgrade-staleness
  check (#79, f2f6842) and token-usage reporting + hard budget (#70, 1ec8ccb).

## [0.21.3] - 2026-07-10

Factory-reliability and dash-polish release: a shared-account impl↔qa review
deadlock fix, and a dash keybinding-discoverability fix. No user-facing feature
or behavior-contract changes.

### Fixed
- **dash: `Ctrl-r` refresh is now discoverable on every tab** (#80, code
  9d3dbd1, docs none — internal) — the `Ctrl-r` refresh binding is global (it
  works on all tabs), but only the Activity tab's footer advertised it. The hint
  is now consistent across tabs, so the feature isn't hidden on Roles/Decisions/
  Issues. (Test goldens updated; the binding was already covered by a test.)
- **Shared-account impl↔qa change-request deadlock** (#82, code 88d82cd, docs
  88d82cd) — when all factory roles authenticate as one shared GitHub identity,
  `gh pr review --request-changes` is rejected ("can't request changes on your
  own PR"), so qa posts change-requests as plain PR comments. The implementer
  loop, reading only the formal review API / `mergeStateStatus` (always empty on
  a shared account), treated the PR as un-reviewed and went idle while qa waited
  — a bilateral deadlock. Introduces a structured `QA-CHANGES-REQUESTED` /
  `QA-APPROVED` sentinel-comment protocol (mirroring the proven `GV-*`
  convention), an `fwf-pr-review-state.sh` helper, and `docs/shared-account.md`;
  implementers now treat the latest qa sentinel as authoritative and never infer
  "no changes requested" from an empty review API.

## [0.21.2] - 2026-07-10

Factory-reliability and dash-correctness release: a dash socket-tracking bugfix,
an upgrade-hint fix for worktree installs, broader gh-cache REST routing, e2e
lock coverage across every role, and substantially broadened dash test coverage.
No new user-facing features or behavior-contract changes.

### Fixed
- **`fwf dash` no longer shows every role as "down" when the factory runs on a
  non-default tmux socket** (#62, code 586221e, docs 586221e) — the launch socket
  is now persisted at `fwf up` and read back by the dash/data layer, so a factory
  started inside a named-socket tmux is tracked correctly. Supersedes the "pin to
  the default socket" alternative (#57), which is closed as not-taken.
- **`fwf upgrade` now shows the git-pull hint for worktree installs** (#71, code
  8eab975, docs none — internal) — the checkout probe used `[ -d .git ]`, which is
  false in a worktree (where `.git` is a file), so worktree installs silently took
  the tarball path. It now uses `[ -e .git ]`; covered by a regression test in
  `test/run.sh`.

### Changed
- **`gh` read-cache routes `issue view` / `pr view` (and common `--search`) through
  the REST API** (#58, code 8ec8ec7, docs 8ec8ec7) — pushes residual GraphQL usage
  toward zero on the hot read paths, reducing rate-limit pressure for factory runs.
  Backwards compatible; no change to command surface.
- **`e2e.lock` is now acquired and released by every role, not just the
  conductor** (#65, code 43b2f21, docs 43b2f21) — an implementer's own local e2e
  run could previously kill a sibling worktree's server mid-test. All roles now
  coordinate through the shared lock. (Per-worktree ports deferred as a separate
  design item.)

### Internal
- **Dash render/golden snapshot tests via ratatui `TestBackend`** (#54, code
  b5ac220, docs b5ac220) — golden snapshots for headers, tabs, overlays, and full
  frames guard the dash UI against unintended rendering regressions.
- **Broadened dash `on_key` coverage and `run_action` execution tests** (#55, code
  3cbf362, docs none — internal) — direct unit coverage of key handling and action
  dispatch in `dash/src/main.rs`.

## [0.21.1] - 2026-07-09

Customer-readiness release: safety, docs, and small fixes from a pre-send review.
No feature or behavior-contract changes to the factory itself.

### Fixed
- **`fwf doctor` no longer reports a missing Claude CLI as "all good"; `install.sh`
  guardrails** (code 1ca588e, docs 1ca588e) — doctor probed `${CLAUDE_CMD%% *}`,
  which is always `env` once `config.sh`/`lib.sh` prepend their env/PATH wrappers,
  so an absent `claude` still passed. It now captures `FWF_CLAUDE_BIN` at
  assignment and probes that (same fix in the user-testing browser preflight).
  `install.sh` absolutizes the target dir so the PATH hint is usable with a
  relative argument, and refuses to overwrite a non-symlink `fwf` (re-installing
  over a symlink stays idempotent). Also aligns `release.yml`'s shellcheck file
  set with `ci.yml`.

### Changed
- **Internal references removed for public/customer use** (code 4e4b5d2, docs
  4e4b5d2) — genericized a private project name, a personal browser-preference
  aside, and a foreign tracker's issue refs across docs, code comments, and the
  test/dash fixtures. No runtime behavior change.
- **Shipped role prompts genericized** (code fdef5ea, docs fdef5ea) — the `dev`
  and `user-testing` templates no longer cite one app's doc set, its version
  history, or a named internal postmortem; the underlying review lenses (UI
  container-vs-viewport check, RUNTIME COST & BLAST RADIUS, the canary class) are
  unchanged, so no behavioral contract moved.

### Removed
- **`darwin-x86_64` (Intel Mac) dropped as a prebuilt `fwf-dash` target** (code
  eaba8f3, docs eaba8f3) — no GitHub-hosted runner was available for that leg and
  it stalled the release matrix. Prebuilt targets are now `darwin-arm64`,
  `linux-x86_64`, and `linux-arm64`. On an Intel Mac `fwf dash` builds from source
  on first run (needs `cargo`), or prints a clear "install Rust / set
  `FWF_DASH_BIN`" message — it no longer attempts a download that would 404.

### Documentation
- **Docs synced to v0.21.0 reality** (code 47f7026, docs 47f7026) — README lists
  all six shipped templates and documents `fwf dash` + the `idea` label; `dash.md`
  matches the Activity-tab redesign (keys `1`–`4`, `x` to reject); `RELEASING.md`
  covers the prebuilt dash binaries; stale help text/flags and the test-count
  figure corrected.
- **`fwf dash` screenshot on sample data** (code 0f36f55, docs 0f36f55) — a real
  render of the TUI against dummy fixtures added to the top of `docs/dash.md`.

## [0.21.0] - 2026-06-30

### Added
- **9-archetype persona library + deep sweep mode** (#47, code a42e2af, docs a42e2af). Expands the
  `user-testing` template from 3 persona archetypes to 9 (power user,
  slow-network / low-end device, returning user, privacy-conscious skeptic,
  international / non-native-English user, and accessibility user join the
  original three). Each archetype is a different bug-class lens; the library is
  embedded in every persona prompt so a 3-persona quick gate and a 9-persona deep
  sweep use the same file with no fork. `FWF_UT_MODE=deep` selects all 9;
  `FWF_PAIRS` still overrides. For runs with `FWF_PAIRS > 9`, personas wrap
  around the library and add a personal twist so coverage never degrades. The
  captain and researcher prompts are now persona-count-aware (rendered from the
  live roster), and `fwf up` rebalances the floor layout as it splits so a wide
  sweep (9+ persona panes) launches without running tmux out of pane width
  ("no space for new pane").

## [0.20.0] - 2026-06-30

### Added
- **Prebuilt dash release binaries** (#63, code 7ff60da, docs 7ff60da) — `fwf dash`
  no longer runs `cargo build` on first use. `fwf-dash.sh` resolves a binary in
  order: `FWF_DASH_BIN` → cached arch+version binary → release-asset download
  (sha256-verified against the published checksums file before it's made
  executable, then cached under `~/.fun-with-friends/cache/dash` keyed by
  VERSION+os-arch) → source `cargo build` fallback. Identical offline. The
  release workflow cross-compiles `fwf-dash` for darwin-arm64/darwin-x86_64/
  linux-x86_64/linux-arm64 on native runners and uploads them + a checksums
  asset. Also fixes a latent bug where `fwf-dash.sh` error paths emitted
  `die: command not found` (it sources lib.sh, which doesn't define `die`).

## [0.19.0] - 2026-06-30

### Fixed
- **Implementer self-recovers bounced/conflicting PRs (no idle-deadlock)** (#49, code 770cb0e, docs 770cb0e) — the implementer loop treated an open PR as "idle, awaiting review" and never re-engaged when qa requested changes or `staging` advanced under it (PR went CONFLICTING/DIRTY), deadlocking until a human hand-rebased. It now acts on new-information-since-last-push: rebase onto staging, re-run the full gate, verify the diff still carries the change, push if green; bounded escalation (escalate to captain + stop after a non-trivial conflict / red gate / 2 failed attempts) kills re-push thrash; self-recovery is logged distinctly from idle.

## [0.18.0] - 2026-06-28

### Added
- **Cost/loop GV gates + incident protocol** (#59/#60/#61, code 8c5216d, docs 8c5216d)
  — hardening from an internal narration incident (a working cache's hit-storm log
  was misread as a metered drain and escalated). `gv.tmpl` gains two review lenses:
  RUNTIME COST & BLAST RADIUS (bound any metered/external call or background loop
  with a content+version cache AND a fail-closed breaker; require real-vs-cache-hit
  observability, a verified deploy-plumbed kill switch, and a canary before
  default-ON — #59 + the kill-switch half of #60) and COMPLETE THE FIX (a regression
  fix must test EVERY reported symptom before its parent closes — #61). New
  `docs/INCIDENT_PROTOCOL.md`: verify ground truth before alarming (a log/counter is
  a proxy — confirm real resource use), then stop the bleeding first on a CONFIRMED
  drain (#60); `captain.tmpl` prod-monitoring duty points at it.

## [0.17.1] - 2026-06-28

### Added
- **Auto version-skew warning at launch** (code 75e13f1, docs 75e13f1) — `fwf up`
  now warns (never blocks) when the box's install is behind the latest release,
  pointing at `fwf upgrade` + respawn. fwf flows (e.g. the discovery ticket path)
  live in the templates, which only reach a machine via `fwf upgrade`, so a
  forgotten box would silently run a stale flow; this makes that visible.
  Self-contained (VERSION via `BASH_SOURCE`), throttled to one network check /
  12h, fail-open (offline/unauth/no-`gh` → silent). (`lib.sh` `fwf_version_skew_warn`,
  `fwf-up.sh` preflight, README "Roles" cross-machine note.)

## [0.17.0] - 2026-06-27

### Added
- **Discovery / exploration flow** (code e423ee7, docs e423ee7) — a new
  `discovery` label and path for tickets whose deliverable is a written proposal
  (an investigation plus a build-or-no-go recommendation), not code. An
  implementer that claims a `discovery` ticket produces
  `docs/proposals/<n>-<slug>.md` instead of code; QA gates the proposal's
  substance (grounded estimates, an actionable recommendation), not tests, and
  the proposal doc satisfies the docs definition of done. A GV "scoped" sign-off
  on a discovery ticket routes it to the flow — drop the `product-wip` gate, KEEP
  the `discovery` label so an impl produces the proposal — instead of being
  re-gated into product-wip limbo. The PM labels explorations `discovery` at
  draft; a proposal that recommends building spawns a new build ticket. Fixes the
  loop where a scoped, approved exploration had no role to produce it and stalled.
  (`FWF_DISCOVERY_LABEL`, default `discovery`; `config.sh`/`lib.sh`; the `dev`
  PM/GV/implementer/QA/captain templates; README "Roles".)

## [0.16.1] - 2026-06-27

### Changed
- **CHANGELOG items carry a docs commit ref** (code 593cc79, docs 593cc79).
  Every entry now cites two refs — code and docs — the per-item guarantee that
  doc changes are in for each change (`RELEASING.md`, the CHANGELOG convention
  header). The `dev` implementer template notes that a change's in-PR docs are
  what the release cites as its `docs <sha>`.

## [0.16.0] - 2026-06-27

### Changed
- **User-testing findings route through PM/GV** (`user-testing` template): the
  captain now files every graduated tester finding as `product-wip`, so it
  enters the dev factory's PM → GV-signoff flow instead of being built straight
  from the report. Closes the gap where the fix path bypassed product review.

## [0.15.0] - 2026-06-27

### Added
- **Docs ride in the PR — definition of done** (`dev` template): a
  behavior-changing implementer PR must update its own docs (README, `docs/`,
  in-app help, keyboard-shortcut reference, tutorials) in the same PR, and QA
  now **requests changes** on a behavior-changing PR whose diff didn't touch its
  docs. Pure internal refactors are exempt. The implementer honors a repo
  `CONTRIBUTING.md` if present. Documented in the pipeline section of the README.

## [0.14.1] - 2026-06-24

### Fixed
- **Portable file-mtime in the gh read cache** (#57): `stat -f %m` is BSD
  "format mtime", but on GNU/Linux `-f` means `--file-system` and *succeeds*
  with junk, so the `|| stat -c %Y` fallback never ran — the canonical snapshot
  was deemed stale and offline reshape fell back to empty. This failed the
  `ghcache … offline` tests on Linux (passing on macOS) and had blocked the
  Release workflow's test gate since v0.12.0. Try GNU `-c %Y` first, then BSD.

## [0.14.0] - 2026-06-24

### Added
- **Disk-pressure guard in `fwf up`**: refuses to bring up / cycle the
  floor when free space is below `FWF_MIN_FREE_GB` (default `50`, set `0` to
  disable). A full disk on a shared host fails not just builds but prod writes —
  it wedged a release.
- **Shared `CARGO_TARGET_DIR` support**: a profile can export one shared
  Rust target dir so all worktrees compile into a single cache instead of each
  carrying a multi-GB `target/`. An internal profile uses it (override via
  `FWF_CARGO_TARGET_DIR`). Dependencies dedupe; only first-party crates rebuild
  on branch switches.

## [0.13.1] - 2026-06-23

### Fixed
- **gh read cache: the dash's detail/thread pane showed "detail unavailable"** (#57
  regression). The cache's fallback `gh issue/pr view` ran without repo context, so
  it worked for agents (whose cwd is their worktree) but failed for the **dash**,
  which runs outside the target repo — `gh` couldn't resolve the issue number,
  returned empty, and the detail pane rendered "detail unavailable". The cache now
  exports `GH_REPO=<owner/repo>` so its gh calls resolve from any cwd. Added a
  dash-data regression test that drives `detail_view` through the **real** cache
  from outside a repo (the existing stubbed-`di_read` tests had skipped that path).

## [0.13.0] - 2026-06-23

### Added
- **Shared REST+ETag `gh` read cache** (`fwf-ghcache.sh`) (#57). The factory's hot
  `gh issue list` / `gh pr list` polls — previously GraphQL, which ten agents drain
  to zero in minutes, stalling the floor (and starving any human `gh`) — now route
  through a **single-flight, TTL'd cache** served from one canonical REST fetch per
  topic off the **core** bucket (separate from the GraphQL pool), with
  `If-None-Match` so an unchanged poll returns `304` for free. Every list variant
  (per-label, per-base, projection, `--jq`) and the dash read the same snapshot;
  output is byte-identical to `gh`. Tunable via `FWF_GHCACHE_TTL` (default 60),
  `FWF_GHCACHE_DIR`, `FWF_GHCACHE_OFF`. See `docs/gh-read-cache.md`.

### Changed
- The pane `gh` shim (`fwf_install_ghguard`) is now installed in **all** modes
  (previously local-only): it provides the read cache everywhere, and additionally
  keeps the fail-closed remote-write guard in `--issues local` mode (#34).

## [0.12.0] - 2026-06-22

### Added
- **Validation factory template** (`fwf up --template validate`) (#56). Funnels
  one posited business+product idea through three falsification gates — market
  reality → solution → business — each with **pre-registered kill criteria**
  written before the analysis. Stance-diverse analysts lead with the
  disconfirming case (evidence-tiered findings + a required cheapest-disconfirming
  test); the red-team runs 2–3 adversarial honing rounds with a different lens
  each; the adjudicator writes a GO/CONDITIONAL-GO/KILL/PIVOT verdict with
  confidence bounded by the weakest load-bearing link and business paths ranked
  pairwise. A KILL short-circuits the funnel but **preserves state** (dossier in
  the repo, closed issue with a verdict); the human overrides by reopening with
  new evidence or an explicitly accepted risk. PIVOT is first-class; no new labels
  (phase lives in the issue's GATE CHECKLIST). Design in `docs/validate-factory.md`.

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
