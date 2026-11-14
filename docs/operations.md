# Operations

The meter and its brake, `run.jsonl` as the only record, cost reporting, the dash, and the tmux layout.
What you do to keep a floor running, and what to read when it stops.

Everything below was learned by breaking a live floor. Some of these rules
are now enforced by the product. They are kept here because the reasoning is
what generalises, not the flag. Fixes for specific symptoms are in
[`troubleshooting.md`](troubleshooting.md).

## Four rules

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

   The three long-running verbs re-exec themselves under their own names
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

   — and inside a wait the loop prints a line about once a minute:

   ```
   waiting: qa seat 1 on #1419 (120s elapsed, deadline in 1680s)
   ```

   `run.jsonl`'s newest event is the truth about a floor. A quiet stdout is
   not a hung loop, and restarting one mid-wait throws away the cycle.

3. **Start the loop inside tmux, not with `nohup`.**

   ```bash
   tmux new-window -d -t fwf-one -n run "fwf run --manifest /path/to/.fwf/fwf.toml"
   ```

   `nohup … &` from a one-shot ssh command leaves the session hanging on
   inherited file descriptors. A tmux window also gives you the loop's
   scrollback later, which is where the `waiting:` lines are. Put it in the
   floor's own session (`fwf-one` here, the manifest's `session`) in a window
   named `run`: that window is how the dash tells whether the loop is up. If
   the session does not exist yet, `tmux new-session -d -s fwf-one -n run "…"`
   creates it with that window.

4. **Stamp meter readings with the floor host's own clock.** See the next
   section.

## The meter and its brake

fwf never measures subscription usage itself. It reads the last line you
logged, and it parks the loop when that line says to.

**The file** is `~/.fwf-meter-log` on the floor host. It sits beside `~/.fwf/`,
not inside it, and only `$HOME` decides where it is. fwf only reads it; you, or
a helper you run, append to it.

**The line format.** Only lines that contain `weekly=` count, and the last such
line wins. Its first two whitespace-separated fields are the timestamp
`YYYY-MM-DD HH:MM:SS` in the **floor host's local time**. `weekly=NN` is the
weekly usage percentage. `session=NN` is optional and only shown by the dash.
Anything else on the line is ignored.

```bash
echo "$(date '+%Y-%m-%d %H:%M:%S') session=12 weekly=41" >> ~/.fwf-meter-log
```

**What the brake does, every tick, before it polls GitHub:**

| The last `weekly=` line | The loop |
|---|---|
| younger than 45 minutes, and `weekly` below `park_at_weekly_pct` | runs normally |
| younger than 45 minutes, and `weekly` at or above `park_at_weekly_pct` | `PARKED — weekly meter NN% ≥ PP%`: wakes no seat, re-reads after `poll_interval_secs` |
| older than 45 minutes, or a stamp `date` cannot parse | `PARKED — last meter reading is Nm old`: wakes no seat. A loop that cannot see the meter must not spend. |
| **no file, or no `weekly=` line at all** | **runs normally, with no brake.** |

The last row matters. The brake fails **open**: a floor with no meter log is
never parked by the meter. If you want the brake, write the file before the
first `fwf run`, and refresh it at least every 45 minutes for as long as the
loop runs. Otherwise the floor parks itself as stale.

While parked, `fwf run --once` returns without waking anything. The brake
writes nothing to `run.jsonl`; the `PARKED` lines are on the loop's stdout.

**Stamp with the floor host's clock.** The stamp is turned into a time by that
host's `date` (`date -j -f` on macOS, `date -d` on Linux), in its local zone. A
line copied from a machine in another timezone reads as hours old, and the
floor parks ("last meter reading is 420m old"). Generate the stamp with `date`
on the host the floor runs on.

## The run record

`<floor>/run.jsonl` is the floor's only record. It is one JSON object per line,
appended and fsynced, and never edited by fwf. `fwf status`, `fwf dash` and
`fwf why` are all folds over it, and so are the loop's own decisions about which
issues are signed off, shipped, claimed or owed a push, and which seats are
busy.

Every line has `ts` (unix seconds), `repo` (`owner/name`) and `kind`. The other
fields depend on `kind`:

| `kind` | Fields |
|---|---|
| `issue` | `issue`, `to` (an issue state) |
| `pr` | `pr`, `issue` (number or `null`), `to` (a PR state) |
| `seat` | `seat` (number), `role`, `to` (a seat state), `tokens_in`, `tokens_out` (numbers or `null`) |
| `gate` | `to` (a gate state) |
| `promote` | `branch`, `from`, `to` (shas). The loop also writes one when it pushes a seat branch upstream. |
| `human` | `actor`, `action`, `target`: an attributed human (or delegated) decision, e.g. `ungate`, `release` |
| `refused` | `what`, `why`: a refusal, with its reason |
| `note` | `text`: free text the loop also reads back by prefix (`GV triage: #`, `PM spec written into #`, `GV sign-off: #`, `fast-track: #`, `spec cycle parked: #`, …) |

`role` is one of `impl`, `qa`, `gv`, `pm`, `captain`. Each `to` is an object
whose `state` field says which state it is. Some states carry more fields:

| Machine | States (`state`), with their extra fields |
|---|---|
| issue | `gated`, `ready`, `claimed` {`seat`, `fence`}, `shipped` {`pr`, `sha`}, `closed`, `unknown` |
| PR | `draft` {`head`}, `open` {`head`}, `approved` {`head`, `reviewer`}, `changes_requested` {`head`}, `stale` {`head`, `approved_head`}, `merged` {`sha`}, `closed_unmerged`, `unknown` |
| seat | `idle`, `working` {`job`, `deadline`}, `reported` {`job`}, `stalled` {`job`}, `gone`, `unknown` |
| gate | `queued` {`sha`, `suite`}, `running` {`sha`, `suite`, `started`}, `green` {`sha`, `suite`, `secs`}, `red` {`sha`, `suite`, `failed`}, `killed` {`sha`, `suite`, `reason`}, `unknown` |

A `job` is `{"role", "issue", "pr"}`. Every sha is the full 40 hex characters.

```json
{"ts":1789844651,"repo":"o/r","kind":"issue","issue":3,"to":{"state":"claimed","seat":1,"fence":"f69ad087e29c8d6263ae3f8b85424b4f9a0a51b7"}}
{"ts":1789844293,"repo":"o/r","kind":"seat","seat":1,"role":"gv","to":{"state":"working","job":{"role":"gv","issue":3,"pr":null},"deadline":1789846693},"tokens_in":null,"tokens_out":null}
{"ts":1789850066,"repo":"o/r","kind":"gate","to":{"state":"green","sha":"ce67c42215b4f35b64fb25cace56f6bcfcfce0a3","suite":"fast","secs":1}}
```

A line that does not parse is an error, never skipped. `fwf why`, `fwf dash`
and `fwf release` refuse and name the line number. The loop, which re-reads the
record every tick, then sees no history at all. Do not edit the file by hand.

`fwf why <pr>` reads `~/.fwf/run.jsonl` (or `FWF_RUN_LOG`) unless you give it
`--log`. For a floor, that is almost never the file you want:

```bash
fwf why 1419 --log /path/to/floor/run.jsonl
```

## Cost

`fwf cost --floor DIR --seat impl1 [--since EPOCH]` reads the seat's own Claude
transcript under `<floor>/home` and prints messages and tokens (input,
cache-read, cache-create, output) since that time. A `seat` event that ends a
job also carries `tokens_in` and `tokens_out`, and the dash's usage tab is a
fold of those.

## The dash

`fwf dash --manifest /path/to/.fwf/fwf.toml` is the board: five tabs (seats,
issues, PRs, decisions, usage), folded from the record, plus tmux pane
liveness and the meter. It makes no GitHub calls. On a terminal it redraws
every 5 seconds. Press `1`–`5` to switch tabs, `j`/`k` to move, `g`/`G` to jump
to either end, `r` to refresh, `q` to quit. `--once`, or a pipe, prints one
frame. Every flag is in [`verbs.md`](verbs.md).

## The tmux layout

One session per floor, named by the manifest's `session` (default `fwf-one`),
with one window per seat: `impl1`, `qa1`, …, `gv1`, `pm1`. The dash looks for
the loop in a window named `run` in the same session. Each seat window runs
`claude` as its pane command, with no shell around it. A seat whose pane
shows a shell as its foreground command is gone.

## Driving a floor by hand

When the loop is stopped and you want one issue moved, the verbs are the same
ones the loop calls, in the same order. Each refuses rather than guesses, so
running one twice is safe. They record into `~/.fwf/floors/<repo-name>`
whatever the manifest says (see
[`configuration.md`](configuration.md#verbs-that-ignore-floor_dir)).

```bash
fwf triage        --repo o/r --issue N --seat fwf-one:gv1
fwf spec          --repo o/r --issue N --seat fwf-one:pm1
fwf ungate        --repo o/r --issue N --by NAME          # the sign-off the planner waits for
fwf slice         --repo o/r --issue N --seat fwf-one:impl1 --check 'make test'
fwf qa            --repo o/r --pr N --seat fwf-one:qa1 --check 'make test'
fwf merge         --repo o/r --pr N
fwf gate          --repo o/r --sha <40-char-sha> --suite fast --cmd '…' --workdir /path/to/floor/gate-wt
fwf promote       --repo o/r --from staging --to main --suite fast
fwf release       --seat 1 --role qa --by NAME            # free a STALLED seat now, instead of waiting out the cool-off
fwf release-check --repo o/r --tag vX.Y.Z --expect 4
```

`fwf status` between any two of them says what changed; `fwf why <pr> --log
<floor>/run.jsonl` replays one PR's whole timeline out of the record;
`fwf dash` watches the floor.

## See also

- [`troubleshooting.md`](troubleshooting.md) — symptoms and their fixes.
- [`releasing.md`](releasing.md) — cutting a release, the Linux asset, `release-check`.
- [`verbs.md`](verbs.md) — every verb, the App it acts under, and what it refuses.
- [`index.md`](index.md) — the fwf 1.0 documentation index.
