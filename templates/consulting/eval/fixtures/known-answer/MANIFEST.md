# Engagement manifest — known-answer fixture (STUB)
#
# The full seeded fixture repo is built in the standalone acceptance step; this
# manifest is the input the firm consumes for it. Sources are named BY TYPE.
- engagement-slug:  known-answer
- target repo:      <path to the seeded fixture repo>        (READ-ONLY input)
- target tracker:   <org/repo or local-issues store>
- factory config:   <the fixture's role prompts + role→model mapping + gates>
- claimed good era: <the ref/tag BEFORE the seeded regression was introduced>
- orchestration logs: OFF
- phase-3 replay:   OFF

## Ground-truth note (for the fixture builder, not the firm)
Seed ONE dated regression cause on the bad side of a real boundary — e.g. a role
prompt edit that drops an acceptance-bar instruction, OR a judgment seat's model
silently swapped to a cheaper one — with a matching, observable degradation in the
timeline. The firm must FIND it. See ../known-answer/expected.md for the assertion.
