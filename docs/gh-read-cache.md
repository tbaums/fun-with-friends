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
   snapshot locally.
3. **Safe fallback** — anything not provably REST-equivalent (`--search`,
   `--comments`, closed/merged state, an unmapped `--json` field, or a refresh
   error) falls back to a single-flight cache of real-`gh` output. Still collapsed;
   never wrong. Mutations are untouched (and in `--issues local` mode still
   fail-closed via the same shim, per `#34`).

Net effect: the per-cycle list polls that drained thousands of GraphQL points/hr
drop to **~zero** (REST + 304s), and the dash reads the same snapshot instead of
re-draining the budget.

## Tuning

- `FWF_GHCACHE_TTL` — cache freshness window in seconds (default `60`). Lower = fresher,
  more upstream fetches; higher = fewer fetches, staler reads. Minute-scale loops
  tolerate 60s well.
- `FWF_GHCACHE_DIR` — cache location (default `$FWF_RUN/ghcache/<owner>__<repo>/`).
- `FWF_GHCACHE_OFF=1` — bypass the cache entirely (straight passthrough to real `gh`).

## Notes

- The cache output is byte-identical to `gh` for the list/view shapes the templates
  and dash use (verified against live `gh` across issue/PR list projections, label
  filters, `--jq`, and `reviewDecision`). `reviewDecision` is computed from REST
  reviews and matches `gh` for repos without required-review branch protection
  (the factory's norm); under such protection it reports `""` rather than
  `REVIEW_REQUIRED`, which the gate logic treats identically (both ≠ `APPROVED`).
- `issue view` / `pr view` use the safe single-flight fallback (still collapsed);
  serving them from REST too is a future refinement — the per-cycle *list* polls
  were the drain.
