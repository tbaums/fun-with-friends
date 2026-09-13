# Branch protection (issue #220)

## Why this exists

CI renders a pass/fail verdict on every PR; nothing on this repo obliges a
merge, promotion, or release to honor it. Confirmed live: `GET
/repos/tbaums/fun-with-friends/branches/{main,staging,integration}/protection`
returned 404 (unprotected) for all three, and two real incidents landed a
known-red `shellcheck + syntax` commit onto `staging` and then `integration`
the same day. See issue #220 for the full incident record.

This closes the gap with **required status checks**, enforced for
administrators — stock GitHub, no keys, no secrets, no custom workflow.

## What's already built (this PR)

- **`.github/branch-policy.json`** — the committed source of truth: which
  branches, which required contexts, `strict`, `enforce_admins`.
- **`fwf branch-policy check [<branch>]`** — read-only, diffs LIVE GitHub
  settings against the committed policy. Run it after applying protection
  (below) to confirm it landed correctly, and periodically after to catch
  drift (someone — possibly the owner account itself — flipping a setting).
- **`fwf branch-policy producible`** — asserts every required context in
  the policy is actually emitted by a job in `ci.yml` (catches a renamed
  job or an `on.paths` filter before either deadlocks every future PR).
- **`fwf pr-checks-honored <pr>`** — the QA-side ergonomic pre-merge
  checkpoint. NOT the security control below; every seat holds owner
  credentials and can merge past it with raw `gh` regardless.

None of the above mutates GitHub settings. Applying protection is a
separate, deliberate, one-time admin action — the commands below.

## Applying protection — exact commands

**Rollout order matters (issue #220): `staging` first, alone.** It's where
a required check buys the most (the conductor's fast-forward-only
promotion assumes a tested `staging`) and where being wrong costs least (a
blocked merge to `staging` stalls one PR; a blocked merge to `main` can
stall a release). Confirm AC (e) — the conductor's promotion still
succeeds under protection — before protecting `integration`/`main`.

```bash
# 1. staging — apply first, alone.
gh api -X PUT repos/tbaums/fun-with-friends/branches/staging/protection \
  -H "Accept: application/vnd.github+json" \
  -f "required_status_checks[strict]=false" \
  -f "required_status_checks[contexts][]=shellcheck + syntax" \
  -f "required_status_checks[contexts][]=functional suite (ubuntu-latest)" \
  -f "required_status_checks[contexts][]=functional suite (macos-latest)" \
  -f "required_status_checks[contexts][]=dash crate (rust)" \
  -F "enforce_admins=true" \
  -F "required_pull_request_reviews=null" \
  -F "restrictions=null"

# Verify it actually landed (do not trust the PUT's 200 alone):
fwf branch-policy check staging
```

**After `staging` is protected, confirm AC (e) before continuing**: watch
the conductor's next real promotion (`staging` → `integration`) succeed.
The conductor's fast-forward-only push is not a PR — required status
checks still apply to it (this endpoint gates the branch, not the merge
method), but it has never been exercised under protection on this repo
before. If it fails, STOP and diagnose before protecting anything else — a
failure here means the promotion pipeline itself is broken, and protecting
`integration`/`main` on top of that compounds the outage rather than
catching it.

```bash
# 2. integration and main — only after AC (e) is confirmed.
for b in integration main; do
  gh api -X PUT "repos/tbaums/fun-with-friends/branches/$b/protection" \
    -H "Accept: application/vnd.github+json" \
    -f "required_status_checks[strict]=false" \
    -f "required_status_checks[contexts][]=shellcheck + syntax" \
    -f "required_status_checks[contexts][]=functional suite (ubuntu-latest)" \
    -f "required_status_checks[contexts][]=functional suite (macos-latest)" \
    -f "required_status_checks[contexts][]=dash crate (rust)" \
    -F "enforce_admins=true" \
    -F "required_pull_request_reviews=null" \
    -F "restrictions=null"
done
fwf branch-policy check   # checks every policy branch at once
```

**Before protecting `main`, confirm AC (m)/(m2) manually — they do not
transfer from AC (e)'s success:**

- **AC (m):** `RELEASING.md`'s release step creates a NEW commit on `main`
  (`git commit -am "Release vX.Y.Z"`) and pushes it directly. That commit
  has never been through CI, so it has no passing contexts to satisfy a
  required check — a release WILL be refused unless #262 lands first
  (which reorders the version bump to ride `staging` → `integration` →
  `main`, so the SHA is CI'd before it reaches `main`). If #262 has not
  shipped, cut a real release under protection once, on a low-stakes
  version, and confirm what actually happens before relying on this.
- **AC (m2):** `fwf_reconcile_cas_push` (`lib.sh`) writes to `staging`/
  `integration` via `git push --force-with-lease`. This IS a force push in
  git's sense (even though the update is a fast-forward). Exercise a real
  reconcile under protection once and confirm it still succeeds — the
  post-publish reconcile is what pulls `staging` back after every release,
  and #262 relies on it to resolve its own race.

## Removing / adjusting protection (incident recovery)

If a required check is genuinely broken in CI itself (infrastructure
outage) it blocks all merges. Recovery is the owner deliberately lifting
protection:

```bash
gh api -X DELETE repos/tbaums/fun-with-friends/branches/staging/protection
```

`fwf branch-policy check` will report `NOT PROTECTED` after this — that's
the intended signal (drift, made visible, not silent). Re-apply with the
commands above once the underlying CI issue is fixed. Do not leave a
branch unprotected after the incident is resolved — re-check
`fwf branch-policy check` is clean before considering it closed.

## Edge cases to know before touching this

- **Matrix context names.** `functional suite (ubuntu-latest)` /
  `functional suite (macos-latest)` come from `ci.yml`'s OS matrix.
  Changing the matrix (an OS bump, a `name:` edit) silently renames the
  context — the OLD required name then never reports, and GitHub treats
  "never reported" as pending forever, blocking every PR with no failing
  check to point at. **Update `.github/branch-policy.json` in the SAME
  commit as any `ci.yml` job/matrix rename.** `fwf branch-policy
  producible` catches this before it ships.
- **`strict` is deliberately OFF.** Requiring every PR to be rebased onto
  the latest `staging` before merge would serialize the floor (multiple
  implementers in flight) for a benefit CI already largely provides.
  Revisit only if a stale-merge incident actually occurs.
- **A docs-only PR must still report success on every required context in
  well under the full suite's runtime** — this is already true today
  (`ci.yml` has no `on.paths` filter, and every job always triggers,
  deciding internally whether there's expensive work to do). Do not
  "optimize" this later by adding `on.paths` filters to the required jobs
  — a required check that never reports on some PRs makes those PRs
  permanently unmergeable with no failing check to point at.
