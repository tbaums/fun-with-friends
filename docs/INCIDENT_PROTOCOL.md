# Incident protocol (operator / captain)

Hard-won from the transom narration incident (2026-06-28). Two rules, in order.

## 1. Verify ground truth BEFORE you alarm

A log line, a counter, a load average, a CI status — these are **proxies**. Before
you declare an incident or escalate to the human, confirm the **actual** thing the
proxy stands for.

- "The judge is logging ~12 calls/min" → **check the real call count**: process
  spawns, the on-disk artifacts a real call would write (e.g. cached-verdict
  files), the actual `$` or token spend. (In the incident, 4 cached-verdict files
  and a 2-concurrent gate proved the ~2,214 "calls" were cache hits the log
  mislabeled — there was no drain. The escalation was wrong.)
- A proxy that *can't* distinguish the benign case from the bad case is not
  evidence. Find the signal that can, then decide.
- Escalations that turn out to be false alarms cost trust and churn. The bar to
  *alarm* is "I checked the ground truth," not "a proxy looked scary."

See also: a recurring class where load/CI/timeout proxies look alarming but are
usually false — verify before alarming.

## 2. Stop the bleeding FIRST (then diagnose)

IF (and only if) ground truth confirms an **ongoing drain on a metered/finite
resource** — runaway metered calls, real spend, disk filling, a hot loop —
**mitigate immediately** (flip the kill switch / disable the flag), THEN diagnose
and fix forward. Do not file a ticket and *offer* the kill switch as an option
while the drain runs.

- A standing "keep feature X on" preference does **not** override stopping a
  confirmed active uncapped drain. A temporary kill is not feature abandonment.
- This only fires when rule 1 has confirmed the drain is real. Don't panic-kill on
  a proxy (that's how you get a false-alarm rollback). Confirm, then act fast.

## Ship requirement for metered / background-loop features

Enforced at GV review (see `templates/dev/gv.tmpl`, RUNTIME COST & BLAST RADIUS).
A feature that makes metered/external calls or runs a background loop ships only
with: a cost **bound** (content+version cache AND a fail-closed breaker/budget
cap), **observability** that tells real calls from cache hits, a **verified,
deploy-plumbed kill switch** (one you can operate from the deploy path, not by
hand-editing prod config under pressure), and ideally a **canary** before
default-ON.
