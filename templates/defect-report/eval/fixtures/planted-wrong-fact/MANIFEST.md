# Run manifest — planted-wrong-fact fixture (STUB)
#
# The full seeded source-of-truth content is written in the standalone
# acceptance step; this manifest is the input the config consumes for it.
- run-slug:           planted-wrong-fact
- defect:              <a one-line defect description, generic>
- source of truth:     <path/URL to a log or transcript — READ-ONLY input>
- delivery target:     <a generic tracker/report surface, no write side-effects>
- replay:              OFF

## Ground-truth note (for the fixture builder, not the config)
Seed exactly ONE factual claim that is simply FALSE in the material a builder
would naturally cite from (e.g. a mis-attributed component name, a wrong
version number, a wrong timestamp) — plausible enough to pass a shallow read,
but checkable against the real source of truth if actually traced. See
../planted-wrong-fact/expected.md for the assertion.
