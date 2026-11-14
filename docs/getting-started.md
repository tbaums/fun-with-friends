# Getting started

Install fwf 1.0, write your first `.fwf/fwf.toml`, make the first run, and read the dash.
The entry point for someone who has never run fwf.

At the end of this page, one issue in your repository has been specced,
signed off, implemented by a seat, reviewed by QA and merged to your base
branch. The sign-off is yours to give.

## What you need

- **macOS (Apple Silicon) or Linux (x86_64)**, with `git`, `tmux`, `jq`, `curl`
  and a stable Rust toolchain.
- **Claude Code** (`claude` on your `PATH`) and a Claude subscription. Every
  seat is a Claude Code session.
- **A GitHub repository** with two branches: one that PRs merge into (default
  `staging`) and one that releases come from (default `main`). The base branch
  must exist before seats come up, because every seat worktree is cloned from
  it.
- **Three GitHub Apps** installed on that repository, with their keys on this
  machine. This takes about ten minutes; see [`github-apps.md`](github-apps.md).

## 1. Install

```sh
git clone https://github.com/tbaums/fun-with-friends && cd fun-with-friends
./install.sh                 # builds one/ and links `fwf` into ~/.local/bin
fwf version
```

`install.sh` builds the binary from `one/` when cargo is present, links it as
`fwf` (and as `fwfd`, an old alias), and installs the 0.x tool as `fwf-legacy`.

**Keep this checkout where it is.** The binary reads the seat job prompts at
run time from the `prompts/` directory of the tree it was built in. Move or
delete the checkout and every seat job fails with `No such file or directory`.
`install.sh` with `FWF_VERSION=X.Y.Z` installs a release asset instead of
building, and a release binary looks for its prompts at its build machine's
path. Build from source for a floor.

## 2. Register the GitHub Apps

Follow [`github-apps.md`](github-apps.md). When you finish, you have:

```
~/.fwf/keys/fwf-impl.pem  ~/.fwf/keys/fwf-qa.pem  ~/.fwf/keys/fwf-ops.pem
~/.fwf/apps.toml          # [impl], [qa], [ops]: app_id, installation_id, key
```

## 3. Give the seats a Claude login

Each seat pane starts with its own `HOME`, so it does not inherit your login.
Its token comes from `~/.fwf/seat-token`:

```sh
claude setup-token                       # prints a long-lived token
umask 077 && pbpaste > ~/.fwf/seat-token # or paste it in by hand; mode 0600
```

On macOS, if this file is missing, `fwf seats --up` copies the short-lived
access token out of the Keychain instead. That token rotates and can be
revoked in the middle of a job. On Linux the file is required.

## 4. Write the manifest

The manifest lives in the repository you want worked, not in fwf's checkout:

```sh
cd /path/to/your-repo
mkdir -p .fwf && fwf init-manifest > .fwf/fwf.toml
$EDITOR .fwf/fwf.toml
```

The example manifest is fwf's own, so change at least these keys:

- `repo = "your-org/your-repo"`;
- `issues = [N]`, the issue you want worked first. `fwf run` refuses to start
  with an empty list;
- `[suites]`: replace both commands with your repository's own. `fast` is what
  every seat must pass before it answers, and what runs after every merge;
- `[models]`: keep `gv` and `pm`. Without them there is no GV or PM seat, and no
  spec cycle.

Every key is in [`manifest.md`](manifest.md). The manifest may hold at most 25
top-level keys, and a misspelt key is ignored silently, so check the line
`fwf up` prints.

## 5. Validate

```sh
fwf up
```

```
manifest ./.fwf/fwf.toml ok: repo your-org/your-repo · staging → main · gate label "product-wip" · 1 pair(s) · session fwf-one · venue local (8 GB, 1800 s) · suites ["e2e", "fast"]
  floor: /Users/you/.fwf/floors/your-repo
  app impl: ok
  app qa  : ok
  app ops : ok
  seat fwf-one:impl1: absent
  seat fwf-one:qa1: absent
```

`fwf up` mints a token from each App and stops at the first thing that is not
ready, naming it. It also refuses to start a floor on an fwf older than the
latest release; run `fwf self-upgrade`, or set `FWF_ALLOW_STALE=1`.

## 6. Decide about the meter

The loop parks itself when Claude subscription usage gets high, but only if you
tell it the usage. It reads the last line of `~/.fwf-meter-log`:

```sh
echo "$(date '+%Y-%m-%d %H:%M:%S') weekly=20" >> ~/.fwf-meter-log
```

With no file, nothing brakes: the loop runs whatever the usage. Once the file
exists, a reading older than 45 minutes also parks the floor, so whatever
writes it must keep writing. The format and every case are in
[`operations.md`](operations.md#the-meter-and-its-brake).

## 7. Bring up the seats

```sh
fwf seats --up
fwf doctor
```

This creates the floor under `~/.fwf/floors/<repo-name>`: a bare mirror of your
repository, one worktree per seat, and one tmux window per seat in the session
`fwf-one`. Each window runs `claude`. Attach to check that every pane is at the
Claude prompt and logged in:

```sh
tmux attach -t fwf-one       # Ctrl-b w to pick a window, Ctrl-b d to leave
```

`fwf doctor` confirms every App can mint a token and every worktree commits
as its own seat. See [`seats.md`](seats.md).

You do not need to create the gate worktree. The loop clones `gate-wt` itself
at its first merge. Create it by hand only if you want to run `fwf gate` before
then (see [`gates-and-promotion.md`](gates-and-promotion.md)).

## 8. File an issue and run the loop

File the issue with the `product-wip` label, and put its number in `issues`.
Then start the loop in a window of its own:

```sh
tmux new-window -d -t fwf-one -n run "fwf run --manifest $PWD/.fwf/fwf.toml"
```

Or run one tick in the foreground, to watch it decide:

```sh
fwf run --once
```

What happens next, one step per tick:

1. **GV** reads the issue. If it is not ready, GV posts why and the issue
   stays gated. Edit the issue, and GV reads it again.
2. **PM** rewrites the issue as a spec with acceptance criteria.
3. **GV** reads the spec back and signs it off.
4. **You** un-gate it. This is the one decision fwf does not make for you,
   unless the manifest sets `delegate_ungate`:

   ```sh
   fwf ungate --repo your-org/your-repo --issue N --by your-name
   ```

5. **impl** builds it on a branch, and the loop opens a draft PR.
6. **QA** checks the PR against each acceptance criterion and approves it or
   asks for changes. Changes go back to impl.
7. The loop **merges** the approved PR into `staging` and runs `fast` on the
   merge.

[`lifecycle.md`](lifecycle.md) is the full path, with every label and every
refusal.

## 9. Watch it

```sh
fwf status                   # one screen, including "needs you"
fwf dash                     # the live board; q to quit
fwf why <pr> --log ~/.fwf/floors/your-repo/run.jsonl
```

Stop the loop with `fwf stop`, never with `pkill`. Promotion to `main` is
yours: `fwf promote --repo your-org/your-repo --from staging --to main --suite fast`.
Read [`operations.md`](operations.md) before you leave a floor running.

## See also

- [`manifest.md`](manifest.md) — every manifest key.
- [`troubleshooting.md`](troubleshooting.md) — when a step above refuses.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
