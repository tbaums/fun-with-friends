# Expected — reproducibility fixture

## Ground truth
The chosen base fixture (known-answer or no-decline) is run through the funnel
TWICE, independently. The firm is stable if the two runs agree on the load-bearing
conclusion.

## PASS assertion (checked against the two DOSSIER.md outputs)
The pair PASSES iff:
- Both runs report the **same premise verdict** (DECLINE CONFIRMED / DRIFT / NO REAL
  DECLINE / UNVERIFIABLE), AND
- If DECLINE CONFIRMED, both rank the **same cause first** in the executive answer.

Non-load-bearing differences are allowed: exact wording, confidence phrasing, the
ordering of lower-ranked coexisting survivors, and which cheapest-tests are named.

## FAIL conditions
- The two runs disagree on the premise verdict, OR
- They convict different top-ranked causes for the same declined target.

## Note
This checks determinism of the FUNNEL'S STRUCTURE, not of the model — reproducibility
is convergence on the verdict, not byte-identical dossiers.
