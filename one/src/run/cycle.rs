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
    gv_gate_baselines, gv_gated_candidates, gv_verdicts, pm_candidates, reviewed_issues,
    signed_off, signoff_candidates, signoff_note, specced_issues, ReviewFilter, RunConfig,
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
    let evs = events(cfg);
    let (judged, baselines) = (gv_verdicts(&evs), gv_gate_baselines(&evs));
    let Some(&n) = gv_gated_candidates(snap, filter, &judged, &baselines).first() else {
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

/// Every "signed off, but the loop is not the one to un-gate it" note starts
/// with this (#663). The phrase is the record's, not a prefix to parse around:
/// the issue number follows it so a reader knows which ticket is waiting.
pub(super) const OUTSIDE_ALLOW_LIST_NOTE: &str =
    "sign-off ok — awaiting human un-gate (outside allow-list)";

pub(super) fn outside_allow_list_note(issue: u64) -> String {
    format!("{OUTSIDE_ALLOW_LIST_NOTE}: #{issue}")
}

/// What a signed-off spec earns, decided before anything is written or called.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum AfterSignOff<'a> {
    /// A human un-gated it between the spec and the sign-off.
    AlreadyUngated,
    /// The manifest names an approver and this issue is the loop's to un-gate.
    Delegate(&'a str),
    /// The gate label stays on, and a human's `fwf ungate` is owed. `Some` is
    /// the line the record owes about why the loop held off.
    Await(Option<String>),
}

/// The decision itself (#663).
///
/// `review_scope` says how far GV and PM may *look* — repo-wide by default,
/// which is the point of #629 — and that is a different question from which
/// issues the loop may make claimable. An allow-list is the operator's own
/// rail: transom #1123, #1313 and #1371 were each signed off, delegated-un-
/// gated and claimable on 2026-09-16 while sitting outside it, and the
/// operator re-gated all three by hand. So the delegated un-gate never widens
/// beyond the allow-list; the human `fwf ungate` path is untouched, and an
/// empty allow-list still means "any eligible issue", as it does everywhere.
pub(super) fn after_sign_off<'a>(
    cfg: &'a RunConfig,
    events: &[crate::log::Event],
    n: u64,
) -> AfterSignOff<'a> {
    // A human may have un-gated between the spec and the sign-off. The record
    // says so, and un-gating twice would comment twice and record a second
    // approval nobody gave.
    if reviewed_issues(events).contains(&n) {
        return AfterSignOff::AlreadyUngated;
    }
    let Some(actor) = &cfg.delegate_ungate else {
        return AfterSignOff::Await(None);
    };
    if !cfg.allow_issues.is_empty() && !cfg.allow_issues.contains(&n) {
        return AfterSignOff::Await(Some(outside_allow_list_note(n)));
    }
    AfterSignOff::Delegate(actor)
}

/// What a signed-off spec earns: the delegated un-gate when a manifest names
/// the approver and the allow-list (if any) covers the issue, and otherwise
/// the wait for a human's `fwf ungate`.
fn ungate_or_await(cfg: &RunConfig, ops: &AppEntry, n: u64) {
    let actor = match after_sign_off(cfg, &events(cfg), n) {
        AfterSignOff::AlreadyUngated => {
            println!("fwf run: #{n} was already un-gated by a human; the sign-off is recorded, nothing else to do");
            return;
        }
        AfterSignOff::Await(why) => {
            if let Some(text) = why {
                note(cfg, text);
                println!("fwf run: #{n} is specced and signed off, but it is outside the `issues` allow-list, so the delegated un-gate does not apply; un-gate it yourself (`fwf ungate --repo {}/{} --issue {n} --by NAME`) or add it to `issues`", cfg.owner, cfg.repo);
            } else {
                println!("fwf run: #{n} is specced and signed off; awaiting the human un-gate (`fwf ungate --repo {}/{} --issue {n} --by NAME`)", cfg.owner, cfg.repo);
            }
            return;
        }
        AfterSignOff::Delegate(actor) => actor,
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

#[cfg(test)]
mod tests {
    use super::super::tests::test_config;
    use super::*;
    use crate::log::Event;

    fn cfg(delegate: Option<&str>, allow: &[u64], scope: super::super::ReviewScope) -> RunConfig {
        RunConfig {
            delegate_ungate: delegate.map(str::to_string),
            allow_issues: allow.to_vec(),
            review_scope: scope,
            ..test_config()
        }
    }

    /// The record after a human ran `fwf ungate` on this issue.
    fn ungated_by_hand(n: u64) -> Vec<Event> {
        crate::triage::ungate_events("tbaums/transom", n, crate::triage::Ungate::Manual("t"), 1)
            .to_vec()
    }

    /// #663, fwf floor 2026-09-16: `review_scope` defaults to all-gated on
    /// purpose — GV and PM are meant to read the whole repo — but the loop
    /// then *un-gated* everything it signed off. Transom #1123, #1313 and
    /// #1371 came off `product-wip` and went claimable while sitting outside
    /// the allow-list their operator had parked them behind; all three were
    /// re-gated by hand. Looking wide and acting wide are different questions.
    #[test]
    fn the_delegated_ungate_never_widens_beyond_the_allow_list() {
        // AC1: the allow-list covers it — un-gated on the delegate's behalf,
        // exactly as before.
        let inside = cfg(Some("jamie-proxy"), &[1123], Default::default());
        assert_eq!(
            after_sign_off(&inside, &[], 1123),
            AfterSignOff::Delegate("jamie-proxy")
        );

        // AC2: outside it — the label stays on, and the record says why.
        let outside = cfg(Some("jamie-proxy"), &[1300], Default::default());
        assert_eq!(
            after_sign_off(&outside, &[], 1123),
            AfterSignOff::Await(Some(
                "sign-off ok — awaiting human un-gate (outside allow-list): #1123".into()
            )),
            "an issue the operator parked outside the rail is not the loop's to free"
        );

        // AC3: no allow-list at all is still "any eligible issue", under
        // either scope — this changes nothing for a floor that sets none.
        for scope in [
            super::super::ReviewScope::AllGated,
            super::super::ReviewScope::AllowList,
        ] {
            assert_eq!(
                after_sign_off(&cfg(Some("jamie-proxy"), &[], scope), &[], 1123),
                AfterSignOff::Delegate("jamie-proxy"),
                "{scope:?}"
            );
            // and the allow-list narrows the un-gate under both scopes: with
            // `allow-list` the filter already kept it from ever being signed
            // off, so this is belt and braces there, never a change.
            assert!(matches!(
                after_sign_off(&cfg(Some("jamie-proxy"), &[1300], scope), &[], 1123),
                AfterSignOff::Await(Some(_)),
            ));
        }
    }

    /// The two answers that never reached the allow-list question: no
    /// delegate configured, and a human who got there first.
    #[test]
    fn a_floor_with_no_delegate_and_an_issue_already_freed_are_unchanged() {
        // No `delegate_ungate`: the wait, with nothing to say about scope —
        // the loop was never going to un-gate this.
        for allow in [&[][..], &[1123][..], &[1300][..]] {
            assert_eq!(
                after_sign_off(&cfg(None, allow, Default::default()), &[], 1123),
                AfterSignOff::Await(None)
            );
        }
        // A human un-gated it between the spec and the sign-off: still the
        // one answer that comes before everything, allow-list or not (#655).
        let c = cfg(Some("jamie-proxy"), &[1300], Default::default());
        assert_eq!(
            after_sign_off(&c, &ungated_by_hand(1123), 1123),
            AfterSignOff::AlreadyUngated,
            "the human path is never constrained by the allow-list"
        );
    }

    /// The note is one line an operator can grep for, and it names the ticket
    /// that is waiting on them.
    #[test]
    fn the_outside_allow_list_note_says_the_phrase_and_the_issue() {
        let text = outside_allow_list_note(1371);
        assert!(text.starts_with(OUTSIDE_ALLOW_LIST_NOTE), "{text}");
        assert_eq!(
            super::super::note_issue(&text, &format!("{OUTSIDE_ALLOW_LIST_NOTE}: #")),
            Some(1371)
        );
    }
}
