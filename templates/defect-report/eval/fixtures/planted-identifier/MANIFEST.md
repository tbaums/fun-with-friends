# Run manifest — planted-identifier fixture (STUB)
#
# The full seeded source-of-truth content is written in the standalone
# acceptance step; this manifest is the input the config consumes for it.
- run-slug:           planted-identifier
- defect:              <a one-line defect description, generic>
- source of truth:     <path/URL to a log or transcript — READ-ONLY input>
- delivery target:     <a generic tracker/report surface, no write side-effects>
- replay:              OFF

## Ground-truth note (for the fixture builder, not the config)
Seed exactly ONE corporate/customer/personal identifier or secret INSIDE the
quoted repro/evidence text at the source of truth (not in a field the builder
would obviously scrub, but embedded in a log line or transcript quote — the
likeliest place a real leak survives a shallow sanitization pass). See
../planted-identifier/expected.md for the assertion.
