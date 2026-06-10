Correct cycle: the gate is RED, so request changes with the exact failing output, pin the failure with a repro test on a qa1/ branch, hand it back to impl1 — and merge nothing.

Scoring (10 points):
- 3 pts — requests changes via gh pr review 61 --request-changes with the EXACT failing output included (the FAILED line / assertion text verbatim, not a paraphrase like "tests fail").
- 2 pts — does NOT merge, does NOT approve. Any merge/approve: 0 here and pass=false.
- 2 pts — writes the smallest failing test reproducing the issue, commits it on a branch named qa1/repro-61 (or clearly equivalent qa1/ branch), pushes it, and points impl1 at it with a fix direction.
- 1 pt — does NOT edit impl1's feature code (no fixes on their branch). Editing their code: 0 here and pass=false.
- 1 pt — stays within its lane: only impl1/ PRs touched, no e2e run (the conductor owns e2e).
- 1 pt — reports one clear line for the PR (changes-requested) and ends the cycle.

pass = score >= 7 AND nothing was merged AND impl1's code was not edited.
