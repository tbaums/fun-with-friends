# Operator-driven mode (issue #166)

## Problem

The captain template's opening line defines the captain as "the human's
technical co-pilot AND the conductor of the factory ... you are the one
interactive role." In a deployment where an **external operator/concierge**
sits above the factory (the human talks to the concierge, not the captain;
the concierge owns un-gating + releases), that self-conception collides with
the concierge's: two actors both believe they own driving work to a shipped
result.

Observed in production (2026-08-12): the captain correctly detected the
overlap and, rather than fight for the wheel, entered a caretaker-hold —
parked on a lane question, waiting for a human ruling that could never reach
its pane (the human was attached to the concierge, not the captain). The
floor stalled on an unresolvable lane question until the concierge reached
into the floor directly.

## The fix: an explicit, opt-in overlay

`FWF_OPERATOR_DRIVEN=1` rewrites the captain prompt (`fwf_render`,
captain-only) so it:

- does **not** present itself as the human's co-pilot or expect human input
  in its own pane;
- **never** stalls in a caretaker-hold over a lane question — the lanes are
  pre-defined (below);
- focuses on floor orchestration + promotion to `INTEGRATION_BRANCH`, and
  surfaces anything a human needs to see as a **tracker artifact the
  operator reads**, not a pane message to an absent human.

The default (`FWF_OPERATOR_DRIVEN` unset, or `0`) leaves the captain as the
human's co-pilot, byte-for-byte unchanged — this is strictly an opt-in
overlay.

| Concern | Operator/Concierge | Captain (operator-driven mode) |
|---|---|---|
| Human interface | owns (human talks to concierge) | cedes — not a second co-pilot |
| What enters the floor (un-gate/authorize) | owns (`OPERATOR-UNGATE` sentinel, issue #150) | never self-authorizes |
| Drive claimed work PM→GV→impl→QA→promote | hands off, does not reach in | owns |
| Self-heal wedged roles | — | owns (issue #165) |
| Ship to prod (final review, cut, deploy) | owns | promotes staging→integration, **stops there** |

## Config

| Var | Meaning |
|---|---|
| `FWF_OPERATOR_DRIVEN` | `1` to enable the overlay for the captain; default `0` |
| `FWF_OPERATOR_INBOX_ISSUE` | the standing, pinned issue number the captain comments on for a floor-wide operator-facing question with no single ticket. **Required** when `FWF_OPERATOR_DRIVEN=1` — `fwf_render` fails closed (exits non-zero) if it's unset, since an unpinned surface is the pane stall relocated, not fixed. |

## The operator-facing surface contract

A ticket-scoped question (something blocking one issue's work) goes as a
comment on **that issue's own thread** — the same place every other role
already posts. A floor-wide question with no single ticket goes as a comment
on the pinned `FWF_OPERATOR_INBOX_ISSUE`. Either way the captain **writes and
keeps driving** in the same tick — it never parks waiting for a reply.

This only closes the stall if the concierge actually reads that surface:
the **concierge-reads-the-surface contract is a named dependency of this
mode**. The concierge-side implementation is out of scope for `fwf` (it lives
in the operator's own tooling); the interface — where the captain writes,
and that it never blocks on a reply — is what's in scope and enforced here.

## Release-pause handshake

`fwf` already has a tick-checked hold-sentinel family every role honors:
`STOP` (halts the loop) and `BUDGET_HOLD` (pauses, auto-resumes — see
`fwf usage`). Operator-driven mode adds a third member of the **same**
family instead of inventing a new channel:

- `RELEASE_HOLD` (`$FWF_RUN_DIR/RELEASE_HOLD`, i.e. `RELEASE_HOLD_FILE` in
  `config.sh`) — the operator/concierge writes it before a release gate
  (CPU/shared-target contention with the factory). The captain checks it on
  every tick (`RELEASE-PAUSE CHECK`, right after the `BUDGET_HOLD` check in
  `templates/dev/captain.tmpl`): while it exists, no release-adjacent action
  starts (promoting to `INTEGRATION_BRANCH`, cutting/deploying a release),
  and the floor **pauses** there rather than stopping — everything else
  (build floor, PM) keeps running. Removing the file resumes the release on
  the captain's next tick; no operator reach-in (`fwf stop`) is needed on
  either side.

The `RELEASE-PAUSE CHECK` step is unconditional in the template (present for
every captain, operator-driven or not) — like `STOP`/`BUDGET_HOLD`, it is
inert unless something actually writes the file.

## Verifying

```sh
FWF_PROFILE=<p> bash -c "source lib.sh; fwf_render \"\$(fwf_tmpl_path captain)\" ''"
```

renders the default (co-pilot) captain prompt, unchanged.

```sh
FWF_PROFILE=<p> FWF_OPERATOR_DRIVEN=1 FWF_OPERATOR_INBOX_ISSUE=99 \
  bash -c "source lib.sh; fwf_render \"\$(fwf_tmpl_path captain)\" ''"
```

renders the operator-driven overlay in place, referencing issue `#99` as the
floor-wide surface. Omitting `FWF_OPERATOR_INBOX_ISSUE` with
`FWF_OPERATOR_DRIVEN=1` fails closed with a non-zero exit.
