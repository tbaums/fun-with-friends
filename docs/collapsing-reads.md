# Collapsing reads (issue #211)

A short, citable convention for a defect that has shipped at least three
times in this codebase in three different subsystems: a read that could not
be completed collapsed into a value indistinguishable from a real one, and a
downstream consumer treated that fallback as a measurement.

## The rule

> A reader that cannot complete its read MUST NOT return a value that is
> indistinguishable from a successful read. Either return an explicit
> *unknown* that the caller is forced to handle, or return the value **plus**
> a status the caller must consult. "Never errors" is a property of the
> *call*, never a licence to treat the fallback as a measurement.

A read has **three** outcomes, not two, and the middle one is a real answer:

- **failed** — report it; never a value.
- **succeeded-and-empty** — a real, confident answer (`[]`, `0`, `"none"`).
  It is *not* a failure.
- **succeeded-with-content**.

Collapsing the middle outcome into either neighbour is the same defect in a
different direction. In particular: **emptiness of output is never a valid
failure signal** — capture the status, don't infer it from `-z`/`-s`.

## Worked examples in this codebase's own idiom

**1. Failure → confident value, misreported downstream (fixed by #146/#193's
class, and by this ticket for the write side).** `fwf_tick_bump` (`lib.sh`)
used to read the current tick count via `fwf_tick_read`, which on an
unreadable or malformed tick file silently returned `0`. The bump then wrote
`0 + 1 = 1` over the counter — a role at tick 5000, hit by one transient
read glitch, was durably reset. Worse: `fwf-supervise.sh` classifies
liveness from tick *deltas*, so a `5000 → 1` reset reads as **movement**, not
corruption — the failure didn't even surface as an anomaly. Fixed by making
`fwf_tick_read` signal the failure via exit status and `fwf_tick_bump`
refuse to write when that status is non-zero (see the idiom below).

**2. Success-and-empty → false failure (issue #200).** `fwf authz` reading a
genuinely zero-comment issue is a real, confident answer — "there are no
comments." The reader instead reported `INDETERMINATE`, i.e. infrastructure
breakage, because `fwf-authz.sh` discarded the read's exit status with
`|| true` and then used `[ -z "$thread" ]` as its read-success test. Empty
output and a failed read were the same observation to that code, so a
perfectly healthy read of an empty issue was indistinguishable from the read
never having happened at all.

**3. A cache can make a stale value look like a fresh success (issue #265).**
Even a reader with a real three-state verdict and callers that honour all
three can still be wrong if the *channel* it reports through can't express
its actual failure mode. `fwf authz`'s guard checks for a non-zero exit to
detect a failed read — but a cache hit that silently returns stale data
**exits zero**. The convention was correctly applied to the reader's exit
status; the failure that mattered arrived in a different channel (a
well-formed-but-stale value) that the guard never inspected. **The audit
question is not just "does this reader have an UNKNOWN state" — it's "can
the failure this reader actually suffers reach the channel its guard
inspects?"**

## The shared idiom

The encoding is decided: **`echo` the value exactly as today; signal failure
by exit status.** This is deliberately *not* a prefix-encoded return
(`ok <value>` / `unknown <reason>`) — that would require every existing call
site to gain parsing it doesn't have today. Bash already has a status
channel that costs nothing:

```sh
# reader echoes the value unchanged, and returns non-zero when it could not
# read it -- an existing bare caller is completely unaffected.
local n
n="$(fwf_tick_read "$role")" || { handle_unknown; return; }   # caller that cares
n="$(fwf_tick_read "$role")"                                   # caller that doesn't: unchanged
```

`fwf_tick_read` (`lib.sh`) is the reference implementation.

### The gotcha this convention must state in bold

```sh
local n="$(cmd)"    # WRONG: masks cmd's exit status. $? reports on `local`,
                    # not on the command substitution.
local n; n="$(cmd)" # RIGHT: declare and assign on separate lines.
```

Verified empirically in this repo's own bash (5.3.9): the combined form
**always** reports exit status 0, regardless of whether `cmd` succeeded —
this is not an old-shell-only quirk. `test/run.sh`'s `#211` section pins
both forms directly against `fwf_tick_read` so the gotcha is enforced by a
test, not just a paragraph.

The same care applies to `set -e` contexts: a bare failing assignment
(`x="$(cmd)"` on its own, outside an `if`/`&&`) aborts the whole script
under `set -e` before any `rc=$?` line would run. Use the assignment
directly as an `if` condition instead — `if x="$(cmd)"; then ... else ... fi`
— which is exempt from `set -e` by design. Both `fwf` (the CLI dispatcher)
and `fwf-pane-liveness.sh` run under `set -euo pipefail`, and both
`fwf_tick_bump` and `fwf-pane-liveness.sh`'s own tick read use this form for
exactly that reason.

### The honest trade

Exit status is ergonomic but fails silent for a lazy caller: a bare
`$(reader)` still gets the fallback value, same as before this convention
existed — never worse, but not caught by the runtime either. The runtime
does not catch that caller; an **audit** does (see the audit table this
ticket's other ACs build out, enumerating bare-value consumers as their own
category).

## Two audit categories

A collapsing **reader** misreports downstream. A collapsing
**read-modify-write** site *persists* the collapsed value, destroying state
— strictly worse, and the category most worth finding exhaustively.
`fwf_tick_bump` (above) is this codebase's worked read-modify-write example.

## Making a failure visible after the fact

A point-in-time check almost always comes back clean on exactly the
incident this convention exists to prevent — a transient read failure is
usually over by the time anyone goes looking. So a converted reader doesn't
just signal failure via exit status; it also appends ONE line (timestamp,
reader, reason) to a bounded diagnostic log via `fwf_log_unknown_read`
(lib.sh) — `fwf_tick_read` and `fwf-issues.sh`'s `labels_of` both do this on
their failure paths. The success path never touches the log, so the common
(healthy) case costs nothing beyond the read itself.

**The log itself is a write that can fail** (full disk, an unwritable
`$FWF_RUN`), and that failure must never touch the calling reader's own
answer — otherwise the diagnostic for collapsing reads becomes another
collapsing read. Every reader calls `fwf_log_unknown_read ... || true` and
never inspects its return value; only a caller that explicitly wants to
know whether the log write itself succeeded (e.g. a test) checks that
status directly. `test/run.sh`'s fixture makes only the log's directory
unwritable (not the value being read) and asserts the reader's own output
is byte-for-byte identical to the writable-log case.

`fwf usage` is the reporting surface: it prints a **live probe** (every
role's tick read, queried right now) and **recent unknowns** (the log's
contents), because both halves are needed — the live probe catches an
ongoing failure, the log catches one that already resolved.
`fwf usage --clear-unknown-log` clears it.
