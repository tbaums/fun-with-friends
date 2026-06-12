# Containerizing fun-with-friends — design exploration (#3)

Status: **explored, first slice shipped.** This doc answers issue #3's open
question — is container isolation worth the complexity of running interactive
agents + tmux + CLI auth in containers, and what's the smallest valuable first
slice — and records the design so the next slice doesn't re-derive it.

## TL;DR / recommendation

**Yes, but only for the build floor, and incrementally.** The factory's value
concentration is the *floor* (impl/qa/conductor churn: parallel e2e, port
collisions, worktree blast radius), and that is also the part that
containerizes cleanly — it is non-interactive from the human's point of view
(you talk to the captain, not to impls). Keep the coordination session
(captain especially) on the host: it is the one interactive, context-carrying
role, and host tmux attach UX is exactly what we want there.

The smallest valuable slice is **one image that can run the whole factory
toolchain** (tmux + git + gh + claude + bash), with auth and state mounted
from the host — shipped here as `containers/Dockerfile` + `fwf shell`. It
proves the riskiest unknown (interactive `claude` under tmux in a container)
cheaply, and every later slice (floor-in-container, e2e isolation, prod
process boundary) builds on the same image.

## What the host-coupling pain actually was

From the issue (all hit live on one Mac):

| Pain | Root cause | Does a container fix it? |
|---|---|---|
| Worktree/profile fragility (wrong `FWF_PROFILE` → respawn at missing path) | host-global env + shared FS | Partially — an image bakes the profile; but the real fix is config validation, not isolation |
| launchd stripped-PATH breakage | macOS service manager | Yes — container entrypoint owns PATH |
| `.git/*.lock` leaks in the data repo from host writers (Spotlight/mds etc.) | every host process can touch the repo | **Yes, decisively** — a container's process set is closed; nothing else can touch a volume-scoped repo |
| Fixed e2e ports (3940/18080) collide across worktrees | shared host network namespace | **Yes, decisively** — per-container netns makes fixed ports free again, and e2e runs parallelize |

Note two of the four are *fully* solved only by containers; the other two have
cheaper non-container fixes. That asymmetry shapes the scoping below.

## Scope options, evaluated

- **(a) Build-floor agents only — recommended target.** Impls/QA/conductor are
  autonomous loops; nobody types into them. Each pane's `claude` runs fine
  inside a container (see "Interactive agents" below). Wins: per-container
  netns ends the e2e port wars; a contained process set ends "who touched my
  worktree"; the floor becomes reproducible (`docker run` N copies) and
  disposable (issue #6's floor-down = stop containers).
- **(b) Prod server+worker.** High value when the factory babysits a live
  service (a clean process boundary around the app's data repo kills
  host-writer lock jams), but it is app-specific, not fwf-generic — it belongs
  in the app repo's profile, not in fwf. fwf's contribution is the base image + the volume/auth pattern below.
- **(c) Whole tmux session(s) including captain.** Works (tmux-in-container +
  `docker exec -it … tmux attach` is fine), but costs the captain's host
  affordances (clipboard, notifications, local editors) for no isolation win —
  the captain is read-mostly on the repo and the human's chat surface. Skip.
- **(d) Everything.** (c)'s costs plus image sprawl. Skip.

## The riskiest unknown: interactive `claude` + tmux + auth in a container

Explored; it works, with these specifics:

- **tmux**: runs identically in a container. The factory already drives panes
  via `tmux send-keys` from scripts; those scripts run *inside* the container
  (entrypoint) or via `docker exec`. Attach from the host:
  `docker exec -it fwf-floor tmux attach -t friends-build`.
- **claude auth** (validated live): the Linux CLI reads
  `~/.claude/.credentials.json` + `~/.claude.json`. Gotcha #1: on a macOS host
  the OAuth blob is NOT in `~/.claude` — it lives in the **Keychain**
  (`security find-generic-password -s "Claude Code-credentials" -w` extracts
  it). Gotcha #2: Docker Desktop cannot nest a file mount inside an
  already-bind-mounted dir, so don't mount `~/.claude` wholesale — copy the
  two files into a throwaway 0700 dir and mount them file-by-file (`fwf
  shell` does exactly this; sandbox-side token refreshes are discarded).
  No secrets are ever baked into the image. Proven: `claude -p` answers
  authenticated inside the container.
- **gh auth** (validated live): same Keychain story on macOS — mounting
  `~/.config/gh` carries no token. Inject `GH_TOKEN="$(gh auth token)"`
  instead; gh honors it everywhere. git identity: mount `~/.gitconfig`
  read-only.
- **Linux-vs-macOS**: the image is Linux, so a floor container on a Mac host
  exercises the Linux path of everything (a side benefit: it is the CI
  environment, locally).

## Networking

- **Floor containers**: default bridge netns. e2e fixed ports live privately
  per container — two floors (or a floor + a host run) no longer mutually
  reap. Publish nothing by default; a dev-UI port can be `-p`-published when a
  human wants to look.
- **Prod (app-side)**: Tailscale is the app repo's concern. Two workable
  patterns, decided there: host-network mode (container shares the host's
  tailnet identity — simplest on macOS where host networking is now supported)
  or `tailscaled` in the container with its own node identity (cleaner, one
  more secret to manage).

## State & durability

- The **app repo + worktrees** mount as a named volume or host bind. Worktrees
  stay host-visible (the human inspects them); the container only adds a
  closed process set around them.
- **Data repos** (an app's separate state/content repo): named volume owned by
  exactly one container — that is the whole point (no Spotlight, no stray host
  writer).
  Back up via `git push` from inside, which the factory already does.
- `~/.fun-with-friends` run-state (locks, STOP sentinel) mounts shared so host
  `fwf stop` still reaches contained agents.

## Cost / complexity honestly

- One Dockerfile to maintain (small: debian-slim + tmux/git/gh/claude).
- macOS Docker file-IO overhead on bind-mounted worktrees is real for heavy
  builds; named volumes avoid it where host visibility isn't needed.
- Debugging an agent inside a container is one `docker exec -it` away — about
  the same as today's `tmux attach`.
- The image adds a supply-chain surface (pin the gh/claude install steps).

## Slices, in order of value

1. **[shipped here] Base image + `fwf shell`** — `containers/Dockerfile`
   builds the full toolchain image; `fwf shell` (new subcommand) builds it and
   drops you into an authenticated, tmux-capable container with the repo,
   `~/.claude`, and gh auth mounted. Proves auth + tmux + claude end-to-end
   and gives a reproducible Linux sandbox for fwf development itself.
2. **Floor-in-container** — `fwf up --container`: run the BUILD session's
   panes inside one floor container (coordination stays on host). Pairs with
   issue #6's floor lifecycle: floor-down = `docker stop`.
3. **e2e isolation** — conductor runs `E2E_CMD` inside a throwaway container
   (`docker run --rm` of the same image), ending fixed-port collisions without
   containerizing any long-lived agent.
4. **Prod process boundary** — app-repo profile concern; reuse the image +
   volume pattern (out of scope for fwf core).
