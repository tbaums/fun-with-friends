# Releasing fwf 1.0

Every release asset is built by GitHub CI. Nothing is built on a laptop and
uploaded by hand (#727). The operator's part is one command that only tags:

```bash
one/scripts/release-publish.sh notes.md
```

## Tag → draft → verify → publish → `release-check`

1. **Tag (the script, on your machine).** It refuses, in order: no notes file
   or a notes file with nothing but whitespace; a dirty tree; a `Cargo.lock`
   that does not already record the version being cut; `HEAD` that is not
   `origin/main` (it fetches first); a version already tagged here or on
   `origin`. Then it creates an annotated tag `v<version>` whose message is
   the notes, verbatim (Markdown headings survive), pushes it, and prints the
   CI run URL and the `release-check` command. If the push fails it deletes
   the local tag, so a re-run starts clean. It does not run the gate, build,
   or call `gh`, so it runs on any host with git and cargo.
2. **Meta (CI).** The tag push runs `.github/workflows/one-release.yml`. It
   fetches the tag object and fails unless the tag is annotated, its message
   is non-empty, and it equals `v` + `one/Cargo.toml`'s version. This happens
   before any release exists.
3. **Draft (CI).** It creates a **draft** release titled `fwf <version>` with
   the notes from the tag (`--notes-from-tag`), or reuses the one release that
   tag already has. It never creates a second one.
4. **Build (CI), two legs:** `macos-latest` → `macos-arm64` and
   `ubuntu-latest` → `linux-x86_64`. Each leg runs `cargo test` (the macOS leg
   is the only macOS test run 1.0 has), then `cargo build --release --locked`
   with the cargo home, the toolchain sysroot and the checkout remapped by
   `--remap-path-prefix`, so the binary does not carry the runner's paths. On
   the built binary it checks the architecture, `codesign --verify` (macOS; the
   linker's ad-hoc signature, as before), that `fwf version` prints the
   version, `one/scripts/baked-paths-check.sh` (no path to the checkout's
   `prompts`/`scripts`, and none under the runner's `$HOME`), and
   `doctor --assets` from `/` with a fresh `HOME` and the checkout's
   `prompts/` moved away. The Linux leg also runs `cargo fmt --check`,
   `clippy -D warnings` and `scripts/size-check.sh`. Then it stages the
   tarball and its `.sha256` and uploads them onto the draft.
5. **Verify and publish (CI).** After both legs, it downloads every asset of
   the draft into an empty directory and runs `one/scripts/release-verify.sh`:
   exactly the four expected names, each checksum matching its tarball, and
   each tarball holding a non-empty `fwf` plus `README.md`, `RELEASING.md` and
   `CHANGELOG.md`. Only then does it publish (`gh release edit --draft=false`).
   Any failure before this leaves a draft, which nobody installs from.
6. **`release-check` (you).** It needs the ops App key, which CI does not have,
   and it reads only published releases. When the run is green:

   ```bash
   fwf release-check --repo tbaums/fun-with-friends --tag vX.Y.Z --expect 4
   ```

   Four assets: two tarballs, two checksums, each uploaded by
   `github-actions[bot]`.

A slow macOS queue only delays the release: it stays a draft until both legs
finish.

## Dry run

Prove the workflow on a branch without tagging or publishing anything:

```bash
gh workflow run one-release.yml --ref <branch> -f dry_run=true
```

`dry_run` defaults to `true`, so an accidental dispatch never publishes. A dry
run builds and checks both legs exactly as a cut does, saves each
`<bin>-<version>-<slug>` pair as a run artifact, and runs `release-verify.sh`
on the four files. It creates no tag, no release and no upload. Dispatching
needs `actions: write` on the repository.

Tags are `vX.Y.Z`, made from `one/Cargo.toml`'s version. The first three 1.0
releases were tagged `one-v1.0.0` to `one-v1.0.2`, and later ones were not.

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

   Then let the script tag it — never `git tag` by hand: a lightweight tag or
   one without notes fails at `meta`, and a tag at a commit that is not
   `origin/main` ships something that was never promoted. A stale lock is how
   one-v1.0.2 shipped with two assets instead of four (#604): the tag was cut
   at a commit whose lock still said 1.0.1, and the runner's
   `cargo build --locked` refused. The script refuses a stale lock before it
   tags.
3. **A tag is not a release.** `release-check --expect 4` after the workflow
   publishes is the proof, and the number you quote when you tell anyone.
4. **Promotion is always an operator's act.** `fwf run` never moves `main` (or
   any `release_branch`); only `fwf promote` does, and the run record shows the
   `promote` event.
5. **Roll back by re-installing the previous release**, never by force-pushing
   `main`: `fwf self-upgrade --to X.Y.Z` (any published version, older
   included), or `FWF_VERSION=X.Y.Z ./install.sh`.

## When a cut fails halfway

If the script refuses, nothing was cut: no tag, no release. If its push fails
it deletes the local tag, so a re-run starts clean.

Once the tag is pushed, the script refuses that version again, which is right:
never cut a version twice and never move a tag. A failed run leaves at most a
**draft** release, which is not public and which `release-check` cannot see.
Recover by re-running the workflow for the tag, not by tagging again:

```bash
gh workflow run one-release.yml -f tag=vX.Y.Z -f dry_run=false
```

It rebuilds both legs onto the tag's existing release (draft or published;
`--clobber` replaces a partial upload), re-runs `release-verify.sh` on all
four assets, and publishes. It never creates a second release for the tag; if
there is somehow more than one, it stops and says so. A transient failure
(a runner hiccup) can also just be re-run from the Actions tab.

If the tagged commit itself cannot build — one-v1.0.2's stale lock — add a
`ref` (the fixed commit, e.g. the branch that repaired the lock):

```bash
gh workflow run one-release.yml -f tag=vX.Y.Z -f ref=<fixed-commit> -f dry_run=false
```

It builds from that ref onto the existing tag's release; the tag itself never
moves, and `meta` still refuses unless that ref's `one/Cargo.toml` version
matches the tag.

## Asset names

`<bin>-<version>-<slug>.tar.gz` with `<asset>.sha256` beside it, slug
`macos-arm64` or `linux-x86_64`. `install.sh` downloads and verifies exactly
these on a machine without cargo, so the names are a contract, not a convention.

The binary carries the seat prompts and seat scripts. It writes them under
`~/.fwf/` at run time and never reads the tree it was built in, so a release
asset works on any host (#719). CI's `one/scripts/baked-paths-check.sh` fails a
build whose binary names a path under its own checkout's `prompts` or
`scripts`, and the release legs pass it the runner's `$HOME` too, so a binary
that still carries a toolchain, registry or checkout path is never uploaded
(#727).
