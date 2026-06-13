# `fwf dash` — the status board + decision inbox

A compiled Rust + ratatui TUI (the `dash/` crate) that shows the factory at a
glance and lets you act on the gated decisions without leaving the keyboard.
`fwf dash` resolves the profile, builds the binary on first run (the gh-dash
model — a bash tool shelling out to a compiled dashboard), points it at the bash
data/action layers, and execs it.

```
fwf dash                  # the only profile, or pass --profile NAME
fwf --profile transom dash
```

Requirements: `cargo` (to build the binary on first run; or set `FWF_DASH_BIN`
to a prebuilt one) and `jq` (the data provider).

## What it shows

Derived-first, so it works with the factory **parked** — nothing here depends on
a running swarm:

| Field | Derived from |
|---|---|
| roles | tmux pane liveness (`@l` label + current command): live / idle / down |
| pipeline | git branch deltas in the target repo (`staging +N ahead · …`) |
| decisions | the label protocol: open + `product-wip` + a `GV-SIGNOFF` comment ⇒ awaiting you |
| issues | every open issue (gated ones marked 🔒) |
| prod | the captain's `status.json` overlay when fresh, else `—` |

The header's provenance stamp says where prod/pipeline came from: `status.json`
(fresh overlay, green), `stale` (overlay too old, amber), or `derived` (gray).

## Keys (no F-keys — the prior-art model)

| Key | Action |
|---|---|
| `1` `2` `3` · `Tab` / `Shift-Tab` · `[` `]` | switch section (Roles / Decisions / Issues) |
| `j` `k` · `↑` `↓` | move the list cursor |
| `g` `G` | first / last row |
| `PgUp` `PgDn` · `Ctrl-u` `Ctrl-d` · wheel | scroll the detail preview |
| `Ctrl-r` | force a data refresh now (it also auto-refreshes on a timer) |
| `?` | help overlay |
| `q` · `Esc` | quit |

Actions (the verb depends on the active section):

| Section | Key | Action |
|---|---|---|
| Decisions | `y` / `n` | approve (un-gate + go-ahead) / reject — **confirms first** |
| Decisions, Issues | `c` | comment — opens an inline text field |
| Decisions, Issues | `o` | open in the browser (gh) / shows the detail (local) |
| Roles | `r` / `s` | respawn the role / stop the whole swarm — **confirms first** |
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
| `FWF_DASH_BIN` | use a prebuilt binary; skip the first-run `cargo build` |
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
