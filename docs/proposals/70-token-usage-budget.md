# Proposal: token-usage reporting + a hard token budget for factory runs (#70)

**Status: DISCOVERY.** This is a feasibility investigation + build-or-no-go
recommendation, not code. Deliverable per the ticket: resolve the token-source
gate with concrete evidence, sketch the aggregation/pause-seam/surfaces/config,
state the fail-safe direction, and recommend.

## Problem recap

A running factory spends against the operator's account autonomously and
today there is no visibility into or control over that spend. Surfaced
2026-07-09 standing up a factory under an explicit "stay under the 5-hour
usage cap" constraint that could not be enforced by tooling — only by a human
watching the clock.

## 1. Token-source feasibility (the gate) — RESOLVED, with a working proof

**Finding: yes, an external process can read per-session cumulative token
usage.** Claude Code writes every turn's usage to a JSONL transcript under
`~/.claude/projects/<slugified-cwd>/<session-uuid>.jsonl`. The directory name
is a deterministic slug of the pane's working directory (e.g. a role's git
worktree path), which `fwf` already knows for every role — it manages each
pane's `cwd` via `fwf_role_cwd()` in `lib.sh`. No claude-side hook or opt-in is
required; this file is written by the stock CLI.

**The proof (ran against my own live impl3 session while working this
ticket):**

```
$ DIR=~/.claude/projects/-Users-jamie--fun-with-friends-workspaces-fwf-self-fwf-self-impl3
$ ls -t "$DIR"/*.jsonl | head -1
.../8f37ee07-8504-4546-b250-02537cf3ca6e.jsonl

$ python3 -c "
import json
with open(F) as f:
    for line in f:
        d = json.loads(line)
        if d.get('type')=='assistant':
            print(d['message']['usage'])
            print('model:', d['message']['model'])
            break
"
{'input_tokens': 14501, 'cache_creation_input_tokens': 12662,
 'cache_read_input_tokens': 27390, 'output_tokens': 218, ...}
model: claude-sonnet-5
```

Every `type: "assistant"` line carries `message.usage` (input, cache-write,
cache-read, output tokens — the exact fields billed by the API) and
`message.model` (the exact model id). Other useful top-level fields on the
same line: `timestamp`, `sessionId`, `gitBranch`, `cwd`.

**Latency/staleness:** the file is appended in near-real-time — my own
in-progress session's file had a line timestamped essentially "now" when
read. `tail -f`-style incremental reads are viable; no batching delay
observed.

**Stability across compaction/restart:** a session rotates to a **new**
`<uuid>.jsonl` file when Claude Code compacts or is restarted — confirmed by
inspecting my own pane's project directory, which holds 5 files for 5
sessions since this worktree was created. Tokens already spent in an old
session file remain on disk and must still be counted — a reader keyed to
"the current file" would silently drop prior spend on every compaction.

**Verdict: working proof delivered. No claude-side hook or log-parse
speculation needed — the format already exists and is stable enough to build
against**, with the version-drift caveat in Risks below.

## 2. Aggregation model

- **Per-role total** = sum of `(input_tokens + cache_creation_input_tokens +
  cache_read_input_tokens + output_tokens)` across **every** `type:
  "assistant"` line in **every** `*.jsonl` file under that role's project
  directory (not just the newest file — see compaction note above).
- **Directory → role mapping**: deterministic from `fwf_role_cwd(role)`
  (already computed by `lib.sh` for every role); the aggregator needs no new
  bookkeeping to know which project directory belongs to which pane.
- **Live update**: tail the newest `*.jsonl` in each role's directory
  (`mtime`-newest), plus a one-time cold sum of older files at aggregator
  start. A `respawn`/compaction event simply starts a new file to tail; the
  cold-sum step already captured everything before it.
- **Double-counting on respawn**: none — respawn does not delete or rewrite
  old session files, so summing across all files is correct and idempotent
  (re-summing from scratch always gives the same answer). The only care
  needed is efficiency (don't re-read a fully-summed old file every tick) —
  cache each file's running sum + byte offset and only read new bytes.
- **$-per-role and $-total** are then `role_total_tokens_by_kind ×
  model_price_by_kind`, described next.

## 3. $-estimate feasibility

**Feasible, model id is already in hand.** Every usage line also carries
`message.model` (e.g. `claude-sonnet-5`), so per-role model selection needs no
separate config lookup — the transcript is self-describing. Mapping model id
→ price does need a small hand-maintained table (Anthropic doesn't expose a
priced-usage endpoint), current as of 2026-06-24:

| Model | Input $/MTok | Output $/MTok | Cache write (5m/1h) | Cache read |
|---|---|---|---|---|
| `claude-opus-4-8` | $5.00 | $25.00 | $6.25 / $10.00 | $0.50 |
| `claude-sonnet-5` | $3.00 ($2.00 intro thru 2026-08-31) | $15.00 ($10.00 intro) | $3.75–$6.25 / $6.00–$10.00 | $0.30–$0.50 |
| `claude-haiku-4-5` | $1.00 | $5.00 | $1.25 / $2.00 | $0.10 |
| `claude-fable-5` | $10.00 | $50.00 | $12.50 / $20.00 | $1.00 |

(Cache write is 1.25× input for a 5-minute breakpoint, 2× for 1-hour; cache
read is 0.1× input — both are fixed multipliers stated in Anthropic's own
docs, not something this fwf feature invents.) **This table WILL go stale**
as pricing changes or new models ship — flag it as a maintenance burden in the
build ticket, not a blocker.

**Important caveat that changes what "$" means here:** `fwf` panes launch via
`claude --dangerously-skip-permissions` under the operator's own `claude`
login — almost always a **Claude subscription (Pro/Max) OAuth session**, not
a metered API key. Subscription plans are NOT billed per token; they consume
against an **opaque rolling usage quota** (the "5-hour cap" the ticket cites)
whose internal weighting formula and reset semantics Anthropic does not
publish. So:

- The $-figures above are a useful **engineering proxy** ("this run is
  equivalent to $X of API spend") for relative cost comparison across roles
  and over time, and are the *correct* real dollar figures if and only if the
  factory is instead run against a metered API key.
- They are **not** a measurement of "how close to the account's actual 5-hour
  cap" — that is a different, Anthropic-internal quota this feature cannot
  read or replicate exactly. See Risks below; this is the single most
  important thing the proposal must be honest about, because it's exactly
  the scenario that prompted the ticket.

## 4. Budget-enforcement seam

**Key structural finding: `fwf` has no central dispatch loop to pause.**
Unlike a typical job-queue architecture, `fwf` arms each pane **once**
(`fwf_arm_pane` in `lib.sh`) with Claude Code's own built-in `/loop <interval>
<role> tick` skill, and every subsequent cycle is scheduled *inside that
pane's own Claude Code session*, not by any `fwf`-side script. There is
therefore no external "between dispatches" hook to intercept in the sense the
ticket first imagines (like pausing a bash `while` loop between iterations).

**The good news: `fwf` already has exactly the right pattern for this, proven
in production** — the STOP-sentinel mechanism (`fwf-stop.sh` /
`config.sh:STOP_FILE`). Every role's system prompt begins its loop tick with a
self-check: *"if the file `$STOPFILE` exists, commit & push any WIP, cancel
your loop (`CronDelete`), report one line, and idle."* This check runs at the
start of each tick — i.e. **between** task cycles, never mid-task — which is
precisely the "pause between dispatches, don't hard-kill mid-task" seam the
ticket asks for.

**Recommended seam:** add a second sentinel, e.g. `$FWF_RUN/BUDGET_HOLD`
(or a small state file with a reason string), self-checked by the exact same
step-0 pattern already present in every role prompt template
(`templates/*/*.tmpl`). When present:
- Each role finishes (or skips starting) its current cycle, commits/pushes
  any WIP exactly as the STOP path does, and **idles rather than cancelling
  the loop outright** (unlike STOP, budget pressure is meant to be
  temporary — the loop should resume once the aggregator clears the hold,
  not require a human to `fwf respawn` every pane).
- A soft-warn threshold (e.g. 80% of budget) can piggyback on the same
  sentinel file by writing a WARN state distinct from HOLD, surfaced in the
  role's tick report but not pausing anything yet.

This reuses a pattern already proven under load (the STOP sentinel ships
today and every role prompt already contains the self-check), rather than
inventing a new coordination primitive.

## 5. Surfaces sketch

**Dash panel.** The dash (`dash/src/main.rs`) has exactly four tabs today —
`Activity`, `Roles`, `Decisions`, `Issues` — driven by a `Tab` enum
(`Tab::ALL`) and a matching bash data layer (`fwf-dash-data.sh`, which shells
`jq` over `gh`/git/tmux state). A fifth tab, `Usage`, is a same-shaped
addition: one more `Tab` variant, one more keybinding (`5`), and a data field
per role (cumulative tokens by kind, $ estimate, current model,
last-successful-read timestamp) contributed by a new `fwf-usage-data.sh`
sibling of the existing data script.

**"Unknown/stale" must not read as "low" (GV item 2).** The panel must render
three distinct states per role, not two:
1. **Fresh** — a $ or token figure plus "as of Ns ago".
2. **Stale** — the last successful read is older than some threshold (e.g.
   2× the aggregator's own poll interval) — render as `⚠ STALE (last read
   3m ago)`, not as a frozen number.
3. **Unreadable** — the aggregator errored on this role's directory (missing,
   permission, unparseable JSON) — render as `⚠ UNKNOWN`, never as `$0` or a
   blank cell, both of which read as "no spend" / "plenty of headroom."

**CLI: `fwf usage --profile NAME`.** Wired exactly like the existing
`fwf pr-review-state` / `fwf issues` subcommands (`usage) engine
fwf-usage.sh "$@";;` in `fwf`), printing a per-role table (model, tokens by
kind, $ estimate, freshness) plus a factory total.

## 6. Config surface (sketch only)

Follow the existing `${FWF_FOO:-default}` + CLI-flag pattern used throughout
`config.sh` (e.g. `FWF_MODEL`, `FWF_PAIRS`):

- `FWF_TOKEN_BUDGET` env var (total tokens; unset = no ceiling).
- `fwf up --token-budget N` CLI flag, threaded the same way `--pairs`/`--model`
  already are.
- A profile default (`FWF_TOKEN_BUDGET="${FWF_TOKEN_BUDGET:-...}"`), so a
  repo's profile can set a sane default the operator can still override.
- Precedence: CLI flag > env var > profile default > unlimited (unset).

## 7. Fail-safe direction when usage is unreadable (GV item 1 — REQUIRED)

**Fail-CLOSED is the recommended and required default.** If the aggregator
cannot produce a fresh reading for a role (transcript directory missing,
`*.jsonl` unparseable — e.g. a future Claude Code version changes the line
schema — reader process crashed, or the reading is older than a staleness
threshold), the enforcer must treat that exactly like crossing the budget:
write the `BUDGET_HOLD` sentinel (or a distinct `BUDGET_UNKNOWN` state that
the role-prompt check treats identically to `HOLD`) and pause new-cycle
dispatch for that role, with the dash/CLI surfacing the UNKNOWN state
distinctly per §5.

**Operator override:** exactly the same shape as the existing `fwf resume`
(clears `STOP_FILE`) — a `fwf usage --clear-hold` (or reusing `fwf resume`)
that removes the sentinel once the operator has confirmed it's safe to
continue, mirroring the `FWF_ALLOW_GH=1` single-authorization pattern already
used for the gh-write guard.

**Justification:** a budget guard's entire value is bounding worst-case
spend. A guard that silently fails open under a broken/rotated log format
would under-enforce exactly when a runaway is most likely (a Claude Code
version bump that changed the transcript schema out from under the reader,
for instance) — the analog of the hit-storm/spend-storm misread this repo's
own `INCIDENT_PROTOCOL.md` already warns about.

## Edge cases / risks

- **Log format drift across Claude Code versions.** The `.jsonl` schema is
  not a published/versioned public API — a future Claude Code release could
  rename `usage` fields or restructure lines. Mitigation: fail-closed (above)
  turns a broken parse into a paused factory, not silent under-counting;
  the build ticket should also pin a schema-version smoke-test that runs in
  CI-adjacent tooling (e.g. `fwf doctor`) so drift is caught before it causes
  a false "everything's fine" reading.
- **Account-rolling-cap ≠ summed-session-tokens (ticket's own flag, and the
  most important one).** As detailed in §3, the local token sum cannot
  exactly reproduce Anthropic's internal 5-hour-window accounting for a
  subscription-auth factory. The build ticket must document this limitation
  in the CLI/dash surface itself (e.g. a footnote: "estimated $ equivalent —
  not your account's actual rolling-window usage"), not just in internal
  docs, so an operator doesn't over-trust the number.
- **Multi-account / which account.** The aggregator reads whichever account
  is logged into `claude` in each pane. On the shared-account fwf-self setup
  (see `docs/shared-account.md`), all roles share one account, so per-role
  totals sum to one shared account-level total — correct for THIS factory's
  topology, but a build ticket for a differently-authed factory (per-role
  accounts) would need per-role bucket, not a single shared total.
- **Pausing safely mid-swarm.** Handled structurally by §4 — the pause point
  is the existing tick boundary, which already carries a "commit & push WIP"
  step proven safe by the STOP-sentinel precedent; no new mid-task
  interruption logic is needed.

## Metered-feature ship requirement (INCIDENT_PROTOCOL)

A hard token budget is a metered/limit-enforcing control, so the follow-on
BUILD ticket is subject to this repo's ship requirement for such features
(`docs/INCIDENT_PROTOCOL.md`): a cost bound (here: the fail-closed guard
itself, since there's no cache to bound — every read is local disk, not a
metered call), observability that distinguishes a real reading from a stale
one (§5), a verified operator override to lift a hold (§7), and ideally a
canary (e.g. ship the dash panel + CLI read-only first, with enforcement
behind an opt-in `FWF_TOKEN_BUDGET`/`--token-budget` that defaults to
unlimited, before defaulting any profile to an enforced budget).

## Cost / effort estimate

- **Reporting only** (aggregator script + `fwf usage` CLI + dash Usage tab,
  read-only, no enforcement): small — one new bash data script following the
  existing `fwf-dash-data.sh` pattern, one new CLI subcommand, one new Rust
  `Tab` variant + panel. Roughly the size of a single past dash feature PR
  (e.g. the `pr-review-state` helper, ~1-2 days).
- **Enforcement** (BUDGET_HOLD sentinel + role-prompt step-0 addition across
  every template + config surface + operator override): comparable size
  again, and touches every role template (`templates/*/*.tmpl`) the way the
  STOP sentinel already does, plus `docs/` updates for the new env
  var/flag — a second PR-sized chunk of similar effort.
- Recommend **splitting into two build tickets** in that order: (1) reporting
  surfaces (dash + CLI, no enforcement) ships value and validates the
  aggregator against real multi-role data with zero risk of pausing a live
  factory by accident; (2) the enforcer (sentinel + role-prompt wiring +
  config + operator override + fail-closed behavior), gated by the
  INCIDENT_PROTOCOL requirements above, built once (1) has proven the numbers
  are trustworthy.

## Recommendation

**Design-to-build.** The load-bearing unknown — can per-session token usage
be read reliably from outside the `claude` process — is resolved with a
working proof against a live session in this very factory, using a
mechanism (`~/.claude/projects/**/*.jsonl`) that needs no claude-side
opt-in. The enforcement seam reuses `fwf`'s own proven STOP-sentinel pattern
rather than inventing new coordination, and the fail-closed direction and
unknown/stale-vs-low surface distinction are both concretely specified above
(§7, §5). The one real caveat — that this measures token spend / an
API-cost-equivalent, not Anthropic's undocumented internal rolling-window
quota for subscription auth — is knowable in advance, doesn't block a build,
but must be surfaced honestly in the shipped UI copy, not just this doc.

Recommended split:
1. **Build ticket A — usage reporting** (aggregator, `fwf usage` CLI, dash
   Usage tab; read-only; ships value immediately, de-risks ticket B).
2. **Build ticket B — hard budget enforcement** (`BUDGET_HOLD` sentinel,
   role-prompt step-0 addition, `FWF_TOKEN_BUDGET`/`--token-budget` config,
   operator override, fail-closed default) — scoped per the
   INCIDENT_PROTOCOL metered-feature requirements above, built on top of A.
