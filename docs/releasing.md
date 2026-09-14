# Releasing fwf 1.0

One command cuts a release. Everything that could be a habit is a refusal in it.

```bash
one/scripts/release-publish.sh notes.md
```

It refuses a dirty tree, refuses a `Cargo.lock` that does not already record the
version being cut, refuses a version already tagged here or on the remote, runs
the gate (`cargo fmt --check`, `clippy -D warnings`, `cargo test`,
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
2. **Bump the version in one commit: `one/Cargo.toml`, `one/Cargo.lock` and
   `CHANGELOG.md`.** The lock records the crate's own version too, so bumping
   `Cargo.toml` alone leaves it stale:

   ```bash
   # in one/, after editing Cargo.toml's version
   cargo update -w            # rewrites Cargo.lock's fwfd entry, nothing else
   git add Cargo.toml Cargo.lock ../CHANGELOG.md && git commit
   ```

   Then let the script tag it — never `git tag` by hand, or the tag and the
   release can disagree about what shipped. A stale lock is how one-v1.0.2
   shipped with two assets instead of four (#604): the local gate rewrote the
   lock after the clean-tree check, the tag was cut at the commit without it,
   and the runner's `cargo build --locked` refused. The script now refuses
   first — before the gate, and again before it tags.
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

If the tagged commit itself cannot build — one-v1.0.2's stale lock — re-run
`one-release.yml` with the tag **and** a `ref` (the fixed commit, e.g. the
branch that repaired the lock). It builds from that ref and uploads onto the
existing tag's release; the tag itself never moves, and the job still refuses
unless that ref's `one/Cargo.toml` version matches the tag.

## Asset names

`<bin>-<version>-<slug>.tar.gz` with `<asset>.sha256` beside it, slug
`macos-arm64` or `linux-x86_64`. `install.sh` downloads and verifies exactly
these on a machine without cargo, so the names are a contract, not a convention.
