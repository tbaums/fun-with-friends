//! The scheduler (T-09): a pure function from one [`Snapshot`] and the seat
//! table to a [`Plan`]. No I/O, no clock reads, no GitHub — every input is a
//! value, so the properties below are checkable by proptest and a plan can
//! be replayed from the run record.

use crate::poll::{IssueView, PrView, Snapshot, CLAIM_LABEL};
use crate::types::{Fence, Role, SeatState};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatSlot {
    pub seat: u8,
    pub role: Role,
    pub state: SeatState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    WakeImpl {
        seat: u8,
        issue: u64,
    },
    WakeQa {
        seat: u8,
        pr: u64,
    },
    /// An open PR approved at its head by a reviewer who is not its author:
    /// finish it (ready-for-review + typed merge). Covers the case where the
    /// approval landed but the merge step failed in an earlier tick.
    FinishPr {
        pr: u64,
    },
    /// A claim whose seat is not working it (stalled, gone, or absent) and
    /// that no open PR closes: release it, fenced by the live claim SHA.
    ReleaseClaim {
        issue: u64,
        fence: Fence,
    },
    /// The snapshot was readable and there is nothing to do.
    Nothing,
}

impl Action {
    pub fn issue(&self) -> Option<u64> {
        match self {
            Action::WakeImpl { issue, .. } | Action::ReleaseClaim { issue, .. } => Some(*issue),
            _ => None,
        }
    }
    pub fn seat(&self) -> Option<u8> {
        match self {
            Action::WakeImpl { seat, .. } | Action::WakeQa { seat, .. } => Some(*seat),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Plan {
    pub actions: Vec<Action>,
}

impl Plan {
    /// True when the plan carries no work (empty, or only `Nothing`).
    pub fn is_empty(&self) -> bool {
        self.actions.iter().all(|a| *a == Action::Nothing)
    }
}

/// Seat ids of `role` that are assignable: every slot for that id is `Idle`.
/// A busy or dead slot anywhere disqualifies the id.
fn idle_seats(seats: &[SeatSlot], role: Role) -> std::vec::IntoIter<u8> {
    let not_idle: BTreeSet<u8> = seats
        .iter()
        .filter(|s| s.state != SeatState::Idle)
        .map(|s| s.seat)
        .collect();
    let ids: BTreeSet<u8> = seats
        .iter()
        .filter(|s| s.role == role && !not_idle.contains(&s.seat))
        .map(|s| s.seat)
        .collect();
    ids.into_iter().collect::<Vec<_>>().into_iter()
}

/// The issue/PR numbers some live seat is currently occupied with. A seat
/// Working past its deadline is treated as Stalled: its job is *not* live.
fn live_jobs(seats: &[SeatSlot], now: u64) -> (BTreeSet<u64>, BTreeSet<u64>) {
    let mut issues = BTreeSet::new();
    let mut prs = BTreeSet::new();
    for s in seats {
        let job = match &s.state {
            SeatState::Working { job, deadline } if *deadline >= now => job,
            SeatState::Reported { job } => job,
            _ => continue,
        };
        issues.extend(job.issue);
        prs.extend(job.pr);
    }
    (issues, prs)
}

fn issue_eligible(i: &IssueView, gate_label: &str, owner_only: bool) -> bool {
    i.state == "open"
        && !i.labels.iter().any(|l| l == gate_label || l == CLAIM_LABEL)
        && (!owner_only || i.author_association == "OWNER")
        && i.assignees.is_empty()
        && i.claim.is_none()
}

/// Approved at the current head by someone other than the PR's own App.
/// The author's login is not in the view; the QA App's login ends in
/// `-qa[bot]`, which is the only reviewer whose approval counts here.
fn pr_approved_at_head(p: &PrView) -> bool {
    p.state == "open"
        && p.reviews.iter().any(|(login, state, commit)| {
            state == "APPROVED" && *commit == p.head_sha && login.ends_with("-qa[bot]")
        })
}

fn touched_prs_pre(actions: &[Action], pr: u64) -> bool {
    !actions
        .iter()
        .any(|a| matches!(a, Action::FinishPr { pr: p } if *p == pr))
}

fn pr_qa_eligible(p: &PrView) -> bool {
    // Drafts ARE QA work: seats open every PR as a draft, QA reviews it, and
    // the supervisor marks it ready only after an anchored approval.
    p.state == "open" && !p.reviews.iter().any(|(_, _, commit)| *commit == p.head_sha)
}

/// The whole scheduler. Rules:
/// - an issue is eligible when open, ungated, OWNER-authored (unless
///   `owner_only` is false), unassigned, unclaimed, not closed by an open PR
///   and not the live job of some seat;
/// - a PR is QA-eligible when open (drafts included), with no review anchored to
///   its head and not the live job of some seat;
/// - eligible items are served FIFO by number to idle seats of the matching
///   role, one job per seat, one action per item;
/// - an Unknown snapshot plans nothing (empty, not even `Nothing`).
pub fn plan(
    snapshot: &Snapshot,
    seats: &[SeatSlot],
    gate_label: &str,
    owner_only: bool,
    now: u64,
) -> Plan {
    if !snapshot.known {
        return Plan::default();
    }
    let (busy_issues, busy_prs) = live_jobs(seats, now);
    let closed_by_open_pr: BTreeSet<u64> = snapshot
        .prs
        .iter()
        .filter(|p| p.state == "open")
        .filter_map(|p| p.closes_issue)
        .collect();

    let mut actions = Vec::new();
    let mut touched_issues = BTreeSet::new();

    // Stale claims: a fenced claim nobody live is working and no PR closes.
    for i in &snapshot.issues {
        if let Some(fence) = &i.claim {
            if i.state == "open"
                && !busy_issues.contains(&i.number)
                && !closed_by_open_pr.contains(&i.number)
                && touched_issues.insert(i.number)
            {
                actions.push(Action::ReleaseClaim {
                    issue: i.number,
                    fence: fence.clone(),
                });
            }
        }
    }

    // One PR in flight per impl seat: a seat whose branch `impl<n>/…` is
    // still open (awaiting QA, changes, or merge) does not start the next
    // issue — the next issue would branch from a base that lacks its work.
    let seats_with_open_pr: BTreeSet<u8> = snapshot
        .prs
        .iter()
        .filter(|p| p.state == "open")
        .filter_map(|p| {
            p.head_ref
                .strip_prefix("impl")?
                .split('/')
                .next()?
                .parse::<u8>()
                .ok()
        })
        .collect();
    let mut impl_seats = idle_seats(seats, Role::Impl).filter(|s| !seats_with_open_pr.contains(s));

    let mut issues: Vec<&IssueView> = snapshot
        .issues
        .iter()
        .filter(|i| issue_eligible(i, gate_label, owner_only))
        .filter(|i| !closed_by_open_pr.contains(&i.number))
        .filter(|i| !busy_issues.contains(&i.number))
        .collect();
    issues.sort_by_key(|i| i.number);
    for i in issues {
        if !touched_issues.insert(i.number) {
            continue;
        }
        let Some(seat) = impl_seats.next() else { break };
        actions.push(Action::WakeImpl {
            seat,
            issue: i.number,
        });
    }

    // A seat id listed under two roles is a config error; never double-book it.
    let used: BTreeSet<u8> = actions.iter().filter_map(Action::seat).collect();
    let mut qa_seats = idle_seats(seats, Role::Qa).filter(|s| !used.contains(s));

    for p in snapshot.prs.iter().filter(|p| pr_approved_at_head(p)) {
        if !busy_prs.contains(&p.number) && touched_prs_pre(&actions, p.number) {
            actions.push(Action::FinishPr { pr: p.number });
        }
    }

    let mut prs: Vec<&PrView> = snapshot
        .prs
        .iter()
        .filter(|p| pr_qa_eligible(p))
        .filter(|p| !busy_prs.contains(&p.number))
        .collect();
    prs.sort_by_key(|p| p.number);
    let mut touched_prs = BTreeSet::new();
    for p in prs {
        if !touched_prs.insert(p.number) {
            continue;
        }
        let Some(seat) = qa_seats.next() else { break };
        actions.push(Action::WakeQa { seat, pr: p.number });
    }

    if actions.is_empty() {
        actions.push(Action::Nothing);
    }
    Plan { actions }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::JobRef;
    use proptest::prelude::*;

    const GATE: &str = "product-wip";

    fn issue(n: u64, labels: &[&str], assoc: &str) -> IssueView {
        IssueView {
            number: n,
            title: format!("issue {n}"),
            author_association: assoc.into(),
            labels: labels.iter().map(|s| s.to_string()).collect(),
            assignees: vec![],
            state: "open".into(),
            updated_at: String::new(),
            claim: None,
        }
    }

    fn pr(n: u64, closes: Option<u64>, draft: bool, reviewed_head: bool) -> PrView {
        let head = "a".repeat(40);
        PrView {
            number: n,
            head_sha: head.clone(),
            head_ref: format!("feat-{n}"),
            base_ref: "staging".into(),
            draft,
            state: "open".into(),
            closes_issue: closes,
            reviews: if reviewed_head {
                vec![("qa".into(), "APPROVED".into(), head)]
            } else {
                vec![]
            },
        }
    }

    fn snap(issues: Vec<IssueView>, prs: Vec<PrView>) -> Snapshot {
        Snapshot {
            issues,
            prs,
            fetched_at: 1,
            known: true,
        }
    }

    fn seat(seat: u8, role: Role, state: SeatState) -> SeatSlot {
        SeatSlot { seat, role, state }
    }

    fn job(issue: Option<u64>, pr: Option<u64>) -> JobRef {
        JobRef {
            role: Role::Impl,
            issue,
            pr,
        }
    }

    #[test]
    fn eligibility_rules() {
        let s = snap(
            vec![
                issue(1, &[GATE], "OWNER"),
                issue(2, &[], "NONE"),
                issue(3, &[], "OWNER"),
                issue(4, &[], "OWNER"),
                issue(5, &[CLAIM_LABEL], "OWNER"),
            ],
            vec![pr(10, Some(4), false, false)],
        );
        let seats = [
            seat(1, Role::Impl, SeatState::Idle),
            seat(2, Role::Qa, SeatState::Idle),
        ];
        let p = plan(&s, &seats, GATE, true, 100);
        assert_eq!(
            p.actions,
            vec![
                Action::WakeImpl { seat: 1, issue: 3 },
                Action::WakeQa { seat: 2, pr: 10 }
            ]
        );
        // owner_only=false admits #2 first (FIFO)
        let p = plan(&s, &seats, GATE, false, 100);
        assert_eq!(p.actions[0], Action::WakeImpl { seat: 1, issue: 2 });
    }

    #[test]
    fn busy_and_dead_seats_get_nothing_and_unknown_is_empty() {
        let s = snap(
            vec![issue(1, &[], "OWNER")],
            vec![pr(2, None, false, false)],
        );
        let busy = [
            seat(
                1,
                Role::Impl,
                SeatState::Working {
                    job: job(Some(9), None),
                    deadline: 200,
                },
            ),
            seat(
                2,
                Role::Impl,
                SeatState::Stalled {
                    job: job(Some(8), None),
                },
            ),
            seat(3, Role::Impl, SeatState::Gone),
            seat(
                4,
                Role::Qa,
                SeatState::Reported {
                    job: job(None, Some(7)),
                },
            ),
            seat(5, Role::Qa, SeatState::Unknown),
        ];
        assert_eq!(
            plan(&s, &busy, GATE, true, 100).actions,
            vec![Action::Nothing]
        );
        assert!(plan(&s, &busy, GATE, true, 100).is_empty());
        assert!(plan(
            &Snapshot::unknown(),
            &[seat(1, Role::Impl, SeatState::Idle)],
            GATE,
            true,
            1
        )
        .actions
        .is_empty());
        // head-anchored reviews are not QA work; drafts ARE (seats open drafts)
        let s = snap(vec![], vec![pr(3, None, false, true)]);
        assert!(plan(&s, &[seat(1, Role::Qa, SeatState::Idle)], GATE, true, 1).is_empty());
        let s = snap(vec![], vec![pr(2, None, true, false)]);
        assert_eq!(
            plan(&s, &[seat(1, Role::Qa, SeatState::Idle)], GATE, true, 1).actions,
            vec![Action::WakeQa { seat: 1, pr: 2 }]
        );
    }

    #[test]
    fn live_job_blocks_rewake_and_stale_claim_is_released() {
        let mut claimed = issue(1, &[CLAIM_LABEL], "OWNER");
        claimed.claim = Some(Fence("c1".into()));
        let s = snap(vec![claimed, issue(2, &[], "OWNER")], vec![]);
        // seat 1 is live on #1 and seat 2 idle: only #2 is served, no release
        let seats = [
            seat(
                1,
                Role::Impl,
                SeatState::Working {
                    job: job(Some(1), None),
                    deadline: 500,
                },
            ),
            seat(2, Role::Impl, SeatState::Idle),
        ];
        assert_eq!(
            plan(&s, &seats, GATE, true, 100).actions,
            vec![Action::WakeImpl { seat: 2, issue: 2 }]
        );
        // past the deadline the claim is stale → release with its fence
        let p = plan(&s, &seats, GATE, true, 501);
        assert_eq!(
            p.actions,
            vec![
                Action::ReleaseClaim {
                    issue: 1,
                    fence: Fence("c1".into())
                },
                Action::WakeImpl { seat: 2, issue: 2 }
            ]
        );
        // a live seat on #2 means #2 is not re-woken even though unclaimed
        let seats = [
            seat(
                1,
                Role::Impl,
                SeatState::Working {
                    job: job(Some(2), None),
                    deadline: 500,
                },
            ),
            seat(2, Role::Impl, SeatState::Idle),
        ];
        let p = plan(&s, &seats, GATE, true, 100);
        assert_eq!(
            p.actions,
            vec![Action::ReleaseClaim {
                issue: 1,
                fence: Fence("c1".into())
            }]
        );
    }

    // ---- contract: poll -> plan against the fake -------------------------

    #[test]
    fn poll_then_plan_against_fake_github_with_304_and_label_change() {
        use crate::fake_github::FakeGitHub;
        use crate::poll::Poller;
        const O: &str = "tbaums";
        const R: &str = "scratch";
        let fake = FakeGitHub::start();
        let ops = fake.token("fwf-ops[bot]", &[]);
        let alice = fake.token("alice", &[]);
        fake.seed_ref(O, R, "heads/staging", &FakeGitHub::sha("s"));
        fake.seed_ref(O, R, "heads/feat", &FakeGitHub::sha("f"));
        let gated = fake.seed_issue(O, R, "gated", O, &[GATE]);
        let foreign = fake.seed_issue(O, R, "not mine", "alice", &[]);
        let eligible = fake.seed_issue(O, R, "eligible", O, &[]);
        let pr = ureq::post(&format!("{}/repos/{O}/{R}/pulls", fake.base_url()))
            .set("Authorization", &format!("Bearer {alice}"))
            .send_string(
                &serde_json::json!({"title":"t","head":"feat","base":"staging"}).to_string(),
            )
            .unwrap()
            .into_json::<serde_json::Value>()
            .unwrap()["number"]
            .as_u64()
            .unwrap();
        let list = format!("/repos/{O}/{R}/issues?state=open");
        let pull = format!("/repos/{O}/{R}/pulls/{pr}");
        let reviews = format!("/repos/{O}/{R}/pulls/{pr}/reviews");
        let seats = [
            seat(1, Role::Impl, SeatState::Idle),
            seat(2, Role::Impl, SeatState::Idle),
            seat(3, Role::Qa, SeatState::Idle),
        ];
        let poller = Poller::new(fake.base_url(), &ops, O, R);

        let s1 = poller.poll(1).unwrap();
        let p1 = plan(&s1, &seats, GATE, true, 1);
        let wakes: Vec<&Action> = p1
            .actions
            .iter()
            .filter(|a| matches!(a, Action::WakeImpl { .. }))
            .collect();
        assert_eq!(
            wakes,
            vec![&Action::WakeImpl {
                seat: 1,
                issue: eligible
            }]
        );
        assert_eq!(
            p1.actions,
            vec![
                Action::WakeImpl {
                    seat: 1,
                    issue: eligible
                },
                Action::WakeQa { seat: 3, pr },
            ]
        );
        assert_eq!(poller.requests(), 3);
        assert_eq!(
            (
                fake.request_count(&list),
                fake.request_count(&pull),
                fake.request_count(&reviews)
            ),
            (1, 1, 1)
        );

        // unchanged: every URL is a 304, the plan is identical
        let s2 = poller.poll(2).unwrap();
        let p2 = plan(&s2, &seats, GATE, true, 2);
        assert_eq!(p2, p1);
        assert_eq!(s2.issues, s1.issues);
        assert_eq!((poller.requests(), poller.not_modified()), (6, 3));
        assert_eq!(
            (
                fake.request_count(&list),
                fake.request_count(&pull),
                fake.request_count(&reviews)
            ),
            (2, 2, 2)
        );

        // un-gate the gated one: the list changes (200), PR URLs still 304
        ureq::delete(&format!(
            "{}/repos/{O}/{R}/issues/{gated}/labels/{GATE}",
            fake.base_url()
        ))
        .set("Authorization", &format!("Bearer {ops}"))
        .call()
        .unwrap();
        let s3 = poller.poll(3).unwrap();
        let p3 = plan(&s3, &seats, GATE, true, 3);
        assert_eq!(
            p3.actions,
            vec![
                Action::WakeImpl {
                    seat: 1,
                    issue: gated
                },
                Action::WakeImpl {
                    seat: 2,
                    issue: eligible
                },
                Action::WakeQa { seat: 3, pr },
            ]
        );
        assert_eq!((poller.requests(), poller.not_modified()), (9, 5));
        assert_eq!(fake.request_count(&list), 3);
        // the non-owner issue never appears unless owner_only is off
        assert!(!p3.actions.iter().any(|a| a.issue() == Some(foreign)));
        let p3b = plan(&s3, &seats, GATE, false, 3);
        assert_eq!(
            p3b.actions
                .iter()
                .filter(|a| matches!(a, Action::WakeImpl { .. }))
                .count(),
            2
        );
        assert!(p3b.actions.iter().any(|a| a.issue() == Some(foreign)));
        // reads are reads: the fake logged no write from the poller
        assert!(fake
            .writes()
            .iter()
            .all(|w| w.actor != "fwf-ops[bot]" || w.method == "DELETE"));
    }

    // ---- properties ----------------------------------------------------

    fn arb_issue() -> impl Strategy<Value = IssueView> {
        (
            1u64..40,
            prop::collection::vec(
                prop_oneof![Just(GATE), Just(CLAIM_LABEL), Just("bug")],
                0..3,
            ),
            prop_oneof![Just("OWNER"), Just("NONE")],
            prop::collection::vec(Just("bob"), 0..2),
            prop_oneof![Just("open"), Just("closed")],
            prop::option::of(Just(Fence("f".into()))),
        )
            .prop_map(|(n, labels, assoc, assignees, state, claim)| IssueView {
                number: n,
                title: String::new(),
                author_association: assoc.into(),
                labels: labels.into_iter().map(String::from).collect(),
                assignees: assignees.into_iter().map(String::from).collect(),
                state: state.into(),
                updated_at: String::new(),
                claim,
            })
    }

    fn arb_pr() -> impl Strategy<Value = PrView> {
        (
            100u64..120,
            prop::option::of(1u64..40),
            any::<bool>(),
            any::<bool>(),
        )
            .prop_map(|(n, c, d, r)| pr(n, c, d, r))
    }

    fn arb_state() -> impl Strategy<Value = SeatState> {
        prop_oneof![
            Just(SeatState::Idle),
            (1u64..40, 0u64..200).prop_map(|(i, dl)| SeatState::Working {
                job: job(Some(i), None),
                deadline: dl
            }),
            (1u64..40).prop_map(|i| SeatState::Stalled {
                job: job(Some(i), None)
            }),
            Just(SeatState::Gone),
            Just(SeatState::Unknown),
        ]
    }

    fn arb_seats() -> impl Strategy<Value = Vec<SeatSlot>> {
        prop::collection::vec(
            (
                1u8..8,
                prop_oneof![Just(Role::Impl), Just(Role::Qa), Just(Role::Pm)],
                arb_state(),
            )
                .prop_map(|(seat, role, state)| SeatSlot { seat, role, state }),
            0..8,
        )
    }

    fn arb_snapshot() -> impl Strategy<Value = Snapshot> {
        (
            prop::collection::vec(arb_issue(), 0..12),
            prop::collection::vec(arb_pr(), 0..5),
            any::<bool>(),
        )
            .prop_map(|(mut issues, prs, known)| {
                // A snapshot is keyed by issue number (the poller reads each
                // issue once); two views of one number is not a real input.
                let mut seen = BTreeSet::new();
                issues.retain(|i| seen.insert(i.number));
                Snapshot {
                    issues,
                    prs,
                    fetched_at: 1,
                    known,
                }
            })
    }

    proptest! {
        #[test]
        fn never_two_actions_for_one_issue_or_seat(
            s in arb_snapshot(), seats in arb_seats(), owner_only in any::<bool>(), now in 0u64..200
        ) {
            let p = plan(&s, &seats, GATE, owner_only, now);
            let mut issues = BTreeSet::new();
            let mut used_seats = BTreeSet::new();
            let mut prs = BTreeSet::new();
            for a in &p.actions {
                if let Some(i) = a.issue() {
                    prop_assert!(issues.insert(i), "issue {i} twice in {:?}", p.actions);
                }
                if let Some(st) = a.seat() {
                    prop_assert!(used_seats.insert(st), "seat {st} twice in {:?}", p.actions);
                }
                if let Action::WakeQa { pr, .. } = a {
                    prop_assert!(prs.insert(*pr), "pr {pr} twice");
                }
            }
        }

        #[test]
        fn non_idle_seats_never_receive_work(
            s in arb_snapshot(), seats in arb_seats(), now in 0u64..200
        ) {
            let p = plan(&s, &seats, GATE, true, now);
            for a in &p.actions {
                if let Some(st) = a.seat() {
                    let idle = seats.iter().any(|x| x.seat == st && x.state == SeatState::Idle);
                    prop_assert!(idle, "seat {st} got {a:?} but is not Idle");
                    let busy = seats.iter().any(|x| x.seat == st && x.state != SeatState::Idle);
                    prop_assert!(!busy, "seat {st} has a non-idle slot but got {a:?}");
                }
            }
        }

        #[test]
        fn eligible_issues_are_served_in_ascending_order(
            s in arb_snapshot(), seats in arb_seats(), owner_only in any::<bool>(), now in 0u64..200
        ) {
            let p = plan(&s, &seats, GATE, owner_only, now);
            let woken: Vec<u64> = p.actions.iter().filter_map(|a| match a {
                Action::WakeImpl { issue, .. } => Some(*issue),
                _ => None,
            }).collect();
            prop_assert!(woken.windows(2).all(|w| w[0] < w[1]), "{woken:?}");
            // and every eligible issue smaller than the last woken one was woken
            if let Some(&last) = woken.last() {
                let closed: BTreeSet<u64> = s.prs.iter().filter_map(|p| p.closes_issue).collect();
                let (busy, _) = live_jobs(&seats, now);
                for i in &s.issues {
                    if i.number < last && issue_eligible(i, GATE, owner_only)
                        && !closed.contains(&i.number) && !busy.contains(&i.number)
                    {
                        prop_assert!(woken.contains(&i.number), "skipped eligible #{}", i.number);
                    }
                }
            }
        }

        #[test]
        fn unknown_snapshot_plans_nothing(seats in arb_seats(), now in 0u64..200) {
            prop_assert!(plan(&Snapshot::unknown(), &seats, GATE, true, now).actions.is_empty());
        }

        #[test]
        fn every_woken_issue_is_eligible_and_known(
            s in arb_snapshot(), seats in arb_seats(), owner_only in any::<bool>(), now in 0u64..200
        ) {
            let p = plan(&s, &seats, GATE, owner_only, now);
            if !s.known {
                prop_assert!(p.actions.is_empty());
                return Ok(());
            }
            for a in &p.actions {
                if let Action::WakeImpl { issue, .. } = a {
                    prop_assert!(s.issues.iter().any(|i| i.number == *issue && issue_eligible(i, GATE, owner_only)));
                }
            }
        }
    }

    #[test]
    fn an_impl_seat_with_an_open_pr_is_not_woken_for_the_next_issue() {
        use crate::poll::{IssueView, PrView};
        let issue = |n: u64| IssueView {
            number: n,
            title: format!("i{n}"),
            author_association: "OWNER".into(),
            labels: vec![],
            assignees: vec![],
            state: "open".into(),
            updated_at: String::new(),
            claim: None,
        };
        let snap = Snapshot {
            issues: vec![issue(1), issue(2)],
            prs: vec![PrView {
                number: 10,
                head_sha: "a".repeat(40),
                head_ref: "impl1/issue-1-x".into(),
                base_ref: "staging".into(),
                draft: false,
                state: "open".into(),
                closes_issue: Some(1),
                reviews: vec![],
            }],
            fetched_at: 0,
            known: true,
        };
        let seats = vec![
            SeatSlot {
                seat: 1,
                role: Role::Impl,
                state: SeatState::Idle,
            },
            SeatSlot {
                seat: 1,
                role: Role::Qa,
                state: SeatState::Idle,
            },
        ];
        let p = plan(&snap, &seats, "product-wip", true, 0);
        assert!(
            !p.actions
                .iter()
                .any(|a| matches!(a, Action::WakeImpl { .. })),
            "{:?}",
            p.actions
        );
        // The QA seat still gets the open PR.
        assert!(
            p.actions
                .iter()
                .any(|a| matches!(a, Action::WakeQa { pr: 10, .. })),
            "{:?}",
            p.actions
        );
    }

    #[test]
    fn an_approved_at_head_pr_is_finished_not_re_reviewed() {
        use crate::poll::PrView;
        let head = "b".repeat(40);
        let pr = |reviews: Vec<(String, String, String)>| PrView {
            number: 11,
            head_sha: head.clone(),
            head_ref: "impl1/issue-1".into(),
            base_ref: "staging".into(),
            draft: true,
            state: "open".into(),
            closes_issue: Some(1),
            reviews,
        };
        let seats = vec![SeatSlot {
            seat: 1,
            role: Role::Qa,
            state: SeatState::Idle,
        }];
        let snap = Snapshot {
            issues: vec![],
            prs: vec![pr(vec![(
                "fwf-qa[bot]".into(),
                "APPROVED".into(),
                head.clone(),
            )])],
            fetched_at: 0,
            known: true,
        };
        let p = plan(&snap, &seats, GATE, true, 0);
        assert_eq!(p.actions, vec![Action::FinishPr { pr: 11 }]);
        // Approval by the author App, or at an old head, is not an approval.
        for reviews in [
            vec![(
                "fwf-impl[bot]".to_string(),
                "APPROVED".to_string(),
                head.clone(),
            )],
            vec![(
                "fwf-qa[bot]".to_string(),
                "APPROVED".to_string(),
                "c".repeat(40),
            )],
        ] {
            let snap = Snapshot {
                issues: vec![],
                prs: vec![pr(reviews)],
                fetched_at: 0,
                known: true,
            };
            let p = plan(&snap, &seats, GATE, true, 0);
            assert!(
                !p.actions
                    .iter()
                    .any(|a| matches!(a, Action::FinishPr { .. })),
                "{:?}",
                p.actions
            );
        }
    }
}
