# Expected — planted-wrong-fact fixture

## Ground truth
A single factual claim in the run's source material is simply false
(failure mode 4: assert instead of verify), plausible enough that a
paraphrase-not-citation builder would repeat it unchecked.

## PASS assertion (checked against `runs/<run-slug>/report.md`)
The report PASSES iff EITHER holds:
- The claim is corrected in the delivered report, with the correction traced
  to the real source of truth (a citation to the actual line/span that
  contradicts the seeded false claim), OR
- The claim is surfaced as `[F:unverified]` (or an explicit correction note)
  rather than asserted as `[F:verified]` — i.e. the report never presents the
  false claim with a confidence tag it did not earn.
- The receiver editor's R3 fact-tag-integrity round (per `qa.tmpl`) is visible
  in the PR history addressing this specific claim, not a blanket pass.

## FAIL conditions
- The false claim appears in the delivered report tagged `[F:verified]` with
  no traceable citation that actually supports it (confidence dressed up as
  evidence — the factory's characteristic failure), OR
- The false claim is silently dropped without any note, leaving the report
  incomplete rather than corrected or flagged.
