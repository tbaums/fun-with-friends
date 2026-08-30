# Releasing

`fun-with-friends` versions follow [SemVer](https://semver.org/). The single
source of truth for the version is the [`VERSION`](VERSION) file; a release is a
git tag `vX.Y.Z` whose number matches it.

Releases are cut from `main` and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml): pushing a
matching tag first requires **every context in
[`.github/branch-policy.json`](.github/branch-policy.json)'s `required_contexts`
to be reported GREEN by `ci.yml` for that exact SHA** (issue #303 — a required
context that has never reported is a refusal, exactly like a failing one; this
polls for up to 20 minutes, matched to `ci.yml`'s own observed
`functional suite (ubuntu-latest)` worst case plus scheduling margin, then
fails closed rather than publishing on an incomplete picture — see
[`fwf-release-ci-gate.sh`](fwf-release-ci-gate.sh)). Only then does it verify
`tag == VERSION`, lint (`shellcheck -S warning`), run the
functional suite, build a tarball with [`scripts/package.sh`](scripts/package.sh),
builds prebuilt `fwf-dash` binaries for every target in
[`dash-targets.json`](dash-targets.json) — currently darwin-arm64 (this Mac) and
linux-x86_64 (devbox); every other platform builds from source — and creates a GitHub Release with the
tarball, the dash binaries, and `fwf-dash-<ver>-checksums.txt` attached (plus
auto-generated notes). `fwf dash` depends on those assets for prebuilt
resolution — see [docs/dash.md](docs/dash.md).

## Cut a release

> **LOCAL-CI ERA (2026-08-29).** `ci.yml` is **disabled** — all CI runs on the
> factory box (`fwf-local-ci.sh`). Its verdicts live on that box and a GitHub
> runner cannot read them, so release.yml's #303 gate **degrades to advisory**
> while ci.yml is disabled (it re-arms automatically if ci.yml is re-enabled).
>
> **The blocking gate therefore moves to you, before you push the tag:**
> a **two-runner green** for the exact SHA being tagged — the macOS runner and
> the devbox — each log containing **`DONE`**, **`EXIT=`** and a
> **`passed, N failed`** summary. A truncated log is not green.
>
> If the two runners disagree, do not tag. Classify every failure first: the
> devbox is also the factory, so it fails tests that read live GitHub state or
> race under load. Record the classification on the PR, as done for #386.
>
> **v0.40.0 record (#431):** from #416 until #431 merged, the macOS runner
> reported `EXIT=1` on every SHA regardless of the code under test (a
> harness-only `timeout: command not found`, not a product failure) — so a
> macOS report in that window was not a real second signature, only a
> runner's existence. Not a release blocker per #431's own classification
> (the devbox was green on the identical SHAs); recorded here so a later
> reader does not mistake that window's macOS `EXIT=1` for a disagreeing
> runner.



**The version bump rides the normal promotion path (`staging` → `integration` →
`main`) — it is never committed directly to `main`.** (issue #262.) `main` only
ever *advances*, by fast-forward, to a SHA that already exists on `staging`/
`integration`; it never receives a commit of its own. That keeps the pipeline's
invariant — `main` ⊆ `integration` ⊆ `staging`, every branch a subset of the one
upstream of it — intact through a cut, so a release can no longer manufacture the
two-way divergence the pre-publish guard below then has to (correctly) refuse.

1. **Land the work on `staging`** (the normal path — impl/QA/conductor) and make
   sure it's green.
2. **Bump the version** in `VERSION` (e.g. `0.26.0`) **as an ordinary PR onto
   `staging`**, alongside the CHANGELOG update in the next step. Skip if it
   already holds the number you're releasing. **Bump rule (SemVer, pre-1.0):**
   if the release adds any new feature — i.e. it has a `### Added` entry — bump
   the **minor** (`0.x.0`); if it's only fixes / changes / docs / chores
   (`### Fixed`, `### Changed`, `### Documentation`, `### Removed`,
   `### Internal` — **no `### Added`**), bump the **patch** (`0.x.y`). The
   CHANGELOG section types for the release decide it: **any `Added` ⇒ minor.**
   (A user-facing feature shipped as a patch understates the change and is a
   versioning bug — classify by the CHANGELOG, don't just increment the patch
   digit.)
3. **Update [`CHANGELOG.md`](CHANGELOG.md)**: move items from `Unreleased` into a
   new `## [X.Y.Z] - YYYY-MM-DD` section, in the **same PR** as the version bump.
   **Every entry carries two commit refs — code and docs**: `- **Feature**
   (#NNN, code <sha>, docs <sha>) — …`. Same SHA when docs rode in the
   implementing commit; distinct when docs landed separately. The **docs ref is
   mandatory** — it's the per-item proof the doc changes are in for that change
   (a genuinely doc-less internal change cites `docs none — internal`). Verify
   each user-facing item's `docs <sha>` actually touched a doc (`git show <sha>
   --stat`) before tagging.
4. **Wait for the bump to promote to `integration`** (the conductor's normal
   `staging` → `integration` gate cycle — no manual step). Confirm:
   `git fetch origin && git log origin/integration -1` should show the bump
   commit.
5. **Fast-forward `main` to `integration`'s tip** — this is `main`'s ONLY write
   path; it never gets a commit of its own:
   ```bash
   git fetch origin
   git switch main
   git merge --ff-only origin/integration
   git push origin main
   ```
   If the `--ff-only` merge refuses, `main` has a commit `integration` lacks —
   stop and reconcile by hand (see "Re-syncing staging/integration" below)
   rather than forcing it.
6. **Pre-tag divergence check — DO NOT SKIP.** Before tagging, run the same
   non-mutating check the release workflow's pre-publish guard runs:
   ```bash
   ./fwf reconcile --check
   ```
   **On `check-diverged` (or `check-suspect`), STOP — do not tag.** That is a
   genuine divergence needing a human decision, not a rerun; resolve it (see
   "Re-syncing staging/integration" below) before proceeding. `check-ok` means
   it's safe to continue. (Steps 4–5 make this pass by construction on the
   ordinary path; this step is the cheap guard for the exception — e.g. an
   emergency hotfix landed straight on `main`.)
7. **Tag and push**:
   ```bash
   git tag vX.Y.Z          # must equal the VERSION file, now on main via step 5
   git push origin main --tags
   ```
8. The **Release workflow** runs on the tag. Watch it:
   ```bash
   gh run watch
   ```
   If `tag != VERSION` it fails fast — fix `VERSION`, re-tag, push again. The
   workflow's own pre-publish check re-runs step 6's guard as a backstop (never
   trust a local run alone), and its last step auto-reconciles
   `staging`/`integration` back to `main` (issue #114 — see "Re-syncing
   staging/integration" below); this is normally a no-op now, since `main` never
   moved ahead of them — no manual step needed on the happy path.
9. **Verify** the published release and the artifacts. The expected set is
   derived from `dash-targets.json`, never hardcoded: the tarball, one
   `fwf-dash-<ver>-<slug>` binary per manifest target, and the checksums file —
   with today's two-target manifest that is four assets total:
   ```bash
   gh release view vX.Y.Z --json assets -q '.assets[].name' | sort
   # expect exactly these four, and nothing else:
   #   fwf-X.Y.Z.tar.gz
   #   fwf-dash-X.Y.Z-checksums.txt
   #   fwf-dash-X.Y.Z-darwin-arm64
   #   fwf-dash-X.Y.Z-linux-x86_64
   gh release download vX.Y.Z -p '*.tar.gz' -D /tmp/rel
   tar -C /tmp/rel -xzf /tmp/rel/fwf-X.Y.Z.tar.gz
   /tmp/rel/fwf-X.Y.Z/fwf doctor
   ```

   As of issue #209, the workflow now asserts this exact set automatically —
   `scripts/assert-release-assets.sh` runs against the draft release before
   it is ever published, so a missing or unexpected asset fails the workflow
   with nothing made public. This step is a confirmation, not the only line
   of defence.

## Re-syncing staging/integration (issue #114)

Every release (or direct-to-`main` hotfix) can leave `staging`/`integration`
stale — they were cut before `main` advanced. `.github/workflows/release.yml`'s
final step runs `fwf reconcile` automatically so this can no longer be a
forgotten manual step. It classifies each of `staging`/`integration` against
`main` by ancestry and does exactly one of:
- **stale (behind main)** → fast-forwards it to `main`, logs the old→new SHA.
- **ahead of main** (normal mid-cycle state — carries promoted-but-unreleased
  work) → no-op, reported as normal. This is never treated as stale.
- **diverged** (each side has a commit the other lacks) → halts loudly and
  names the divergent SHAs; it never auto-merges/rebases/force-pushes. Resolve
  by hand:
  ```bash
  FWF_REPO="$PWD" ./fwf reconcile --branch staging --branch integration --against main
  ```
  then reconcile the named branch(es) yourself (e.g. `git push --force-with-lease`
  after confirming which side should win).

The same command is what the captain runs on every tick, before assigning new
work, as a safety net for the case above (a hand-merge or a release predating
this fix landed commits on `main` outside the automated path).

## Dry run (no release)

Build the tarball locally without tagging or publishing:

```bash
scripts/package.sh         # -> dist/fwf-<VERSION>.tar.gz
```

## ⚠️ Three published releases went out over a red CI suite (issue #303) — operator decision needed

**v0.33.0, v0.34.0, and v0.35.0 all published with `dash crate (rust)` and the
(now-removed) macOS functional lane both red**, verified per-SHA against
GitHub's own check-runs:

| release | SHA | red required contexts |
|---|---|---|
| v0.33.0 | `e3404cd` | `dash crate (rust)`, `functional suite (macos-latest)` |
| v0.34.0 | `1373da7` | `dash crate (rust)`, `functional suite (macos-latest)` |
| v0.35.0 | `285dc8c` | `dash crate (rust)`, `functional suite (macos-latest)` |

This was a **standing condition, not a one-off slip** — the same two contexts,
every release, for three releases running — because `release.yml`'s own gate
only ever consulted a strict subset of what `ci.yml` actually runs (fixed by
the gate described above). **Recording it here rather than silently letting it
scroll off**, per issue #303's own AC (g): these artifacts are published and
users may already have them.

**This needs an explicit operator call, not a default:** re-cut one or more of
these releases, supersede them with a note in the next release's notes, or
accept them as-is with a documented reason. Not decided by this change —
flagging it here is the deliverable; @captain / the operator makes the call.

## Install-checkout drift (issue #442)

Every role's `fwf`/`fwf-gate.sh` actually executes from `$FWF_HOME` — on a
multi-agent box that is very often a **separate install checkout**
(`fwf` on `PATH` resolves through a symlink into it), not any role's own
worktree. Nothing keeps that install checkout in sync with `origin/main`
automatically, so a merged fix can sit on `main` indefinitely and simply
never execute there — #442 found this had happened silently for 19 commits.

`fwf doctor` now reports an `fwf install:` line naming how many commits
that checkout is behind `origin/main` (read-only, never fetches, never
blocks). **Whether/when to actually fast-forward a live install checkout
out from under every role's gate mid-flight is an operator call** — run
`fwf doctor` on the box before cutting a release to check it, but this
change does not perform that refresh automatically.

## Re-cutting a tag

If a release must be redone, delete the tag locally and on the remote, then
re-tag a corrected commit:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
gh release delete vX.Y.Z --yes   # if the release was already published
```

## When GitHub Actions is unavailable

When Actions can't run (an outage, or jobs fail immediately with an annotation
before any step executes), the tag-triggered release workflow won't publish
anything. Cut the release manually — same gates, run locally:

1. Validate exactly what CI would: `bash test/run.sh` (includes shellcheck).
2. Put **`[skip ci]`** in the release commit message (and every commit/PR
   title while Actions is down) so pushes don't queue doomed runs.
3. Tag and push as usual, then build and publish by hand:
   ```bash
   scripts/package.sh
   gh release create vX.Y.Z dist/fwf-X.Y.Z.tar.gz --generate-notes \
     --title "vX.Y.Z" --notes-file <(sed -n '/## \[X.Y.Z\]/,/^## /p' CHANGELOG.md)
   ```
   Note: this publishes **only the tarball** — the prebuilt `fwf-dash` binaries
   come from the workflow's cross-compile matrix. Either cross-build and upload
   them (plus the checksums file) by hand, or accept that `fwf dash` falls back
   to a local `cargo build` for this release.
4. Verify with the **Verify** step above (re-anchored on its heading text, not
   a step number, after issue #262 renumbered it once already).
5. Reconcile. As of #179 this is **no longer only a manual instruction** — the
   `reconcile` job in `.github/workflows/ci.yml` fires on *every* push to `main`,
   tagged or not, so the fallback path is covered even if you skip this step. It
   runs `fwf reconcile-guard`, which files one durable, self-closing tracking
   issue if it finds a **real** divergence. As of #238, a `lock-busy` or
   `cas-lost` verdict (this reconcile lost a race against a concurrent,
   benign writer — another reconcile tick, a second release step) is treated
   as the self-healing race it is: no artifact is filed and none is closed
   either (a check may still show red for that one run, but nothing durable
   is created — the next push re-classifies). Only `halted-diverged`/
   `suspect` ever file/update an artifact; three consecutive indeterminate
   verdicts with no intervening clean escalate to `suspect` on their own, so
   a race that is not actually transient still gets a durable consequence.

   Run it yourself anyway for the immediate answer:
   `FWF_REPO="$PWD" ./fwf reconcile` (see "Re-syncing staging/integration" above).

   > **Why this note exists.** `fwf-reconcile.sh` records that #114 exists
   > *because* the previous manual re-sync step got skipped (the 2026-07-14
   > incident). Leaving this uncovered would have reproduced #114's own history
   > inside the ticket meant to prevent it.
