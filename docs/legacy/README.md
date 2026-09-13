# fwf 0.x — the bash factory (archived)

> **Deprecated.** Everything under `docs/legacy/` documents fwf 0.x, the bash
> harness driven by `fwf-legacy`: captains, profiles, `lib.sh`, marker-comment
> coordination. It is kept because the 0.x tool still runs and its history
> explains why 1.0 is shaped as it is. None of it describes fwf 1.0.
>
> For 1.0, start at [`../index.md`](../index.md).

## Cutover and rollback (T-33)

The v0.42.x install stays. 1.0 runs beside it until the head-to-head says
otherwise, and going back is a `fwf-legacy up` away.

### Before

- `fwf doctor` mints all three Apps on the target repo.
- `.fwf/fwf.toml` exists in the customer repo and `fwf up` prints the plan
  (convert with `fwf init-manifest --from-profile`).
- `~/.fwf/seat-token` exists (`claude setup-token`); seats come up
  authenticated with `one/scripts/seat-up.sh`.
- The v0.42 floor for that repo is DOWN (`fwf-legacy down`); two factories on one
  repo would race on claims.

### Cut over (one repo at a time)

1. `fwf mirror-init --repo o/r`; clone the seat worktrees from the mirror
   (README, step 3). Old `~/tx-*`-style worktrees are not reused: archive
   them (`mv ~/tx-impl1 ~/archive/`) once their branches are pushed.
2. Put only the issues you mean to work in the manifest allow-list.
3. `fwf run --once`; read `fwf status` and `fwf dash`; then `fwf run`.
4. State lives only in `~/.fwf/floors/<name>/` (mirror, worktrees, verdicts,
   `run.jsonl`) and in GitHub's own objects. There is no v0.42 state to
   migrate: claims are refs, not comments; the run record starts empty.

### Roll back

1. Stop `fwf run` (Ctrl-C; it never leaves a half-applied write: each
   GitHub write is a single request, and the record shows the last one).
2. Delete any live claim refs it held: `git push origin :refs/claims/<n>`
   under the operator's own credentials.
3. `fwf-legacy up` on the v0.42 profile. Nothing 1.0 did needs undoing: its PRs
   are ordinary PRs, its merges ordinary merges, its check-runs inert.

### Keep both

Two repos can run on different versions indefinitely: 1.0 owns the repos whose
manifest exists; v0.42 owns the rest. The App identities are per-repo installs.

## Archived pages

- [`BUILD-LOG.md`](BUILD-LOG.md) — one/ — build log (M0–M3, 2026-09-09)
- [`CHANGELOG-0.x.md`](CHANGELOG-0.x.md) — Changelog
- [`INCIDENT_PROTOCOL.md`](INCIDENT_PROTOCOL.md) — Incident protocol (operator / captain)
- [`THIN-SLICE.md`](THIN-SLICE.md) — Thin slice: what a woken seat actually does
- [`authz-point-of-action.md`](authz-point-of-action.md) — Authorization at the point of action (issue #207)
- [`branch-protection.md`](branch-protection.md) — Branch protection (issue #220)
- [`captain-split.md`](captain-split.md) — Splitting the Captain: Factory Coordinator vs Prod Ops/SRE (#4)
- [`citation-anchors.md`](citation-anchors.md) — Citing code in a spec: anchor on a token, not a bare line number (issue #370)
- [`collapsing-reads-audit.md`](collapsing-reads-audit.md) — Collapsing-reads audit (issue #211)
- [`collapsing-reads.md`](collapsing-reads.md) — Collapsing reads (issue #211)
- [`consulting-factory.md`](consulting-factory.md) — The consulting factory — design and basis
- [`containers.md`](containers.md) — Containerizing fun-with-friends — design exploration (#3)
- [`coordination-idle-backfill.md`](coordination-idle-backfill.md) — Coordination-lane idle-backfill (issue #169)
- [`dash.md`](dash.md) — `fwf dash` — the status board + decision inbox
- [`defect-report-factory.md`](defect-report-factory.md) — The defect-report factory — design and basis
- [`eval-harness.md`](eval-harness.md) — The eval harness (#8) — which model for which role, with evidence
- [`fwf-scale.md`](fwf-scale.md) — fwf scale — reconcile pairs on a live floor (issue #210)
- [`gate-throughput.md`](gate-throughput.md) — Gate throughput (issue #138)
- [`gh-read-cache.md`](gh-read-cache.md) — gh read cache (REST + ETag)
- [`ideation-factory.md`](ideation-factory.md) — The ideation factory (#9) — design and research basis
- [`macos-ci.md`](macos-ci.md) — macOS CI runs locally, not on GitHub
- [`needs-captain.md`](needs-captain.md) — The `needs-captain` flag (issue #113)
- [`operator-decision.md`](operator-decision.md) — The operator→captain channel (issue #192)
- [`refactor-factory.md`](refactor-factory.md) — The refactoring factory (#10) — design and research basis
- [`repo-profiles.md`](repo-profiles.md) — Repo profiles: in-tree vs. out-of-tree (issue #188)
- [`shared-account.md`](shared-account.md) — The shared-GitHub-account reality
- [`sleep-bounded-concurrency-audit.md`](sleep-bounded-concurrency-audit.md) — Sleep-bounded concurrency audit (issue #247)
- [`subscription-budget.md`](subscription-budget.md) — Subscription-usage brake (issue #149)
- [`tutorial.md`](tutorial.md) — The fun-with-friends tutorial
- [`user-testing.md`](user-testing.md) — The user-testing factory (#42) — runbook
- [`validate-factory.md`](validate-factory.md) — The validation factory — design and basis

### Proposals

0.x-era design history, kept as filed.

- [`144-event-driven-handoff.md`](proposals/144-event-driven-handoff.md)
- [`152-attributable-operator-sentinel.md`](proposals/152-attributable-operator-sentinel.md)
- [`156-build-serialization.md`](proposals/156-build-serialization.md)
- [`157-concierge-liveness.md`](proposals/157-concierge-liveness.md)
- [`158-box-oversubscription-strategy.md`](proposals/158-box-oversubscription-strategy.md)
- [`321-factory-metrics-observability.md`](proposals/321-factory-metrics-observability.md)
- [`70-token-usage-budget.md`](proposals/70-token-usage-budget.md)
- [`79-upgrade-staleness-check.md`](proposals/79-upgrade-staleness-check.md)
- [`80-build-provenance-stamp.md`](proposals/80-build-provenance-stamp.md)

### Images

- [`img/dash.png`](img/dash.png) — the 0.x dash TUI, used by [`dash.md`](dash.md).

## See also

- [`../index.md`](../index.md) — the fwf 1.0 documentation index.
