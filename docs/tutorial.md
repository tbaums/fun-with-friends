# The fun-with-friends tutorial

A hands-on tour of everything the factory can do, in the order you'll actually
use it: stand up your first factory, learn to drive it, manage its cost, size
and model it, switch factory designs, build your own design, measure which
models are good enough for which seats, and work in the container sandbox.

Everything here assumes the repo is cloned and `./install.sh` has put `fwf` on
your PATH. Each section is self-contained — skim to what you need.

---

## 1. Your first factory

Check the machine first:

```bash
fwf doctor
```

You need `tmux`, `git`, an **authenticated** `gh`, and the `claude` CLI. Fix
anything it flags, then point fwf at a repo:

```bash
fwf start https://github.com/you/your-repo
```

`start` clones the repo, detects its toolchain (Rust / Node / Go / Python),
and **pauses to show you the four commands it inferred** — the QA gate, the
build, the e2e suite, the dev-UI hint. Review them: the gate is what QA runs
before every merge, so if it's wrong, everything downstream is wrong. Approve
(or edit `profiles/<name>.sh` after) and fwf provisions ten git worktrees and
launches two tmux sessions:

```
coordination   PM · GV · CAPTAIN          ← you attach HERE and talk to the captain
implementation IMPL1-3 / QA1-3 · CONDUCTOR ← the build floor; watch, don't type
```

```bash
fwf attach            # coordination — the captain's pane is the right column
fwf attach build      # the floor, if you want to watch it work
```

**The one rule of driving the factory: talk only to the captain.** Every other
pane is an autonomous loop; typing into one garbles its input buffer. The
agents coordinate exclusively through GitHub issues/PRs and git — that's also
your audit trail.

A 60-second test drive: type into the captain's pane —

> here's an idea: add a `--json` flag to the export command. wdyt?

and watch the ladder run: the captain hones the idea with the **GV** (grand
vizier — the strategic critic), briefs the **PM**, the PM opens a **gated**
draft issue (labeled `product-wip`, invisible to implementers) and specs it,
the GV hardens the spec (`GV-CHANGES:` → revisions → `GV-SIGNOFF:`), and the
captain surfaces it to you as a decision: *"#12 is signed off — go ahead?"*
Say **"go ahead on #12"** and the gate comes off; an implementer claims it,
builds it on a branch, QA gates and merges it to `staging`, the conductor
e2e-promotes `staging → integration`, and the captain asks you before
releasing `integration → main`. The issue auto-closes when its commit lands
on main.

Shutting down:

```bash
fwf stop          # graceful: agents commit WIP, cancel their loops, idle
fwf resume        # clear the stop sentinel and re-arm every loop
fwf down          # kill both sessions (worktrees survive)
fwf down --purge  # retire the factory: also remove the worktrees
```

---

## 2. Driving it day to day

**Read the status table.** Every captain report opens with one table — IN
PROGRESS / QUEUED / DONE (last 24h) — sourced from `gh` data, never guessed.
Under it, a one-line health note and the single next action.

**Watch the "⛔ NEEDS YOU" list.** Every captain tick sweeps for decisions
only you can make — an unanswered PM question, a GV escalation, a signed-off
draft waiting on your go, a risky call — and presents them as a numbered
list. If something's blocked on you, it's here; if the list says "nothing
needs you", you can walk away.

**The three labels.**

| Label | Meaning | Who acts |
|---|---|---|
| `product-wip` | a PM draft being specced/hardened — implementers can't see it | you (or the captain) approve to remove it |
| `release-hold` | held for a future release during a freeze | the PM lifts it when you authorize |
| `idea` | parked by you for later — **every** role skips it entirely | you remove `idea` to activate it |

**Approving work.** Any unambiguous go-ahead works — "go ahead on #N",
"lgtm", "ship it", a 👍 comment on the issue. The PM verifies the spec is
complete and GV-signed-off, then removes the gate. Questions and critiques
are never treated as approval.

**The GV's two markers.** In any issue thread: `GV-CHANGES:` = concrete edits
required (a hard gate on PM drafts); `GV-SIGNOFF:` = strategically sound,
ready for your decision. The GV *thinks*; it never *authorizes* — releases
and anything irreversible still come to you.

**qa's two markers.** Every role shares one GitHub identity, so a qaN pane
can't formally `--request-changes` on implN's own PR — it posts
`QA-CHANGES-REQUESTED:`/`QA-APPROVED:` comments instead (implN acknowledges
with `IMPL-ADDRESSED:`), read via `fwf pr-review-state <pr>`. See
[docs/shared-account.md](shared-account.md) for the full protocol.

**Claims, races, and assignments.** Implementers claim atomically: a
`CLAIM implN` comment, then a re-check that the first claim in the thread is
theirs — losers yield instantly, a claim older than 15 minutes with no PR is
abandoned. When the captain releases a *batch*, it pre-assigns with
`ASSIGNED implN` comments so the batch doesn't stampede. If you see those
comments in your issues, that's the machinery working.

**Fixing a wedged agent.** A pane stuck on a crash or a garbled buffer:

```bash
fwf respawn impl2     # any role: implN | qaN | conductor | pm | gv | captain | sre
```

It kills that pane's claude, relaunches it, and re-delivers its role prompt.
Loops make this safe — the agent re-derives its state from GitHub on the next
cycle.

**Release freeze.** Tell the PM (or captain) to "freeze for release": new
work gets `release-hold`, in-flight PRs drain, and when `staging` ==
`integration` with nothing open you have a clean cutoff to release. "Lift the
freeze" afterward.

---

## 3. Idle the floor, keep the captain (token conservation)

An idle-but-looping floor is the factory's main token waste — nine agents
re-checking empty queues. The fix (and the captain does this autonomously),
and it idles the **build floor** and the **PM** independently — each on its
own workload:

```bash
fwf down --build-only   # kill only the build session (impl/qa/conductor)
fwf up   --build-only   # recreate it, around the live captain — its
                        # conversation is never lost

fwf down --pm-only      # kill only the PM pane (GV and captain untouched)
fwf up   --pm-only      # recreate it

fwf down --floor-only   # both together (--build-only + --pm-only) — the
fwf up   --floor-only   # original all-or-nothing behavior, kept as an alias
```

The **GV never idles** — no flag ever tears it down, so the captain can
always summon it for a gate with no cold-boot latency. Every one of these is
idempotent and safe in partial states (`up` on an already-running unit is a
no-op), and every `down` refuses — even with `--force` — if idling would
strand work: `--build-only` while a PR is open or a promotion is mid-flight,
`--pm-only` while a `product-wip` draft still needs grooming. Each unit also
has its own deterministic anti-thrash cooldown (`FWF_BUILD_COOLDOWN` /
`FWF_PM_COOLDOWN`, default 300s — see the README).

This is the cycle for "factory on demand": leave the captain (and GV) up as
your always-on copilot, spin each plane up when it has work, down when it
drains.

---

## 4. Size the floor, pick the models

Every launching command (`start`/`provision`/`up`/`respawn`/`resume`/`down`)
accepts, in any position:

```bash
fwf up --pairs 2                                  # 2 implementer/QA pairs instead of 3
fwf up --model claude-haiku-4-5-20251001          # one model for every agent
fwf up --model haiku --impl-model sonnet \
       --captain-model opus                       # layered: role override > floor default
```

The full set: `--pairs N`, `--model M`, and per-role `--impl-model`,
`--qa-model`, `--pm-model`, `--gv-model`, `--captain-model`,
`--conductor-model`. (`--model` values are passed straight to `claude
--model`.) There's also `--budget-usd N` — a hard, human-intuitive budget
ceiling in estimated dollars across every role (or `--token-budget N` for a
raw-token ceiling), unset by default (unlimited); see the README's "Token
budget enforcement" section.

Make it permanent in a profile:

```bash
# profiles/your-repo.sh
FWF_PAIRS="${FWF_PAIRS:-2}"
FWF_MODEL_IMPL="${FWF_MODEL_IMPL:-claude-sonnet-4-6}"
FWF_MODEL_QA="${FWF_MODEL_QA:-claude-haiku-4-5-20251001}"
```

Keep the `${VAR:-default}` shape — that's what lets a CLI flag or env var
still win. Precedence everywhere: **CLI/env → profile → template → stock**.

Which models are *good enough* per role is an empirical question — that's
what `fwf eval` is for (section 8).

---

## 4½. Not sure what to run? `fwf suggest`

Describe the goal in plain language and get a factory design back:

```bash
fwf suggest "I inherited a legacy Django app with no tests and weekly prod \
incidents. Make it safe to change without breaking users, on a budget."
```

The advisor reads the **installed** template catalog (so your custom templates
show up too), the sizing/model knobs, and the model menu (`FWF_MODEL_MENU` in
`config.sh` — edit it as models evolve), then answers in a fixed shape:

- **Recommendation** — a prebuilt template, or a custom one with a named base.
- **Why** — and the strongest alternative it rejected.
- **Launch** — the exact `fwf up --template … --pairs … --<role>-model …`
  command to copy-paste.
- **Per-role models** — a seat-by-seat table with one-line rationale
  (strong models only where judgment failures are silent and costly; the
  cheap model on mechanical, rubric-checkable seats).
- **Custom template sketch** — when warranted: a complete `template.sh` plus
  which role prompts to override and the one behavioral change each makes
  (section 7 shows you how to build it).
- **Verify** — the `fwf eval` commands that would pressure-test its riskiest
  model picks before you commit a budget to them.

It needs no profile — run it before `fwf start` when you're deciding what to
build. `--model M` picks the advisor model itself; pipe the description on
stdin if you prefer. Treat the output as a strong draft, not gospel: the
Verify section exists precisely because model fit is empirical (section 8).

---

## 5. The refactoring factory

```bash
fwf up --template refactor
```

Same grid, different contract: **structure improves, observable behavior does
not change at all.** What each seat does differently:

- **PM → refactor planner.** Kick it off through the captain: *"clean up the
  payments module"*. It fans out read-only survey subagents, ranks the debt
  by **churn × complexity evidence** (hotspots that change weekly outrank
  ugly corners nobody touches), and splits it into small gated items — each
  with preservation invariants, an honest blast radius, and `depends on #M`
  edges.
- **GV → architecture critic.** Hunts behavior changes wearing refactor
  clothes ("simplify error handling" that changes error shapes), rejects
  big-bang scope, and reframes risky rewrites as **strangler-fig** sequences.
- **Implementers → refactorers.** *Characterize first*: if coverage is thin
  they write tests pinning **current** behavior (bugs included!) and commit
  those before touching structure. Then one mechanical move per commit, gate
  green at every step. A bug found mid-refactor gets **filed, never fixed
  in-band** — the captain surfaces the bug list to you as a fix/defer call.
- **QA → behavior-preservation verifiers.** Diff-first review with a hard
  rule you'll see enforced: **any edit to an existing test expectation is a
  behavior change** and gets rejected, even when the gate is green.
- **Captain → sequencer.** Refactors collide on shared files, so the captain
  releases items in dependency order, pre-assigns one item per refactorer,
  and serializes when in doubt. The template defaults to `--pairs 2` for the
  same reason.

Expect releases from this factory to be *invisible* — that's the success
criterion, and the release notes say so.

Design + research basis: [refactor-factory.md](refactor-factory.md).

---

## 6. The ideation factory

```bash
fwf up --template ideation
```

The product isn't code — it's **ranked idea portfolios**. Ideas are markdown
briefs under `ideas/` in the target repo, flowing through the same PR
machinery.

Kick one off by giving the captain (or PM) something fuzzy: *"we should do
something about onboarding"*. The PM frames it as a gated **challenge brief**
— a "How might we…" question at the right altitude, constraints marked
HARD/SOFT, success criteria, and the rubric weights ideas will be judged by.
The GV gates the *frame* (a too-narrow frame smuggles in its own conclusion).
You approve it like any draft, then the floor diverges:

- **Generators** (the impl seats) are **stance-diverse by id** — impl1 starts
  from user pain, impl2 transfers analogies from other domains, impl3 inverts
  constraints — and each one diverges 8–12 raw candidates *before* reading
  anyone else's ideas (anti-anchoring), then develops the best 1–3 into
  briefs with a named riskiest assumption.
- **Critics** (the QA seats) harden rather than kill: the merge bar is
  "developed enough to compare", and their standard demand is a testable
  feasibility path — not "less weird".
- **The synthesizer** (the conductor seat) clusters the merged briefs, files
  `combine:` requests when two ideas are stronger merged, ranks **pairwise**
  within clusters, and maintains `ideas/PORTFOLIO.md` — the curated, ranked
  index that gets promoted to `integration`.
- **The captain** owns the diverge/converge rhythm and brings you a decision
  when returns diminish: top 3–5 picks with a recommendation — pick winners,
  run another round with a corrected frame, or close the challenge. Winning
  briefs hand off however you want (commonly: seed a dev-factory issue set).

Design + research basis: [ideation-factory.md](ideation-factory.md).

---

## 6½. The dev-sre variant

```bash
fwf up --template dev-sre
```

The dev factory plus a **fourth coordination pane**: an SRE that owns *all*
prod ops — health heartbeat, recovery, lock-sweeps, deploy mechanics, live
verification — and reports upward through issues (it is never human-facing;
you still talk only to the captain). While it runs, the captain does **zero**
ops actions; it keeps the release *decision* and your go-ahead, and hands the
deploy *mechanics* to the SRE, which posts verification evidence.

Don't run this by default. The trigger ladder in
[captain-split.md](captain-split.md): script the toil first, stay fused
second, split only when you have a live prod service + ops work most hours +
a visibly degraded captain loop.

---

## 7. Build your own template

A template is a directory:

```
templates/<name>/
  implementer.tmpl   qa.tmpl   conductor.tmpl   pm.tmpl   gv.tmpl   captain.tmpl
  template.sh        # optional: config defaults + roster declarations
```

`fwf up --template <name>` validates at launch that all six roles resolve;
`fwf templates` lists every template directory it finds (underscore-prefixed
addenda like `_local-issues` excluded).

**Inherit instead of copying.** Override only what differs:

```bash
# templates/my-variant/template.sh
# fwf template: <one-line description shown by `fwf templates`>
FWF_TEMPLATE_BASE="dev"            # any role tmpl missing here falls back to dev's
FWF_PAIRS="${FWF_PAIRS:-2}"        # config DEFAULTS — keep the ${VAR:-} shape so
                                   # CLI/env/profile still win
```

**Add panes.** A template can declare extra roles beyond the stock roster:

```bash
FWF_EXTRA_ROLES="${FWF_EXTRA_ROLES:-sre:coord:2m:colour208}"
#                                   name:session:interval[:color]
#                                   session = coord | build
```

Each extra role needs a matching `<name>.tmpl` (own dir or base) and gets a
worktree at provision, a pane at `up`, its own `/loop <interval>` prompt, and
full `fwf respawn <name>` / floor-lifecycle support. Coordination-side extras
are treated as PM-plane: they die on `down --pm-only` (and so also on
`--floor-only`), the captain and GV survive.

**Placeholders.** `fwf render`s every `.tmpl` with these substitutions
(whitespace is collapsed to one line — write prose, not ASCII art):

| Placeholder | Becomes |
|---|---|
| `__ID__` | the pair number (implementer/qa only) |
| `__REPO__` | the target repo's basename |
| `__STAGING__` / `__INTEGRATION__` / `__DEFAULT__` | the branch ladder |
| `__WIP_LABEL__` / `__HOLD_LABEL__` | the gate + freeze labels |
| `__GATE__` / `__E2E__` | the profile's gate/e2e commands, wrapped as `fwf gate <role> [--e2e] -- ...` (issue #123) — the shared guarded launcher; exits 75 (skip, not red) when that role's own prior gate is still in flight |
| `__LOCK__` | the e2e lock path |
| `__STOPFILE__` | the stop sentinel path (every role must honor it) |
| `__COORD_SESSION__` / `__BUILD_SESSION__` | the tmux session names |
| `__PM_INTERVAL__` | the PM's loop interval |
| `__DEVUI__` | the live-dev hint (with `__DATA__` expanded) |
| `__DISCOVERY_LABEL__` | the discovery-flow label |
| `__UT_APP_URL__` / `__UT_ROOT__` / `__UT_PERSONA_PANES__` / `__UT_PERSONA_COUNT__` | user-testing template only: target app URL, output root, persona roster |

**Keep the harness contract.** Whatever your roles do, preserve these
behaviors from the shipped prompts — the machinery depends on them: the STOP
check (commit WIP, cancel loop, idle when `__STOPFILE__` exists), one PR in
flight per worker, never pushing shared branches directly, never merging your
own PR, the atomic CLAIM protocol if workers self-select work, and
communicating through issues rather than tmux. Steal liberally from
`templates/dev/` — the prompts are the documentation.

**Test it** the cheap way before burning tokens: render every role through
the real path —

```bash
FWF_TEMPLATE=my-variant FWF_PROFILE=example bash -c \
  'source lib.sh; fwf_render "$(fwf_tmpl_path captain)" ""' | head -c 400
```

and add an eval scenario for any behavior you care about (next section).

---

## 8. Which model for which seat: `fwf eval`

Role-level evals answer "is the cheap model good enough for this seat?"
with evidence instead of vibes:

```bash
fwf eval --role qa --models claude-haiku-4-5-20251001,claude-sonnet-4-6 --trials 3
fwf eval --role implementer --template refactor --models claude-opus-4-8
fwf eval --role captain --scenario needs-you --models default --judge-model claude-opus-4-8
```

What happens per trial: the harness renders the role's **production prompt**
(same code path as `fwf up`), pairs it with a **scenario** — a fixture of the
exact command outputs an agent would see on one loop tick — and asks the
candidate model (via `claude -p`, no tools) what it would do this cycle. A
judge model scores the response 0–10 against the scenario's **rubric**, with
hard pass/fail lines for the violations that matter (merging a red gate,
fixing a bug inside a refactor, branching before the claim…).

Output lands in `eval/results/<ts>-<template>-<role>/`: a `report.md` with
per-trial scores and a mean per model, plus every prompt, response, and judge
verdict as files — the report is the summary, the transcripts are the
evidence.

Six scenarios ship (claim-race, red-gate, needs-you, bug-found,
expectation-edit, anchoring — see [eval-harness.md](eval-harness.md)).
**Adding one is just a directory:**

```
eval/scenarios/<template>/<role>/<name>/
  scenario.md   # the state the agent observes: issue lists, PR diffs, gate output
  rubric.md     # points per behavior + the hard pass/fail conditions
```

Write the scenario as literal command outputs (look at
`eval/scenarios/dev/implementer/claim-race/` for the house style), make the
rubric score what you'd actually fire a model over, and run it. Reading the
judge's `violations` array across trials tells you *why* a model fails a
seat, not just that it does.

Practical reading: a model that clears `qa/red-gate` at 8+ is safe for the
verifier seats at a third of the cost; a model that fails
`implementer/claim-race` will duplicate work on a contended floor no matter
how well it codes.

---

## 9. The container sandbox: `fwf shell`

```bash
fwf shell             # build the toolchain image + drop into it
fwf shell --rebuild   # rebuild the image from scratch first
```

You land in a Debian container with the full pane toolchain (bash 5, tmux,
git, gh, claude) and this repo mounted at `/opt/fwf` — with your **host
credentials injected, never baked in**: `GH_TOKEN` from `gh auth token`, and
your claude OAuth blob extracted (from the macOS Keychain if needed) into a
throwaway 0700 dir mounted file-by-file. Sandbox-side token refreshes are
deliberately discarded.

Use it as a reproducible Linux environment for developing fwf itself (`bash
test/run.sh` works inside), or as the substrate for the next containerization
slices — floor-in-container and throwaway e2e containers — designed in
[containers.md](containers.md).

---

## 10. When something looks wrong

| Symptom | What it usually is | Do |
|---|---|---|
| A pane shows a shell prompt instead of claude | claude crashed or never booted | `fwf respawn <role>` |
| An agent "isn't doing anything" | normal between loop ticks (1–5 min), or waiting on a dependency | read its pane; check the captain's status table before poking |
| Two PRs for one issue | a worker skipped the claim protocol | the captain closes the newer one; it also reminds the offender |
| `CLAIM implN` comments piling up in issues | the atomic-claim mutex at work | nothing — that's the fix, not the bug |
| e2e never runs / "e2e busy" forever | a role holding the lock died (issue #65) | usually self-recovers on the next acquire attempt (dead-PID check); if the holder is stamped from a different host and still under the ~30m backstop, `rm -rf ~/.fun-with-friends/e2e.lock` (NOT `rmdir` — the dir now holds a holder-identity stamp file) |
| Everything idles immediately after `fwf up` | stale STOP sentinel | `fwf resume --clear-only` (a fresh `fwf up` also clears it) |
| Agents still looping after you wanted quiet | you attached and typed into a worker pane | don't; `fwf stop` for a graceful halt |
| CI red on GitHub | check the annotation — billing/credit failures kill jobs in ~2s with zero steps | trust `bash test/run.sh` locally |

Internals worth knowing when debugging: prompts are typed into panes in 1KB
chunks (tmux rejects >10KB `send-keys` arguments); `fwf up` verifies claude
actually booted in each pane before delivering its prompt and re-sends to
laggards; everything any agent knows it re-derives from GitHub + git on each
tick, which is why respawning is always safe.

## 10½. Repos whose issues you don't control: `--issues local`

On a work repo or upstream OSS project you usually can't create labels or fill
the tracker with a factory's wall-of-text reasoning. Local issues mode moves
the entire bus out of the repo:

```bash
fwf up --issues local        # or --local-issues, or FWF_ISSUES=local in the profile
```

You drive the factory **exactly as before** — same conversations with the
captain, same gated drafts, GV markers, approvals, claims — but issues live as
**one markdown file each** under
`~/.fun-with-friends/issues/<profile>/{open,closed}/N-slug.md`: a
`# LI-N: title` header, `labels:` and `created:` lines, the body, then every
comment appended as a `## comment <timestamp>` section. Status is the
directory; open a file and you can read the entire discussion top to bottom
(or hand-edit it — the parser is lenient).

What changes mechanically:

- **The factory never touches the remote.** `fwf provision` installs a
  `pre-push` guard in the repo that blocks *every* push — including `staging`
  and `integration`, which are created as local branches only — unless a
  human authorizes that single push with `FWF_ALLOW_PUSH=1 git push …`. The
  guard is removed automatically if you re-provision in gh mode.
- Every role's `gh issue …` commands are rewritten at render time to
  `fwf issues …` (a gh-shaped CLI: `create/list/view/edit/comment/close/
  reopen/export`, including `--json`/`--jq` and `--search "is:open -label:x"`,
  so the prompts work verbatim). The atomic CLAIM mutex carries over —
  comment appends are lock-ordered, first CLAIM in the file wins.
- **There are no PRs on the floor.** Implementers hand off with a
  `READY-FOR-REVIEW implN · branch · sha` comment on the local issue; the
  paired QA gates the branch on a detached checkout and squash-merges it into
  the **local** `staging` (freeing the shared branch immediately after); the
  conductor promotes `staging → integration` locally, never fetching or
  pushing.
- Issue references become **`LI-N`** everywhere (branches, squash commits),
  so nothing ever auto-links or pollutes the upstream repo's real issue
  numbers.
- Nothing auto-closes on merge, so the **captain closes shipped issues at
  release** (`fwf issues close N --comment "shipped in vX"`) — and the
  captain is the **only** role that may ever touch the remote, strictly on
  your explicit, per-instance instruction: it pushes the curated branch with
  `FWF_ALLOW_PUSH=1`, opens the upstream PR, and writes the PR body by mining
  the local reasoning (`fwf issues view N --comments`, `fwf issues export`).

`fwf provision` in this mode touches **no GitHub labels**. The `--jq` flag of
`fwf issues` needs the `jq` binary; everything else is dependency-free.

## 11. Staying current

```bash
fwf upgrade --check    # am I behind the latest release?
fwf upgrade            # bring this install up to date
```

A git-clone install ff-pulls (refusing if you have local edits); a tarball
install downloads the latest release *next to* the current directory and
re-points the `fwf` symlink, leaving the old directory in place for rollback.
A git **worktree** install (every fwf-self swarm role runs from one) never
pulls itself in place — that's unsafe on a feature branch, detached HEAD, or
dirty tree — and instead refuses with the exact command to run from its main
checkout.

One thing the command will remind you of, because it matters: **a running
factory keeps its old prompts** — agents are armed at launch — so after an
upgrade, `fwf resume` (or `fwf respawn <role>`) re-arms them on the new
version. `FWF_UPGRADE_REPO` points at a fork if you run one.
