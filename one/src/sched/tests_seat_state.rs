//! #667 — the record's seat states reaching the planner.
//!
//! The scheduler was always able to hold a seat's issue back; nothing ever
//! told it a seat was holding one. `log::seat_states` is the replay, and
//! `SeatSlot::from_record` is how a slot is built from it; this covers the
//! path from a run record to a plan that leaves a held issue alone.
//!
//! Split from `tests.rs` to keep both files inside the 1,000-line rule (T-30).

use super::tests::{issue, job, seat, snap};
use super::*;
use crate::log::{Event, Kind};
use crate::types::{Fence, IssueState, JobRef};

fn ev(ts: u64, kind: Kind) -> Event {
    Event {
        ts,
        repo: "tbaums/transom".into(),
        kind,
    }
}

fn seat_ev(n: u8, role: Role, to: SeatState) -> Event {
    ev(
        10,
        Kind::Seat {
            seat: n,
            role,
            to,
            tokens_in: None,
            tokens_out: None,
        },
    )
}

/// The record's word on a seat, and what the planner is handed for it.
#[test]
fn a_seat_plans_as_the_record_last_left_it_and_a_finished_cycle_frees_it() {
    let j = job(Some(1383), None);
    let working = SeatState::Working {
        job: j.clone(),
        deadline: 500,
    };
    let evs = vec![
        seat_ev(1, Role::Impl, working.clone()),
        seat_ev(2, Role::Impl, SeatState::Reported { job: j.clone() }),
        seat_ev(1, Role::Qa, SeatState::Stalled { job: j.clone() }),
    ];
    let states = crate::log::seat_states(&evs);
    assert_eq!(states.get(&(1, Role::Impl)), Some(&working));
    assert_eq!(states.len(), 3, "one entry per (seat, role): {states:?}");

    // Working stands as it is; a seat the record never saw is Idle.
    assert_eq!(
        SeatSlot::from_record(1, Role::Impl, states.get(&(1, Role::Impl))).state,
        working
    );
    assert_eq!(
        SeatSlot::from_record(9, Role::Impl, states.get(&(9, Role::Impl))).state,
        SeatState::Idle
    );
    // A cycle that reported is over and the pane is free — nothing writes an
    // `Idle` event to say so, which is why this mapping exists at all.
    assert_eq!(
        SeatSlot::from_record(2, Role::Impl, states.get(&(2, Role::Impl))).state,
        SeatState::Idle
    );
    // The same seat number in another role is a different seat.
    assert_eq!(
        SeatSlot::from_record(1, Role::Qa, states.get(&(1, Role::Qa))).state,
        SeatState::Stalled { job: j }
    );
}

/// AC1: a stalled seat's job is still live work. The supervisor is the only
/// thing that ever kills a pane, so a seat past its deadline may well still be
/// building — transom #1383 finished minutes after its stall verdict — and its
/// issue is nobody else's to take meanwhile.
#[test]
fn a_stalled_seats_issue_counts_busy_and_is_not_offered_to_another_seat() {
    let s = snap(
        vec![issue(1383, &[], "OWNER"), issue(1385, &[], "OWNER")],
        vec![],
    );
    let seats = [
        seat(
            1,
            Role::Impl,
            SeatState::Stalled {
                job: job(Some(1383), None),
            },
        ),
        seat(2, Role::Impl, SeatState::Idle),
    ];
    let (busy, _) = live_jobs(&seats, 100);
    assert!(busy.contains(&1383), "{busy:?}");
    // the free seat takes the other issue and nothing is offered #1383
    assert_eq!(
        plan(
            &s,
            &seats,
            true,
            &all_reviewed(&s),
            &BTreeSet::new(),
            &BTreeSet::new(),
            100
        )
        .actions,
        vec![Action::WakeImpl {
            seat: 2,
            issue: 1385
        }]
    );
}

/// AC2, the transom #1383 replay: claimed at 07:20, the seat stalled at 08:00,
/// and every tick after that offered the issue again — the re-dispatch wrote
/// `Ready` over the live claim, and from then on the re-claim could not prove
/// the ref upstream was this floor's. A plan built from the record leaves it
/// alone, and the claim is still the record's to reuse.
#[test]
fn a_claimed_issue_whose_seat_stalled_is_never_offered_again() {
    let fence = Fence("3f2357d".repeat(5) + "abcde");
    let evs = vec![
        ev(
            100,
            Kind::Issue {
                issue: 1383,
                to: IssueState::Claimed {
                    seat: 1,
                    fence: fence.clone(),
                },
            },
        ),
        seat_ev(
            1,
            Role::Impl,
            SeatState::Working {
                job: job(Some(1383), None),
                deadline: 200,
            },
        ),
        seat_ev(
            1,
            Role::Impl,
            SeatState::Stalled {
                job: job(Some(1383), None),
            },
        ),
    ];
    let states = crate::log::seat_states(&evs);
    let seats = [SeatSlot::from_record(
        1,
        Role::Impl,
        states.get(&(1, Role::Impl)),
    )];
    // the poll still shows the issue open, unlabelled and free — GitHub has no
    // idea a seat holds it (`refs/claims/<n>` is only read for `claimed`-
    // labelled issues, and nothing applies that label)
    let s = snap(vec![issue(1383, &[], "OWNER")], vec![]);
    let p = plan(
        &s,
        &seats,
        true,
        &all_reviewed(&s),
        &BTreeSet::new(),
        &BTreeSet::new(),
        300,
    );
    assert!(
        !p.actions.iter().any(|a| a.issue() == Some(1383)),
        "the stalled seat's own issue was offered again: {:?}",
        p.actions
    );
    // and the record still holds the claim for the re-entry to reuse
    assert_eq!(
        crate::log::claimed_issues(&evs).get(&1383),
        Some(&(1, fence))
    );
}

/// The restart shape (fwf #669, 2026-09-16): the supervisor died mid-slice and
/// came back with the seat still Working per the log. The claim is the
/// record's, the deadline has not passed, and the plan must not re-offer it.
#[test]
fn a_seat_left_working_by_a_restart_still_holds_its_issue() {
    let evs = vec![
        ev(
            100,
            Kind::Issue {
                issue: 669,
                to: IssueState::Claimed {
                    seat: 1,
                    fence: Fence("f".repeat(40)),
                },
            },
        ),
        seat_ev(
            1,
            Role::Impl,
            SeatState::Working {
                job: JobRef {
                    role: Role::Impl,
                    issue: Some(669),
                    pr: None,
                },
                deadline: 2_000,
            },
        ),
    ];
    // a second process, reading only the record it was left
    let states = crate::log::seat_states(&evs);
    let seats = [SeatSlot::from_record(
        1,
        Role::Impl,
        states.get(&(1, Role::Impl)),
    )];
    let s = snap(vec![issue(669, &[], "OWNER")], vec![]);
    assert_eq!(
        plan(
            &s,
            &seats,
            true,
            &all_reviewed(&s),
            &BTreeSet::new(),
            &BTreeSet::new(),
            900
        )
        .actions,
        vec![Action::Nothing],
        "the seat is busy and its issue is taken"
    );
}
