//! #723 — the floor saw only the newest 30 open issues.
//!
//! `Poller::poll` read `issues?state=open` once, and GitHub serves 30 items a
//! page unless asked for more, PRs included. On the hazumi floor 29 of 64 open
//! issues were seen, and an un-gated, allow-listed issue older than the 30th
//! was never claimed. This is the poll → filter → plan contract with more open
//! issues than one default page holds.

use super::tests::seat;
use super::*;
use crate::fake_github::FakeGitHub;
use crate::poll::Poller;

const O: &str = "tbaums";
const R: &str = "scratch";

/// AC1: 35 open issues; only the oldest, #1, is signed off and allow-listed.
/// Through the real `Poller` and `fwf run`'s allow-list filter, the plan
/// wakes an impl seat on #1.
#[test]
fn the_oldest_of_35_open_issues_is_claimed_when_it_is_the_only_one_allowed() {
    let fake = FakeGitHub::start();
    let ops = fake.token("fwf-ops[bot]", &[]);
    for i in 1..=35 {
        assert_eq!(fake.seed_issue(O, R, &format!("issue {i}"), O, &[]), i);
    }
    let allow_issues = BTreeSet::from([1u64]);
    let signed_off = BTreeSet::from([1u64]);

    let mut snap = Poller::new(fake.base_url(), &ops, O, R).poll(1).unwrap();
    // The same narrowing `run.rs` applies to every tick's snapshot.
    snap.issues.retain(|i| allow_issues.contains(&i.number));
    snap.prs
        .retain(|p| p.closes_issue.is_some_and(|n| allow_issues.contains(&n)));
    assert_eq!(
        snap.issues.iter().map(|i| i.number).collect::<Vec<_>>(),
        vec![1],
        "the allow-listed issue is in the polled snapshot"
    );

    let seats = [seat(1, Role::Impl, SeatState::Idle)];
    let plan = plan_fifo(&snap, &seats, true, &signed_off, 1);
    assert_eq!(plan.actions, vec![Action::WakeImpl { seat: 1, issue: 1 }]);
}
