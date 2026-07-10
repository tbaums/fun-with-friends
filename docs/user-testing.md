# The user-testing factory (#42) — runbook

A factory instance of three **whacky, unscripted, structurally source-blind
personas** + one **researcher** + a **captain**. The personas drive a real
browser like real humans (not like an LLM writing tests); the researcher dedupes
their diaries into a ranked **top-10** findings report; the captain grades the
trial against ground truth and gates which findings graduate to real tickets.

Trial one validated this template against a real application (10 real findings
filed, 75% canary recall). This runbook codifies the exact setup that worked so a trial
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

- **Firefox is the default** (`UT_BROWSER=firefox`) — trial one validated on
  it. To use another engine, set `UT_BROWSER=chromium`
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

## Trial modes (issue #47)

| Mode | Activate | Personas | Duration |
|------|----------|----------|----------|
| **Quick gate** (default) | nothing, or `FWF_UT_MODE=quick` | 3 (archetypes 1–3) | ~25 min |
| **Deep sweep** | `FWF_UT_MODE=deep` | 9 (all archetypes) | ~75 min |

The **quick gate** (archetypes 1–3: rusher, mobile, label-blind first-timer) is cheap enough to run before every promotion. The **deep sweep** is for periodic full-coverage audits — use it before a major release or when the quick gate has been green long enough that you want broader coverage.

### Archetype library

| # | Archetype | Bug class it catches |
|---|-----------|----------------------|
| 1 | Impatient rusher | Rage-click bugs, slow responses, friction abandonment |
| 2 | Distracted mobile user | Tiny targets, overflow, stale tab recovery |
| 3 | Label-blind first-timer | Wrong mental model, hostile input, shortcut accidents |
| 4 | Power user | Edge cases, bulk actions, keyboard shortcuts, missing undo |
| 5 | Slow-network / low-end device | Latency-masked failures, double-submit, silent errors |
| 6 | Returning user | Stale sessions, moved nav, lost drafts |
| 7 | Privacy-conscious skeptic | Export/delete paths, sharing visibility, encryption claims |
| 8 | International / non-native-English user | Unicode, RTL, locale assumptions, translation overflow |
| 9 | Accessibility user | Keyboard-only, focus traps, contrast, unlabeled controls |

For a deep sweep, set `UT_APP_URL_1` through `UT_APP_URL_9` so each archetype drives its own app instance — the trial-1 lesson: shared backends blur cross-persona findings.

---

## Conductor-triggered pre-promotion gate (issue #46)

Everything above is the manual, human-attended trial. The **dev** template's
conductor (README.md's pipeline) can ALSO run a quick gate automatically,
right before it ff-merges `staging` into `integration` — no human attaches to
it. This works with zero changes to the trial mechanics above: a persona with
an empty/missing `goals.md` already invents its own first-use goal from the
landing page (`templates/user-testing/implementer.tmpl`), and the researcher
rewrites `findings-report.md` from diaries every loop tick regardless of
whether a captain is present — so an unattended trial produces a real report
on its own.

**Opt-in, per profile.** Unset (the default) = the gate never runs; nothing
about the dev pipeline changes. To wire it up, add to your target's profile
(next to the rest of the `UT_*` knobs — see `profiles/example.sh`):

```bash
UT_GATE_PROFILE="example-ut"                      # a hand-authored user-testing profile (section 2 above) — REQUIRE a WT_PREFIX distinct from your main profile's, so the nested trial's pm/captain worktrees never collide with the live factory's own pm/captain worktrees
UT_GATE_UI_GLOB='\.(tsx?|jsx?|vue|css|scss)$|/(ui|views|components)/'   # extended-regex; the staged diff must match at least one path, or the gate skips (cost control — don't run a 25min trial on a backend-only change)
UT_GATE_APP_CMD='./scripts/serve-staged.sh'       # boots a THROWAWAY instance of the staged build; MUST print its URL as the first stdout line once ready, then keep running in the foreground until killed
```

`UT_GATE_APP_CMD` runs from the conductor's own worktree, which is already
checked out on the staged, e2e-green commit (conductor.tmpl step 3) — so
whatever you point it at is exactly the code about to be promoted. A minimal
contract-satisfying script for a Node app might be:

```bash
#!/usr/bin/env bash
npm run build >&2
npm run preview -- --port 0 > /tmp/serve.out 2>&1 &
until grep -qo 'http://[^ ]*' /tmp/serve.out 2>/dev/null; do sleep 0.5; done
grep -o 'http://[^ ]*' /tmp/serve.out | head -1
wait
```

**What happens on a UI-touching promotion.** The conductor runs
`fwf-ut-gate.sh` (baked into its prompt as a literal, already-resolved
command — never a bare env-var reference, since a tmux pane's shell doesn't
inherit the conductor's `FWF_PROFILE`). It:
1. Skips immediately (exit 0) if the gate isn't configured, the deploy kill
   switch is on (`FWF_UT_GATE_DISABLE=1`), the staged diff doesn't match
   `UT_GATE_UI_GLOB`, or today's trial budget (`FWF_UT_GATE_DAILY_CAP`,
   default 2/day) is spent. Each skip logs WHY on stderr — a real run and a
   skip never look the same in the logs.
2. Boots `UT_GATE_APP_CMD`, captures its URL, and launches a **quick-gate**
   trial (`FWF_UT_MODE=quick`, forced regardless of ambient env — a deep
   sweep would blow the budget this gate exists to bound) against it, under
   its own isolated `TMUX_TMPDIR` **and its own isolated `FWF_RUN_DIR`** —
   the trial gets a private STOP sentinel / e2e-lock / findings root, so it
   can never cross-signal the live factory (in particular: this is why the
   gate tears the trial down with a bare `fwf down`, never `fwf stop` — that
   command's STOP sentinel is a single path shared by every role in the
   OUTER factory, conductor included).
3. Waits up to `FWF_UT_GATE_TIMEOUT` seconds (default 1800 ≈ the quick gate's
   ~25min plus buffer), then reads `findings-report.md` for its severity mix
   and tears everything down (app process, nested tmux server, worktrees).
4. Exits 0 (skipped), 2 (ran, no blockers — promote normally, but the
   conductor mentions the report path in its promotion note for human
   review), 3 (ran, **blocker**-severity findings — the conductor does NOT
   promote; it comments the blocker count + report path on the batch's PR(s)
   tagging the captain for a human call), or 4 (the trial's own
   infrastructure failed — fail OPEN: promote normally, but log loudly so a
   human looks at the gate itself, not the shipped code).

**Cost bound (non-negotiable — see `templates/dev/gv.tmpl`'s "RUNTIME COST &
BLAST RADIUS" bar).** The gate is OFF by default (a canary, not a fleet-wide
default-on), fails CLOSED on budget (`FWF_UT_GATE_DAILY_CAP`), and has a
deploy-plumbed kill switch (`FWF_UT_GATE_DISABLE=1`) independent of any
profile edit. Every skip is observable (a distinct stderr log line per
reason), so a quiet day never reads the same as a broken gate.

**Known simplification.** Severity parsing is a loose text match ("severity"
+ "blocker" co-occurring on one line, case-insensitive) against the
researcher's markdown, not a structured field — a first-pass signal only. The
findings report itself is always linked in the conductor's note, so a human
can verify before trusting the blocker count for anything consequential.

---

## Knobs (all user-testing-only; no-ops elsewhere)

| knob | default | meaning |
|------|---------|---------|
| `FWF_UT_MODE` | `quick` | `deep` → 9 personas (all archetypes); `quick` → 3 |
| `UT_APP_URL` | — (required) | the shared UAT/scratch app the personas drive |
| `UT_APP_URL_<id>` | falls back to `UT_APP_URL` | per-persona app instance (avoids shared-backend bleed) |
| `UT_BROWSER` | `firefox` | browser engine the Playwright MCP drives |
| `FWF_UT_SETUP_BROWSER` | `0` | `1` → provision installs the browser MCP if missing |
| `FWF_UT_ALLOW_TARGET` | `0` | `1` → override the prod-target guard for one launch (human only) |

Models default to Sonnet for personas (cheap, impulsive, more user-like) and Opus
for the researcher (synthesis quality); override per role with the usual
`FWF_MODEL_*` machinery.

### Conductor gate knobs (dev template only; issue #46)

| knob | default | meaning |
|------|---------|---------|
| `UT_GATE_PROFILE` | — (unset = gate disabled) | name of a hand-authored user-testing profile the gate launches |
| `UT_GATE_UI_GLOB` | — (unset = gate disabled) | extended-regex; the staged diff must match a path for the gate to run |
| `UT_GATE_APP_CMD` | — (unset = gate disabled) | boots a throwaway instance of the staged build; prints its URL as the first stdout line |
| `FWF_UT_GATE_DAILY_CAP` | `2` | max gate trials/day (fail-closed — cap hit skips, never blocks promotion) |
| `FWF_UT_GATE_DISABLE` | `0` | `1` → deploy-plumbed kill switch, overrides any profile config |
| `FWF_UT_GATE_TIMEOUT` | `1800` | seconds the gate lets the nested trial run before forcing teardown |
