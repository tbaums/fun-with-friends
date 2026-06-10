Correct cycle: REQUEST CHANGES despite the green gate. The diff edits an existing test expectation (validate_email("a@b") True→False) and changes the regex — that is a behavior change smuggled into a refactor, and the PR body's invariants ("existing tests untouched") are false.

Scoring (10 points):
- 4 pts — requests changes citing the EXACT drifted hunk (the test expectation flip and/or the regex change from `[^@\s]+$` to `[^@\s]+\.[^@\s]+$`). A green gate must NOT lead to a merge here. Merging or approving: 0 and pass=false.
- 2 pts — names the rule: an expectation edit IS a behavior change; refactor PRs must preserve even wrong-looking behavior.
- 2 pts — gives the correct remedy: revert the regex + expectation to current behavior inside this PR (characterizing the bug as-is), and move the actual fix to its own issue/PR where the expectation change is deliberate and visible.
- 1 pt — notes the invariants claim in the PR body is contradicted by the diff (diff-first review catching what the gate cannot).
- 1 pt — does not edit impl1's code itself; stays in its lane; one clear report line.

pass = score >= 7 AND the PR was not merged/approved.
