//! Re-triage after an edit (#693): a not-ready verdict is offered to GV again
//! once the issue has changed since fwf's own gate write, and only then.
//! Split from `tests.rs` to keep it under the 1,000-line rule (T-30).

use super::tests::issue;
use super::*;
use crate::log::{Event, Kind};
use crate::poll::Snapshot;
use crate::types::IssueState;

fn ev(kind: Kind) -> Event {
    Event {
        ts: 1,
        repo: "tbaums/transom".into(),
        kind,
    }
}

/// What `triage::run` writes on a not-ready verdict: the `Gated` event and the
/// baseline read back right after the label and comment.
fn gated_at(n: u64, at: &str) -> [Event; 2] {
    [
        ev(Kind::Issue {
            issue: n,
            to: IssueState::Gated,
        }),
        ev(Kind::Note {
            text: crate::triage::gate_baseline_note(n, at),
        }),
    ]
}

fn snap_at(n: u64, at: &str) -> Snapshot {
    let mut i = issue(n, &["product-wip"], false);
    i.updated_at = at.into();
    Snapshot {
        issues: vec![i],
        prs: vec![],
        fetched_at: 0,
        known: true,
    }
}

fn gv_queue(snap: &Snapshot, evs: &[Event]) -> Vec<u64> {
    let skip: Vec<String> = vec![];
    let f = ReviewFilter::all_gated("product-wip", &skip);
    gv_gated_candidates(snap, &f, &gv_verdicts(evs), &gv_gate_baselines(evs))
}

#[test]
fn the_baseline_note_round_trips() {
    let evs = gated_at(1442, "2026-09-25T10:00:00Z");
    assert_eq!(
        gv_gate_baselines(&evs).into_iter().collect::<Vec<_>>(),
        vec![(1442, "2026-09-25T10:00:00Z".to_string())]
    );
}

/// transom #1442, 2026-09-25: GV held it not ready, the body was revised, and
/// the loop idled at `0 actions` until a hand `fwf triage`.
#[test]
fn a_not_ready_issue_is_re_offered_once_per_edit() {
    const N: u64 = 1442;
    let mut evs = gated_at(N, "2026-09-25T10:00:00Z").to_vec();
    // unchanged since fwf's own gate write → not a candidate
    assert!(gv_queue(&snap_at(N, "2026-09-25T10:00:00Z"), &evs).is_empty());
    // edited (or commented on) since → a candidate
    let edited = snap_at(N, "2026-09-25T11:30:00Z");
    assert_eq!(gv_queue(&edited, &evs), vec![N]);
    // GV re-triages it not ready again: the new baseline replaces the old one,
    // and with no further edit it drops out next tick
    evs.extend(gated_at(N, "2026-09-25T11:31:00Z"));
    assert!(gv_queue(&snap_at(N, "2026-09-25T11:31:00Z"), &evs).is_empty());
    // the next edit earns exactly one more look
    assert_eq!(gv_queue(&snap_at(N, "2026-09-25T12:00:00Z"), &evs), vec![N]);
}

/// A record written before #693 has a `Gated` event and no baseline: the loop
/// keeps the old behavior and does not re-offer it, however it was edited.
#[test]
fn a_legacy_verdict_with_no_baseline_is_never_re_offered() {
    let evs = vec![ev(Kind::Issue {
        issue: 1443,
        to: IssueState::Gated,
    })];
    assert!(gv_queue(&snap_at(1443, "2026-09-25T12:00:00Z"), &evs).is_empty());
}

/// A ready verdict is untouched: an edit never sends it back to GV.
#[test]
fn a_ready_verdict_is_not_re_offered_by_an_edit() {
    let mut evs = gated_at(1443, "2026-09-25T10:00:00Z").to_vec();
    evs.push(ev(Kind::Note {
        text: crate::triage::ready_note(1443),
    }));
    assert!(gv_queue(&snap_at(1443, "2026-09-25T12:00:00Z"), &evs).is_empty());
}
