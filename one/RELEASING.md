# Releasing fwf 1.0

Five imperatives. Each is a refusal in code, not a habit.

1. **Cut from `main`, which only ever fast-forwards from `staging`.**
   `fwf promote --from staging --to main --suite e2e` refuses without a
   recorded Green for the exact SHA.
2. **Bump `one/Cargo.toml` `version` and `CHANGELOG.md` in one commit**, then
   tag `one-vX.Y.Z` on that SHA.
3. **Publish the release object with the binaries**; a tag is not a release.
   (`one-release.yml` is not written yet: until it is, `cargo build --release`
   for darwin-arm64 and linux-x86_64 and `gh release create one-vX.Y.Z` with
   both binaries and a checksums file, by hand.) Name each asset
   `fwf-<version>-<slug>` — slug `darwin-arm64`, `darwin-x86_64`,
   `linux-arm64`, `linux-x86_64` — with a `<asset>.sha256` beside it: that is
   what `install.sh` downloads and verifies on a machine without cargo.
   `fwf release-check --repo tbaums/fun-with-friends --tag one-vX.Y.Z --expect N`
   must print `release ok` before you tell anyone.
4. **Never promote `main` without the operator**; `fwf run` promotes only to
   `staging`'s successor named in the manifest, and the run record shows who.
5. **Roll back by re-installing the previous release**, never by force-pushing
   `main` (`docs/CUTOVER.md`).
