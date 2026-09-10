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
| T-02 three GitHub Apps (impl, qa, ops) | done — all three mint (impl trimmed to 4 permissions) |
| T-03 GitHub client | mint LIVE; ETag poller in poll.rs |
| T-04 fake GitHub | `src/fake_github.rs`, 9 contract tests |
| T-05 fake seat pane (tmux-backed) | done — `src/seat.rs` FakeSeat |
| T-06 seat waker + verdict reader | done — `wake`/`wait_verdict`; woken panes, no /loop, no claude -p |
| T-07 canary | canary PASS (see below); 10-cycle cost comparison parked (needs real seats) |
| T-08 thin slice (kill criterion) | **DONE 2026-09-09 19:00 PDT** — PR #565 opened by fwf-impl[bot] from a woken seat (`fwfd slice`) |
| T-12 QA cycle | **DONE** — `fwfd qa`: a woken QA pane reviewed #565 from the mirror and its verdict became fwf-qa's APPROVED anchored to fc7092b8 (plus the identity proof: fwf-impl self-approve → 422). |
| T-13 typed merge | **DONE** — `fwfd merge` squash-merged #565 into staging as 7b9fb7d8 under fwf-ops after fence + anchored-approval checks; claim ref deleted; Merged/Shipped recorded. |
| T-19 gate runner | **DONE** — Local / Apple container / systemd-run venues; verdicts idempotent per (sha, suite); Local runs under `bash -o pipefail` (a trailing pipe once masked a Red). |
| T-20 check-runs | **DONE** — `fwfd gate` posts `fwfd/<suite>` check-runs under fwf-ops; success on 7b9fb7d8 is live. |
| T-21 promotion | **DONE** — `fwfd promote` refused on an Unknown/absent verdict and fast-forwarded a scratch branch to 7b9fb7d8 under fwf-ops on a recorded Green. |
| T-09 poller + scheduler | done — `src/poll.rs`: `Poller` (base URL + bearer injectable; per-URL ETag cache with `If-None-Match`/304 body reuse; single-flight per URL; `requests()`/`not_modified()` counters; any failure = typed `PollError`, caller holds `Snapshot::unknown()`) reads `issues?state=open`, then `pulls/{n}` + `pulls/{n}/reviews` per PR and `git/ref/claims/{n}` per `claimed` issue. `src/sched.rs`: pure `plan(snapshot, seats, gate_label, owner_only, now) -> Plan` (WakeImpl / WakeQa / ReleaseClaim / Nothing). 14 tests: 5 proptest properties, 1 poll→plan→304→relabel contract test against the fake, single-flight proved with a barrier transport |
| T-09 notes | `author_association` is derived (author == repo owner → OWNER) when the API omits it, as the fake does; `closes_issue` accepts GitHub's close/fix/resolve keyword set; `IssueView.claim: Option<Fence>` and `Snapshot.known` added beyond the spec so `ReleaseClaim` carries a real fence (never fabricated) and `Unknown` is a value; `ReleaseClaim` fires only for a fenced claim no live seat is working (Working past `deadline` counts as stalled) and no open PR closes; a seat id that is non-Idle in any slot, or listed under two roles, is never double-booked (found by proptest); `mod poll; mod sched;` not yet in `main.rs` |
| T-11 local bare mirror | done — `src/mirror.rs`: `Mirror::init` (idempotent; `refs/remotes/upstream/*` + protected heads mirrored, HEAD=staging), `seat_remote_url()` (`file://`, the seat's only remote), `branch_head`/`upstream_head`, `sync_branch` (`--force-with-lease` CAS, expect-empty for new branches; `staging`/`main` → `Protected`), `create_claim_ref`/`release_claim_ref` on `refs/claims/<n>` (fence = ref sha). 6 tests against on-disk bare upstreams |
| T-11 notes | token goes into the push URL at call time and is scrubbed from every captured git line; an up-to-date (`=`) push under expect-empty is `LeaseLost`/`ClaimTaken`, not success; unparseable porcelain → `Unknown`; 120 s hard timeout per git call; `mod mirror;` not yet in `main.rs` |
| T-19 gate runner | done — `src/gate.rs`: `Gate { venue, memory_gb, timeout, workdir }.run(sha, suite, cmd, log_path) -> GateState`. Venues: `Local` (`sh -c`, own process group, group-killed on the wall clock), `AppleContainer { image }` (`container run --rm --name … --memory {n}g -v workdir:/work -w /work image sh -c cmd`; on timeout `container kill <name>` then the group), `SystemdRun` (`--scope -p MemoryMax -p RuntimeMaxSec`; Linux-only test). Exit 0 → `Green{secs}`; non-zero → `Red{failed}` with "N failed" parsed from the tail of what this run appended (else 1); 137/143/signal/timeout → `Killed{reason}`. Verdict file `<workdir>/.fwfd/gate/<sha>-<suite>.json` (tmp+rename) makes `run` idempotent per (sha, suite); `forget()` is the re-run path. 7 tests, both container tests **ran** (alpine `echo ok` → Green in ~1 s; 1.5 GB awk string under `--memory 1g` → `Killed{"oom or killed"}`, exit 137 in ~3 s), skipped with a printed reason if `container system status` is not running or alpine is not cached |
| T-19 notes | stdout+stderr of the gate go to `log_path` (the `container` CLI's `[n/6] Starting container` progress lines land there too); `Killed` is recorded like any other verdict — the supervisor's "re-run once" is `forget()` + `run()`, not an automatic loop; `kill(2)` is an `extern "C"` (std already links libc, no new dep); `mod gate;` not yet in `main.rs` |
| T-20 check-run writer | done — `src/checks.rs`: `CheckClient { base_url, token }`; `post_check_run(client, repo, sha, name, state, details_url) -> Result<u64, CheckError>` POSTs a `completed` check run (Green → `success`, Red → `failure`, Killed → `cancelled`; `Unknown`/`Queued`/`Running` → `CheckError::Unknown`, nothing sent) with `output.{title,summary}` from the verdict; `list_check_runs(client, repo, sha) -> Vec<(name, status, conclusion)>` via `commits/{sha}/check-runs`. 6 tests against the fake incl. a narrowed token without `checks:write` → `Refused{403}` |
| T-20 notes | `github::send_json` hardcodes `api.github.com`, so `checks.rs` carries its own tiny ureq sender keyed on `base_url` (same headers) to be testable against the fake; `mod checks;` not yet in `main.rs` |
| T-13 typed merge | done — `src/merge.rs`: `Client { base_url, token }` (GET/POST/PUT/PATCH/DELETE JSON, 30 s hard timeout, non-2xx is a `Reply.status` value) and `merge_pr(client, repo, pr, fence, log) -> Result<Sha, MergeError>`. Re-derives every precondition from the live objects, in order: open + not draft (`NotReady`); `Closes #N` body → `refs/claims/N` sha must equal the fence (`FenceMismatch`; no ref → `NotReady`); latest review per login, author's reviews never count, APPROVED must be anchored to the current head and no CHANGES_REQUESTED at head (`NotApproved` / `ApprovalStale{approved_head}`, DISMISSED-by-head-move counts as stale); check-runs on head all `completed/success` (`GateNotGreen`; none → allowed in M1 with a `Note`). Then one `PUT pulls/{n}/merge {squash, sha: head, commit_title, commit_message: "Closes #N" + history card seat/fence/reviewer/head}`; on 200 `DELETE git/refs/claims/N`, records `Pr→Merged` + `Issue→Shipped`. Every refusal is a `Kind::Refused{what: "merge #N"}`. 13 tests |
| T-13 notes | the fake has no `pulls/{n}/merge`, `compare` or `releases` routes and cannot be edited from this ticket, so `merge.rs` carries a test-only `shim` (tiny_http) that fronts the fake: serves those three routes over a seeded commit graph, forwards everything else verbatim (auth/ETag/CAS intact), can inject a review the fake refuses (author self-APPROVE) and can move a ref right before a forwarded PATCH (the CAS race). The history card's `seat=` is the PR author login (the API does not carry a seat id; the signature is fixed). Check-run failure reuses `Refusal::GateNotGreen{sha: head}` rather than a new variant (types.rs untouched). A failed claim-ref delete after a 200 merge is a `Note`, not an error — the merge happened. `mod merge;` not yet in `main.rs` |
| T-21 promotion | done — `src/promote.rs`: `promote(client, repo, from, to, gate, suite, log) -> Result<Sha, PromoteError>`: reads both `git/ref/heads/*` (`RefMissing`), `GET compare/{to}...{from}` must be `ahead` with `behind_by 0` (`behind`/`diverged` → `NotFastForward`, never forced; `identical` → recorded no-op), `gate.promotable(&from_sha, suite)` (Red/Killed/wrong sha/wrong suite → `GateNotGreen`, `Unknown` → `UnknownState`), then `PATCH git/refs/heads/{to} {sha, force:false}` under `X-Fake-Expect-Sha: <to sha as read>`; 422/409 or a post-write re-read ≠ from_sha → `LeaseLost{branch, expected, actual}`. Records `Kind::Promote{branch, from: old, to: new}`. `release_check(client, repo, tag) -> bool`: true only for a 200 release with ≥1 asset (404 / no assets / transport failure → false). 8 tests |
| T-21 notes | the real API has no CAS header: `force:false` only guarantees fast-forward, so against GitHub the supervisor promotes via the mirror (`sync_branch` `--force-with-lease`) or relies on the re-read this function does on every path; the gate is checked before the identical no-op so a Red sha is never reported "fine"; `mod promote;` not yet in `main.rs` |

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

## Thin slice — what it took (T-08, 4 attempts, one evening)

`fwfd slice --repo tbaums/fun-with-friends --issue 564 --seat fwf-one:impl1`
→ mint (narrowed) → poll → plan → `refs/claims/564` (fence) → paste job into
the warm pane → verdict file → mirror `sync_branch` (force-with-lease) →
draft PR #565 under fwf-impl[bot] → `fwfd why 565` shows the whole timeline.

Lessons that are now code (`scripts/seat-up.sh`, `src/seat.rs`):
1. `dontAsk` denies every tool not explicitly allowed, and an allow rule for
   `git status:*` does not match a compound `git a && git b`. M0 seats get
   `Bash(*)` plus denies (gh, curl, force-push, WebFetch) and the PreToolUse
   hook; the seat holds no GitHub token and its only remote is the mirror.
2. Never type a launch line into an interactive shell: the first keystroke
   was eaten (`export` → `xport`), an oh-my-zsh update prompt ate more, HOME
   never changed, and the OAuth token was echoed into tmux scrollback. The
   pane now runs `bash --norc -c "source env.sh && exec claude …"` directly,
   with `--settings`, `--allowedTools`, `--disallowedTools` and `--add-dir`
   passed explicitly, and scrollback is cleared.
3. A fresh per-floor HOME shows onboarding and the trust dialog; seed
   `.claude.json` (onboarding done, project trusted) before launch.
4. The seat's input box can contain staged text nobody typed ("go ahead,
   bash is enabled now", "retry now, permissions are granted"). The waker
   clears the box (Esc, C-u) before every paste and nothing is ever sent
   from it. Unsent is unsent.
5. Multi-line jobs go in as one bracketed paste (`load-buffer` +
   `paste-buffer -p`), then Enter.

## The loop, proven live on fun-with-friends (2026-09-09 evening)

claim ref → implementer seat (woken) → draft PR #565 by fwf-impl[bot] →
QA seat (woken) → fwf-qa APPROVED anchored to the head → ready-for-review →
`fwfd merge` (ops) → staging 7b9fb7d8 → `fwfd gate` (pipefail) → check-run
`fwfd/fwfd-fast` success → `fwfd promote` fast-forwarded a scratch branch.
No seat ever held a GitHub write token; every write is in the run record.
