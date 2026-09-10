# Cutover and rollback (T-33)

The v0.42.x install stays. 1.0 runs beside it until the head-to-head says
otherwise, and going back is a `fwf up` away.

## Before

- `fwfd doctor` mints all three Apps on the target repo.
- `.fwf/fwf.toml` exists in the customer repo and `fwfd up` prints the plan
  (convert with `fwfd init-manifest --from-profile`).
- `~/.fwf/seat-token` exists (`claude setup-token`); seats come up
  authenticated with `one/scripts/seat-up.sh`.
- The v0.42 floor for that repo is DOWN (`fwf down`); two factories on one
  repo would race on claims.

## Cut over (one repo at a time)

1. `fwfd mirror-init --repo o/r`; clone the seat worktrees from the mirror
   (README, step 3). Old `~/tx-*`-style worktrees are not reused: archive
   them (`mv ~/tx-impl1 ~/archive/`) once their branches are pushed.
2. Put only the issues you mean to work in the manifest allow-list.
3. `fwfd run --once`; read `fwfd status` and `fwfd dash`; then `fwfd run`.
4. State lives only in `~/.fwf/floors/<name>/` (mirror, worktrees, verdicts,
   `run.jsonl`) and in GitHub's own objects. There is no v0.42 state to
   migrate: claims are refs, not comments; the run record starts empty.

## Roll back

1. Stop `fwfd run` (Ctrl-C; it never leaves a half-applied write: each
   GitHub write is a single request, and the record shows the last one).
2. Delete any live claim refs it held: `git push origin :refs/claims/<n>`
   under the operator's own credentials.
3. `fwf up` on the v0.42 profile. Nothing 1.0 did needs undoing: its PRs
   are ordinary PRs, its merges ordinary merges, its check-runs inert.

## Keep both

Two repos can run on different versions indefinitely: 1.0 owns the repos whose
manifest exists; v0.42 owns the rest. The App identities are per-repo installs.
