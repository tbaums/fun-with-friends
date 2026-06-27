# The user-testing factory (#42) — runbook

A factory instance of three **whacky, unscripted, structurally source-blind
personas** + one **researcher** + a **captain**. The personas drive a real
browser like real humans (not like an LLM writing tests); the researcher dedupes
their diaries into a ranked **top-10** findings report; the captain grades the
trial against ground truth and gates which findings graduate to real tickets.

Trial one validated this template against transom (10 real findings filed,
75% canary recall). This runbook codifies the exact setup that worked so a trial
never re-hits the wall trial one hit — personas with no browser.

> **Personas are source-blind by construction.** They get NO worktree — only a
> browser against a profile-declared app URL. Everything below assumes that.

---

## 1. One-time setup: the browser MCP (do this first)

The personas' "hands" are a [Playwright MCP](https://github.com/microsoft/playwright-mcp)
server. Without it they can launch but cannot touch the app — the gap that
blocked trial one. Wire it once, per machine:

```bash
npx playwright install firefox
claude mcp add playwright -s user -- npx -y @playwright/mcp@latest --headless --isolated --browser firefox
```

- **Firefox is the default** (`UT_BROWSER=firefox`) — trial one validated on it
  and it is Jamie's browser. To use another engine, set `UT_BROWSER=chromium`
  (or `webkit`) and substitute it in BOTH commands above.
- `--isolated` gives each browser session a throwaway profile (no cookies/state
  carried between runs); `--headless` keeps it off-screen.

Verify it is registered:

```bash
claude mcp list        # expect a 'playwright' entry
```

`fwf provision` and `fwf up` run a **preflight** for the `user-testing` template:
if the `playwright` MCP is not registered they print these exact commands and
keep going (a warning, never a block). The preflight reads the MCP registry from
your config (`~/.claude.json` `mcpServers`, override with `CLAUDE_CONFIG`) — NOT
a live `claude mcp list` probe — so a server that is registered but momentarily
unconnectable does not false-alarm as "missing". To have provision install it
for you:

```bash
FWF_UT_SETUP_BROWSER=1 fwf --profile <p> provision
```

---

## 2. Make a profile pointed at a scratch/UAT target

A trial runs **only** against an isolated scratch/UAT instance — never prod.
Start from the target's own profile (or `fwf init <path>`), then set the
user-testing knobs:

```bash
# profiles/<target>-ut.sh  (copy of the target profile + these lines)
FWF_TEMPLATE="user-testing"                 # run the persona factory
UT_APP_URL="${FWF_UT_APP_URL:-http://localhost:3939}"   # the running UAT/scratch app
```

**Prod-target guard.** `fwf up` refuses a prod-looking `UT_APP_URL` before any
pane boots — a fail-closed allow-list: loopback (`localhost`/`127.*`/`::1`),
`*.local`/`*.localhost`/`*.test`, or a host containing
`uat`/`staging`/`test`/`scratch`/`sandbox`/`dev`. Anything else is refused. A
human can override a single launch with `FWF_UT_ALLOW_TARGET=1` (your call, never
the captain's).

**Per-persona isolation (recommended).** Trial one ran three personas against one
UAT backend, so shared state bled between them — the scorecard's #1 false-signal
source. Give each persona its own app instance and the researcher never has to
quarantine cross-session artifacts:

```bash
UT_APP_URL_1="http://localhost:3941"        # persona 1's instance
UT_APP_URL_2="http://localhost:3942"        # persona 2's instance
UT_APP_URL_3="http://localhost:3943"        # persona 3's instance
```

Each `UT_APP_URL_<id>` overrides the shared `UT_APP_URL` for that persona and is
guarded the same way. Unset → the persona shares `UT_APP_URL`.

---

## 3. Launch the trial (under tmux isolation)

The fwf scripts drive a tmux server; run a trial under an **isolated**
`TMUX_TMPDIR` so it can never disturb another tmux server on the box:

```bash
export TMUX_TMPDIR=/tmp/fwf-ut && mkdir -p "$TMUX_TMPDIR"

fwf --profile <target>-ut provision      # worktrees for researcher+captain;
                                         # scratch dirs for the source-blind personas
fwf --profile <target>-ut up             # 5 panes: 3 PERSONA + RESEARCHER + CAPTAIN
fwf --profile <target>-ut attach         # talk to the CAPTAIN (coordination session)
```

The floor is **3 personas (Sonnet) + researcher (Opus) + captain** — no QA, no
conductor, no Grand Vizier (a user-test has no gate pipeline). The captain seeds
each persona's goal in `~/.fun-with-friends/ut/<profile>/goals.md` — real-user
intentions ("save a note and find it again"), never scripts and never hints at a
known defect.

---

## 4. Conclude the trial

```bash
fwf --profile <target>-ut stop           # personas save diaries + idle
# the RESEARCHER finalizes the two docs (see below) and does its post-session
# tracker cross-reference; the CAPTAIN grades with you against ground truth
fwf --profile <target>-ut down           # kill the sessions (add --purge to remove scratch)
tmux -S "$TMUX_TMPDIR/default" kill-server 2>/dev/null || true
```

Outputs land under `~/.fun-with-friends/ut/<profile>/`:

- **`findings-report.md`** — ranked **top-10-max** findings (severity, persona,
  narrative repro, evidence path, suspected-known-issue cross-ref). Trial one
  writes this **for human grading** — findings graduate to real tracker tickets
  only after you pass them, and graduated findings are filed `product-wip` so
  they route through the dev factory's PM → GV-signoff flow (not built straight
  from the report).
- **`scorecard.md`** — recall against the captain's known-unfixed-defects list
  (the canary), human-graded precision per finding, your triage time (target
  < 30 min), and "what to change next trial" (persona-card / researcher-rule
  tweaks) so trial-over-trial improvement is visible in one place.
- **`<persona>/diary.md`** + **`<persona>/evidence/*.png`** — each persona's
  raw think-aloud diary and a screenshot per action.

---

## 5. The scoring loop (why this isn't token-burn)

Every trial is graded against ground truth. The canary: the target has known
unfixed defects the personas were never told about. Recall against those +
human-graded precision are the trial's metrics, and they feed back into the
persona cards and researcher rules. The personas are nudged toward **coverage**
without losing the unscripted spirit — at least one desktop persona, between its
own goals, opens every nav destination once and tries the app's keyboard
shortcuts (including any Help/"?" overlay), as curiosity rather than a checklist.
This is how the two recall misses from trial one (an unopened tab, an untried
shortcut) close without scripting the personas.

---

## Knobs (all user-testing-only; no-ops elsewhere)

| knob | default | meaning |
|------|---------|---------|
| `UT_APP_URL` | — (required) | the shared UAT/scratch app the personas drive |
| `UT_APP_URL_<id>` | falls back to `UT_APP_URL` | per-persona app instance (avoids shared-backend bleed) |
| `UT_BROWSER` | `firefox` | browser engine the Playwright MCP drives |
| `FWF_UT_SETUP_BROWSER` | `0` | `1` → provision installs the browser MCP if missing |
| `FWF_UT_ALLOW_TARGET` | `0` | `1` → override the prod-target guard for one launch (human only) |

Models default to Sonnet for personas (cheap, impulsive, more user-like) and Opus
for the researcher (synthesis quality); override per role with the usual
`FWF_MODEL_*` machinery.
