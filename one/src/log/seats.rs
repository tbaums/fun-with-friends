//! Where the record says every seat stands now — and which of those seats are
//! ghosts (#676).
//!
//! Split out of `log.rs` to keep that file inside the 1,000-line rule (T-30),
//! the same way `run/cycle.rs` and `slice/tests.rs` are.

use super::{claimed_issues, Event, Kind};
use crate::types::{IssueState, Role, SeatState};
use std::collections::{BTreeMap, BTreeSet};

/// The latest `Kind::Seat` event per (seat, role), with ghost seats (below)
/// replayed as Idle. Nothing earlier counts.
///
/// Nobody asked the record this before (#667). Every `SeatSlot` the planner
/// saw was built `Idle` by hand — in the loop's tick and in `slice::recheck`
/// alike — so a seat still Working or Stalled on an issue was offered that
/// same issue again, and the re-dispatch wrote `Ready` over the live claim.
/// After that the re-claim could not prove the claim was this floor's, and
/// every later tick refused with `refs/claims/<n> exists upstream and this
/// floor's record does not own it`: transom #1383 after a stall, fwf #669
/// after a bare supervisor restart mid-slice.
pub fn seat_states(events: &[Event]) -> BTreeMap<(u8, Role), SeatState> {
    let mut last = last_seat_states(events);
    for g in ghosts_in(&last, events) {
        last.insert((g.seat, Role::Impl), SeatState::Idle);
    }
    last
}

/// The replay with nothing reconciled: what each seat's last event said.
fn last_seat_states(events: &[Event]) -> BTreeMap<(u8, Role), SeatState> {
    let mut last: BTreeMap<(u8, Role), SeatState> = Default::default();
    for e in events {
        if let Kind::Seat { seat, role, to, .. } = &e.kind {
            last.insert((*seat, *role), to.clone());
        }
    }
    last
}

/// An impl seat the record left Stalled or Working on an issue it no longer
/// holds — so the seat is free, and nothing was ever going to say so.
///
/// Nothing writes a later `Idle`: `Reported` ends a cycle, and a seat that
/// stalled or was interrupted never reports. So a seat's last word stood
/// forever, and `plan()` treats anything but Idle as busy. On a 1.0.12 floor
/// one restart left seat 1 `Stalled{#1412}` (shipped since) and seat 2
/// `Working{#1411}` (re-sliced onto seat 3): two of three pairs unplannable,
/// with four eligible issues waiting and every seat pane alive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ghost {
    pub seat: u8,
    /// The record's last word: `"stalled"` or `"working"`.
    pub was: &'static str,
    /// The issue it was left on, which has since shipped, closed, been
    /// released, or been claimed by another seat.
    pub issue: u64,
}

impl Ghost {
    /// What `fwf status` prints so the freed capacity is visible (#676).
    pub fn line(&self) -> String {
        format!(
            "ghost: impl{} was {} on #{} (now resolved) — idle",
            self.seat, self.was, self.issue
        )
    }
}

/// The ghosts in this record, which [`seat_states`] replays as Idle.
pub fn ghost_seats(events: &[Event]) -> Vec<Ghost> {
    ghosts_in(&last_seat_states(events), events)
}

/// A seat is a ghost when the record shows it *did* claim that issue and
/// [`claimed_issues`] no longer says it holds it — the claim shipped, closed,
/// was released, or was re-claimed by another seat.
///
/// The evidence matters: "this issue is not currently claimed by this seat"
/// alone would free a Working seat whose claim the record never carried at
/// all, and `stale_working` (whose job is exactly those seats) would stop
/// seeing them. A seat only stops being busy here once the record has shown
/// both halves — it held the issue, and it does not now.
///
/// A seat validly stalled on its own live claim is untouched, which is what
/// keeps `stalled_claims` and #669's late adoption working: that path ends in
/// a `Reported` event, already Idle to `SeatSlot::from_record`.
fn ghosts_in(last: &BTreeMap<(u8, Role), SeatState>, events: &[Event]) -> Vec<Ghost> {
    let held = claimed_issues(events);
    let ever: BTreeSet<(u64, u8)> = events
        .iter()
        .filter_map(|e| match &e.kind {
            Kind::Issue {
                issue,
                to: IssueState::Claimed { seat, .. },
            } => Some((*issue, *seat)),
            _ => None,
        })
        .collect();
    last.iter()
        .filter(|((_, role), _)| *role == Role::Impl)
        .filter_map(|((seat, _), to)| {
            let (was, job) = match to {
                SeatState::Stalled { job } => ("stalled", job),
                SeatState::Working { job, .. } => ("working", job),
                _ => return None,
            };
            // Defensive: an impl job always names its issue. Nothing to look
            // up without one, so the record's word stands.
            let issue = job.issue?;
            let still_mine = held.get(&issue).map(|(s, _)| *s) == Some(*seat);
            (ever.contains(&(issue, *seat)) && !still_mine).then_some(Ghost {
                seat: *seat,
                was,
                issue,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Fence, JobRef, Sha};

    fn ev(kind: Kind) -> Event {
        Event {
            ts: 10,
            repo: "tbaums/transom".into(),
            kind,
        }
    }

    fn seat_ev(seat: u8, to: SeatState) -> Event {
        ev(Kind::Seat {
            seat,
            role: Role::Impl,
            to,
            tokens_in: None,
            tokens_out: None,
        })
    }

    fn job(issue: u64) -> JobRef {
        JobRef {
            role: Role::Impl,
            issue: Some(issue),
            pr: None,
        }
    }

    fn claimed(issue: u64, seat: u8) -> Event {
        ev(Kind::Issue {
            issue,
            to: IssueState::Claimed {
                seat,
                fence: Fence("f".repeat(40)),
            },
        })
    }

    fn issue_ev(issue: u64, to: IssueState) -> Event {
        ev(Kind::Issue { issue, to })
    }

    fn working(issue: u64) -> SeatState {
        SeatState::Working {
            job: job(issue),
            deadline: 500,
        }
    }

    fn stalled(issue: u64) -> SeatState {
        SeatState::Stalled { job: job(issue) }
    }

    /// #676, transom 2026-09-18: claim, work, restart (which marks Stalled),
    /// then the issue ships — by someone's hand, by another seat, however. The
    /// seat is free from that moment, and nothing writes it down.
    #[test]
    fn a_seat_stalled_on_an_issue_that_has_since_shipped_replays_idle() {
        for resolved in [
            IssueState::Shipped {
                pr: 1419,
                sha: Sha::parse(&"a".repeat(40)).unwrap(),
            },
            IssueState::Closed,
            // released back to the queue: also not this seat's any more
            IssueState::Ready,
        ] {
            let evs = vec![
                claimed(1412, 1),
                seat_ev(1, working(1412)),
                seat_ev(1, stalled(1412)),
                issue_ev(1412, resolved.clone()),
            ];
            assert_eq!(
                seat_states(&evs).get(&(1, Role::Impl)),
                Some(&SeatState::Idle),
                "{resolved:?}"
            );
            assert_eq!(
                ghost_seats(&evs),
                vec![Ghost {
                    seat: 1,
                    was: "stalled",
                    issue: 1412
                }],
                "{resolved:?}"
            );
        }
    }

    /// The other half of the same outage: seat 2 was left Working by an
    /// interrupted supervisor and its issue was re-sliced onto seat 3.
    #[test]
    fn a_reclaim_by_another_seat_frees_the_seat_that_lost_it_and_not_the_new_one() {
        let evs = vec![
            claimed(1411, 2),
            seat_ev(2, working(1411)),
            issue_ev(1411, IssueState::Ready),
            claimed(1411, 3),
            seat_ev(3, working(1411)),
        ];
        let states = seat_states(&evs);
        assert_eq!(states.get(&(2, Role::Impl)), Some(&SeatState::Idle));
        assert_eq!(
            states.get(&(3, Role::Impl)),
            Some(&working(1411)),
            "the seat that holds it now is untouched"
        );
        assert_eq!(
            ghost_seats(&evs),
            vec![Ghost {
                seat: 2,
                was: "working",
                issue: 1411
            }]
        );
    }

    /// #669's late adoption rests on this: a seat stalled on its OWN live
    /// claim is still stalled, so `stalled_claims` still finds it and the
    /// loop still re-reads its verdict path.
    #[test]
    fn a_seat_stalled_on_a_claim_it_still_holds_is_left_exactly_as_recorded() {
        let evs = vec![claimed(1383, 1), seat_ev(1, stalled(1383))];
        assert_eq!(
            seat_states(&evs).get(&(1, Role::Impl)),
            Some(&stalled(1383))
        );
        assert!(ghost_seats(&evs).is_empty());
        assert_eq!(
            super::super::stalled_claims(&evs)
                .get(&1383)
                .map(|(s, _)| *s),
            Some(1),
            "the adoption path must still see it"
        );
    }

    /// The evidence rule, both ways. A Working seat whose claim the record
    /// never carried is not a ghost — that seat is `stale_working`'s business
    /// — and a job with no issue at all is nobody's to reconcile.
    #[test]
    fn a_seat_is_only_freed_by_a_claim_the_record_actually_shows_it_taking() {
        // no claim event anywhere: the record's word stands
        let bare = vec![seat_ev(1, working(7))];
        assert_eq!(seat_states(&bare).get(&(1, Role::Impl)), Some(&working(7)));
        assert!(ghost_seats(&bare).is_empty());
        assert_eq!(super::super::stale_working(&bare, 1000).len(), 1);

        // claimed by someone else and never by this seat: still not ours to free
        let others = vec![
            claimed(7, 2),
            issue_ev(7, IssueState::Closed),
            seat_ev(1, stalled(7)),
        ];
        assert!(ghost_seats(&others).is_empty());

        // a job with no issue: nothing to look up
        let no_issue = vec![
            claimed(7, 1),
            issue_ev(7, IssueState::Closed),
            seat_ev(
                1,
                SeatState::Stalled {
                    job: JobRef {
                        role: Role::Impl,
                        issue: None,
                        pr: Some(9),
                    },
                },
            ),
        ];
        assert!(ghost_seats(&no_issue).is_empty());

        // a QA seat is never one of these: only impl seats claim issues
        let qa = vec![
            claimed(7, 1),
            issue_ev(7, IssueState::Closed),
            ev(Kind::Seat {
                seat: 1,
                role: Role::Qa,
                to: stalled(7),
                tokens_in: None,
                tokens_out: None,
            }),
        ];
        assert!(ghost_seats(&qa).is_empty());
        assert_eq!(seat_states(&qa).get(&(1, Role::Qa)), Some(&stalled(7)));
    }

    /// Two seats left on the same resolved issue is not a shape the loop can
    /// produce, but the replay must not pick a favourite if it ever sees one.
    #[test]
    fn two_seats_left_on_one_resolved_issue_are_both_freed() {
        let evs = vec![
            claimed(1412, 1),
            seat_ev(1, stalled(1412)),
            issue_ev(1412, IssueState::Ready),
            claimed(1412, 2),
            seat_ev(2, stalled(1412)),
            issue_ev(1412, IssueState::Closed),
        ];
        let states = seat_states(&evs);
        assert_eq!(states.get(&(1, Role::Impl)), Some(&SeatState::Idle));
        assert_eq!(states.get(&(2, Role::Impl)), Some(&SeatState::Idle));
        assert_eq!(ghost_seats(&evs).len(), 2);
    }

    #[test]
    fn the_status_line_names_the_seat_the_state_and_the_issue() {
        assert_eq!(
            Ghost {
                seat: 1,
                was: "stalled",
                issue: 1412
            }
            .line(),
            "ghost: impl1 was stalled on #1412 (now resolved) — idle"
        );
    }
}
