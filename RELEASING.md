# Releasing

`fun-with-friends` versions follow [SemVer](https://semver.org/). The single
source of truth for the version is the [`VERSION`](VERSION) file; a release is a
git tag `vX.Y.Z` whose number matches it.

Releases are cut from `main` and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml): pushing a
matching tag verifies `tag == VERSION`, lints (`shellcheck -S warning`), runs the
functional suite, builds a tarball with [`scripts/package.sh`](scripts/package.sh),
cross-compiles prebuilt `fwf-dash` binaries for the three supported platforms
(darwin-arm64, linux-arm64, linux-x86_64 — Intel Macs build from source), and creates a GitHub Release with the
tarball, the dash binaries, and `fwf-dash-<ver>-checksums.txt` attached (plus
auto-generated notes). `fwf dash` depends on those assets for prebuilt
resolution — see [docs/dash.md](docs/dash.md).

## Cut a release

1. **Land the work on `main`** and make sure it's green (CI passing).
2. **Bump the version** in `VERSION` (e.g. `0.26.0`). Skip if it already holds the
   number you're releasing. **Bump rule (SemVer, pre-1.0):** if the release adds
   any new feature — i.e. it has a `### Added` entry — bump the **minor**
   (`0.x.0`); if it's only fixes / changes / docs / chores (`### Fixed`,
   `### Changed`, `### Documentation`, `### Removed`, `### Internal` — **no
   `### Added`**), bump the **patch** (`0.x.y`). The CHANGELOG section types for
   the release decide it: **any `Added` ⇒ minor.** (A user-facing feature shipped
   as a patch understates the change and is a versioning bug — classify by the
   CHANGELOG, don't just increment the patch digit.)
3. **Update [`CHANGELOG.md`](CHANGELOG.md)**: move items from `Unreleased` into a
   new `## [X.Y.Z] - YYYY-MM-DD` section. **Every entry carries two commit refs —
   code and docs**: `- **Feature** (#NNN, code <sha>, docs <sha>) — …`. Same SHA
   when docs rode in the implementing commit; distinct when docs landed
   separately. The **docs ref is mandatory** — it's the per-item proof the doc
   changes are in for that change (a genuinely doc-less internal change cites
   `docs none — internal`). Verify each user-facing item's `docs <sha>` actually
   touched a doc (`git show <sha> --stat`) before tagging.
4. **Commit** the bump: `git commit -am "Release vX.Y.Z"`.
5. **Tag and push**:
   ```bash
   git tag vX.Y.Z          # must equal the VERSION file
   git push origin main --tags
   ```
6. The **Release workflow** runs on the tag. Watch it:
   ```bash
   gh run watch
   ```
   If `tag != VERSION` it fails fast — fix `VERSION`, re-tag, push again. The
   workflow's last step also auto-reconciles `staging`/`integration` back to
   `main` (issue #114 — see "Re-syncing staging/integration" below); no manual
   step needed on the happy path.
7. **Verify** the published release and the artifacts (the tarball AND the five
   `fwf-dash-*` assets — binaries + checksums):
   ```bash
   gh release view vX.Y.Z            # expect fwf-X.Y.Z.tar.gz + 4 fwf-dash binaries + checksums
   gh release download vX.Y.Z -p '*.tar.gz' -D /tmp/rel
   tar -C /tmp/rel -xzf /tmp/rel/fwf-X.Y.Z.tar.gz
   /tmp/rel/fwf-X.Y.Z/fwf doctor
   ```

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
4. Verify with step 7 above.
5. Since the workflow's reconcile step didn't run, do it yourself:
   `FWF_REPO="$PWD" ./fwf reconcile` (see "Re-syncing staging/integration" above).
