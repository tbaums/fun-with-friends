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
| T-03 GitHub client | token mint + probe done; ETag client next |
| T-04 fake GitHub | `src/fake_github.rs`, 9 contract tests |
| T-05 fake seat pane (tmux-backed) | done — `src/seat.rs` FakeSeat |
| T-06 seat waker + verdict reader | done — `wake`/`wait_verdict`; woken panes, no /loop, no claude -p |
| T-07 canary | canary PASS (see below); 10-cycle cost comparison parked (needs real seats) |
| T-08 thin slice (kill criterion) | blocked: needs the real fwf-impl ids in apps.toml |

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
- **App token mint (T-03): code done, live check blocked.** `fwfd doctor`
  mints a narrowed installation token per App from `~/.fwf/apps.toml`
  (JWT RS256 → `/app/installations/{id}/access_tokens`). The live call
  returns 401 "A JSON web token could not be decoded" because `apps.toml`
  still holds the placeholder ids from the how-to (`app_id = 123456`,
  `installation_id = 78901234`); an openssl-signed JWT fails identically, so
  the code is not at fault. Needs the real App ID and installation id for
  fwf-impl (see NEXT-STEPS.md).

## Fake GitHub (T-04)

`src/fake_github.rs` (test-only, `tiny_http` on `127.0.0.1:0`) is the
in-process stand-in the client's contract tests run against. Construct
`FakeGitHub::start()`, seed it (`token`, `add_installation`, `seed_issue`,
`seed_ref`), point the client at `base_url()`, assert on `writes()` (every
accepted write as `(actor, method, path, body)`) and `request_count(path)`
(every request, 304s included, so single-flight tests can assert "one").
Ids are sequential, timestamps come from an injectable clock (default:
2026-01-01T00:00:00Z ticking one second per read).

Routes: `GET issues[?state=]`, `GET issues/{n}`, `POST/DELETE
issues/{n}/labels[/{name}]`, `GET issues/{n}/events`, `GET/POST
issues/{n}/comments`, `POST pulls`, `GET/PATCH pulls/{n}`, `GET/POST
pulls/{n}/reviews`, `GET git/ref/{ref}`, `POST/PATCH/DELETE git/refs[/{ref}]`,
`POST check-runs`, `PATCH check-runs/{id}`, `GET commits/{sha}/check-runs`,
`POST /app/installations/{id}/access_tokens`.

Semantics it models, because the old harness got them wrong:

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
