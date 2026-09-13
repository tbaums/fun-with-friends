# Releasing fwf 1.0

One command cuts a release. Everything that could be a habit is a refusal in it.

```bash
one/scripts/release-publish.sh notes.md
```

It refuses a dirty tree, refuses a version already tagged here or on the remote,
runs the gate (`cargo fmt --check`, `clippy -D warnings`, `cargo test`,
`scripts/size-check.sh`), builds release, stages `<bin>-<version>-macos-arm64/`
— the binary named by `Cargo.toml`'s first `[[bin]]`, plus `README.md`,
`RELEASING.md`, `CHANGELOG.md` — tars it with a `.sha256`, and publishes with
`gh release create`, which creates the tag and the release in one call. It
finishes by proving the release object exists: `release-check … --expect 2`.

That tag push triggers `.github/workflows/one-release.yml`, which builds
`x86_64-unknown-linux-gnu` on `ubuntu-latest` and uploads the
`<bin>-<version>-linux-x86_64` pair onto the same release. It only ever uploads:
a tag with no release behind it fails the job loudly instead of publishing
something nobody vouched for. When it finishes:

```bash
fwf release-check --repo tbaums/fun-with-friends --tag one-vX.Y.Z --expect 4
```

Four assets: two tarballs, two checksums. Until the workflow lands `--expect 4`
under-counts, which is the honest reading, not a bug.

## Five imperatives

1. **Cut from `main`, which only ever fast-forwards from `staging`.**
   `fwf promote --from staging --to main --suite e2e` refuses without a recorded
   Green for the exact SHA. The script does not promote: that stays a separate,
   deliberate act.
2. **Bump `one/Cargo.toml` `version` and `CHANGELOG.md` in one commit**, and let
   the script tag it — never `git tag` by hand, or the tag and the release can
   disagree about what shipped.
3. **A tag is not a release.** `release-check` is the proof, the script runs it,
   and `--expect 4` after the workflow lands is the number you quote when you
   tell anyone.
4. **Never promote `main` without the operator**; `fwf run` promotes only to
   `staging`'s successor named in the manifest, and the run record shows who.
5. **Roll back by re-installing the previous release**, never by force-pushing
   `main` (`docs/CUTOVER.md`).

## When a cut fails halfway

Before `gh release create` there is nothing to clean up: no tag, no release, and
nothing staged inside the repo (artifacts go to a temp dir the script prints).
After it, the release is live — so a re-run refuses and points at it, which is
right: finish it by uploading what is missing (`gh release upload`, or re-run
`one-release.yml` from the Actions tab with the tag) rather than cutting the
version twice.

## Asset names

`<bin>-<version>-<slug>.tar.gz` with `<asset>.sha256` beside it, slug
`macos-arm64` or `linux-x86_64`. `install.sh` downloads and verifies exactly
these on a machine without cargo, so the names are a contract, not a convention.
