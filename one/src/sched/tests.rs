//! The scheduler's tests: the deterministic rules, the poll → plan contract
//! against the fake GitHub, and the properties proptest checks. Split out of
//! `sched.rs` to keep both files inside the 1,000-line rule (T-30).

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
        .send_string(&serde_json::json!({"title":"t","head":"feat","base":"staging"}).to_string())
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

/// #576, as the loop meets it: a real review posted through the API, read
/// back by the real poller, must plan one action — not nothing.
#[test]
fn a_refused_pr_read_back_through_the_api_plans_one_rework() {
    use crate::fake_github::FakeGitHub;
    use crate::poll::Poller;
    const O: &str = "tbaums";
    const R: &str = "scratch";
    let fake = FakeGitHub::start();
    let ops = fake.token("fwf-ops[bot]", &[]);
    let implr = fake.token("fwf-impl[bot]", &[]);
    let qa = fake.token("fwf-qa[bot]", &[]);
    fake.seed_ref(O, R, "heads/staging", &FakeGitHub::sha("s"));
    let head = FakeGitHub::sha("h");
    fake.seed_ref(O, R, "heads/impl1/issue-575-thin-slice", &head);
    let issue = fake.seed_issue(O, R, "the stale worktree", O, &[]);
    let post = |tok: &str, path: &str, body: serde_json::Value| {
        ureq::post(&format!("{}{path}", fake.base_url()))
            .set("Authorization", &format!("Bearer {tok}"))
            .send_string(&body.to_string())
            .unwrap()
            .into_json::<serde_json::Value>()
            .unwrap()
    };
    let pr = post(
        &implr,
        &format!("/repos/{O}/{R}/pulls"),
        serde_json::json!({
            "title": "the stale worktree",
            "head": "impl1/issue-575-thin-slice",
            "base": "staging",
            "draft": true,
            "body": format!("Closes #{issue}")
        }),
    )["number"]
        .as_u64()
        .unwrap();
    let seats = [
        seat(1, Role::Impl, SeatState::Idle),
        seat(1, Role::Qa, SeatState::Idle),
    ];
    let poller = Poller::new(fake.base_url(), &ops, O, R);
    // before the review: QA's job, and the impl seat is held by its own PR
    let s = poller.poll(1).unwrap();
    assert_eq!(
        plan(&s, &seats, GATE, true, 1).actions,
        vec![Action::WakeQa { seat: 1, pr }]
    );
    // QA refuses it at that head
    post(
        &qa,
        &format!("/repos/{O}/{R}/pulls/{pr}/reviews"),
        serde_json::json!({"event":"REQUEST_CHANGES","commit_id":head,"body":"the base is two merges behind"}),
    );
    let s = poller.poll(2).unwrap();
    let p = plan(&s, &seats, GATE, true, 2);
    assert_eq!(
        p.actions,
        vec![Action::Rework {
            seat: 1,
            pr,
            issue: Some(issue),
        }],
        "a refused PR must plan one action, not park the floor"
    );
    assert!(!p.is_empty());
    // the review body the rework job quotes comes off the same endpoint
    let reviews = fake.reviews(O, R, pr);
    assert_eq!(
        crate::rework::latest_refusal(&serde_json::Value::Array(reviews), &head).as_deref(),
        Some("the base is two merges behind")
    );
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

/// PRs as the poller sees them, including the shapes rework needs: a
/// branch that names an impl seat, and a review at head that refused it.
fn arb_pr() -> impl Strategy<Value = PrView> {
    (
        100u64..120,
        prop::option::of(1u64..40),
        any::<bool>(),
        any::<bool>(),
        prop_oneof![Just(None), Just(Some(1u8)), Just(Some(2u8))],
        prop_oneof![
            Just(None),
            Just(Some("CHANGES_REQUESTED")),
            Just(Some("APPROVED"))
        ],
    )
        .prop_map(|(n, c, d, r, seat, at_head)| {
            let mut p = pr(n, c, d, r);
            if let Some(s) = seat {
                p.head_ref = format!("impl{s}/issue-{n}");
            }
            if let Some(state) = at_head {
                p.reviews
                    .push(("fwf-qa[bot]".into(), state.into(), p.head_sha.clone()));
            }
            p
        })
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
        .prop_map(|(mut issues, mut prs, known)| {
            // A snapshot is keyed by number (the poller reads each issue
            // and each PR once); two views of one number is not a real
            // input, and one action per item is asserted per number.
            let mut seen = BTreeSet::new();
            issues.retain(|i| seen.insert(i.number));
            let mut seen = BTreeSet::new();
            prs.retain(|p| seen.insert(p.number));
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
            let pr = match a {
                Action::WakeQa { pr, .. }
                | Action::FinishPr { pr }
                | Action::Rework { pr, .. } => Some(*pr),
                _ => None,
            };
            if let Some(pr) = pr {
                prop_assert!(prs.insert(pr), "pr {pr} twice in {:?}", p.actions);
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
    fn every_rework_is_a_refused_pr_on_the_seat_that_owns_its_branch(
        s in arb_snapshot(), seats in arb_seats(), owner_only in any::<bool>(), now in 0u64..200
    ) {
        let p = plan(&s, &seats, GATE, owner_only, now);
        for a in &p.actions {
            let Action::Rework { seat, pr, issue } = a else { continue };
            let v = s.prs.iter().find(|x| x.number == *pr).unwrap();
            prop_assert!(pr_changes_requested_at_head(v), "{v:?}");
            prop_assert_eq!(impl_seat_of(&v.head_ref), Some(*seat));
            prop_assert_eq!(*issue, v.closes_issue);
            // and never beside another action for the same PR
            prop_assert!(!p.actions.iter().any(|b| matches!(b,
                Action::WakeQa { pr: q, .. } | Action::FinishPr { pr: q } if q == pr)),
                "{:?}", p.actions);
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
fn a_refused_pr_is_rework_for_its_own_seat_not_a_parked_floor() {
    let head = "d".repeat(40);
    let mk = |reviews: Vec<(String, String, String)>, state: &str| PrView {
        number: 1270,
        head_sha: head.clone(),
        head_ref: "impl1/issue-575-thin-slice".into(),
        base_ref: "staging".into(),
        draft: false,
        state: state.into(),
        closes_issue: Some(575),
        reviews,
    };
    let refused = || {
        vec![(
            "fwf-qa[bot]".to_string(),
            "CHANGES_REQUESTED".to_string(),
            head.clone(),
        )]
    };
    let seats = [
        seat(1, Role::Impl, SeatState::Idle),
        seat(1, Role::Qa, SeatState::Idle),
    ];
    // #575 is open and claimed, its PR refused: before #576 this planned
    // nothing at all — the seat sat idle and the loop ticked 0 actions.
    let mut claimed = issue(575, &[CLAIM_LABEL], "OWNER");
    claimed.claim = Some(Fence("f".repeat(40)));
    let s = snap(vec![claimed], vec![mk(refused(), "open")]);
    assert_eq!(
        plan(&s, &seats, GATE, true, 100).actions,
        vec![Action::Rework {
            seat: 1,
            pr: 1270,
            issue: Some(575),
        }]
    );
    // The QA seat is not re-woken for it, and the claim is not released.
    // A seat already live on that PR (a rework in flight) is not re-woken.
    let busy = [
        seat(
            1,
            Role::Impl,
            SeatState::Working {
                job: JobRef {
                    role: Role::Impl,
                    issue: Some(575),
                    pr: Some(1270),
                },
                deadline: 500,
            },
        ),
        seat(1, Role::Qa, SeatState::Idle),
    ];
    assert_eq!(
        plan(&s, &busy, GATE, true, 100).actions,
        vec![Action::Nothing]
    );
    // Closed, approved-at-head, stale-head or foreign-reviewer: no rework.
    for (reviews, state) in [
        (refused(), "closed"),
        (
            vec![
                (
                    "fwf-qa[bot]".to_string(),
                    "CHANGES_REQUESTED".to_string(),
                    head.clone(),
                ),
                (
                    "fwf-qa[bot]".to_string(),
                    "APPROVED".to_string(),
                    head.clone(),
                ),
            ],
            "open",
        ),
        (
            vec![(
                "fwf-qa[bot]".to_string(),
                "CHANGES_REQUESTED".to_string(),
                "e".repeat(40),
            )],
            "open",
        ),
        (
            vec![(
                "someone".to_string(),
                "CHANGES_REQUESTED".to_string(),
                head.clone(),
            )],
            "open",
        ),
    ] {
        let s = snap(vec![], vec![mk(reviews, state)]);
        let p = plan(&s, &seats, GATE, true, 100);
        assert!(
            !p.actions.iter().any(|a| matches!(a, Action::Rework { .. })),
            "{:?}",
            p.actions
        );
    }
    // A branch that names no seat is nobody's rework (a human's PR).
    let mut human = mk(refused(), "open");
    human.head_ref = "jamie/fix".into();
    let s = snap(vec![], vec![human]);
    assert_eq!(
        plan(&s, &seats, GATE, true, 100).actions,
        vec![Action::Nothing]
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
