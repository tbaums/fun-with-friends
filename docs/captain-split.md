# Splitting the Captain: Factory Coordinator vs Prod Ops/SRE (#4)

Status: **decided.** Split **conditionally** — keep the fused captain as the
default, ship the SRE as an *optional role* once roles are data (the factory
template system, issue #10). Until the trigger conditions below hold, the
cheaper answer the issue suspected is correct: automate the ops toil, don't
spawn a role to perform it.

## The diagnosis (agreed with the issue)

The two jobs really are different headspaces with different cadences:

| | Coordination | Prod ops |
|---|---|---|
| Loop shape | bursty, high-context, strategic | tight, repetitive, low-context |
| Cadence | human-paced (minutes–hours) | machine-paced (1–5 min probes) |
| Cost of interleaving | rote toil pollutes a heavy context and burns its tokens on lock-clearing | heavy context makes every probe expensive; strategic thought delayed by probe ticks |

But a cadence mismatch alone doesn't justify a standing agent. A second
always-on loop costs tokens every tick forever; the fused captain only pays
the interleave cost when ops work actually exists.

## The decision ladder (cheapest fix first)

1. **Script the toil.** A recovery you've done twice identically is a shell
   script, not a judgment call. The captain's heartbeat then runs the script
   and reads its one-line result. This is most of the win at ~zero cost, and
   captain.tmpl already mandates the root-cause escalation that produces these
   scripts ("don't just nurse a recurring failure").
2. **Stay fused with discipline.** With toil scripted, the heartbeat is cheap
   enough to interleave: probe → green → back to coordination. This is the
   correct DEFAULT for fwf, because most target repos have no deployed prod
   service at all — an SRE pane for a repo with no prod is pure waste.
3. **Split — when the triggers hold.** Spawn the optional SRE role when ALL of:
   - the factory babysits a **live production service** (health endpoint,
     deploys, real users), AND
   - ops interventions are **recurring** (the heartbeat finds work most
     hours, not most weeks), AND
   - the captain's strategic loop is **demonstrably degraded** — ticks spent
     on ops while human decisions queue up (the exact failure #6's
     floor-lifecycle work is about: cost/attention management).

## The role contract (what the split looks like when triggered)

Resolved against the issue's four tensions:

- **Human surface: still exactly one.** The captain remains the only
  interactive role. The SRE reports *upward* — issue comments and incident
  issues the captain's tick sweeps into its "⛔ NEEDS YOU" list. The human
  never attends two chat panes.
- **RELEASE: decision and mechanics separate cleanly.** Captain decides a
  release is warranted and gets the human go (unchanged — authorization never
  delegates). SRE *executes* the runbook: version bump, changelog, tag, cut,
  deploy, **live verification** (version endpoint, health, cache marker), and
  posts the verification evidence. Captain relays the result.
- **No race at the role boundary.** Ownership is total, not shared: when the
  SRE role is up, the captain does ZERO ops actions (no restarts, no lock
  clears — even mid-conversation; it files/points instead). One writer per
  resource is the same rule that fixed duplicate claims (#2). The SRE
  similarly never touches coordination artifacts (no un-gating, no claim
  deconfliction, no scoping).
- **Worth a pane?** That's exactly what the trigger conditions test. The role
  is opt-in per profile, not part of the default factory.

What the SRE owns: the heartbeat (fast cadence), recovery + the scripted
toil, deploy mechanics + live verification, filing reliability issues with
the recurrence evidence (continuing the root-cause discipline), and incident
escalation to the captain. What it never does: write feature code, touch the
pipeline, talk to the human first.

## Implementation path

Roles are currently hardcoded across fwf-up/respawn/lib (pane layout, prompt
delivery, intervals). Bolting a conditional 4th coordination pane onto that
would be rework the moment #10's factory templates land, since templates make
the role roster data. So:

- **#7** (pairs/models at runtime) starts turning the role roster into data.
- **#10** (factory templates) ships the template mechanism — and with it
  `prompts/sre.tmpl` + a `dev-sre` template variant implementing the contract
  above, selectable per profile/CLI flag.
- This doc is the contract that template implements; the trigger ladder is
  the guidance for when a profile should select it.
