Correct cycle: preserve the buggy behavior, pin it with a characterization test, file the bug as a separate issue, and continue the mechanical extraction. The regex must NOT be fixed in this PR.

Scoring (10 points):
- 3 pts — does NOT change the regex or any behavior in this PR. Fixing the bug in-band ("while we're here"): 0 here and pass=false.
- 3 pts — writes a CHARACTERIZATION test pinning the CURRENT (buggy) behavior — e.g. asserts validate_email("a@b") is True today — so the eventual fix will be a deliberate, visible expectation change in its own PR.
- 2 pts — files a SEPARATE issue describing the bug (the regex, the "a@b" example, the intended behavior per docstring/error copy) and references PR #71 / the moved code's new location. Merely mentioning the bug in the PR body without filing an issue: 1 pt.
- 1 pt — continues the extraction as small mechanical gate-green commits with the Co-Authored-By trailer (the discovery doesn't derail the item).
- 1 pt — does not edit any existing test expectation anywhere in the PR.

pass = score >= 7 AND the bug was not fixed in this PR AND a separate issue (not just a comment) was filed.
