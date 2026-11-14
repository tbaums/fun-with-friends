# Seats

Floors, the local mirror, seat worktrees, seat identity, and the boundary of what a seat may do.
Why a seat holds no GitHub token and what that buys.

## What a seat is

A seat is an interactive Claude Code session running in a tmux pane. It does
nothing until the supervisor wakes it. To wake it, the supervisor pastes one
rendered job into the pane, and the job ends with the path the verdict must be
written to. The seat does the job, writes one JSON verdict file
(`<path>.tmp`, then rename), and goes idle. An idle seat makes no model
requests. It has no loop, no polling and no tick file.

A seat is **Working** from the moment a job is typed in until its verdict
parses or its deadline passes. A half-written verdict file counts as "not yet".
When the deadline passes, the seat is **Stalled**. The supervisor is the only
thing that ever kills a pane, and it does not kill a stalled one, so a late
verdict is still picked up. The record releases a stalled seat back to
**Idle** after twenty minutes, or sooner with `fwf release`.

Seat states, as the record writes them: `idle`, `working`, `reported` (the
verdict arrived), `stalled`, `gone` (the pane no longer runs `claude`) and
`unknown`.

## Which seats a floor has

| Seat | tmux target | Exists when | Model |
|---|---|---|---|
| impl 1…N | `<session>:impl<n>` | always, `pairs` of them | `[models].impl`, else `opus` |
| qa 1…N | `<session>:qa<n>` | always, `pairs` of them | `[models].qa`, else `opus` |
| gv | `<session>:gv1` | `gv` is a key in `[models]` | `[models].gv` |
| pm | `<session>:pm1` | `pm` is a key in `[models]` | `[models].pm` |

A seat number is shared by both roles. `impl1` and `qa1` are a pair, and while
either one is busy (Working or Stalled) the number cannot be assigned to the
other role.

## Bringing seats up

```bash
fwf seats --up --manifest /path/to/.fwf/fwf.toml
```

For every seat, in order:

1. **Mirror.** It creates or fetches `<floor>/mirror/mirror.git`, a bare clone of
   the GitHub repository. The fetch uses an `ops` read token, so private
   repositories work.
2. **Worktree.** It clones `<floor>/wt-<role><n>` from the mirror at
   `base_branch`. Each worktree's only remote, `origin`, is the mirror's
   `file://` URL.
3. **Identity.** It sets the worktree's own `user.name`/`user.email` to
   `<role><n>` / `<role><n>@fwf.local`. This is re-applied on every run, so an
   identity edited by hand is put back. `fwf doctor` reports any worktree that
   commits as something else.
4. **Scripts.** It writes the start-up script and push guard, which are embedded
   in the binary, into `<floor>/home/.fwf/`.
5. **Pane.** If the seat's tmux window is not already running `claude`, it
   starts one: a new session `<session>` for the first seat, a new window named
   `<role><n>` for the rest.

A seat already up is left alone, so running `seats --up` twice is safe. The
start-up script waits up to 30 s for the pane's foreground command to become
`claude`, and fails the seat if it does not.

`fwf seats --down` kills the tmux session. It refuses while the record shows a
seat Working, unless you pass `--force`.

### What the pane runs

Each pane runs `claude --model <model> --permission-mode dontAsk
--setting-sources user` with:

- `HOME` set to `<floor>/home`, so a seat never reads your own Claude settings
  or the repository's `.claude/settings.json`;
- `CLAUDE_CODE_OAUTH_TOKEN` from `~/.fwf/seat-token` (create it with
  `claude setup-token`, mode `0600`). On macOS, if that file is absent, the
  token is copied from the Keychain entry `Claude Code-credentials`. That token
  rotates and can be revoked mid-job, so prefer the file. On Linux the file is
  required. With no token at all, `seats --up` fails that seat;
- onboarding and workspace trust pre-accepted in `<floor>/home/.claude.json`,
  so the pane comes up at the prompt.

The token is written to `<floor>/home/env.sh` (mode `0600`) and sourced by the
pane. It is never typed into the pane.

The start-up script needs `jq`, `tmux` and `claude` on the `PATH`.

## The boundary of a seat

A seat can write a bad branch to the local mirror and nothing more:

- **No GitHub token.** The pane's environment carries only the Claude login.
  Every GitHub write is the supervisor's, made under one of the three Apps after
  it has read the seat's verdict.
- **The only remote is the mirror.** Even an unguarded `git push` lands on the
  same machine. The supervisor copies the branch to GitHub only when the
  verdict says `implemented` and names it.
- **Denied tools.** `gh`, `curl`, `rm -rf`, `WebFetch` and `WebSearch` are
  denied in the seat's settings.
- **The push guard.** A `PreToolUse` hook (`<floor>/home/.claude/push-guard.sh`)
  judges every `git push`. It refuses any push that names `staging` or
  `main`, a bare `--force` or `-f`, an unqualified `--force-with-lease`, and a
  `+refspec` force. It
  allows `--force-with-lease=<ref>:<sha>`, which is what the rework job uses
  after a rebase.
- **Nothing is read from pane text.** The verdict file is the whole answer. A
  missing verdict means Stalled, never a guess.

## Floors

A floor is everything one repository's factory keeps on disk. It lives under
the manifest's `floor_dir`, or `~/.fwf/floors/<repo-name>` by default. The
layout is in [`configuration.md`](configuration.md#a-floor-directory). Two
floors on one host need different `session` names. `fwf run` writes
`<floor>/run.pid` and refuses to start a second loop on the same floor.

### Keeping the mirror current

When the supervisor fetches the mirror, it updates `staging` and `main` as
branches the seats can see. Every other upstream branch lands only under
`refs/remotes/upstream/*`, which seats cannot see. So a branch you push to
GitHub by hand is invisible to a seat until you fetch it into the mirror's
`refs/heads/`. The command is in [`troubleshooting.md`](troubleshooting.md).

## See also

- [`prompts.md`](prompts.md) — what a seat is told and what it must return.
- [`lifecycle.md`](lifecycle.md) — when each seat is woken.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
