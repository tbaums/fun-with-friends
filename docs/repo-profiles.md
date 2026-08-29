# Repo profiles: in-tree vs. out-of-tree (issue #188)

A profile is the per-project factory config: the target repo path, the branch
ladder, the gate/build/e2e commands, per-seat model overrides. Two places a
profile can live:

- **In-tree** — `profiles/<name>.sh` inside the fwf checkout. `.gitignore`
  deliberately excludes `profiles/*.sh` (only `example.sh` is tracked), so a
  real in-tree profile is untracked local state: one `rm -rf` or one fresh
  clone from gone, no history, no review.
- **Out-of-tree** — `$FWF_REPO/.fwf/<name>.sh`, versioned **in the target
  repo itself**. This is what #188 adds. Per-host variants are first-class
  (`.fwf/linux-devbox.sh`, `.fwf/laptop.sh`, ...) — the convention mirrors
  `profiles/<name>.sh` exactly, just rooted in the target repo instead of the
  fwf install.

## Resolution rules (ordered, never silent)

1. **Explicit always wins and never falls through.** `FWF_PROFILE_PATH=/abs/path.sh`,
   or `FWF_PROFILE` itself looking like a path (contains `/` or ends `.sh`),
   resolves to an absolute path. If that file is missing, fwf **fails** with
   `fwf: unknown profile '<name>' (missing <path>)` — it never silently falls
   through to auto-detection.
2. **Bare names resolve to `profiles/<name>.sh`**, exactly as before this
   ticket — the common path is unchanged.
3. **Auto-detect `$FWF_REPO/.fwf/<name>.sh` only where fwf would already have
   errored** — a bare name with no in-tree file. It strictly converts an
   error into a success and can never change the meaning of a currently
   working invocation. If both `profiles/<name>.sh` and
   `$FWF_REPO/.fwf/<name>.sh` exist, **in-tree wins**, deterministically.

`$FWF_REPO` unset or not a directory silently skips auto-detection (it is the
would-have-errored path anyway); you see the ordinary in-tree error.

## Trust model

In-tree `profiles/*.sh` are sourced directly — they live inside the fwf
install and share its trust domain, same as today.

An out-of-tree profile is **never sourced directly** into an fwf process.
Every `fwf-*.sh` entrypoint sources `lib.sh` unconditionally, including
`fwf-authz.sh` — the command whose entire job is adjudicating whether a human
authorized the work — so naively sourcing arbitrary target-repo bash there
would let a hostile or merely careless profile shadow a function or variable
authz depends on.

Instead, an out-of-tree profile is sourced in a **throwaway child process**
with no inherited fwf functions or state. The repo's file stays ordinary bash
— it can still compute values, use `${VAR:-default}`, call commands — but
nothing it *defines* (a function, a variable outside the allowlist) reaches
the calling process. The child reports back only a fixed **allowlist** of
plain-string values, over an import channel with **no `eval` anywhere in
it**: a NUL-delimited `NAME\0VALUE\0` stream, read with `read -r -d ''` and
assigned with `printf -v`. A profile that writes crafted `declare`/assignment
text to any stream it can reach still changes nothing in the parent.

**Two names are denied to every out-of-tree profile, unconditionally:**
`OPERATOR_UNGATE_SENTINEL` and `FWF_ISSUES`. The sentinel is the literal
string `fwf authz` keys on; `FWF_ISSUES` selects which backend that signal is
read from. A profile that sets either **fails loudly** — the whole import is
rejected, not silently dropped — because isolation without this denial would
still let a repo profile pick the store that answers "did a human authorize
this?".

**A name that is neither allowlisted nor denied is dropped**: it has no
effect on the parent, and is named in a warning surfaced by `fwf doctor` (not
only at source time), so "why is my setting ignored?" is answerable in one
command instead of by reading source.

**Which names are exportable out-of-tree** (add a new profile knob to
`FWF_PROFILE_ALLOWLIST` in `lib/profile-sandbox.sh`, or it silently does not
apply out-of-tree):

```
FWF_REPO WT_PREFIX WT_BASE STAGING_BRANCH INTEGRATION_BRANCH DEFAULT_BRANCH
GATE_CMD BUILD_CMD E2E_CMD E2E_SETUP_CMD GATE_CASE_EXTRACTOR DEV_UI_HINT
UT_APP_URL UT_BROWSER UT_BROWSER_1 UT_BROWSER_2 UT_BROWSER_3 FWF_TEMPLATE
FWF_PAIRS FWF_MODEL FWF_MODEL_IMPL FWF_MODEL_QA FWF_MODEL_PM FWF_MODEL_GV
FWF_MODEL_CAPTAIN FWF_MODEL_CONDUCTOR PM_COLOR CONDUCTOR_COLOR GV_COLOR
CAPTAIN_COLOR
```

In-tree and out-of-tree profiles have **subtly different capabilities** as a
result — a reader who knows only "there's an allowlist" cannot tell whether
their setting is inside it, hence this list being spelled out rather than
merely referenced.

**Lost capability, stated rather than discovered:** a target repo cannot
select `FWF_ISSUES=local` from its own out-of-tree profile (that backend is
what authz reads the sentinel from). If a repo genuinely wants the local
issue store, opt in via an **in-tree profile** or explicit env
(`FWF_ISSUES=local`) at the fwf install.

**Residual, stated rather than buried:** a hostile target repo can still do
damage *to the machine* from inside the sandboxed child — exactly as
`GATE_CMD` can today, run inside an ordinary gate. What this closes is a
repo's ability to influence **adjudication** — for every command, not just
`fwf authz`.

## Bounded evaluation

An out-of-tree profile that hangs or exits non-zero fails the whole `fwf`
invocation with `fwf: profile '<path>' failed to evaluate — ...` rather than
wedging it — an unbounded profile would otherwise convert this trust fix
into an availability attack on `fwf authz`. The bound is
`FWF_PROFILE_EVAL_TIMEOUT_SECS` (default 5s) — a named, tunable constant
(the `FWF_GATE_TEARDOWN_GRACE_SECS` precedent from #195), since the correct
value is unmeasured and a slow profile on a slow box may need it raised.

## Observability

`fwf doctor` prints the **absolute** profile file actually loaded and its
resolution mode (`in-tree` / `explicit` / `auto-detected`), plus any dropped
out-of-tree names. `fwf-dash-data.sh`'s JSON carries the same as
`profile_resolution: {path, mode, dropped}` (data-layer only for now, the
same pattern `unrouted_prs` established — the dash binary does not yet
render it; query the JSON field directly).

## Known gap: two factories on one box share gate-tip state (AC i)

This ticket cross-posted an acceptance criterion from #237 §5: *"with two
profiles resolving to different target repos on one box, state written by
one is not read by the other."* **Verified real, not theoretical** (qa2
review on PR #346 traced it to a concrete collision and asked for it pinned
rather than papered over as "follow-on work" — the distinction #261's own
AC (c) discipline draws):

`FWF_STATE_DIR="$FWF_RUN/state/$PROFILE"` (`lib.sh`) keys purely on the
**profile name**, never on `$FWF_REPO`. Two different repos each choosing
the same out-of-tree profile name — plausible, even likely, given this
ticket's own per-host `.fwf/<name>.sh` convention (`.fwf/laptop.sh` is the
example used throughout this doc) — resolve `fwf_gate_tip_marker_path` to
the **identical** path. `test/run.sh`'s "AC(i)" section pins this end to
end: repo A's `fwf_gate_tip_record` writes a GREEN tip, and repo B's real
`fwf gate-tip` CLI reads that SHA back as its own — the exact cross-repo
false green #237 §5 warns about, reachable the moment two out-of-tree
profiles share a name on one box.

**Why this PR doesn't fix it:** the underlying fix is re-keying
`FWF_STATE_DIR` (or every state path built from it) by repo identity, not
just profile name — a change with a much larger blast radius than profile
resolution, since `FWF_STATE_DIR` underlies gate locks, e2e leases, and
every other piece of per-role state, not only gate-tip. That is squarely
`#237`'s "owns keying its own record by repo+branch" territory, generalized
to the whole `FWF_STATE_DIR` foundation rather than one file.

**Deferral, stated as a trigger/owner/date rather than open-ended
follow-on work:**
- **Trigger:** before out-of-tree profiles (`.fwf/<name>.sh`) are used for
  two or more repos that could plausibly share a profile *name* on the same
  box/`$FWF_RUN` — which this ticket makes reachable, not hypothetical.
- **Owner:** unassigned as of this PR — flagged here for PM/GV routing
  (either as new scope on #237, since it already owns "key state by
  repo+branch," or a new ticket if #237 is scoped narrowly to the
  conductor's gated-SHA record specifically).
- **Condition to close:** `FWF_STATE_DIR` (or the specific paths built from
  it — gate-tip at minimum, audited for others) incorporates repo identity,
  and `test/run.sh`'s AC(i) section above is updated from "KNOWN GAP,
  pinned" to an actual isolation assertion once it holds.

## Out of scope for this ticket

- Migrating the private `hetzner-devbox` provisioner off writing straight
  into the fwf checkout — an expected follow-on in a repo this ticket
  cannot reach, not retired here.
- Changing `.gitignore` (the exclusion of `profiles/*.sh` is correct).
