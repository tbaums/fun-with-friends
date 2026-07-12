#!/usr/bin/env bash
# shellcheck disable=SC2034  # consumed by lib.sh after the profile loads
# fwf template: consulting firm — a 3-phase falsification funnel that diagnoses
# whether an agent-built software pipeline's SHIPPED QUALITY regressed and, if so,
# why. Premise gate (real decline? null-as-champion) → cause tournament (closed-set
# elimination against a dated delta) → empirical replay (git-restore old prompts/
# models, re-run real briefs). "No real decline / unverifiable" is a first-class win.
#
# ADVISORY, structurally: FWF_REPO is the firm's own FINDINGS repo — the client's
# repo is read-only input, never written. See profiles/consulting.sh + the runbook
# in this dir's README.md.
#
# ---- PROPOSED FIRM NAMES (owner: pick one for the display identity; the template
#      *id* stays `consulting`). Set FWF_FIRM_NAME to override the dossier byline:
#        1) "Boundary & Vane"    — the good→bad boundary + a wind-vane for drift.
#        2) "The Null Bureau"    — the null hypothesis has a paid, resourced lawyer.
#        3) "Recorder Forensics" — an NTSB board bolted to a flight-data recorder.
# Firm name: DESCRIPTIVE (owner's call — states what it does, not a creative alias).
FWF_FIRM_NAME="${FWF_FIRM_NAME:-Software Quality Regression Diagnostics}"
#
# Built ON the `validate` template (itself a falsification funnel with pre-registered
# kill criteria, evidence tiers, paired analyst/red-team debate, pairwise ranking).
# We override all six role prompts (each is reframed for the diagnosis funnel), but
# declare the base so lineage is explicit and any future/un-overridden role file
# falls back to validate rather than erroring.
FWF_TEMPLATE_BASE="validate"
#
# Config DEFAULTS. lib.sh sources this AFTER the profile; only ${VAR:-default}
# patterns apply, so env/CLI/profile settings still win.
#
# Three lens-specialist / red advocate pairs work the SIX-LENS evidence bench
# (model · prompt · orchestration · process · codebase · metrics) as a claimable
# pool: each pair claims the next uncovered lens, stays blind to the others until
# adjudication, and the coverage gate blocks Phase-1 judgment until all six lenses
# plus the mandatory "other/unknown" contender are covered. Three pairs keep the
# floor within the 8-core box's pane/OOM budget (never nest factories).
FWF_PAIRS="${FWF_PAIRS:-3}"

# Visual identity (issue #31): a diagnosis floor should LOOK like one — lens
# specialists working an evidence bench, a citation-cop arguing the null, a judge
# assembling a dossier — not a code floor.
FWF_DISPLAY_IMPL="${FWF_DISPLAY_IMPL:-LENS}"
FWF_DISPLAY_QA="${FWF_DISPLAY_QA:-REDCITE}"
FWF_DISPLAY_CONDUCTOR="${FWF_DISPLAY_CONDUCTOR:-JUDGE}"
FWF_DISPLAY_PM="${FWF_DISPLAY_PM:-REGISTRAR}"
FWF_DESC_IMPL="${FWF_DESC_IMPL:-one lens → tier-tagged evidence}"
FWF_DESC_QA="${FWF_DESC_QA:-citation-cop · argues the null}"
FWF_DESC_CONDUCTOR="${FWF_DESC_CONDUCTOR:-adjudicates premise + tournament → dossier}"
FWF_DESC_PM="${FWF_DESC_PM:-frames + PRE-REGISTERS the rubric}"

# Judgment-heavy seats want the strong model; the lens bench is high-volume
# evidence-gathering. Per-role FWF_MODEL_* overrides still win.
FWF_MODEL_CONDUCTOR="${FWF_MODEL_CONDUCTOR:-opus}"
FWF_MODEL_PM="${FWF_MODEL_PM:-opus}"
FWF_MODEL_GV="${FWF_MODEL_GV:-opus}"
