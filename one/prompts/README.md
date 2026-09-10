# prompts — one job per wake, one file per (family, role)

fwf 0.x rendered one 300-line looping prompt per role with ~40 `__MARKERS__` and a
comment protocol (`CLAIM`, `GV-SIGNOFF`, `GV-CHANGES`, `COORD-DRAFT`, tick/stop/budget
files). fwf 1.0 seats are woken with exactly one job and answer with one JSON verdict;
every GitHub write, claim, label and merge is the supervisor's. So the port removed, not
translated, everything that was coordination: no `gh`, no claims, no heartbeats, no
stop files, no marker comments, no "each cycle" loops. What remains is the role's
judgment: what to do and what a good result is.

Layout: `prompts/<family>/<role>-job.md`. The manifest's `template` key picks the
family (default `dev`). A missing file falls back to `dev/<role>-job.md`, so a family
only overrides the roles whose judgment differs.

| family (0.x) | impl | qa | gv | pm | notes |
|---|---|---|---|---|---|
| dev | ✔ | ✔ | ✔ | ✔ new: `fwfd spec` cycle | proven live (PRs #565/#567/#569, triage #570) |
| refactor | ✔ | ✔ | dev | dev | characterize-first, one mechanical move per commit, never edit an expectation |
| validate | ✔ | ✔ | ✔ | dev | evidence tiers `[E:cited]/[E:inferred]/[A:assumption]`; red-team QA |
| ideation | ✔ | ✔ | ✔ | dev | assigned stance, one idea per brief |
| consulting | ✔ | ✔ | ✔ | dev | validate + client repo read-only + roles not names |
| defect-report | ✔ | ✔ | dev | dev | locators into a named source of truth; receiver's editor |
| user-testing | ✔ (persona) | ✔ (researcher) | dev | dev | source-blind by construction: the seat worktree holds no product source |
| dev-sre | – | – | – | – | not a seat: prod ops is `fwfd status`/`dash` plus the operator |
| _local-issues | – | – | – | – | absorbed: every 1.0 seat already works only against the local mirror |

captain and conductor are code, not prompts: `fwfd status`, `fwfd dash`, `fwfd gate`,
`fwfd promote`.

Placeholders the supervisor fills: `{{SEAT}} {{REPO}} {{ISSUE}} {{TITLE}} {{BODY}}
{{BRANCH}} {{PR}} {{HEAD}} {{BASE}}`. `prompts.rs` refuses a file that uses any other.

Eval harness: `eval/run.sh` (0.x) drives prompts through `claude -p` against fixture
scenarios and an LLM judge. It has not been re-run on these one-job prompts (metered,
and the scenario fixtures describe the looping protocol); porting the harness to feed
a woken seat instead of `claude -p` is the open piece of T-26.
