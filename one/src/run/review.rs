//! #630 — the two questions the scheduler now asks the record before an
//! issue may reach an impl seat: was it signed off, and has a fast-track
//! bypass already been said out loud. Plus #656: what the record says when a
//! human has since put the gate label back on, and which issue just refused.

use super::{note_issue, Action, RunConfig};
use crate::types::IssueState;
use std::collections::{BTreeMap, BTreeSet};

/// The record's last word on each issue, and when it was said. A sign-off is
/// not a fact about the past that stays true forever (#656): the record is a
/// sequence, and only its latest `Issue` event says where an issue stands now.
///
/// The timestamp is what #664 needs: a snapshot polled before that event was
/// written cannot speak to what the issue looks like after it.
pub fn latest_issue_state_at(events: &[crate::log::Event]) -> BTreeMap<u64, (IssueState, u64)> {
    use crate::log::Kind;
    let mut out = BTreeMap::new();
    for e in events {
        if let Kind::Issue { issue, to } = &e.kind {
            out.insert(*issue, (to.clone(), e.ts));
        }
    }
    out
}

/// [`latest_issue_state_at`] without the timestamps.
pub fn latest_issue_state(events: &[crate::log::Event]) -> BTreeMap<u64, IssueState> {
    latest_issue_state_at(events)
        .into_iter()
        .map(|(n, (to, _))| (n, to))
        .collect()
}

/// Issues the record says a human signed off: an `IssueState::Ready` event,
/// which `triage::ungate` writes for both `fwf ungate` and the delegated
/// un-gate. This — not the absence of a gate label — is what makes an issue
/// claimable by an impl seat (#630).
///
/// It is the *latest* state that decides (#656). A `Ready` anywhere in history
/// used to be enough, so an issue re-gated after its sign-off stayed eligible
/// forever: on #653 every tick re-planned it, wrote another `Ready`, and the
/// one idle seat never reached #655 behind it. A `Gated` event — which
/// [`reconcile_regated`] writes the moment the label comes back — now takes
/// the sign-off away until a human un-gates again.
pub fn reviewed_issues(events: &[crate::log::Event]) -> BTreeSet<u64> {
    latest_issue_state(events)
        .into_iter()
        .filter(|(_, to)| matches!(to, IssueState::Ready | IssueState::Claimed { .. }))
        .map(|(n, _)| n)
        .collect()
}

/// The record's note for a re-gate the loop noticed, carrying the reason the
/// `Gated` event itself has nowhere to put.
pub fn regated_note(issue: u64) -> String {
    format!("re-gated: #{issue} — gate label re-applied after Ready")
}

/// A human put the gate label back on an issue the record still calls signed
/// off (#656). Their hand on the label is the decision; the loop's job is to
/// write it down, once, so every later tick plans from it.
///
/// Returns the issues re-gated this tick — already excluded from the plan,
/// because [`reviewed_issues`] reads the event this just wrote.
///
/// A snapshot only gets to report a re-gate for an issue it was polled *after*
/// (#664). The tick polls once and reuses that `Snapshot` all tick, so with
/// `delegate_ungate` set the loop's own un-gate — a real label removal, and a
/// `Ready` event — lands after the poll, and the payload still shows the label
/// the loop just took off. That looked like a human re-gating the issue
/// seconds after sign-off, and the loop undid its own un-gate. A payload read
/// at or before the sign-off cannot speak to what happened after it, so it is
/// not evidence of anything; the next tick's poll postdates the `Ready` event
/// and catches a real re-gate exactly as before, one tick later.
pub fn reconcile_regated(cfg: &RunConfig, snap: &crate::poll::Snapshot) -> BTreeSet<u64> {
    let last = latest_issue_state_at(&crate::log::read_all(&cfg.run_log).unwrap_or_default());
    let mut out = BTreeSet::new();
    for i in &snap.issues {
        let gated_now = i.state == "open" && i.labels.contains(&cfg.gate_label);
        let Some((state, since)) = last.get(&i.number) else {
            continue;
        };
        let signed_off = matches!(state, IssueState::Ready | IssueState::Claimed { .. });
        if !(gated_now && signed_off) {
            continue;
        }
        // `fetched_at == 0` is a snapshot with no fetch time to compare
        // against ([`crate::poll::Snapshot::unknown`], and test fixtures); a
        // real poll stamps unix seconds.
        if snap.fetched_at > 0 && *since >= snap.fetched_at {
            continue;
        }
        let Ok(mut log) = crate::log::Log::open(&cfg.run_log) else {
            continue;
        };
        let repo = format!("{}/{}", cfg.owner, cfg.repo);
        let ev = |kind| crate::log::Event {
            ts: crate::seat::now(),
            repo: repo.clone(),
            kind,
        };
        let _ = log.append(&ev(crate::log::Kind::Note {
            text: regated_note(i.number),
        }));
        if log
            .append(&ev(crate::log::Kind::Issue {
                issue: i.number,
                to: IssueState::Gated,
            }))
            .is_ok()
        {
            out.insert(i.number);
            println!(
                "fwf run: #{} is gated again — the `{}` label is back on after a sign-off; not planning it",
                i.number, cfg.gate_label
            );
        }
    }
    out
}

/// Issues a cycle refused inside the last `window` seconds, newest word wins.
///
/// One issue that refuses every cycle used to take the tick's only impl seat
/// every time, because the plan is FIFO by number and a refusal left nothing
/// in the plan to say otherwise (#653 sat in front of #655 for an hour). A
/// refusal is not a verdict on the issue, so this is a tie-break and nothing
/// more: [`crate::sched::plan`] serves these last, and serves them anyway when
/// nothing else is eligible.
pub fn refused_recently(events: &[crate::log::Event], now: u64, window: u64) -> BTreeSet<u64> {
    use crate::log::Kind;
    let claimed = crate::log::claimed_issues(events);
    events
        .iter()
        .filter(|e| now.saturating_sub(e.ts) <= window)
        .filter_map(|e| match &e.kind {
            Kind::Refused { what, .. } => note_issue(what, "#"),
            _ => None,
        })
        // A claim the record still holds is a cycle in flight, not a refusal
        // to step over.
        .filter(|n| !claimed.contains_key(n))
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
///
/// Reconciliation runs first (#656), so a re-gate a human made between ticks
/// is in the record before anything is planned from it.
pub fn planned_after_review(
    cfg: &RunConfig,
    snap: &crate::poll::Snapshot,
    seats: &[crate::sched::SeatSlot],
    now: u64,
) -> crate::sched::Plan {
    reconcile_regated(cfg, snap);
    let evs = crate::log::read_all(&cfg.run_log).unwrap_or_default();
    let reviewed = reviewed_issues(&evs);
    let refused = refused_recently(&evs, now, cfg.interval.as_secs());
    let p = crate::sched::plan(snap, seats, true, &reviewed, &refused, now);
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
