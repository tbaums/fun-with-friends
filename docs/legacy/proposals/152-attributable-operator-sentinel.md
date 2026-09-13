# Proposal: an attributable operator un-gate sentinel (#152, #150 ask 3)

Status: **investigation complete — SUPERSEDED by #191. Recommend closing #152.**

## Reconciliation with #191 (read this first)

While this investigation was in flight, **#191** ("authz: verify
cryptographic operator signatures") was filed, GV-reviewed, and moved to
`product-wip` — and it answers this ticket's exact question with a stronger,
already-working design: real `ssh-keygen -Y sign`/`verify` signatures
(private key never touches the box), replay-bound to both **issue and gate
episode**, verified against a **root-owned `0644` trust anchor** the factory
user can read but — this is the load-bearing detail — **cannot write**. #191
has already been decomposed into #213 (signing helper), #214 (board-path
design, discovery), and #215 (a related bug), and is sequenced to ship after
**#200** (authz's `INDETERMINATE`-on-readable-threads false positive, since a
wrongly-firing fail-closed check is exactly the pressure that produces forged
authorization artifacts). #207 (enforce the verdict at the point of
action — claim/build refuses on anything but `AUTHORIZED`) is the
complementary ticket that makes the hardened verdict load-bearing, not just
observable.

**This changes my answer below.** Before finding #191 I concluded a fully
cryptographic root wasn't achievable without an OS/container change (my
"coupling 2": operator and roles share one machine and OS user). #191's
root-owned-`0644`-anchor design is a narrower, cheaper way to break that same
coupling — it doesn't need to isolate the whole floor from the operator, only
make **one specific file** unwritable by the factory user, which standard
Unix permissions already do without any new infrastructure. That is strictly
better than this proposal's "Option A" (a second GitHub identity + an
`author.login` check), which remains honor-system-shaped (its guarantee is
capped by keeping a credential out of role-reachable paths, a procedural
invariant, not an OS-enforced one) and would ship a genuinely weaker
mechanism in parallel with one already scoped, reviewed, and further along.

**Recommendation: close #152 as superseded by #191.** Do not build this
proposal's "Option A" — it would be obsolete within the same work cycle #191
ships in, per #191's own acceptance criteria (four distinct verdicts,
episode binding, position-constrained sentinel, anchor-permission assertion)
already exceeding what Option A specifies. The investigation below is kept
for its research value (the coupling-1/coupling-2 framing, and the concrete
"why a second GitHub identity alone isn't enough" analysis) and because it
independently arrived at the same root-owned-file insight #191 already
shipped as a working PoC — but it should not spawn a competing build ticket.

The original investigation (pre-#191) follows.

## Problem recap

`fwf authz <issue>` (`fwf-authz.sh`) verifies human authorization by grepping the
issue thread for the `OPERATOR-UNGATE` sentinel string
(`config.sh:OPERATOR_UNGATE_SENTINEL`):

```bash
if printf '%s\n' "$thread" | grep -qF "$OPERATOR_UNGATE_SENTINEL"; then
  echo "AUTHORIZED #$num ..."; exit 0
fi
```

This closed the *accidental* failure from #150 (a role hallucinating a human
confirmation from pane ghost-text). It does **not** close the *deliberate*
one: any role can run `gh issue comment <n> --body "OPERATOR-UNGATE ..."`
itself and `fwf authz` will report `AUTHORIZED`. Nothing in the check
distinguishes a human-minted sentinel from a role-minted one, because — this
is the crux — every role and the operator's own `fwf dash` process
**authenticate to GitHub as the same account** (`docs/shared-account.md`,
issue #82), so the comment's `author` field carries zero information.

## MUST-ANSWER: naming the trust root, honestly

**Trust root today: none. The current check is honor-system**, not
cryptographic — it verifies a *string*, and nothing prevents any process with
`gh` access (every role has this) from producing that exact string. Dressing
the same `grep -qF` up as "attribution" without changing what mints the
signal would repeat #150's failure shape under a new name, which is exactly
what this ticket warns against.

I looked for a route to a genuinely unforgeable (cryptographic) root and
found one is **achievable, but only by breaking one of two couplings that
both hold true in this codebase today**:

1. **Identity coupling**: `fwf dash`'s write path (`fwf-dash-act.sh: di
   comment`) and every role's `gh` calls resolve to the *same* GitHub login.
   Confirmed by reading `fwf-dash-act.sh` (`di()` just shells to `gh issue
   ...` with no distinct credential) and `docs/shared-account.md` ("every
   role... can authenticate as the same GitHub account").
2. **Process coupling**: the operator's `fwf dash` process and every role's
   `claude`/bash process run **on the same machine, as the same OS user**,
   with mutual file/process read access. Confirmed by `docs/containers.md`
   ("all hit live on one Mac" — the human's own laptop) and by
   `fwf-dash-act.sh` reaching the SAME tmux default-socket server the role
   panes run in (`unset TMUX` + `tmux send-keys` to role panes for
   respawn/passthrough). There is no sandbox boundary between "the operator's
   terminal" and "a role's bash tool" in the current deployment model.

As long as **both** couplings hold, no secret-at-rest fix works: any file,
env var, or script (`fwf-dash-act.sh` itself included) that could mint or
verify a real signature is *equally reachable and equally invocable* by a
role's bash tool as it is by the operator's own keypress — a role doesn't
even need to steal a secret, it can just call the same shell function
`fwf-dash-act.sh approve <n>` directly. Layering crypto verification on top
of a mint path the verifier's own adversary can also call is theater.

**So the honest answer to (a) is: not fully achievable without an
infrastructure change; a genuine, real improvement (not fully cryptographic,
but no longer bare-string honor-system) is achievable now by breaking
coupling 1 alone, and the remaining gap is closed by breaking coupling 2 as a
follow-up.**

## Options evaluated

### Option A — a second GitHub identity for the un-gate write path (recommended now)

Give the operator's `fwf dash approve` action a **second, distinct GitHub
credential** — a machine/bot account or a second personal account — that no
role ever authenticates as. `fwf authz` upgrades from a plain `grep -qF` to:

```
sentinel present AND the comment's author.login == $FWF_OPERATOR_LOGIN
```

**Why this is buildable cheaply:** the comments payload already carries
`.user.login` end-to-end. `fwf-ghcache.sh` already normalizes it
(`author: (if .user then {login: .user.login} else null end)`,
`fwf-ghcache.sh:156,165,176`) for every comment view, so `fwf authz` needs no
new API surface — just a field it's currently discarding.

**Concrete cost:**
- Manual, one-time, human-only setup (cannot be automated by a role — GitHub
  ToS requires a human to create the second account/App, and doing it via
  agent automation would itself be a fresh trust problem): create a second
  GitHub identity (a personal account or, cleaner, a GitHub App/machine user
  so comments render distinctly as `name[bot]`), add it as a repo
  collaborator, mint a fine-grained PAT scoped to `issues: write` on this one
  repo only. ~15–30 minutes, no cost beyond a second free GitHub account.
- Engineering (small, roughly a half-day-to-day ticket):
  - `fwf-dash-act.sh`: the `approve` verb sources the operator token (e.g.
    `~/.fun-with-friends/operator-token`, mode 600) and sets `GH_TOKEN=...`
    only for that one `di comment` call — never written to
    `$FWF_PANE_ENV_FILE`, never listed in any profile's `FWF_PANE_ENV`.
  - `fwf-authz.sh`: after the sentinel-string match, additionally check
    `.user.login` on the matched comment against a new `FWF_OPERATOR_LOGIN`
    config var (`config.sh`, alongside `OPERATOR_UNGATE_SENTINEL`). A
    sentinel-shaped comment from the WRONG login should verdict `HELD` (not
    `AUTHORIZED`) — and is worth a distinct log line, since it's evidence of
    an actual forgery attempt, not just an absent approval.
  - `config.sh`: `FWF_OPERATOR_LOGIN="${FWF_OPERATOR_LOGIN:-}"` — empty means
    "not configured," and `fwf authz` should fall back to today's
    string-only check with a loud warning, so this stays backward compatible
    for anyone who hasn't done the manual setup step yet (never fail closed
    on a missing *feature*, only on a missing *authorization*).
  - `test/run.sh`: extend the existing authz test section with a case that
    posts a sentinel-shaped comment authored by a login other than
    `FWF_OPERATOR_LOGIN` and asserts `HELD`, plus the matching-login case
    asserting `AUTHORIZED`.
  - `docs/shared-account.md`: add a note that the operator un-gate path is
    the **one intentional exception** to "everything shares one account" —
    worth flagging since a future refactor might "simplify" it back to the
    shared identity without realizing that regresses this fix.
- Latency/runtime cost: none — `fwf authz` already reads the full comment
  object off the same cached thread; checking one more field is free.

**What this genuinely closes:** a role, even with full bash/file access on
the box, cannot make GitHub report a comment as authored by an account it
holds no credential for — that part is enforced by GitHub's server, not by
anything on this box, so it is a real (if narrow) cryptographic/server-side
boundary, not a convention. **What this does NOT close:** if the operator
token file is ever readable by a role (coupling 2 is still true — same OS
user, same filesystem), a role could steal and reuse it. So Option A's
strength is capped by operational credential hygiene until coupling 2 is
also broken (Option B).

### Option B — OS-level isolation of the floor from the operator (follow-up, don't fold into this ticket)

Run role panes under a distinct, unprivileged OS user/session (or inside a
container, per the floor-isolation work already explored in
`docs/containers.md` for unrelated port/lock reasons) separate from the
operator's own login. The operator-token file from Option A then lives under
permissions a role's OS user genuinely cannot read — turning "the token
must never leak into a role-reachable path" from a discipline into an
OS-enforced fact.

This is materially bigger than #152's footprint: it's a deployment-topology
change (`fwf up`, worktree provisioning, `containers.md`'s already-scoped
"build-floor agents only" containerization target), not a `lib.sh`/`config.sh`
change. **Recommendation: file as a separate follow-up ticket** ("harden
operator-credential isolation with OS/container boundary, per #152's
residual"), scoped against the containers.md groundwork rather than
re-litigated here.

### Option C — hardware/biometric signing (available if A+B prove insufficient; not recommended now)

FIDO2/WebAuthn touch-to-sign, or a macOS Keychain item ACL'd to the
code-signed `fwf-dash` binary (any other reader triggers an OS
password/biometric prompt a headless script can't satisfy). This is the only
option that stays unforgeable even if coupling 2 is never fully broken (the
private key material is never extractable to *any* process, operator or
role) — but it is materially more engineering, has no clean Linux-portable
equivalent (fwf ships prebuilt `dash` binaries for macOS and two Linux
targets — `docs/dash.md`), and adds real friction (every approval needs a
physical touch, not just a keypress). Flag as a future escalation; not
justified as the first move.

## Recommendation (superseded — see Reconciliation above)

Original (pre-#191) recommendation, kept for the record: build Option A now,
file Option B as a follow-up, punt Option C. **This is superseded**: #191
already delivers a design at least as strong as Option A + Option B combined
(cryptographic signatures, replay-bound, root-owned unwritable anchor) and is
further along (GV-reviewed, `product-wip`, working PoC, decomposed into
#213/#214/#215). Do not file the build-ticket spec below — it is kept only to
show what this investigation would have produced absent #191, for comparison
against #191's actual acceptance criteria.

### Ready-to-file build-ticket spec (NOT to be filed — superseded by #191, kept for comparison)

**Title:** Harden `fwf authz` with an author-attributed operator sentinel (#152 Option A)

**Problem:** `fwf authz` verifies the `OPERATOR-UNGATE` sentinel by plain
string match; any role can mint it. Verify comment authorship too.

**Scope:**
- `config.sh`: add `FWF_OPERATOR_LOGIN` (default empty = feature off, falls
  back to today's behavior with a warning).
- `fwf-dash-act.sh` `approve` verb: post the sentinel comment using a
  distinct operator credential (read from a new, gitignored, mode-600 path;
  document the manual one-time GitHub-side setup in `docs/`), never exported
  via `FWF_PANE_ENV`.
- `fwf-authz.sh`: after a sentinel string match, also check the matched
  comment's `.user.login` (already present in the ghcache-normalized author
  field) equals `FWF_OPERATOR_LOGIN`; mismatch → `HELD` with a distinct
  "sentinel present but WRONG author — possible forgery" message (not the
  generic "no sentinel" message, since operators should be able to tell the
  two apart in logs).
- `docs/shared-account.md`: document this as the one deliberate
  two-identity exception.
- Tests: `test/run.sh` — matching-login → `AUTHORIZED`; mismatched-login →
  `HELD`; `FWF_OPERATOR_LOGIN` unset → today's string-only behavior
  unchanged (backward compat).

**Out of scope:** OS/container isolation (Option B, separate ticket);
hardware signing (Option C); changing the destructive-action guard's call
sites (they already key off `fwf authz`'s exit code/verdict — this ticket
only strengthens what that verdict means).

**Acceptance criteria:**
- A sentinel comment authored by the configured operator login →
  `AUTHORIZED`.
- A sentinel-shaped comment authored by any other login (including the
  shared role account) → `HELD`, with a message distinguishing "forged
  sentinel" from "no sentinel at all."
- `FWF_OPERATOR_LOGIN` unset → identical behavior to today (no regression
  for operators who haven't done the manual setup).
- Operator token is never written to `$FWF_PANE_ENV_FILE` or referenced by
  any profile's `FWF_PANE_ENV` list (asserted by a test or explicit code
  review note).
- Docs updated per DoD.

## Out of scope for this proposal

Implementing any of the above (this ticket's deliverable is the proposal
itself, per its `discovery` label). Changing #82's shared-account model for
anything other than the operator un-gate write path. The destructive-action
guard's call sites (unchanged; they already consume `fwf authz`'s verdict).
