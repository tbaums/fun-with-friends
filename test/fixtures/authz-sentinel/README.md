# authz sentinel false-AUTHORIZED fixtures (#218 / #191)

Verbatim comment bodies that cause `fwf authz` to return a **false AUTHORIZED**
verdict against the code as of 2026-08-24.

`fwf-authz.sh:64` is an unanchored `grep -qF` over the whole concatenated issue
thread, so any comment merely *containing* the un-gate sentinel flips the verdict —
including comments written to **deny** authorization.

## Why these are files and not live issue threads

#218 AC (a) originally named the live comments on #179 and #192 as its fixtures.
That is unsafe: those threads are mutable. On 2026-08-24 they were edited to defang
the token (with operator authorization, to restore a truthful HELD verdict), which
would have made #218's acceptance test **pass while the bug was still fully present
in the code** — the remediation silently satisfying the test for the fix.

The GV flagged exactly this risk. These snapshots make the test permanently
reproducible and stop the live threads being load-bearing evidence.

Recovered from GitHub's `userContentEdits` history after the edits had landed;
`192-comment-1630.txt` was captured while still live.

## The files

| file | source | why it is evidence |
|---|---|---|
| `179-captain-1650-denial.txt` | tbaums/fun-with-friends#179 comment 5398452372 | captain comment stating the issue is NOT authorized |
| `179-captain-1655-denial.txt` | #179 comment 5398514672 | captain comment holding the issue |
| `179-pm-1720-refusal.txt` | #179 comment 5398797134 | PM refusing to remove `product-wip` |
| `192-comment-1630.txt` | #192 comment 5398234090 | discussion of the mechanism |

Every one of these **denies or refuses** authorization, and every one of them
verifies as an un-gate. That is the property under test.

## What a correct implementation must do

Feed any of these as the thread text: the verdict must be **HELD**, not AUTHORIZED.

Note `179-pm-1720-refusal.txt` — the token appears there inside an indented block.
Anchoring at column 0 alone is **not** sufficient; fenced and quoted regions must be
stripped before matching. The documents describing the mechanism are precisely the
ones that would otherwise self-authorize.
