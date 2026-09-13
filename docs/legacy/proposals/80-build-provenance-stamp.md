# Proposal: build-provenance stamp on every factory PR

**Status: SHIPPED (v0.24.0).** Implemented as `fwf_model_for` +
`fwf_provenance_block` in `lib.sh`, a `__PROVENANCE__` template placeholder, and
a one-line `fwf-Provenance:` trailer wired into the implementer PR body and the
QA squash-merge commit across every PR-producing template. Covered by
`test/run.sh` (section "build-provenance stamp"). This note is kept for
rationale.

## The problem it solves

A factory's most damaging blind spot shows up *after the fact*, when someone
asks: **"did the work this floor shipped actually get worse — and if so, why?"**

That question is often unanswerable, because the evidence to answer it was never
recorded:

- The **role→model map** (which seat ran which model) lives only in a
  gitignored `profiles/*.sh` with no version history. A silent model swap on one
  seat leaves zero git trace.
- **Per-PR build provenance** (which fwf checkout produced a change) is written
  nowhere durable.

So a later quality diagnosis becomes **archaeology** — reconstructing from
scattered, decaying signals what should simply have been written down when the
work shipped. The single most decision-relevant axis (which models built which
change) is exactly the one that evaporates first.

## The insight

Nothing new has to be computed. The factory already *knows* its provenance at
render time — the per-seat model resolver (`fwf_model_for`) and its own identity
(`VERSION` + git SHA). The fix is to **persist it next to the work**, in the one
place that is permanent, greppable, and co-located with both the diff and the
ticket: the **squash-merge commit** every PR produces.

## Design

- `fwf_provenance_block` emits a single git-trailer line, e.g.:

  ```
  fwf-Provenance: fwf=0.24.0@abc1234 profile=example seats=[captain=<model> pm=<model> gv=<model> impl=<model> qa=<model> conductor=<model>]
  ```

- It is exposed as a `__PROVENANCE__` placeholder through the existing template
  substitution (`fwf_render`), so it is stamped at launch = the seat assignments
  actually in force for the run.
- It is wired into every PR-producing template at two points: the implementer's
  `gh pr create --body` (live visibility on the open PR) and the QA
  `gh pr merge --squash` body (the durable, in-history anchor). Templates that
  never open an upstream PR (`_local-issues`) are exempt; a coverage test
  enforces that any template which *does* run `gh pr create|merge` carries the
  stamp, so a new factory design can't silently ship un-attributed work.

## The payoff

Per-release quality/provenance becomes a **derived git query**, not a maintained
ledger. `git log <tagA>..<tagB>` reading the `fwf-Provenance:` trailers tells you
which fwf checkout and which per-seat models produced that range — the exact
input a "did quality regress across this boundary?" investigation needs, with no
separate artifact to keep in sync.

Generic by design: the trailer carries only the factory's own identity and its
seats — never any client, repository, or target specifics.
