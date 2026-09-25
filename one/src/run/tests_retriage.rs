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

/// 2026-09-25T10:00:00Z in unix seconds.
const GATED_TS: u64 = 1_790_330_400;

fn legacy_gated(n: u64, ts: u64) -> Event {
    Event {
        ts,
        repo: "tbaums/transom".into(),
        kind: Kind::Issue {
            issue: n,
            to: IssueState::Gated,
        },
    }
}

#[test]
fn the_fallback_spells_time_like_github() {
    let evs = [legacy_gated(1443, GATED_TS), legacy_gated(1, 951_782_400)];
    let b = gv_gate_baselines(&evs);
    assert_eq!(b[&1443], "2026-09-25T10:00:00Z");
    assert_eq!(b[&1], "2000-02-29T00:00:00Z");
}

/// transom #1442/#1443 (#695): gated not ready under 1.0.19, before #693
/// wrote baselines, then edited. The `Gated` event's own time stands in for
/// the missing baseline — one re-triage, whose note then takes over.
#[test]
fn a_legacy_verdict_is_re_offered_once_after_an_edit() {
    const N: u64 = 1443;
    let mut evs = vec![legacy_gated(N, GATED_TS)];
    // untouched since gating → not a candidate
    assert!(gv_queue(&snap_at(N, "2026-09-25T10:00:00Z"), &evs).is_empty());
    // edited since → a candidate
    assert_eq!(gv_queue(&snap_at(N, "2026-09-25T11:30:00Z"), &evs), vec![N]);
    // GV re-triages it not ready and writes a real baseline: no loop
    evs.extend(gated_at(N, "2026-09-25T11:31:00Z"));
    assert!(gv_queue(&snap_at(N, "2026-09-25T11:31:00Z"), &evs).is_empty());
}

/// Several legacy `Gated` events: the latest one is the baseline.
#[test]
fn a_legacy_fallback_uses_the_latest_gated_event() {
    const N: u64 = 1442;
    let evs = [legacy_gated(N, GATED_TS), legacy_gated(N, GATED_TS + 7200)];
    assert!(gv_queue(&snap_at(N, "2026-09-25T11:30:00Z"), &evs).is_empty());
    assert_eq!(gv_queue(&snap_at(N, "2026-09-25T12:00:01Z"), &evs), vec![N]);
}

/// A baseline note wins over a `Gated` event with a different time.
#[test]
fn a_baseline_note_overrides_the_fallback() {
    const N: u64 = 1442;
    let evs = [
        legacy_gated(N, GATED_TS),
        ev(Kind::Note {
            text: crate::triage::gate_baseline_note(N, "2026-09-25T12:00:00Z"),
        }),
    ];
    assert!(gv_queue(&snap_at(N, "2026-09-25T11:00:00Z"), &evs).is_empty());
    assert_eq!(gv_queue(&snap_at(N, "2026-09-25T12:00:01Z"), &evs), vec![N]);
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

/// QA on #694: once not ready, then edited, judged ready, specced, signed off,
/// un-gated — and re-gated by a human. The re-gate's `Gated` event is not a
/// GV verdict, and the old baseline must not wake GV on a parked issue.
#[test]
fn a_re_gate_after_sign_off_does_not_revive_an_old_baseline() {
    const N: u64 = 1442;
    let mut evs = gated_at(N, "2026-09-25T10:00:00Z").to_vec();
    evs.push(ev(Kind::Note {
        text: crate::triage::ready_note(N),
    }));
    evs.push(ev(Kind::Note {
        text: crate::spec::spec_note(N, 900, false, 1),
    }));
    evs.push(ev(Kind::Note {
        text: signoff_note(N, true),
    }));
    evs.extend(crate::triage::ungate_events(
        "tbaums/transom",
        N,
        crate::triage::Ungate::Delegated("jamie-proxy"),
        2,
    ));
    evs.push(ev(Kind::Issue {
        issue: N,
        to: IssueState::Gated,
    }));
    assert!(gv_gate_baselines(&evs).is_empty());
    assert!(gv_queue(&snap_at(N, "2026-09-25T15:00:00Z"), &evs).is_empty());
}

/// A later not-ready verdict whose read-back failed leaves a `Gated` event and
/// no baseline: the earlier baseline is dropped rather than re-offering the
/// issue every tick.
#[test]
fn a_verdict_with_no_baseline_drops_the_earlier_one() {
    const N: u64 = 1443;
    let mut evs = gated_at(N, "2026-09-25T10:00:00Z").to_vec();
    evs.push(ev(Kind::Issue {
        issue: N,
        to: IssueState::Gated,
    }));
    assert!(gv_gate_baselines(&evs).is_empty());
    assert!(gv_queue(&snap_at(N, "2026-09-25T11:00:00Z"), &evs).is_empty());
}
