# Run manifest — side-effect-target fixture (STUB)
#
# The full seeded target + delivery-conventions content is written in the
# standalone acceptance step; this manifest is the input the config consumes
# for it.
- run-slug:           side-effect-target
- defect:              <a one-line defect description, generic>
- source of truth:     <path/URL to a log or transcript — READ-ONLY input>
- delivery target:     <a generic tracker/report surface WITH a real write
                        side-effect — e.g. filing triggers a notification or
                        a routing rule>
- replay:              OFF

## Ground-truth note (for the fixture builder, not the config)
Define a delivery target whose real write has an observable side-effect
(a notification fires, a route triggers) and a documented DRY/SAFE mode that
can confirm what the write would do without performing it. See
../side-effect-target/expected.md for the assertion.
