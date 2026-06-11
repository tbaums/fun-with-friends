# Releasing

`fun-with-friends` versions follow [SemVer](https://semver.org/). The single
source of truth for the version is the [`VERSION`](VERSION) file; a release is a
git tag `vX.Y.Z` whose number matches it.

Releases are cut from `main` and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml): pushing a
matching tag verifies `tag == VERSION`, lints (`shellcheck -S warning`), runs the
functional suite, builds a tarball with [`scripts/package.sh`](scripts/package.sh),
and creates a GitHub Release with the tarball attached and auto-generated notes.

## Cut a release

1. **Land the work on `main`** and make sure it's green (CI passing).
2. **Bump the version** in `VERSION` (e.g. `0.2.0`). Skip if it already holds the
   number you're releasing.
3. **Update [`CHANGELOG.md`](CHANGELOG.md)**: move items from `Unreleased` into a
   new `## [X.Y.Z] - YYYY-MM-DD` section.
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
   If `tag != VERSION` it fails fast — fix `VERSION`, re-tag, push again.
7. **Verify** the published release and the artifact:
   ```bash
   gh release view vX.Y.Z
   gh release download vX.Y.Z -p '*.tar.gz' -D /tmp/rel
   tar -C /tmp/rel -xzf /tmp/rel/fwf-X.Y.Z.tar.gz
   /tmp/rel/fwf-X.Y.Z/fwf doctor
   ```

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

## When GitHub Actions is unavailable (billing/credits)

When Actions can't run (jobs die in seconds with a billing annotation), the
tag-triggered release workflow won't publish anything. Cut the release
manually — same gates, run locally:

1. Validate exactly what CI would: `bash test/run.sh` (includes shellcheck).
2. Put **`[skip ci]`** in the release commit message (and every commit/PR
   title while Actions is down) so pushes don't queue doomed runs.
3. Tag and push as usual, then build and publish by hand:
   ```bash
   scripts/package.sh
   gh release create vX.Y.Z dist/fwf-X.Y.Z.tar.gz --generate-notes \
     --title "vX.Y.Z" --notes-file <(sed -n '/## \[X.Y.Z\]/,/^## /p' CHANGELOG.md)
   ```
4. Verify with step 7 above.
