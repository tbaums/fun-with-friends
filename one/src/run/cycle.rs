//! The spec cycle (#629, #655): GV judges a gated ticket, PM writes the spec,
//! GV reads that spec back, and only then does anything un-gate.
//!
//! The sign-off is the half that was missing. Until #655 a first-pass ready
//! verdict ran PM and then, with `delegate_ungate` set, un-gated on the spot —
//! on #653 the record reads `GV triage: #653 judged ready` → `PM spec written
//! into #653` → `human jamie-proxy ungate`, two seconds apart. Nobody read the
//! spec the implementer would build from: the first pass judged a raw ticket,
//! which is a different question with a different answer.
//!
//! So the three passes below are one per tick each, all driven by the record:
//! a pass whose seat stalled writes nothing and is offered again next tick,
//! and a pass whose verdict landed is never repeated. Split out of `run.rs` to
//! keep that file inside the 1,000-line rule (T-30).

use super::{
    gv_gated_candidates, gv_verdicts, pm_candidates, reviewed_issues, signed_off,
    signoff_candidates, signoff_note, specced_issues, ReviewFilter, RunConfig,
};
use crate::github::AppEntry;
use crate::poll::Snapshot;

/// GV's job for one issue, wherever the cycle wakes that seat. The first pass
/// and the sign-off are the same judgement asked twice: what differs is the
/// issue body GitHub hands back, which by the second call is PM's spec.
fn gv_job(cfg: &RunConfig, issue: u64, gv: &str) -> crate::triage::TriageConfig {
    crate::triage::TriageConfig {
        owner: cfg.owner.clone(),
        repo: cfg.repo.clone(),
        issue,
        gate_label: cfg.gate_label.clone(),
        seat_target: gv.to_string(),
        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
        floor_dir: cfg.floor_dir.clone(),
        job_template: crate::prompts::path(&cfg.prompts_dir, &cfg.template, "gv"),
        run_log: cfg.run_log.clone(),
        timeout: cfg.job_timeout,
    }
}

fn events(cfg: &RunConfig) -> Vec<crate::log::Event> {
    crate::log::read_all(&cfg.run_log).unwrap_or_default()
}

fn note(cfg: &RunConfig, text: String) {
    if let Ok(mut log) = crate::log::Log::open(&cfg.run_log) {
        let _ = log.append(&crate::log::Event {
            ts: crate::seat::now(),
            repo: format!("{}/{}", cfg.owner, cfg.repo),
            kind: crate::log::Kind::Note { text },
        });
    }
}

/// The whole cycle, in the order the record has to show it.
///
/// It runs before the allow-list narrows the snapshot, because by default it
/// is not scoped by the allow-list at all, for the same reason `triage_new` is
/// not: a specced ticket is how an issue becomes worth allow-listing in the
/// first place. `ReviewFilter` is what it *is* scoped by (#652).
pub fn spec_cycle(cfg: &RunConfig, ops: Option<&AppEntry>, snap: &Snapshot) {
    let Some(ops) = ops else { return };
    let filter = ReviewFilter::of(cfg);
    super::note_gated_skips(cfg, snap);
    first_pass(cfg, ops, snap, &filter);
    pm_pass(cfg, ops, snap, &filter);
    sign_off(cfg, ops, snap, &filter);
}

/// GV on a gated issue nobody has judged: a readiness read of the raw ticket.
/// A ready verdict here buys the ticket a spec, nothing more — it is not
/// approval of anything, because there is nothing yet to approve.
fn first_pass(cfg: &RunConfig, ops: &AppEntry, snap: &Snapshot, filter: &ReviewFilter) {
    let Some(gv) = &cfg.gv_seat else { return };
    let judged = gv_verdicts(&events(cfg));
    let Some(&n) = gv_gated_candidates(snap, filter, &judged).first() else {
        return;
    };
    match crate::triage::run(&gv_job(cfg, n, gv), ops) {
        Ok((ready, reason)) => println!(
            "fwf run: GV judged gated #{n}: {} — {reason}",
            if ready {
                "ready (PM specs it next)"
            } else {
                "not ready (still gated, reason posted)"
            }
        ),
        // A stalled or refused seat records as such and leaves no verdict, so
        // the issue is offered again next tick.
        Err(e) => eprintln!("fwf run: GV cycle for #{n} failed: {}", e.0),
    }
}

/// PM writes the spec into a gated issue GV called ready. The gate label is
/// never touched here, and neither is the un-gate: what a written spec earns
/// is a reader, not eligibility.
fn pm_pass(cfg: &RunConfig, ops: &AppEntry, snap: &Snapshot, filter: &ReviewFilter) {
    let Some(pm) = &cfg.pm_seat else { return };
    // Re-read: GV may have judged an issue ready moments ago, and PM may take
    // it in this same tick.
    let evs = events(cfg);
    let (judged, specced) = (gv_verdicts(&evs), specced_issues(&evs));
    let Some(&n) = pm_candidates(snap, filter, &judged, &specced).first() else {
        return;
    };
    let scfg = crate::spec::SpecConfig {
        owner: cfg.owner.clone(),
        repo: cfg.repo.clone(),
        issue: n,
        gate_label: cfg.gate_label.clone(),
        discovery_label: crate::spec::DISCOVERY_LABEL.into(),
        seat_target: pm.clone(),
        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
        floor_dir: cfg.floor_dir.clone(),
        job_template: crate::prompts::path(&cfg.prompts_dir, &cfg.template, "pm"),
        run_log: cfg.run_log.clone(),
        timeout: cfg.job_timeout,
    };
    match crate::spec::run(&scfg, ops) {
        Ok((title, questions)) => println!(
            "fwf run: PM specced #{n} — {title} ({} open question(s)); GV signs the spec off next",
            questions.len()
        ),
        Err(e) => eprintln!("fwf run: PM cycle for #{n} failed: {}", e.0),
    }
}

/// The sign-off (#655): GV reads back the spec PM wrote, and only a ready
/// verdict un-gates. A refusal leaves the issue gated with its reason posted —
/// the same shape a first-pass refusal has — and nothing re-specs it: that is
/// a human's call, via `fwf ungate` or an edit.
fn sign_off(cfg: &RunConfig, ops: &AppEntry, snap: &Snapshot, filter: &ReviewFilter) {
    let Some(gv) = &cfg.gv_seat else { return };
    // Re-read: PM may have written the spec moments ago, in this same tick.
    let evs = events(cfg);
    let (specced, signed) = (specced_issues(&evs), signed_off(&evs));
    let Some(&n) = signoff_candidates(snap, filter, &specced, &signed).first() else {
        return;
    };
    match crate::triage::run(&gv_job(cfg, n, gv), ops) {
        Ok((ready, reason)) => {
            note(cfg, signoff_note(n, ready));
            if !ready {
                println!(
                    "fwf run: GV sign-off refused #{n}'s spec — {reason}; still gated, not un-gated"
                );
                return;
            }
            println!("fwf run: GV signed off #{n}'s spec — {reason}");
            ungate_or_await(cfg, ops, n);
        }
        // No note, so the spec is read again next tick — and never re-written:
        // a failed sign-off is not a failed spec.
        Err(e) => eprintln!(
            "fwf run: GV sign-off for #{n} failed: {}; it stays gated and is offered again next tick",
            e.0
        ),
    }
}

/// What a signed-off spec earns: the delegated un-gate when a manifest names
/// the approver, and otherwise the wait for a human's `fwf ungate`.
fn ungate_or_await(cfg: &RunConfig, ops: &AppEntry, n: u64) {
    // A human may have un-gated between the spec and the sign-off. The record
    // says so, and un-gating twice would comment twice and record a second
    // approval nobody gave.
    if reviewed_issues(&events(cfg)).contains(&n) {
        println!("fwf run: #{n} was already un-gated by a human; the sign-off is recorded, nothing else to do");
        return;
    }
    let Some(actor) = &cfg.delegate_ungate else {
        println!("fwf run: #{n} is specced and signed off; awaiting the human un-gate (`fwf ungate --repo {}/{} --issue {n} --by NAME`)", cfg.owner, cfg.repo);
        return;
    };
    match crate::triage::ungate(
        &cfg.owner,
        &cfg.repo,
        n,
        &cfg.gate_label,
        // Marked as what it is (#645): the loop typed this, standing in for a
        // name, and a reader of the issue or the record must be able to tell.
        crate::triage::Ungate::Delegated(actor),
        &cfg.run_log,
        ops,
    ) {
        Ok(()) => println!("fwf run: #{n} un-gated on {actor}'s behalf (delegated); now eligible"),
        Err(e) => eprintln!(
            "fwf run: #{n} is specced and signed off but the delegated un-gate failed: {}",
            e.0
        ),
    }
}
