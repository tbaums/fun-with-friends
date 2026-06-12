# `fwf dash` — the captain dashboard (#40)

The captain has two jobs that fight for the same surface. **Judgment** —
scoping work, weighing tradeoffs, deciding what ships — is bursty, high-context,
and belongs in the chat session. **State display and decision ergonomics** —
"what's the floor doing right now, and what is waiting on me?" — want a
persistent, deterministic surface you can glance at any time and act on with one
keystroke. `fwf dash` is that second surface.

```
fwf [--profile NAME] dash
```

It opens a dedicated tmux window (a new window in the coordination session when
you launch it from inside one; a throwaway standalone session otherwise):

```
┌ fwf · transom · dev ──────────── prod v0.16.0 ✓ · status.json ✓ ┐
│ ROLES    impl1 ● live   #441 auth refactor                      │
│          qa1   ● live   #438 gating                             │
│ PIPELINE staging +3 ahead · integration clean · main = prod     │
├ DECISIONS · y approve · n reject · c comment · o open · t captain┤
│ ▶ #384  un-gate: KB folder merge      GV ✓✓ · captain: ship      │
│   REL   release v0.17.0 → main        gate ✓                     │
└──────────────────────────────────────────────────────────────────┘
```

Top pane: a plain refresh loop rendering the status board. Bottom pane: an
[fzf](https://github.com/junegunn/fzf) decision inbox whose preview is the issue
body and whose keybinds are the actions. No daemon, no LLM in the read path or
the button path — `fzf` and `tmux` are the only dependencies beyond what the
factory already needs.

## Derived first

The dashboard works **with the factory parked**, because the core data is
derived live, not read from any agent:

| Field | Source |
|---|---|
| Roles (live/idle/down) | tmux pane state — the role's `@l` label + `pane_current_command` |
| Pipeline | `git` branch deltas in the target repo (staging ↦ integration ↦ default) |
| Decision queue | the label protocol: an **open** issue carrying **`product-wip`** that also has a **`GV-SIGNOFF`** comment is awaiting the human's go-ahead |

The decision queue is exactly the gate the PM and captain already honor: the PM
keeps a draft gated with `product-wip`; the GV signs off with a comment whose
first line is `GV-SIGNOFF`; the human removes the gate to approve. The dashboard
surfaces precisely the issues sitting at that point and lets you act on them.

## The judgment overlay: `status.json`

The captain's tick MAY write a small JSON file with the things that need
*judgment* to compute — a prod summary, a one-line pipeline read, per-role
"what is it on", a recommendation per decision, and any decisions that are not
gated issues (a release gate, say). The board **overlays** these when the file
is fresh and **degrades gracefully** — falling back to the derived values — when
it is stale or absent.

Path (per profile, honoring `$FWF_RUN_DIR`):

```
~/.fun-with-friends/state/<profile>/status.json
```

Freshness is the file's mtime: younger than `FWF_DASH_STALE_SECS` (default 90s,
i.e. "written this captain tick") counts as fresh. The overlay's *content* is
read with `jq`; without `jq` the board simply renders derived-only — never an
error.

### Schema

```json
{
  "ts": "2026-06-12T12:04:00Z",
  "prod": "v0.16.0 ✓ · e2e ✓",
  "pipeline": "staging +3 ahead · integration clean · main = prod",
  "roles": [
    { "id": "impl1", "issue": 441, "title": "auth refactor" },
    { "id": "qa1",   "issue": 438, "title": "gating" }
  ],
  "decisions": [
    { "id": "384", "kind": "ungate",  "issue": 384, "title": "un-gate: KB folder merge", "gv": "✓✓", "recommendation": "ship" },
    { "id": "REL", "kind": "release", "issue": null, "title": "release v0.17.0 → main",   "gv": "gate ✓", "recommendation": "ship tonight" }
  ]
}
```

| Field | Meaning |
|---|---|
| `ts` | ISO-8601 timestamp the captain wrote it (human-facing; freshness uses mtime) |
| `prod` | one-line production summary shown in the header |
| `pipeline` | one-line pipeline read; supersedes the git-derived line when fresh |
| `roles[]` | `id` = role tag (`impl1`, `qa1`, `pm`, …); `issue` + `title` = what it is on. Overlaid onto the derived live/down state |
| `decisions[]` | `id` = the row key (an issue number, or a label like `REL`); `kind` = `ungate`/`release`/…; `issue` = the tracker number (or `null`); `gv` = a terse sign-off marker; `recommendation` = the captain's one-line call. For a gated issue, `recommendation` enriches the derived row by matching `issue`; a `kind:"release"` entry appears as its own row |

Everything is optional. A `status.json` with only `{ "prod": "…" }` just fills
the prod field and leaves the rest derived.

## Keys

The inbox is the interactive surface; the board pane is display-only.

| Key | Decisions / Issues view | Roles view |
|---|---|---|
| `j` / `k`, arrows | move | move |
| `enter` | preview the full issue (right pane) | — |
| `y` | **approve** — remove `product-wip` + post the standard go-ahead | — |
| `n` | **reject** — post a "needs changes" comment, stay gated | — |
| `c` | **comment** — prompts for text, posts it | — |
| `o` | **open** — browser (gh) / pager (local) | — |
| `r` | — | **respawn** the role under the cursor (`fwf-respawn.sh`) |
| `s` | — | **stop** — swarm-wide graceful halt (`fwf-stop.sh`) |
| `t` | **captain passthrough** — prompts, then send-keys to the captain pane | (same) |
| `F1` / `F2` / `F3` | switch to Decisions / Issues / Roles | (same) |
| `ctrl-r` | force a reload | — |
| `q` / `esc` | quit | quit |

## Actions go through the tracker

`y`/`n`/`c` post to the issue via the same `fwf issues` abstraction the factory
uses, so the **gh** and **local** backends behave identically — `y` is exactly a
human typing "go ahead" and removing the gate. The captain reacts on its next
tick; nothing here talks to an LLM. `r`/`s` wrap the existing
`fwf-respawn.sh`/`fwf-stop.sh`. `t` injects a one-liner into the captain pane so
you never have to leave the dashboard to nudge it.

## Dry run

Every mutation runs through one seam:

```
FWF_DASH_DRYRUN=1 fwf dash act approve 384
# DRYRUN: gh issue comment 384 --body go ahead — approved via fwf dash; …
# DRYRUN: gh issue edit 384 --remove-label product-wip
```

It prints the exact command instead of executing it — useful for a cautious
look before you wire the keys to a live tracker, and the seam the hermetic tests
assert against.

## Tuning

| Env var | Default | Effect |
|---|---|---|
| `FWF_DASH_REFRESH` | `5` | Board redraw cadence (seconds). Each redraw re-derives the decision count (one issue read per gated draft), so on the **gh** backend keep this gentle to stay clear of API rate limits; on the local store it is free. |
| `FWF_DASH_STALE_SECS` | `90` | How fresh `status.json` must be (by mtime) to overlay it. |
| `FWF_DASH_DRYRUN` | `0` | When `1`, `act` prints the command instead of running it. |
| `PAGER` | `less -R` | Pager for `o` on the local backend. |

## Scope

v1 is the bash/fzf/tmux MVP above. A compiled TUI (bubbletea/ratatui), per-role
log tailing, a multi-profile switcher, and mouse support are explicit v2
candidates — earned only if the MVP proves the shape.
