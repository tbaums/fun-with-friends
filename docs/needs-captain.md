# The `needs-captain` flag (issue #113)

## Problem

An agent (impl/qa/pm/gv) that hits something only the captain can decide had
no reliable channel to reach it. A tmux pane line the captain wasn't primed
to read, or a plain issue comment the captain only sees if it happens to open
that issue, are both ephemeral — nothing forces the captain to notice, and
nothing survives a respawn. That's exactly what happened on 2026-07-14: impl1
raised a concern and the captain never saw it.

## The fix: a persisted, tracker-native flag

Any role raises a `needs-captain` flag on an issue **or** a PR. The flag is
carried by two things together:

- the `needs-captain` **label** on the item (works identically in both the
  GitHub-issues and local-issues trackers — see below)
- a comment whose first line is exactly

  ```
  NEEDS-CAPTAIN: [<role>] <one-line reason>
  ```

  e.g. `NEEDS-CAPTAIN: [impl1] blocked: base missing #104 provenance primitive`

The raiser role is **self-declared** in the `[role]` tag, never inferred from
the comment author — every fwf-self role authenticates as the same GitHub
account, so the author field carries no role information.

The captain's per-tick loop (wired into every `captain.tmpl`) sweeps every
open `needs-captain` item and folds it into its report: `#` · role · reason ·
age. A flag raised during tick N is guaranteed to surface no later than the
captain's next tick — no pane-reading required. The flag **persists** across
ticks, idle/respawn, and pane churn until the captain explicitly clears it.

## `fwf flag-captain`

```
fwf flag-captain <n> --role <role> --reason "<text>"   raise (or re-raise)
fwf flag-captain <n> --clear [--note "<text>"]         clear (captain only)
fwf flag-captain sweep                                  list every open flag
```

- **Raise** is idempotent on the label (re-applying it no-ops) and *appends* a
  new `NEEDS-CAPTAIN:` comment every time — a second raiser's reason is never
  lost, and a duplicate raise by the same role just refreshes the reason.
- **Clear** removes the label and, with `--note`, records what the captain
  did in a `NEEDS-CAPTAIN-CLEARED: <note>` comment. Clearing resets what
  counts as "active" for that item: a `NEEDS-CAPTAIN:` comment posted *after*
  the clear is a fresh, active flag again (a raise-clear-raise sequence never
  gets silently swallowed by the earlier clear).
- **Sweep** unions open issues and open PRs carrying the label (both
  independently, since a flag can be raised on either), and for each surfaces
  one row per *active* raise:
  - zero active `NEEDS-CAPTAIN:` comments on a labeled item → still surfaces,
    as `role unstated` / `no reason given` (a flag is never silently dropped
    for a missing reason or role)
  - a `NEEDS-CAPTAIN:` line with no `[role]` tag → `role unstated`

The label is guaranteed to exist before any raise: the GitHub-backend raise
path (`gh label create ... --force`) create-if-absents it inline, and `fwf
provision` also pre-creates it at setup time (belt-and-suspenders) — a raise
against a fresh repo/tracker never fails on a missing label.

## Both trackers, one command

`fwf-issues.sh` (the local-issues store used with `--issues local`) already
mirrors the `gh issue`/`gh pr` label surface (`edit --add-label`/
`--remove-label`, `list --label`, `comment`), so `fwf flag-captain` branches
internally on `FWF_ISSUES` and produces the **same command, same sweep output
shape** in both trackers (AC5) — a raiser never needs to know which backend is
active.

## Out of scope

This is poll/sweep-based, matching the captain's existing per-tick loop —
there is no new interrupt/push channel, and none is needed: the captain
already ticks on its own cadence. It also doesn't triage what the captain
*does* with a flag; it only guarantees the flag is reliably **visible**. A
wedged or tick-missing captain (the captain-liveness failure class, #99/#85)
would still leave a flag unseen — that's an accepted, separately-tracked
residual, not something this mechanism claims to close.
