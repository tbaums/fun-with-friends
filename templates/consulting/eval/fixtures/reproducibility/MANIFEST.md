# Engagement manifest — reproducibility fixture (STUB)
#
# Reuses one of the other two fixtures, run TWICE. Two independent runs must
# CONVERGE on the same premise verdict (and, if declined, the same top-ranked
# cause). Point this at whichever base fixture you are checking for stability.
- engagement-slug:  reproducibility
- base fixture:     known-answer            # or: no-decline
- target repo:      <same as the chosen base fixture>        (READ-ONLY input)
- target tracker:   <same as the base fixture>
- factory config:   <same as the base fixture>
- claimed good era: <same as the base fixture>
- orchestration logs: OFF
- phase-3 replay:   OFF
- runs:             2                        # run the funnel twice, independently

## Ground-truth note (for the fixture builder, not the firm)
Convergence, not identical prose: the two DOSSIERs must agree on the PREMISE
VERDICT and (for a confirmed decline) the TOP-RANKED cause. Wording and lower-ranked
survivors may differ. See ./expected.md.
