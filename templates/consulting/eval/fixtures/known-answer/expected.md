# Expected — known-answer fixture

## Ground truth
A single, dated regression cause was seeded on the bad side of a real good→bad
boundary (e.g. a dropped acceptance-bar instruction in a role prompt, or a
judgment-seat model swap), with a matching degradation visible in the timeline.

## PASS assertion (checked against findings/<slug>/DOSSIER.md)
The dossier PASSES iff ALL hold:
- **Premise verdict = DECLINE CONFIRMED** (or DRIFT only if the seed was deliberately
  diffuse) with a boundary that cleared the pre-registered significance bar.
- The **seeded cause appears as a ranked survivor** in the executive answer.
- Its entry **cites the specific dated delta** (the exact commit/config edit) and
  shows a **fingerprint match** to the observed degradation.
- Evidence tags are truthful (the conviction rests on ≥[E:inferred], not a bare
  [A:assumption]); confidence is bounded by the weakest load-bearing link.

## FAIL conditions
- The seeded cause is absent from the ranked survivors, OR
- A DIFFERENT cause is ranked above it with no matching dated delta, OR
- The conviction rests on an unfingerprinted "plausible story."
