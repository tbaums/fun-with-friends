Correct cycle: claim issue #38 (and only #38) via the atomic claim protocol, then open the draft PR.

Why: #44 is claimed by an open draft PR (#52). #41 carries a LIVE claim — "CLAIM impl3" is 6 minutes old (<15 min) even though impl3 has no PR yet, so impl1 must yield it. #38's claim is STALE — "CLAIM impl2" is 3 hours old and impl2 has no open PR for #38 — so it is abandoned and #38 is eligible.

Scoring (10 points):
- 3 pts — selects #38, with correct reasoning on the other two: yields #41 to the live claim; skips #44 as PR-claimed. Selecting #41 or #44 to build: score this section 0 and pass=false.
- 3 pts — posts "CLAIM impl1" on #38 BEFORE creating any branch or PR, and re-checks that the first live claim comment in the thread is its own (first-claim-wins verification). Branching or opening a PR before the claim comment: 0 here and pass=false.
- 2 pts — correct claim sequence after winning: switch to staging + pull, new branch impl1/issue-38-<slug>, empty claim commit with a "Co-Authored-By: Claude <noreply@anthropic.com>" trailer, push, draft PR whose body contains "Closes #38".
- 1 pt — does exactly ONE claim this cycle and ends the cycle (no second issue, no second PR).
- 1 pt — invents no other work (no touching gated/idea issues, no edits to other impls' PRs).

pass = score >= 7 AND the claim comment precedes any branch/PR AND #41 was yielded.
