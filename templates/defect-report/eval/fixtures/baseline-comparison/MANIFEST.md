# Run manifest — baseline-comparison fixture (STUB)
#
# This fixture is the thesis run itself: it carries no seeded defect of its
# own. Its "manifest" is the pre-registered protocol committed in
# ../../README.md#proving-the-thesis--the-pre-registered-eval-protocol —
# restated here as the concrete run parameters so the eval can be checked
# off without re-deriving them.
- eval-slug:           baseline-comparison
- instances (N):       6 distinct (skill,target) instances, PAIRED across arms
                        (same 6 instances run through both Arm F and Arm S)
- model tiers:         2 minimum (whichever two tiers are configured for
                        FWF_MODEL / the single-model baseline at eval time)
- total runs:          2 arms x 2 tiers x 6 instances = 24 (the bounded
                        ceiling — does not grow without a new pre-registration)
- Arm F:               this template, run end-to-end per instance
- Arm S:               one continuous single-model session per instance,
                        given the IDENTICAL skill doc + the same
                        contract-loader-derived checklist + the same single
                        human-gate opportunity (no ensemble structure)
- scoring:             blinded (scorer has no arm-identifying signal), each
                        artifact scored twice, agreement rate reported
- replay:              N/A (this fixture is the comparison itself)
