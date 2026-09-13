# Proposal: review of the "16GB box is oversubscribed" strategy verdict (#158)

**Status: REVIEWED, no fwf-factory code action.** This is a STRATEGIC
discovery ticket whose own body already contains a completed 4-critic
adversarial review, verdict, and recommendation — and whose "Decision for
Jamie" section explicitly frames the actual call (spend on hosting, adopt
CI, migrate prod) as an **operator decision on a separate project's
infrastructure** (the `transom` deployment), not a build task in this repo.
My role here is impl1 for `fun-with-friends`/fwf-factory specifically; I
have no visibility into or authority over `transom`'s hosting, CI, or prod
box. So this proposal does two things instead of re-deriving the analysis:
(1) independently verifies the parts of the verdict that reference
*this* repo's mechanisms, since those I can actually check, and (2) states
plainly what — if anything — is actionable inside fwf-factory itself.

## 1. Verifying the fwf-factory-specific claims

The verdict leans on several claims about how this tool's own knobs work.
Checked directly against the current codebase:

- **"`GATE_CMD`/`E2E_CMD`/`BUILD_CMD` are already isolated single-line
  vars, so wiring [to CI] is tractable."** Confirmed —
  `profiles/example.sh`: `GATE_CMD='make test'`, `BUILD_CMD='true'`,
  `E2E_CMD='true'`, each a single string a profile overrides. Nothing about
  how the gate/build/e2e commands are invoked assumes local/resident
  execution; a CI job could shell out to the exact same strings a profile
  already declares. This part of the recommendation is accurate and
  requires no fwf-factory change to be true.
- **"the flock build lock (#156), `FWF_PAIRS=1`, `FWF_MIN_FREE_GB`, the
  shared-target hack ... are rationing mechanisms."** `FWF_MIN_FREE_GB`
  (`fwf-up.sh`, default 50G, refuses to launch/cycle below the floor) and
  per-worktree `CARGO_TARGET_DIR` isolation (#151, this repo's own recent
  fix — see #178/#180/#181's neighbor work this same cycle) are real,
  present mechanisms, and they are exactly what their names say: capacity
  management, not new capability. Accurate.
- **"resident agents coordinate through shared state (tmux panes, one
  checkout, one cargo target, one gh identity, cron heartbeats)."** All
  true of fwf-factory's resident-floor design as it exists today — this is
  the architecture, not a bug in it. The referenced incidents (#150 fake
  approval, #151 shared-target false-green, worktree/lock issues) are
  fwf-factory issues this implementer has direct visibility into, and the
  characterization is fair.

I found nothing in the verdict that misrepresents this repo's actual
behavior.

## 2. What (if anything) is actionable in fwf-factory itself

Reviewing the three recommended moves against what fwf-factory, as a
*tool*, would need to support them:

1. **Builds/e2e → hosted CI.** Already supported architecturally (§1) —
   nothing to build here. The actual CI workflow is a `transom`-repo
   artifact, out of scope for an fwf-factory PR.
2. **Prod + Kokoro daemon → its own host.** Entirely a `transom`/ops
   concern; fwf-factory has no involvement.
3. **Agents → ephemeral-default, resident-as-opt-in.** This is the one
   claim closest to fwf-factory's own surface — but the concrete direction
   named (#154, "concierge-orchestrated ephemeral subagents") is a
   *different* orchestration model, not a mode this tool implements or
   would need to. If `transom` (or any consumer) later wants fwf itself to
   default to a leaner/ephemeral floor shape, that would come in as its
   own scoped ticket against a concrete design — nothing to speculatively
   build against an unwritten spec today.

## Recommendation

**No fwf-factory code or docs change.** The verdict is sound as far as it
touches this repo, and the recommended actions are correctly scoped to
`transom`'s infrastructure and an operator (Jamie) decision, not this
tool. Leaving the "Decision for Jamie" section as the actual next step;
this proposal exists only to confirm fwf-factory isn't hiding a blocker or
misrepresented capability in that decision.
