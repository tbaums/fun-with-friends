# `fwf dash` — the status board + decision inbox

![the fwf dash TUI: Activity tab with building/in-test/merged PRs and a detail pane](img/dash.png)

*The dash rendered against sample data — the Activity landing tab plus the detail
pane for the selected PR.*

A compiled Rust + ratatui TUI (the `dash/` crate) that shows the factory at a
glance and lets you act on the gated decisions without leaving the keyboard.
`fwf dash` resolves the profile, finds a runnable `fwf-dash` binary (the gh-dash
model — a bash tool shelling out to a compiled dashboard), points it at the bash
data/action layers, and execs it.

```
fwf dash                  # the only profile, or pass --profile NAME
fwf --profile myapp dash
```

Requirements: `jq` (the data provider). A Rust toolchain (`cargo`) is **not**
required when a prebuilt binary is available for your platform — see *Binary
resolution* below.

## Binary resolution (issue #63)

`fwf dash` resolves a runnable binary in this order, stopping at the first hit:

1. **`FWF_DASH_BIN`** — if set, it's used verbatim (no download, no build). A
   missing path surfaces a "no runnable binary" error rather than falling back.
2. **Cached arch+version binary** — `~/.fun-with-friends/cache/dash/fwf-dash-<version>-<slug>`.
   The cache key embeds the installed `VERSION`, so `fwf upgrade` automatically
   re-resolves rather than running a stale binary.
3. **Release asset download** — the matching prebuilt binary is downloaded from
   the GitHub Release for this `VERSION`, **sha256-verified against the published
   `fwf-dash-<version>-checksums.txt`**, cached, and run. A failed checksum or
   missing asset is ignored and resolution falls through. Uses `curl` (or `wget`)
   against the public release URL — no `gh`/token required.
4. **Source build** — the original first-run behavior: `cargo build --release` in
   `dash/`. This is the offline / unsupported-platform fallback and requires
   `cargo` — and a git-clone install (the release tarball doesn't ship the
   `dash/` crate source).

The `<slug>` is derived from `uname -s`/`uname -m`:

| Host | slug |
|---|---|
| macOS Apple Silicon | `darwin-arm64` |
| macOS Intel | `darwin-x86_64` |
| Linux x86_64 | `linux-x86_64` |
| Linux arm64 | `linux-arm64` |

Prebuilt binaries are produced and uploaded by the release workflow
(`.github/workflows/release.yml`) when a `vX.Y.Z` tag is pushed. Trust is rooted
in GitHub Releases over TLS plus the sha256 checksum (which guards against a
corrupted/mismatched download); GPG signing is not done in v1.

## What it shows

Derived-first, so it works with the factory **parked** — nothing here depends on
a running swarm:

| Field | Derived from |
|---|---|
| activity | open/merged PRs against the integration targets: BUILDING / IN TEST·REVIEW / MERGED (the landing tab) |
| roles | tmux pane liveness (`@l` label + current command): live / idle / down |
| pipeline | git branch deltas in the target repo (`staging +N ahead · …`) |
| decisions | the label protocol: open + `product-wip` + a `GV-SIGNOFF` comment ⇒ awaiting you |
| issues | every open issue (gated ones marked 🔒) |
| prod | the captain's `status.json` overlay when fresh, else `—` |
| ⛔ CAPTAIN NEEDS YOU | a full-width banner when the captain pane is blocked on you (read from the captain pane) |

The header's provenance stamp says where prod/pipeline came from: `status.json`
(fresh overlay, green), `stale` (overlay too old, amber), or `derived` (gray).

## Keys (no F-keys — the prior-art model)

| Key | Action |
|---|---|
| `1` `2` `3` `4` · `Tab` / `Shift-Tab` · `[` `]` | switch section (Activity / Roles / Decisions / Issues) |
| `j` `k` · `↑` `↓` | move the list cursor |
| `g` `G` | first / last row |
| `PgUp` `PgDn` · `Ctrl-u` `Ctrl-d` · wheel | scroll the detail preview |
| `Ctrl-r` | force a data refresh now (it also auto-refreshes on a timer) |
| `?` | help overlay |
| `q` · `Esc` | quit |

Actions (the verb depends on the active section):

| Section | Key | Action |
|---|---|---|
| Decisions | `y` / `x` | approve (un-gate + go-ahead) / reject — **confirms first** |
| Decisions, Issues | `c` | comment — opens an inline text field |
| Decisions, Issues | `o` | open in the browser (gh) / shows the detail (local) |
| Roles | `r` / `s` | respawn the role / stop the whole swarm — **confirms first** |
| anywhere | `n` `p` | scroll the detail / PR preview |
| anywhere | `t` | send a line to the captain pane (text field) |

`y` un-gates by removing the `product-wip` label and posting the standard
go-ahead, so the captain reacts on its next tick exactly as if you'd typed in
the issue. Actions run on a worker thread; the result shows in a colour-coded
status line and the board refreshes.

## Architecture

The binary is purely the renderer + input layer. Both sides stay in bash so the
gh/local backend abstraction, profile resolution, and the tests live in one
place:

- **`fwf-dash-data.sh`** — emits the whole dashboard as one JSON doc (read-only;
  never mutates). The binary shells out to it on the refresh timer.
- **`fwf-dash-act.sh`** — the write side (approve/reject/comment/open/respawn/
  stop/passthrough). Every mutation funnels through a `_run` seam:
  `FWF_DASH_DRYRUN=1` prints `DRYRUN: <argv>` instead of executing it (a real
  `--dry-run`, and what the hermetic tests assert on). In local-issues mode
  writes route to `fwf-issues.sh` and never reach gh.

### Environment

| Var | Effect |
|---|---|
| `FWF_DASH_REFRESH` | auto-refresh seconds (default 5, floor 1) |
| `FWF_DASH_BIN` | use this binary verbatim; skip download + build entirely |
| `FWF_DASH_CACHE_DIR` | where downloaded binaries are cached (default `~/.fun-with-friends/cache/dash`) |
| `FWF_DASH_NO_DOWNLOAD` | skip the release-asset download step (cache/source only) |
| `FWF_DASH_RELEASE_BASE` | base URL for release assets (test seam; default GitHub) |
| `FWF_DASH_DRYRUN` | actions print their constructed command instead of running |
| `FWF_DASH_STALE_SECS` | how old `status.json` may be before it's `stale` (default 90) |

### `status.json` (optional captain overlay)

`~/.fun-with-friends/state/<profile>/status.json`, written by the captain. When
fresh (by mtime) it overlays prod/pipeline, per-role detail, decision
recommendations, and any release-kind decisions; when stale or absent the board
falls back to the derived values. Shape:

```json
{
  "prod": "v0.16.0 ✓",
  "pipeline": "staging +3 ahead",
  "roles":     [ { "id": "impl1", "issue": 441, "title": "auth refactor" } ],
  "decisions": [ { "issue": 384, "recommendation": "ship" },
                 { "kind": "release", "id": "REL", "gv": "GV ✓✓", "title": "v0.7.0", "body": "…" } ]
}
```
