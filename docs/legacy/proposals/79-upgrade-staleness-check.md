# Proposal: check for a newer fwf release on startup and loudly warn (#79)

**Status: DISCOVERY.** This is a feasibility investigation + build-or-no-go
recommendation, not code.

## Key finding before anything else: this is already half-built

`lib.sh` already ships `fwf_version_skew_warn()` (added for a different
purpose — warning that a stale box may be running an old template flow),
wired into exactly one call site, `fwf-up.sh:42`:

```bash
fwf_version_skew_warn() {
  command -v gh >/dev/null 2>&1 || return 0
  ...
  latest="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || echo '')"
  ...cache in ${TMPDIR:-/tmp}/.fwf-latest-release + .ts, 12h staleness...
  if [ "v$cur" != "$latest" ]; then
    printf '⚠️  fwf v%s on this box, but v%s is released — ...\n' ...
    printf "    run 'fwf upgrade', then 'fwf resume' ...\n"
  fi
  return 0
}
```

So the discovery question isn't "can this be built from scratch" — it's
**"does the existing mechanism satisfy the seven axes, and if not, what's the
smallest fix?"** That reframing changes the effort estimate a lot (see
Recommendation). Each axis below is evaluated against this existing code,
not a green-field design.

## Axis 1 — source of truth: `gh` (already correct)

Already uses `gh api repos/tbaums/fun-with-friends/releases/latest --jq
.tag_name` — the PM's recommended default, authenticated (5000/hr, not
60/hr), and `gh` is already a hard `fwf doctor` dependency so there's no new
tool requirement. **Bonus not called out in the ticket: GitHub's
`releases/latest` endpoint already excludes drafts and pre-releases by
definition** (it returns the most recent non-draft, non-prerelease release),
which resolves half of axis 6 for free — no client-side pre-release
filtering logic is needed.

**Recommendation: keep `gh` as the only fetcher.** A raw-`curl` REST fallback
for a `gh`-absent box adds real complexity (parsing JSON without `jq`,
handling the 60/hr cap) for a case that's already a hard failure elsewhere —
`fwf doctor` already flags a missing `gh` as broken. Don't build a fallback
for a dependency the tool already requires. The `VERSION`-file-on-`main`
option is strictly worse than the releases API (no draft/prerelease
filtering, requires its own fetch) — reject it.

## Axis 2 — caching + cadence: two concrete gaps in the existing cache

**What's already right:** cached with a timestamp sibling, checked for a
staleness window before re-fetching, called from exactly one place
(`fwf-up.sh`, once per factory launch) rather than from `lib.sh` itself
(which ~20 scripts source) — so today's call count is already bounded by
*launches*, not by *every process*. That's a better starting point than the
ticket's worst-case framing assumes.

**Gap A — cache location.** `${TMPDIR:-/tmp}/.fwf-latest-release` is not
tied to `fwf`'s own established shared-state root. `$FWF_RUN` already exists
as exactly this kind of profile-independent, machine-shared home for run
state (`$FWF_RUN/e2e.lock`, `$FWF_RUN/STOP`, `$FWF_RUN/state/$PROFILE/...`)
— `TMPDIR` can vary per shell/sandbox/user in ways `$FWF_RUN` deliberately
doesn't. **Recommendation:** move the cache to `$FWF_RUN/upgrade-check/{latest,ts}`,
consistent with existing conventions, still one file shared across every
profile and process on the machine (the "latest fwf release" fact has
nothing to do with which profile is running).

**Gap B — no single-flight guard.** If two `fwf up` invocations (different
profiles, same machine) land inside the same staleness window's expiry at
once, both can independently fire `gh api`. Low-probability (this only fires
on `fwf up`, an infrequent human action, not a per-tick loop), but the ticket
asks for it explicitly, and `fwf` already has a proven pattern for exactly
this shape of problem: the e2e lock's `mkdir`-based mutex
(`fwf_e2e_lock_acquire`/`release` in `lib.sh`). **Recommendation:** reuse the
same `mkdir <dir> || <someone else already refreshing>` idiom, but
**non-blocking** — unlike the e2e lock (which must wait for exclusive access
to a shared resource), a stale version-check losing the race should just use
the slightly-stale cache for *this* invocation rather than waiting; the next
staleness-window check will pick up whatever the winner wrote.

**Worst-case call count under this design:** at most one live `gh api` call
per staleness window per machine, regardless of how many profiles/processes
are active — bounded by the cache, not by process count. Recommend keeping
the existing 12h window (tighter than the PM's suggested 24h default;
tighter is strictly safer against the 5000/hr authenticated cap, which this
is nowhere close to saturating either way) rather than loosening it — no
reason found to relax it.

## Axis 3 — how loud: reuse the dash's existing full-width-banner precedent

The current implementation's only surface is a two-line `stderr` message
printed to whichever terminal ran `fwf up` — easy to miss (scrolls away, and
never printed again). It does NOT fan out per-pane (good — it isn't a banner
storm today), but it also isn't durably visible.

`dash/src/main.rs` already has exactly the "seen once, not once-per-pane"
surface this ticket wants: a conditional full-width banner rendered below the
tab bar (`⛔ CAPTAIN NEEDS YOU`, `render_header`'s line 2 already carries a
prod/pipeline/provenance/clock strip). **Recommendation:** add a third
banner condition of the same shape — `⬆ fwf vX.Y available (running vA.B) —
run 'fwf upgrade'` — sourced from the same cache file axis 2 defines, read
by `fwf-dash-data.sh` the way it already reads `status.json` and pipeline
state. This is a same-shaped addition to a proven mechanism, not new UI
plumbing.

Also surface it in `fwf doctor` (see axis 5) — the two surfaces (dash header,
`doctor`) cover "the factory is running" and "I'm about to launch/am
troubleshooting" without ever touching a per-pane startup banner.

**Silencing:** `FWF_ACK_VERSION` env var (or a small
`$FWF_RUN/upgrade-check/acked` file written by a `fwf doctor --ack-version`
flag) storing the last version the operator acknowledged. Compare
`latest` to `acked`, not to `cur` — this makes silence **per-version** by
default (the PM's stated preference): landing a NEW release re-arms the
alert even if the operator dismissed the previous one.

## Axis 4 — never block startup: the one real code-level gap

**This is the most important actionable finding.** The existing
`fwf_version_skew_warn` calls `gh api ...` **synchronously**, inline in
`fwf-up.sh`'s startup sequence, with no timeout. If `gh` stalls (slow DNS,
captive portal, network blip), `fwf up` hangs on it — nothing today
guarantees the "never block" property the ticket requires, it just happens
to usually be fast.

**Recommendation: adopt the ticket's suggested async design exactly**, and
confirm it's cheap to retrofit onto the existing function:

1. On startup, read ONLY the cache file (`$FWF_RUN/upgrade-check/latest` +
   `/ts`) — zero network on the hot path. If cache says newer-available,
   surface it immediately (axis 3). This part requires no design work — it's
   what the function already does when the cache is fresh; the change is
   just to *never* fall through to a synchronous fetch when it's stale.
2. When the cache is stale (past the window) or missing, spawn the refresh
   **detached**: `( fwf_version_skew_refresh & ) disown 2>/dev/null` (bash
   built-ins available on the 3.2 floor this repo targets — confirmed
   feasible without a spike; this is a standard detached-subshell idiom, not
   novel bash). The refresh acquires the axis-2 lock, calls `gh api`, writes
   the cache, releases the lock. The *current* invocation never waits on it
   and returns immediately either way.
3. Net effect: alert is always instant; freshness is eventually-consistent
   (at most one launch stale after a new release ships); offline means the
   cache doesn't refresh and nothing false is shown; "never block" becomes
   structural (no network call sits in the foreground path at all) rather
   than "usually fast enough."

## Axis 5 — observability: extend `fwf doctor`, don't invent a new surface

`doctor()` (in `fwf`) already prints a per-dependency version line for
`bash`/`tmux`/`git`/`gh`/`claude` via `_doctor_one`, but nothing about `fwf`
itself. **Recommendation:** add one more line reading the axis-2 cache file
and reporting exactly the three states the ticket requires:

```
  fwf       : v0.21.3 — up to date (checked 3h ago)
  fwf       : v0.21.2 — OUT OF DATE, v0.21.3 available: run 'fwf upgrade' (checked 11h ago)
  fwf       : v0.21.2 — could not check (last success: 4d ago; gh unreachable?)
```

The distinguishing signal is exactly the `ts` file already written only on
a *successful* fetch — if `ts` is older than, say, 3× the staleness window,
report "could not check" with that timestamp rather than silently reusing a
possibly-ancient cached "latest," which would otherwise misrepresent a dead
checker as "you're current." This is a small, additive change to a function
that already exists in the same file.

## Axis 6 — what counts as "out of date": fix a real bug in the existing code

`[ "v$cur" != "$latest" ]` is a **strict string inequality**, not an
ordering comparison. Concretely: **a maintainer running a newer, unreleased
dev build is currently nagged** — the exact case the ticket calls out as a
requirement to handle gracefully ("never nag a maintainer running ahead of
the release"). This is a genuine, demonstrable bug in the shipped code, not
a hypothetical edge case to design around.

**Recommendation:** replace the string comparison with a small numeric
semver-ordering check (`IFS=. read -r maj min patch <<< "$cur"` vs `$latest`,
compare numerically field-by-field — no new dependency, `bash` 3.2-safe).
Only warn when `cur` sorts *strictly lower* than `latest`; a dev build ahead
of the latest tag, or an exact match, produces no warning. Pre-releases are
already excluded by the `releases/latest` endpoint itself (axis 1), so no
extra pre-release-detection logic is needed on the comparison side.

## Axis 7 — surface the upgrade path: already correct

The existing message ("run `fwf upgrade`, then `fwf resume`") is already
consistent with the corrected upgrade guidance from #71/#78 and never
suggests an in-worktree `git pull`. **Recommendation:** reuse this exact
copy verbatim in the dash banner and `doctor` line for consistency, rather
than drafting new wording.

## Effort estimate

Because the fetch, cache, comparison, and copy already exist and are
individually close to correct, the remaining build is a set of small,
independent, well-scoped patches to code that's already in `lib.sh`/`fwf`/
`dash/`, not a green-field feature:

1. Move cache to `$FWF_RUN/upgrade-check/` + add the non-blocking single-flight
   guard (axis 2) — small.
2. Make the stale-cache refresh path detached/backgrounded instead of
   synchronous (axis 4) — small, the highest-value fix.
3. Fix the version comparison to numeric ordering (axis 6) — small, and
   fixes a real bug.
4. Add the `doctor` three-state line (axis 5) — small, additive to an
   existing function.
5. Add the dash header banner + `fwf-dash-data.sh` wiring (axis 3) — small,
   same shape as the existing `CAPTAIN NEEDS YOU` banner.
6. Add the per-version silence mechanism (axis 3) — small.
7. `docs/` updates (README/dash.md/doctor's help text) for the new
   `doctor` line, dash banner, and silence flag/env var.

Rough total: **half to one day** for a single implementer — smaller than a
typical build ticket because most of the hard part (working, tested fetch +
cache + correct copy) is sunk cost already in the repo.

## Metered-feature / background-loop ship requirement (INCIDENT_PROTOCOL)

The recommended design (axis 4) introduces a **detached background call**,
which is exactly the class of feature `docs/INCIDENT_PROTOCOL.md` gates at
GV review. Folding those requirements into the build ticket's scope now so
they aren't discovered late:

- **Cost bound:** the single-flight lock + staleness window already bounds
  this to ≤1 authenticated `gh api` call per window per machine (axis 2) —
  nowhere near the 5000/hr cap.
- **Observability that separates real calls from cache hits:** the `doctor`
  three-state line (axis 5) already gives this — "up to date" / "out of
  date" both imply a successful recent check; "could not check" flags a
  dead fetcher distinctly.
- **A verified, deploy-plumbed kill switch:** the per-version silence
  mechanism (axis 3) suppresses the *banner*, not the *network call* — add
  a separate `FWF_SKIP_VERSION_CHECK=1` env var that disables the check
  entirely (no cache read, no background refresh), for fully offline/
  air-gapped operation. This is the actual kill switch the protocol asks
  for; silence-the-banner alone doesn't satisfy it.
- **Canary:** not really applicable at this scale (a read-only version
  comparison, not a mutating or costly operation) — note as N/A with
  reasoning rather than skip silently.

## Recommendation

**Design-to-build — and scoped as a fix/extension to existing code, not a
new feature.** All seven axes resolve to concrete, small, independently
shippable patches against `lib.sh:fwf_version_skew_warn`, `fwf:doctor()`,
and `dash/src/main.rs`'s existing banner mechanism. The single most
important fix is axis 4 (make the refresh genuinely non-blocking — today's
implementation can hang `fwf up` on a network stall, which is the one
axis where "it happens to work" isn't the same as "it's guaranteed to never
block"), closely followed by axis 6 (the newer-than-latest false-positive
bug, which is real and currently shipping). The build ticket should be
scoped as ONE ticket (not split, unlike #70) given the small, tightly-coupled
size of the whole patch set — a PM can draft it directly from the
numbered list above.
