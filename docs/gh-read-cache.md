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

## Tuning

- `FWF_GHCACHE_TTL` — cache freshness window in seconds (default `60`). Lower = fresher,
  more upstream fetches; higher = fewer fetches, staler reads. Minute-scale loops
  tolerate 60s well.
- `FWF_GHCACHE_DIR` — cache location (default `$FWF_RUN/ghcache/<owner>__<repo>/`).
- `FWF_GHCACHE_OFF=1` — bypass the cache entirely (straight passthrough to real `gh`).

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
