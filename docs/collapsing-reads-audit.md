<title>Collapsing-Reads Audit</title>

# Collapsing-reads audit (issue #211)

The exhaustive audit issue #211's acceptance criteria (c)/(c2) require: every
site matching the mechanical collapsing-read patterns (`|| echo 0`, `|| true`
feeding a value, `2>/dev/null` on a value read, `[ -z "$var" ]`/`[ -s "$file" ]`
used as a read-success test), in **both** directions —

- **shape 1** — failure collapses into a confident value (the #193 shape).
- **shape 2** — a legitimate empty result collapses into a reported failure
  (the #200 shape).

— and in three categories: a **reader** (misreports downstream), a
**read-modify-write** site (a collapsed read gets *persisted*, destroying
state — the category most worth finding exhaustively), and a **bare-value
consumer** (a call site that would silently swallow the new non-zero status
per [docs/collapsing-reads.md](collapsing-reads.md)'s idiom).

Every row below has a disposition. "Safe" is a stated, reasoned judgment —
never blank.

## Fixed in this PR

| Site | File:line | Category | Shape | What collapsed |
|---|---|---|---|---|
| `fwf_tick_read` | `lib.sh` | reader | 1 | unreadable/malformed tick file → confident `0`, indistinguishable from "never ticked" |
| `fwf_tick_bump` | `lib.sh` | read-modify-write | 1 | the collapsed `0` above got **written back** as the new counter — a role at tick 5000 durably reset to 1 by one transient glitch |
| `fwf-pane-liveness.sh` tick read (`cur_tick`) | `fwf-pane-liveness.sh` | reader + read-modify-write | 1 | an untrustworthy tick read fed straight into the WEDGED/HEALTHY delta computation, and got stamped as the next window's baseline |
| `fwf-pane-liveness.sh` token read (`cur_tok`) | `fwf-pane-liveness.sh` | reader + read-modify-write | 1 | `_fwf_usage_role`'s own honest `state:"unknown"` field was ignored; its deliberately-zeroed placeholder tokens were read as a confident "0 tokens", producing a fabricated flat delta (→ false WEDGED) and getting stamped as the baseline |
| `labels_of` | `fwf-issues.sh` | reader | 1 (+2: absent-file vs unreadable-file now distinguished) | a genuinely label-less issue and an unreadable issue file both produced identical empty output |
| `_rewrite_header_locked` (title/labels/created reads) | `fwf-issues.sh` | read-modify-write | 1 | the **highest-consequence instance in the tree** — a collapsed `labels_of` silently dropped every label, including `product-wip`, on any `--title` edit (`__KEEP__` path) |
| `_set_body_locked` (title/labels/created reads) | `fwf-issues.sh` | read-modify-write | 1 | same drop, reached via `--body` edits |
| `cmd_edit --add-label` | `fwf-issues.sh` | read-modify-write | 1 | computed its own label list via an unchecked `labels_of` call — a sibling door into the same defect as the two rows above, not covered by `_rewrite_header_locked`'s own guard since it's called with an explicit (not `__KEEP__`) label string |
| `cmd_edit --remove-label` | `fwf-issues.sh` | read-modify-write | 1 (+2: the pre-existing `\|\| true` legitimately absorbs "removed the last label, grep found nothing" — now scoped to only that step, not the underlying read) | same sibling-door defect |
| `fwf_reconcile_record_history` | `lib.sh` | read-modify-write | 1 | a malformed/unreadable flap-streak file silently reset to 0/1, delaying the `ANOMALY` a reconcile storm must surface (issue #114 AC9) |
| `fwf_reconcile_indeterminate_streak` | `lib.sh` | reader (echoed value is load-bearing for its caller's own escalation arithmetic, issue #238 AC7) | 1 | same collapse, **deliberately** not converted to refuse-to-write (see disposition below) |

**`fwf_reconcile_indeterminate_streak`'s disposition, stated explicitly:** its
return value is consumed directly by the caller's escalation decision, so
refusing to answer (the `fwf_tick_bump` shape) would break that caller rather
than protect it. Logs the collapse via `fwf_log_unknown_read` instead —
smaller blast radius than the sibling function above, since an indeterminate
result already escalates on its own merit regardless of this counter (per
the function's own header comment). A deliberate choice, not an oversight.

## Fixed by another, already-filed ticket — not duplicated here

| Site | File:line | Category | Shape | Owner |
|---|---|---|---|---|
| `roles_json`'s `else` branch | `fwf-dash-data.sh` | reader | 1 | **#193** — this is the exact incident #193 was filed to fix ("every role rendered down while the factory was healthy"); root cause is `fwf_find_pane` failure indistinguishable from "pane genuinely absent" |
| `status_fresh` / `status_q` | `fwf-dash-data.sh` | reader | 1 | **#193** — same dash-observability territory, same root fix |
| `fwf-authz.sh`'s `read_ok` guard | `fwf-authz.sh:57-71` | reader (channel gap, not a collapsing-state gap) | neither 1 nor 2 — a *third* failure mode this audit's own predicate exists to catch: a reader can hold a correct three-state verdict, with callers that honour all three, and still be wrong if a failure it suffers can't reach the channel its guard inspects | **#265** — the commit that built this guard (`dd36009`) is itself correctly structured (`\|\| read_ok=0` fires on a non-zero exit, verified not masked by this script's own `set -e`); #265 found that a **stale cache hit exits 0**, so the guard's exit-status channel cannot express "succeeded, but with stale data" |

## Safe, or deliberately deferred — with a stated reason

| Site | File:line | Category | Shape | Disposition |
|---|---|---|---|---|
| `has_gv_signoff()` | `fwf-dash-data.sh` | reader | 1 | safe — dash is advisory-only; a human reviews it before acting, so a false "no signoff" is caught by the same human loop that catches every other dash misreport. Not named by any ticket. |
| `open_issues_json()` | `fwf-dash-data.sh` | reader | 1 | safe — same dash-advisory reasoning as above |
| cached `latest`/`ts` | `lib/version_check.sh` | reader | 1 | safe — explicitly named by issue #211's own body as "low consequence, listed for completeness"; a stale-cache upgrade-nag is the worst case, never a data-loss or false-action risk |
| `has_label()` (list/search filter use) | `fwf-issues.sh:93`, used at `_matches_filter` and the `list`/`export` JSON emitters (`:139,:390,:417`) | reader, bare-value consumer | 1 | safe for now — a false negative here only affects a read-only view (an issue appears to have fewer labels than it does, or is filtered out of a search), never a write. The two WRITE-path callers that used to share this exposure (`cmd_edit`'s `--add-label`/`--remove-label`) were fixed directly by reading labels once, checked, rather than hardening `has_label()` itself — hardening the display path is lower-value follow-up, not blocking |
| e2e-lock/build-slot pagination bounds (`jq 'length' \|\| echo 0` deciding whether to keep paginating) | `fwf-ghcache.sh:115,356,436` | read-modify-write (writes the possibly-truncated page into the cache) | 1 | **found, deferred** — a real gap, not owned by another ticket, but the pagination/cache logic (multiple loops, page-size heuristics) is complex enough to warrant dedicated review rather than a quick two-line fix bolted onto an already fully-tested cache implementation. Recommend a focused follow-up ticket rather than rushing a change here. |

## Positive example — already correct, checked for completeness

`_fwf_e2e_lock_holder_phrase` (`lib.sh` ~1230) already distinguishes "a single
missed poll" (still-acquiring, ambiguous) from "≥2 consecutive misses"
(holder genuinely unknown) via an explicit counter — it never collapses that
ambiguity into a confident phrase. Included here because the audit's job is
to notice the class, not just list violations, and a codebase with only bad
examples would say something false about how consistently the class is
already handled.

## Bare-value-consumer summary

Per [docs/collapsing-reads.md](collapsing-reads.md)'s honest trade: the
runtime can't stop a lazy caller from reading a bare `$(reader)`, so this is
the audit's job. `fwf_tick_read` has **zero** remaining bare consumers in
this tree as of this PR — every call site (`fwf_tick_bump`,
`fwf-pane-liveness.sh`, `fwf usage`'s live probe) checks its status.
`labels_of` still has bare consumers, all in the safe/deferred row above —
none on a write path.
