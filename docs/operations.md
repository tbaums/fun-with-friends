# Operations

The meter and its brake, `run.jsonl` as the only record, cost reporting, the dash, and the tmux layout.
What you do to keep a floor running, and what to read when it stops.

Everything below was learned by breaking a live floor. Three of the seven rules
are now enforced by the product; they are kept here because the reasoning is
what generalises, not the flag.

## Seven rules

1. **Stop the loop with `fwf stop`, never with `pkill`.**

   ```bash
   fwf stop --manifest /path/to/.fwf/fwf.toml
   ```

   `fwf run` writes its own pid to `<floor>/run.pid` at startup and refuses to
   start beside a live one; `fwf stop` sends SIGTERM to exactly that pid. Both
   `pkill` forms are traps: `pkill -f "fwf run"` matches the command line of
   the shell you typed it in — over ssh that is your own session — and
   `pkill -x fwf` kills every in-flight `fwf gate` and `fwf qa`, because they
   are the same binary. **`pkill -x fwf` is never correct — use `fwf stop`.**

   The three long-running verbs now re-exec themselves under their own names
   (`fwf-run`, `fwf-gate`, `fwf-qa`, via `~/.fwf/bin/`), so `ps -o comm=` tells
   them apart and a signal aimed at one cannot reach another (#678). That is a
   safety net, not a new habit: `pkill -x fwf-run` still matches every floor's
   loop on the host, and `fwf stop` matches exactly one.

   If you must do it by hand, do it by pid:

   ```bash
   kill "$(cat /path/to/floor/run.pid)"
   ```

   A loop killed with SIGKILL cannot clean up its pidfile. That is fine: the
   next `fwf run` checks whether the pid is alive and reclaims a dead one.

2. **Judge liveness by the record, not by stdout.**

   A seat wait is routinely 30+ minutes, and for all of it the loop is doing
   exactly one thing: waiting. `fwf status`'s first two lines answer the
   question directly —

   ```
   record age 42s
   loop: pid 81234 (alive)
   ```

   — and inside a wait the loop now prints a line about once a minute:

   ```
   waiting: qa seat 1 on #1419 (120s elapsed, deadline in 1680s)
   ```

   `run.jsonl`'s newest event is the truth about a floor. A quiet stdout is
   not a hung loop, and restarting one mid-wait throws away the cycle. (Rust's
   stdout is line-buffered to a terminal; there is no buffering bug to chase.)

3. **Start the loop inside tmux, not with `nohup`.**

   ```bash
   tmux new-session -d -s fwf-run "fwf run --manifest /path/to/.fwf/fwf.toml"
   ```

   `nohup … &` from a one-shot ssh command leaves the session hanging on
   inherited file descriptors. A tmux session also gives you the loop's
   scrollback later, which is where the `waiting:` lines are.

4. **Stamp meter readings with the floor host's own clock.**

   Meter log lines are parsed in the local time of the host reading them, so a
   line stamped in another machine's timezone reads as hours old and the brake
   parks the floor ("last meter reading is 420m old"). Generate the stamp with
   `date` on the host the floor runs on, never by copying a line from
   somewhere else.

5. **`fwf gate --sha` needs the full 40-character sha and a gate worktree.**

   A fresh floor has no `gate-wt`; nothing creates one for you before the
   loop's first merge:

   ```bash
   git clone /path/to/floor/mirror/mirror.git /path/to/floor/gate-wt
   ```

   An abbreviated sha is refused, not resolved.

6. **A hand-pushed branch must be fetched into the floor's mirror.**

   The seats' only remote is the local mirror, so a branch pushed to GitHub by
   hand does not exist for `fwf qa` until the mirror has it — the symptom is a
   head that "does not exist after git fetch origin":

   ```bash
   git -C /path/to/floor/mirror/mirror.git \
     fetch upstream "+refs/heads/impl1/*:refs/heads/impl1/*"
   ```

7. **A re-run of `fwf triage` is not a sign-off.**

   Triage records a GV verdict; the planner waits for the `Ready` event that
   only an un-gate writes. Re-triaging an already-specced issue records a
   second verdict and changes nothing:

   ```bash
   fwf ungate --repo o/r --issue N --by NAME
   ```

## Driving a floor by hand

When the loop is stopped and you want one issue moved, the verbs are the same
ones the loop calls, in the same order. Each refuses rather than guesses, so
running one twice is safe.

```bash
fwf ungate       --repo o/r --issue N --by NAME          # the sign-off the planner waits for
fwf slice        --repo o/r --issue N --seat fwf-one:impl1
fwf gate         --repo o/r --sha <40-char-sha> --suite fast --cmd '…' --workdir /path/to/floor/gate-wt
fwf qa           --repo o/r --pr N --seat fwf-one:qa1
fwf merge        --repo o/r --pr N
fwf release-check --repo o/r --tag one-vX.Y.Z --expect 4
```

`fwf status` between any two of them says what changed; `fwf why <pr>` replays
one PR's whole timeline out of the record; `fwf dash` watches the floor.

## See also

- [`releasing.md`](releasing.md) — cutting a release, the Linux asset, `release-check`.
- [`verbs.md`](verbs.md) — every verb, the App it acts under, and what it refuses.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
