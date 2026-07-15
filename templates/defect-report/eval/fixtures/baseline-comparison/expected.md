# Expected — baseline-comparison fixture (the thesis run)

## Ground truth
There is no seeded defect here — this fixture *is* the falsifiable test of
issue `#117`'s central thesis: does the factory beat a fair single-model
baseline on the same skill, checklist, and human-gate opportunity?

## PASS assertion (checked against the blinded-scoring output for both arms)
The **config** (not any one run) PASSES iff, applying the pre-registered
decision rule from `../../README.md` per tier:
- **Per tier**, Arm F passes strictly more checklist items unaided than Arm S
  on **at least 5 of the 6 paired instances** (the sign-test majority bar),
  AND
- **Per tier**, Arm F's mean correction-rounds-to-filable is **at least 1.0
  round lower** than Arm S's, averaged over the 6 instances, AND
- **Both tiers** clear the above — winning only one tier is a loss for the
  config as a whole, reported as such.
- The scoring was genuinely blinded (no arm-identifying metadata reached the
  scorer) and the two independent scoring passes' agreement rate is reported
  alongside the result.
- Both arms' logged cost and the resulting cost multiple (Arm F spend ÷ Arm S
  spend) are reported next to the win/loss call.

## FAIL / non-suppressible outcomes
- Either tier fails the decision rule above — report it plainly as a loss on
  that tier; a losing tier is a valid, reportable outcome and must **never**
  be hidden inside an aggregate "won overall" framing.
- Scoring agreement rate below 80% — reported as a scoring-reliability
  concern; the comparison is not treated as settled until re-scored or the
  disagreement is explained.
- Any arm-identifying leak into the scorer's input invalidates that
  instance's score — re-run the blinding, do not keep the tainted result.
