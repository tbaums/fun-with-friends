//! #630 — the two questions the scheduler now asks the record before an
//! issue may reach an impl seat: was it signed off, and has a fast-track
//! bypass already been said out loud.

use super::{note_issue, Action, RunConfig};
use std::collections::BTreeSet;

/// Issues the record says a human signed off: an `IssueState::Ready` event,
/// which `triage::ungate` writes for both `fwf ungate` and the delegated
/// un-gate. This — not the absence of a gate label — is what makes an issue
/// claimable by an impl seat (#630).
pub fn reviewed_issues(events: &[crate::log::Event]) -> BTreeSet<u64> {
    use crate::log::Kind;
    use crate::types::IssueState;
    events
        .iter()
        .filter_map(|e| match &e.kind {
            Kind::Issue {
                issue,
                to: IssueState::Ready,
            } => Some(*issue),
            _ => None,
        })
        .collect()
}

/// Issues the record has already said were fast-tracked, so the note is
/// written once, not once per tick.
pub fn fast_track_noted(events: &[crate::log::Event]) -> BTreeSet<u64> {
    use crate::log::Kind;
    events
        .iter()
        .filter_map(|e| match &e.kind {
            Kind::Note { text } => note_issue(text, "fast-track: #"),
            _ => None,
        })
        .collect()
}

/// The plan, with review enforced (#630): an issue reaches an impl seat
/// because the record says a human signed it off, or because someone applied
/// `fast-track` by hand — and a bypass is said out loud, once.
pub fn planned_after_review(
    cfg: &RunConfig,
    snap: &crate::poll::Snapshot,
    seats: &[crate::sched::SeatSlot],
    now: u64,
) -> crate::sched::Plan {
    let evs = crate::log::read_all(&cfg.run_log).unwrap_or_default();
    let reviewed = reviewed_issues(&evs);
    let p = crate::sched::plan(snap, seats, true, &reviewed, now);
    note_fast_tracks(cfg, snap, &p, &reviewed, &evs);
    p
}

/// Say it once, in the record, when the loop serves an issue that skipped the
/// review path (#630): a bypass nobody can see is the same failure the label
/// convention already had.
pub fn note_fast_tracks(
    cfg: &RunConfig,
    snap: &crate::poll::Snapshot,
    p: &crate::sched::Plan,
    reviewed: &BTreeSet<u64>,
    events: &[crate::log::Event],
) {
    let already = fast_track_noted(events);
    for a in &p.actions {
        let Action::WakeImpl { issue, .. } = a else {
            continue;
        };
        if reviewed.contains(issue) || already.contains(issue) {
            continue;
        }
        let Some(i) = snap.issues.iter().find(|i| i.number == *issue) else {
            continue;
        };
        if !crate::sched::is_fast_track(i) {
            continue;
        }
        if let Ok(mut log) = crate::log::Log::open(&cfg.run_log) {
            let _ = log.append(&crate::log::Event {
                ts: crate::seat::now(),
                repo: format!("{}/{}", cfg.owner, cfg.repo),
                kind: crate::log::Kind::Note {
                    text: crate::sched::fast_track_note(*issue),
                },
            });
        }
        eprintln!("fwf run: #{issue} is `fast-track`; serving it with no recorded review");
    }
}
