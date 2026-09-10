# one/ — fwf 1.0 (`fwfd`)

The rebuild proposed in *fwf One* (2026-09-09): one Rust supervisor that owns
every authority-bearing action, wakes idle Claude Code panes only when there is
work (no `/loop` polling, no `claude -p` seats), keeps GitHub's typed objects as
the only coordination state, gates in containers, and promotes by literal SHA.
Seats hold read-only tokens and push to a local mirror.

This directory is developed on the `one/*` branches alongside the v0.42.x tree
it replaces. Nothing here is wired into `fwf` yet.

## Status — M0

| ticket | state |
|---|---|
| T-00 v0.42.10 security fix (#562) | PR open on the v0.42.x tree |
| T-01 crate skeleton, four enums, event log, `why` | this directory |
| T-02 three GitHub Apps (impl, qa, ops) | needs Jamie |
| T-03 GitHub client | mint LIVE for fwf-impl; ETag client next |
| T-04 fake GitHub | `src/fake_github.rs`, 9 contract tests |
| T-05 fake seat pane (tmux-backed) | done — `src/seat.rs` FakeSeat |
| T-06 seat waker + verdict reader | done — `wake`/`wait_verdict`; woken panes, no /loop, no claude -p |
| T-07 canary | canary PASS (see below); 10-cycle cost comparison parked (needs real seats) |
| T-08 thin slice (kill criterion) | unblocked (impl-only); needs T-09 scheduler + T-11 mirror first |
| T-09 poller + scheduler | done — `src/poll.rs`: `Poller` (base URL + bearer injectable; per-URL ETag cache with `If-None-Match`/304 body reuse; single-flight per URL; `requests()`/`not_modified()` counters; any failure = typed `PollError`, caller holds `Snapshot::unknown()`) reads `issues?state=open`, then `pulls/{n}` + `pulls/{n}/reviews` per PR and `git/ref/claims/{n}` per `claimed` issue. `src/sched.rs`: pure `plan(snapshot, seats, gate_label, owner_only, now) -> Plan` (WakeImpl / WakeQa / ReleaseClaim / Nothing). 14 tests: 5 proptest properties, 1 poll→plan→304→relabel contract test against the fake, single-flight proved with a barrier transport |
| T-09 notes | `author_association` is derived (author == repo owner → OWNER) when the API omits it, as the fake does; `closes_issue` accepts GitHub's close/fix/resolve keyword set; `IssueView.claim: Option<Fence>` and `Snapshot.known` added beyond the spec so `ReleaseClaim` carries a real fence (never fabricated) and `Unknown` is a value; `ReleaseClaim` fires only for a fenced claim no live seat is working (Working past `deadline` counts as stalled) and no open PR closes; a seat id that is non-Idle in any slot, or listed under two roles, is never double-booked (found by proptest); `mod poll; mod sched;` not yet in `main.rs` |
| T-11 local bare mirror | done — `src/mirror.rs`: `Mirror::init` (idempotent; `refs/remotes/upstream/*` + protected heads mirrored, HEAD=staging), `seat_remote_url()` (`file://`, the seat's only remote), `branch_head`/`upstream_head`, `sync_branch` (`--force-with-lease` CAS, expect-empty for new branches; `staging`/`main` → `Protected`), `create_claim_ref`/`release_claim_ref` on `refs/claims/<n>` (fence = ref sha). 6 tests against on-disk bare upstreams |
| T-11 notes | token goes into the push URL at call time and is scrubbed from every captured git line; an up-to-date (`=`) push under expect-empty is `LeaseLost`/`ClaimTaken`, not success; unparseable porcelain → `Unknown`; 120 s hard timeout per git call; `mod mirror;` not yet in `main.rs` |

## Build and test

```
cd one && cargo test && cargo run -- doctor
```

## Week-0 findings (2026-09-09)

- macOS 26.5.1, 16 GB. Claude Code 2.1.266 exposes `--setting-sources`,
  `--disallowedTools`, `--permission-mode`, `--json-schema`, `--bare`.
- Apple `container` 1.4.1 installed (`brew install container`; kernel via
  `container system kernel set --recommended`, kata 3.32.0). First run of
  `alpine` with `--memory 512m`: boot ≈ 9 s cold, guest `MemTotal` 614184 kB —
  the cap is honoured. The transom `cargo test` benchmark is still to do.
- **Canary (week-0 test 3): PASS.** `claude -p` (Haiku, 2 turns) under
  `--permission-mode dontAsk --setting-sources user` with a throwaway HOME:
  the `PreToolUse` deny hook fired (`permission_denials: 1`, the model
  reported "blocked by a hook (CANARY-DENY)"), so hooks are a real enforcement
  point in that mode. Finding: a per-floor HOME has **no credentials**
  ("Not logged in") — the supervisor must inject `CLAUDE_CODE_OAUTH_TOKEN`
  from the real account (Keychain `Claude Code-credentials`), exactly what
  the old auth sink did. Cost of the canary: $0.02 API-equivalent.
- **Container (week-0 test 2): the cap kills.** Boot+run of alpine: ~2 s warm,
  ~9 s cold. A 1.5 GB in-process allocation under `--memory 1g` is killed in
  7 s with exit **137**. tmpfs writes do not test the cap (64 MB /dev/shm,
  remount denied as non-root). The transom `cargo test` benchmark is still to do.
- **App-as-assignee (week-0 test 1): NO.** With the owner token,
  `GET /repos/tbaums/fun-with-friends/assignees/fwf-impl%5Bbot%5D` → **404**
  while `GET /users/fwf-impl%5Bbot%5D` resolves the bot. Decision: claim =
  supervisor-owned label + a `claim/<n>` ref created with expect-empty
  `--force-with-lease`; the fencing token is that ref's SHA.
- **App token mint (T-03): LIVE.** With the real ids (App ID 4889626,
  installation 160423751, discovered via `GET /app/installations` with an App
  JWT) `fwfd doctor` mints a narrowed installation token for fwf-impl.
  Proven with a `contents:read,metadata:read` token: `GET contents/VERSION`
  → 200; `POST issues/562/labels` → **403**; `PATCH git/refs/heads/main` →
  **403** ("Resource not accessible by integration"). The seat-token model
  is enforced by GitHub, not by hooks alone. The assignee check via the App's
  own token is also **404**. Finding: fwf-impl was registered with write on
  nearly every repository permission (administration, secrets, workflows,
  actions, …); mint-time narrowing contains it, but the App's grant should be
  trimmed to the four permissions in `docs/github-apps.md` so a leaked PEM
  cannot do more than the supervisor would.
- **ETag/304** on every GET; `If-None-Match` (strong, weak, or list) → 304.
- **Auth**: every `/repos` route needs `Authorization: Bearer <token>`
  (401 otherwise). A token minted with narrowed `permissions` is 403 on a
  write it only holds `read` for, and 403 on any route whose permission it
  lacks (`issues`, `pull_requests`, `contents`, `checks`). Unnarrowed = all.
  The minted token string encodes its permissions (`…_contents.read+…`).
- **Reviews**: APPROVE / REQUEST_CHANGES by the PR author → 422, as GitHub.
  `commit_id` defaults to the head; a `commit_id` that is not the current
  head → 422 (the real API accepts any commit in the PR — the fake only
  knows heads).
- **Head move dismisses approvals**: `PATCH pulls/{n}` with the fake-only
  `head_sha` field, or `PATCH git/refs/heads/<pr-head-branch>`, sets the
  head, moves the branch ref, flips APPROVED reviews to DISMISSED and
  appends `head_ref_force_pushed` + `review_dismissed` events (what
  dismiss-stale-reviews does). `ready_for_review: true` or `draft: false`
  un-drafts (GitHub does this via GraphQL only).
- **Ref CAS** (`--force-with-lease` stand-in): `PATCH git/refs/{ref}` honours
  `X-Fake-Expect-Sha`; a mismatch is 422 and the ref does not move.
  `POST git/refs` is 422 "Reference already exists" — the expect-empty CAS
  that claims `claim/<n>`. `DELETE git/refs/{ref}` releases it.
- **PRs are issues**: a PR appears in the issues list with `pull_request`,
  and labels/comments/events on it go through the issues routes.
  `POST pulls` needs both branch refs to exist and refuses a second open PR
  for the same head (422).
- **Events carry the actor** (`labeled`/`unlabeled` with `label.name`);
  re-adding a present label emits no event; deleting an absent one is 404.

Not modelled: pagination, rate limits, GraphQL, fast-forward checks on
`force: false` (there is no commit graph — CAS is the only guard), branch
protection / required checks, PR merge, assignees (week 0 showed Apps
cannot be assignees), JWT verification on the mint route, `updated_at`
on list ETags being anything but a body hash.
