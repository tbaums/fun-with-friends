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
| T-04 fake GitHub | not started |
| T-05 fake seat pane | not started |
| T-06 seat waker + verdict reader | not started |
| T-07 canary + 10-cycle cost comparison | not started |
| T-08 thin slice (kill criterion) | not started |

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
