# Changelog — fwf 1.0 (`one/`)

## Unreleased (one/m0, 2026-09-09)

- M0: crate, four state enums with `Unknown`, append-only JSONL run record,
  `why`; three GitHub Apps; GitHub client with narrowed installation tokens;
  fake GitHub for contract tests; tmux seat waker (bracketed paste, atomic
  verdict files); canary for deny hooks under `dontAsk`.
- M1: ETag poller + pure scheduler (proptest); claim refs as fencing tokens;
  local bare mirror per repo; QA cycle with reviews anchored to the head;
  typed merge; manifest (`.fwf/fwf.toml`, ≤25 keys, `issues` allow-list);
  per-cycle cost from the seat's own transcript.
- M2: gate runner (local / Apple container / systemd-run, `bash -o pipefail`,
  venue preflight); check-runs; promotion by literal SHA; `release-check`.
- M3: GV triage + human `ungate`; `status`; conductor-as-code (gate after
  merge); one-job prompts for seven template families; PM `spec` cycle;
  `dash` from the run record; meter brake; profile → manifest converter;
  hosted CI (test / fmt+clippy / size ratchet).
- Proven live on fun-with-friends: PRs #565, #567, #569 (impl → QA → merge →
  gate → check-run), triage/un-gate on #570, spec on #571.
