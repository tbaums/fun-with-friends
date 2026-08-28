# gh read cache (REST + ETag)

The factory's coordination bus is the GitHub API. Ten agents each polling
`gh issue list` / `gh pr list` every 1–2 minutes use **GraphQL** — a 5,000-point/hr
bucket with tight secondary limits — and drain it in minutes, stalling the floor
(and any human `gh` you run shares the same pool). This is the bus failure that
`#57` is about.

## What it does

A `gh` shim on every pane's PATH (`$FWF_RUN/ghguard/gh`, installed by
`fwf_install_ghguard`) routes the hot, high-frequency reads through a **shared,
single-flight cache** (`fwf-ghcache.sh`):

1. **Single-flight + TTL** — N identical polls within `FWF_GHCACHE_TTL` seconds
   (default 60) collapse to **one** upstream fetch that all panes and the dash
   read. Always correct: it serves the same bytes `gh` would.
2. **REST + ETag** — `issue list` / `pr list` are served from **one canonical
   per-topic REST fetch** off the **core** bucket (separate from GraphQL), with an
   `If-None-Match` conditional request, so an unchanged poll returns `304` for free.
   Every list variant (per-label, per-base, projection, `--jq`) filters that one
   snapshot locally. Three enumerated `--search` patterns filter the same
   canonical open-set snapshot (below). `issue/pr view --json …` (+ `comments`)
   and `pr diff --name-only` are likewise served from per-resource REST+ETag
   fetches, each keyed and ETag'd separately from the list-level snapshot.
3. **Safe fallback** — anything not provably REST-equivalent (an unrecognized
   `--search` string, an unmapped `--json` field, closed/merged state, any other
   `view`/`diff` flag, or a refresh error) falls back to a single-flight cache of
   real-`gh` output. Still collapsed; never wrong — an unrecognized query FAILS
   SAFE to real `gh`/GraphQL rather than risk serving the wrong issue/PR set.
   Mutations are untouched (and in `--issues local` mode still fail-closed via
   the same shim, per `#34`).

### `--search` translation

Only the exact literal token patterns the templates emit are translated —
built from `is:open`, `is:closed`, `label:<x>`, `-label:<x>` — filtered
locally over the same canonical open-set snapshot `list` uses. Any other
`--search` string (`author:`, `sort:`, free text, a date qualifier, `#123`,
…) is not modeled and falls straight through to the safe fallback. A test
(`test/run.sh`) re-greps `templates/` for every literal `--search "…"` string
built entirely from the recognized vocabulary and pins that set, so a
template edit that adds a new one goes RED until this cache is taught it.

### `pr diff --name-only`

Served from `/repos/{owner}/{repo}/pulls/{n}/files`, following **every**
page (30/page) — a truncated file list would make a role wrongly conclude a
file was untouched. Any other `pr diff` flag (a real patch, `--color`, …)
falls back to real `gh`.

Net effect: the per-cycle list, view, search, and diff-file-name polls that
drained thousands of GraphQL points/hr drop to **~zero** (REST + 304s), and the
dash reads the same snapshot instead of re-draining the budget.

## Degraded reads (issue #266)

"Correct" above means *the cache never invents data* — but until #266, a
read could return **stale data with exit 0**, indistinguishable from a
validated one. Two mechanisms:

- **The lock-wait fallback.** When another pane's refresh is already in
  flight, a contended read waits up to `FWF_GHCACHE_LOCK_WAIT` (default 8s)
  plus a short poll loop for it to finish. If it doesn't finish in time, the
  existing (possibly stale) snapshot is served anyway — the right call
  (stale beats none) — but it was never re-validated against upstream.
- **A comment thread past the 100-comment page boundary.** Only page 1 of a
  paginated read carries a conditional ETag; a `304` on page 1 alone used to
  be trusted as "the whole thread is unchanged," which is wrong once there's
  a page 2+ a new comment can land on invisibly to that check. Fixed:
  a page-1 `304` on a thread already ≥100 comments long reuses page 1's
  confirmed-unchanged records from cache but still re-checks pages 2+
  unconditionally. Under 100 comments (a single page), the fast `304` path
  is unchanged — page 1 unchanged genuinely is the whole thread unchanged.

**The exit code, not just stdout, is where this surfaces.** `serve issue|pr
list|view` returns `0` when the served data was validated against upstream
(a fresh fetch, or a confirming `304`), or `2` when data was served but its
freshness was never confirmed (the lock-wait fallback above) — same
JSON-on-stdout either way, so a caller that only checks "did this print
something" cannot tell them apart. A caller that wants to know must check
the exit code. Any other/nonzero code is `real_gh`'s own exit from the
safe-fallback path or a direct passthrough, unrelated to degradation.

Consumers, and whether a degraded (unconfirmed) read is tolerable for each:

- **`fwf-dash-data.sh`** (the operator's decision queue) — intolerable, and
  handled: a degraded per-resource view is marked on its row; a gated
  ticket's GV sign-off state is **three-way** (`SIGNED` / `NONE` /
  `INDETERMINATE` — "could not tell" never renders as "no sign-off," the
  same shape as `fwf authz`'s `INDETERMINATE`), with indeterminate tickets
  counted and surfaced as their own summary row rather than silently
  dropped from the queue; a degraded **list** read (which can mean an
  entire just-filed or just-gated ticket is absent, not just stale) gets
  its own summary row too, since no per-row check is ever reached for a row
  that isn't in the list at all.
- **`fwf-authz.sh`** (the operator un-gate sentinel oracle) — intolerable,
  and now structurally exempt rather than merely fail-closed: issue #265
  found that this cache's own freshness defect (a `stdout/` entry can be
  REWRITTEN with a bumped mtime on a 304 renewal while still serving
  pre-edit content, so it looks fresh to every mtime/TTL check while
  serving stale content — the failure mode this section's `2`/degraded
  signal exists to catch, but through a **success** exit, not a failure
  one) produced a live false HELD and a live false AUTHORIZED. The
  `read_ok=0` guard this doc describes above catches a non-zero exit; a
  stale-and-self-renewing read exits zero, so it could not see this one.
  As of #265, `fwf-authz.sh`'s thread read no longer goes through this
  cache at all (a direct `gh issue view --json comments` call) — not
  because the degraded-read signalling above is wrong, but because a
  reader this security-critical, running only a handful of times per
  ticket, should not depend on a cache tuned for pollers in the first
  place. **This does not fix the underlying cache defect** — every other
  reader listed below still depends on this cache's own freshness
  behaving as documented, and #266 (still open) is where that gets fixed,
  not here.
- **Every other `gh issue|pr list|view` call** — routed here transparently
  via the `gh` shim, so its exit code becomes the shim's own. Tolerable by
  default: a caller that ignores the exit code sees no behaviour change
  (stdout is identical to before); a caller that already treats a nonzero
  `gh` exit as "don't trust this" gets strictly safer, not more fragile,
  the moment it starts occasionally seeing `2` where it used to always see
  `0`.

## Budget observability (issue #239)

Individually, `#140`'s per-tick rehydration scan, `#146`'s per-tick worktree
fetch, and `#147`'s per-tick liveness check are each cheap. **Nobody owned
the sum**, and every seat shares the owner's GitHub account, so the floor is
one consumer that looks like a dozen — the account that fails when the
budget runs out. A `gh` call failing for rate-limit reasons doesn't surface
as "I could not read the world"; without this section's mechanisms it
surfaces as an empty result, which every reader downstream would treat as
an authoritative "there is nothing in flight" (the same defect shape as
`#211` and `#193`).

**Per-role, per-tick, measured (not estimated):**

| Caller | Reads/tick | Scales with |
|---|---|---|
| `#140` rehydration scan | 1 `gh pr list` | 1 per role |
| `#146` worktree refresh | 1 `git fetch` (not `gh`, no quota cost) | 1 per role |
| `#147` liveness check | 1 `gh issue list`/`gh pr list` (`fwf_build_plane_blocked`/`fwf_pm_plane_blocked`, `lib.sh`) | 1 per role |
| `fwf-dash-data.sh` | ~1 `gh issue/pr view` per **open, gated** issue (`decisions_json`'s GV-signoff check) | the **open gated backlog**, not `FWF_PAIRS` or the tick interval |

The dash term is the one that does not shrink with a healthy floor and does
not show up in a per-role accounting — it scales on the backlog, which can
double while every other term stays flat. All four terms are collapsed by
this cache's TTL/ETag machinery (above) to a small fraction of their raw
call count; **it is the CHARGED (200) rate that matters, never the raw call
count**, which is why the metrics below count responses, not requests.

**Measuring spend, not requests** (`fwf-ghcache.sh metrics [window-seconds]`,
default window `3600`): `N` identical polls inside the TTL window collapse
to one fetch, and an unchanged poll returns a free `304` — a call-site
counter would measure requests, which differs from spend by the hit rate,
and on a dozen roles polling the same coordination bus the hit rate **is**
the design. Three counts, recorded as a bounded rolling log at the actual
REST+ETag branch points (the canonical list fetch and the per-resource view
fetch — this cache's two dominant, documented consumers):

- `hit` — served from the TTL window, zero upstream cost.
- `revalidated` — an upstream `304`, zero primary-quota cost.
- `charged` — a genuine `200`, the only kind that spends quota.

```
$ fwf-ghcache.sh metrics 3600
hit=42 revalidated=8 charged=3 window=3600s
```

A burst of identical polls shows up entirely as `hit`, never as spend —
that is the property worth checking after any change near this cache.

**Headroom** (`fwf-ghcache.sh headroom`) reports `gh api rate_limit`'s
`remaining`/`limit`/`reset`, cached on the **same TTL** as every other read
here — headroom must not become a fourth per-tick call. On any failure
(network, auth, the rate limit itself being exhausted, `/rate_limit`'s own
secondary-limit cost) it prints the literal string `UNKNOWN` and exits
non-zero — never a guessed number. `fwf doctor` surfaces this alongside the
observed `charged` rate over the last hour and an estimated time-to-
exhaustion (`_doctor_api_budget_check`); like every other `doctor` sub-check
it is informational and never fails `doctor` overall.

**The dash renders exhaustion as a NAMED element** (`fwf-dash-data.sh`'s
`api_budget_json`, consumed by the Rust dash's `ApiBudget`/
`render_api_budget_banner`): a full-width red banner reading `API BUDGET
EXHAUSTED`, shown whenever the headroom read reports zero remaining **or**
could not complete at all — both mean "do not trust the read layer right
now" from an operator's chair, and both get the same visible alarm (the
banner text still says which one it is). This is deliberately a specific,
assertable string rather than "an operator could probably notice the dash
looks emptier than usual" — the latter is unfalsifiable, and it was this
requirement's own rejected first draft.

## Tuning

- `FWF_GHCACHE_TTL` — cache freshness window in seconds (default `60`). Lower = fresher,
  more upstream fetches; higher = fewer fetches, staler reads. Minute-scale loops
  tolerate 60s well.
- `FWF_GHCACHE_DIR` — cache location (default `$FWF_RUN/ghcache/<owner>__<repo>/`).
- `FWF_GHCACHE_OFF=1` — bypass the cache entirely (straight passthrough to real `gh`).
- `FWF_GHCACHE_LOCK_WAIT` (default `8`) / `FWF_GHCACHE_WAITER_ITERS` (default
  `12`, one per second) — how long a contended read waits for another pane's
  in-flight refresh before serving the existing snapshot degraded (above).
  Test-only in practice; lowering them in production just serves degraded
  reads sooner under contention.

## Notes

- The cache output is byte-identical to `gh` for the list/view/comments shapes the
  templates and dash use (verified against live `gh` across issue/PR list
  projections, label filters, `--jq`, `reviewDecision`, and view/comments). A
  `--json comments` call is never served a stale comment-less body from an
  earlier comment-less call of the same issue/PR — the base resource and its
  comments are cached in separate, independently-ETag'd files, keyed by
  resource identity alone, and the field projection is recomputed from those
  raw files on every call rather than cached. `reviewDecision` is computed from
  REST reviews and matches `gh` for repos without required-review branch
  protection (the factory's norm); under such protection it reports `""` rather
  than `REVIEW_REQUIRED`, which the gate logic treats identically (both ≠
  `APPROVED`).
- Comment fields with no REST equivalent (`isMinimized`, `minimizedReason`,
  `reactionGroups`, `viewerDidAuthor` — GraphQL-only concepts) default to the
  common case (unminimized, not-the-viewer) rather than being omitted.
