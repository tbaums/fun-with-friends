# Subscription-usage brake (issue #149)

`--budget-usd`/`--token-budget` measure tokens/estimated dollars derived from
this run's own transcripts. They cannot see the thing that actually stops a
Max-plan operator: the **subscription's own usage meters** — the rolling
**5-hour session window** and the **weekly all-models allowance** shown at
`claude.ai/settings/usage`.

`--session-pct`/`--weekly-pct` park the floor (the same `BUDGET_HOLD`
mechanism, sharing the same writer) when those meters cross a threshold. fwf
cannot read them itself — this environment has no access to claude.ai's
account-side usage API/UI, and that boundary isn't fwf's to cross (the same
shape as #205's e2e-port boundary: fwf can define the contract, not reach
across it). Instead, an **operator-run helper**, outside this repo, writes a
small structured signal that fwf polls.

## What the helper should read — and what it must never do

**Never OCR a rendered page.** The workaround this issue replaces did exactly
that (screenshot the usage page, `tesseract` the percentage out of it), and
every observed failure mode failed OPEN — a misread digit, a stale image, a
phase-locked poll, a shell one-liner swallowing an error — because "healthy"
was the default reading when the pipeline broke anywhere. Read the
**structured value the page's own render is built from** instead:

1. **Preferred: an official Anthropic usage API**, if one is available to the
   account in question, at the time you're setting this up. It's not in this
   repo's authority to keep this pointer current — check current developer
   docs.
2. **Fallback: the same backend JSON `claude.ai/settings/usage` fetches to
   render itself** (its XHR response), read directly rather than rendered
   then re-OCR'd. **This is not a stable contract** — it can change shape on
   any UI update with no notice, and that fragility is real and not designed
   away here. It's bounded, though: every way this can break (helper stops
   writing, writes empty/truncated, writes something malformed) is a shape
   fwf's reader fails closed on (see below) — a broken helper parks the floor
   and alarms, it can never make fwf read a healthy number it isn't.

Either way, the helper's job ends at writing the sentinel file below. It does
not need to understand fwf, and fwf does not shell out to it or manage its
lifecycle.

## The sentinel contract

The helper writes (atomically — write-then-rename, not a truncate-in-place,
so fwf never observes a partial write mid-poll) a small JSON file to
`$FWF_RUN/subscription-usage.json` (`$SUBSCRIPTION_USAGE_FILE` in `config.sh`
— override its parent via `FWF_RUN_DIR` like every other per-run state path):

```json
{"session_pct": 42, "weekly_pct": 17, "as_of": "2026-08-25T05:52:00Z"}
```

- `session_pct` / `weekly_pct` — numbers, 0-100.
- `as_of` — an ISO-8601 timestamp of when the helper last successfully read
  the meters (NOT when it wrote the file — those should usually be close, but
  it's `as_of` fwf uses for the staleness bound, so make it the read time).

fwf-budget-check.sh polls this file every `$FWF_BUDGET_CHECK_INTERVAL` seconds
(same writer loop as the token/$ guard) and treats it as it treats every
externally-owned reader on this floor: fail closed on anything it cannot
positively certify as fresh and well-formed. That includes park logic (see
`fwf --help`'s `--session-pct`/`--weekly-pct` entry) with hysteresis-gated
resume — a resumed floor never comes back on a timer, only on a fresh reading
below the resume threshold.

## Sizing FWF_SUBSCRIPTION_STALE_SECS

The default (900s / 15min) assumes the helper polls meaningfully more often
than that. If your helper's own poll interval is close to 900s, raise the
staleness bound accordingly (`FWF_SUBSCRIPTION_STALE_SECS=<secs>`) — a bound
tighter than the helper's own cadence parks every single poll.
