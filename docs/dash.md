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

It is a **single [fzf](https://github.com/junegunn/fzf) surface** that takes over
the terminal you run it in (run it in its own pane/window/terminal to keep your
captain chat visible; `q` returns you to the shell):

```
 fwf · transom · dev   ·   prod v0.16.0 ✓ · status.json ✓
 roles 3 live · 0 idle · 7 down   ·   pipeline staging +3 ahead · integration clean · main = prod
 j/k move · y approve · n reject · c comment · o open · t captain · F2 issues · F3 roles · ? help · q quit
 decisions ▸                                    ┌───────────────────────────────────┐
 ▶ #384  un-gate: KB folder merge   ·  GV ✓✓    │ # un-gate: KB folder merge         │
   #333  un-gate: graph v2 backlinks · GV ✓✓    │ labels: product-wip               │
   REL   release v0.17.0 → main      ·  gate ✓  │                                   │
                                                │ Merge the KB folders into one …   │
                                                └───────────────────────────────────┘
```

The **board is the fzf header** (top three lines: identity + prod, a roster glance
+ pipeline, and a context key legend). The **issue is the preview**. There is no
second pane and no refresh loop, so:

- **No flicker.** fzf repaints the whole surface atomically; the header is
  re-rendered (via `transform-header`) only on an action, a tab switch, or
  `ctrl-r` — never in a `clear`-and-reprint loop.
- **One input surface.** fzf runs with `--disabled` (no fuzzy-search field), so
  every printable key is a real binding — `j`/`k` move, `y`/`n`/`c`/`o` act,
  nothing lands as garbage in a filter. A persistent key legend lives in the
  header and `?` opens a full help overlay; a first-timer never needs this doc.
- **Nesting is a non-issue.** One fullscreen app has no inner panes to switch
  focus between, so it behaves the same whether or not you are inside (an outer)
  tmux. No daemon, no LLM in the read path or the button path — `fzf` is the only
  dependency beyond what the factory already needs.

## Setup

- **`fzf` must be installed** (`brew install fzf` / `apt install fzf`). It is the
  one dependency the dashboard adds beyond the factory's; `fwf dash` errors with a
  clear message if it is missing.
- The dash reads the profile like every `fwf` command, so it needs
  `profiles/<name>.sh` to resolve. A profile written by `fwf init`/`fwf start`
  lives in *that* install's `profiles/` dir — a **fresh clone or git worktree of
  the fwf repo has only `profiles/example.sh`**, so run the dash from your real
  install (or copy the profile in / pass `--profile`).

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

The legend is always visible in the header, and `?` opens this as an overlay.

| Key | Decisions / Issues view | Roles view |
|---|---|---|
| `j` / `k`, `↓` / `↑`, `g` / `G` | move (the preview follows the cursor) | move |
| `y` | **approve** — remove `product-wip` + post the standard go-ahead | — |
| `n` | **reject** — post a "needs changes" comment, stay gated | — |
| `c` | **comment** — prompts for text, posts it | — |
| `o` | **open** — browser (gh) / pager (local) | — |
| `r` | — | **respawn** the role under the cursor (`fwf-respawn.sh`) |
| `s` | — | **stop** — swarm-wide graceful halt (`fwf-stop.sh`) |
| `t` | **captain passthrough** — prompts, then send-keys to the captain pane | (same) |
| `F1` / `F2` / `F3` | switch to Decisions / Issues / Roles | (same) |
| `?` | help overlay · `ctrl-r` force refresh · `q` / `esc` quit | (same) |

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
| `FWF_DASH_STALE_SECS` | `90` | How fresh `status.json` must be (by mtime) to overlay it. |
| `FWF_DASH_DRYRUN` | `0` | When `1`, `act` prints the command instead of running it. |
| `PAGER` | `less -R` | Pager for `o` on the local backend. |

## Scope

v1 is the bash/fzf/tmux MVP above. A compiled TUI (bubbletea/ratatui), per-role
log tailing, a multi-profile switcher, and mouse support are explicit v2
candidates — earned only if the MVP proves the shape.
