//! Re-gate reconciliation tests for the run loop (#664): a snapshot polled
//! before a sign-off cannot report a re-gate. Split from `tests.rs` to keep
//! it under the 1,000-line rule (T-30).

use super::tests::{issue, test_config};
use super::*;
use crate::log::{Event, Kind};
use crate::poll::Snapshot;
use crate::triage::Ungate::Delegated;
use crate::types::IssueState;
use std::path::Path;

/// A run log of its own, so these tests never read each other's events.
fn regate_log(tag: &str) -> (RunConfig, PathBuf) {
    let dir = std::env::temp_dir().join(format!("fwfd-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let _ = std::fs::remove_file(&run_log);
    (
        RunConfig {
            run_log: run_log.clone(),
            ..test_config()
        },
        run_log,
    )
}

fn sign_off(run_log: &Path, issue: u64, ts: u64) {
    let mut log = crate::log::Log::open(run_log).unwrap();
    for ev in crate::triage::ungate_events("tbaums/transom", issue, Delegated("jamie-proxy"), ts) {
        log.append(&ev).unwrap();
    }
}

fn regated_notes(evs: &[Event]) -> usize {
    evs.iter()
        .filter(|e| matches!(&e.kind, Kind::Note { text } if text.starts_with("re-gated: #")))
        .count()
}

/// #664, fwf floor 2026-09-16: the tick polls once and reuses that snapshot
/// all tick, so the delegated un-gate — a real label removal — happens after
/// the poll. The payload still shows the label the loop itself just took off,
/// which read as a human re-gating the issue 0s after sign-off: the loop wrote
/// `Gated` and undid its own un-gate, and #1383, #1385 and #1386 sat eligible
/// for six ticks with an idle seat. A snapshot older than the sign-off is not
/// evidence of a re-gate.
#[test]
fn a_snapshot_polled_before_the_sign_off_cannot_report_a_re_gate() {
    let (cfg, run_log) = regate_log("regate-stale");
    // polled at 100, un-gated at 100 — the same tick
    sign_off(&run_log, 1383, 100);
    let stale = Snapshot {
        issues: vec![issue(1383, &["product-wip"], false)],
        prs: vec![],
        fetched_at: 100,
        known: true,
    };
    assert!(
        reconcile_regated(&cfg, &stale).is_empty(),
        "the loop's own un-gate is not a re-gate"
    );
    let evs = crate::log::read_all(&run_log).unwrap();
    assert_eq!(regated_notes(&evs), 0, "nothing to say: {evs:?}");
    assert_eq!(
        latest_issue_state(&evs).get(&1383),
        Some(&IssueState::Ready),
        "the sign-off stands"
    );
    assert!(reviewed_issues(&evs).contains(&1383));
    let _ = std::fs::remove_file(&run_log);
}

/// The other side of #664, and the guard on #656: a snapshot polled *after*
/// the sign-off saw the label with its own eyes, so a human put it back. That
/// still takes the sign-off away, one tick later at worst.
#[test]
fn a_snapshot_polled_after_the_sign_off_still_reports_a_re_gate() {
    let (cfg, run_log) = regate_log("regate-fresh");
    sign_off(&run_log, 1383, 100);
    let fresh = Snapshot {
        issues: vec![issue(1383, &["product-wip"], false)],
        prs: vec![],
        fetched_at: 101,
        known: true,
    };
    assert_eq!(
        reconcile_regated(&cfg, &fresh)
            .into_iter()
            .collect::<Vec<_>>(),
        vec![1383]
    );
    let evs = crate::log::read_all(&run_log).unwrap();
    assert_eq!(regated_notes(&evs), 1);
    assert!(evs
        .iter()
        .any(|e| matches!(&e.kind, Kind::Note { text } if *text == regated_note(1383))));
    assert_eq!(
        latest_issue_state(&evs).get(&1383),
        Some(&IssueState::Gated)
    );
    assert!(!reviewed_issues(&evs).contains(&1383));
    let _ = std::fs::remove_file(&run_log);
}

/// The tick as `run.rs` runs it: poll once, `spec_cycle` un-gates on the
/// manifest's behalf, then `planned_after_review` reconciles against that same
/// snapshot. The freshly un-gated issue reaches the seat in the tick that
/// signed it off; a sibling the operator really did re-gate is still caught.
#[test]
fn a_freshly_un_gated_issue_is_planned_in_the_tick_that_signed_it_off() {
    let (mut cfg, run_log) = regate_log("regate-tick");
    cfg.impl_seats = vec![(1, "fwf:1.1".into()), (2, "fwf:1.2".into())];
    // #1385 was signed off a tick ago and the operator put the label back on
    sign_off(&run_log, 1385, 40);
    // the tick's one poll, with both labels on
    let snap = Snapshot {
        issues: vec![
            issue(1383, &["product-wip"], false),
            issue(1385, &["product-wip"], false),
        ],
        prs: vec![],
        fetched_at: 100,
        known: true,
    };
    // spec_cycle's delegated un-gate: #1383's label is really gone now
    sign_off(&run_log, 1383, 100);
    let seats: Vec<SeatSlot> = cfg
        .impl_seats
        .iter()
        .map(|(n, _)| SeatSlot {
            seat: *n,
            role: Role::Impl,
            state: SeatState::Idle,
        })
        .collect();
    let p = review::planned_after_review(&cfg, &snap, &seats, 100);
    assert!(
        p.actions.iter().any(|a| a.issue() == Some(1383)),
        "the issue this tick un-gated took a seat: {:?}",
        p.actions
    );
    assert!(
        !p.actions.iter().any(|a| a.issue() == Some(1385)),
        "the re-gated one did not: {:?}",
        p.actions
    );
    let evs = crate::log::read_all(&run_log).unwrap();
    assert_eq!(regated_notes(&evs), 1, "only #1385's: {evs:?}");
    assert!(reviewed_issues(&evs).contains(&1383));
    assert!(!reviewed_issues(&evs).contains(&1385));
    let _ = std::fs::remove_file(&run_log);
}
