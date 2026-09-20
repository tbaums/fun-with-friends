//! #690 — the planner and the merge path reading one head the same way.
//!
//! Seen on the devbox floor on 2026-09-20, PR #689 at head `e5716177`: QA
//! approved at 02:02Z; CI's "no file > 1000 lines" job failed, so `merge_pr`
//! refused; at 02:07Z the operator posted a changes-requested at that same
//! head with the fix. From then on, every tick: `#689 approved but not merged:
//! refused: no approval anchored to head e5716177`. The planner still called
//! it approved — `pr_approved_at_head` matched ANY QA approval at the head,
//! whatever came after, and `pr_changes_requested_at_head` was gated on
//! `!pr_approved_at_head`, so the later refusal was invisible to it — while
//! `merge::verdict` took the latest review per login and refused. Neither a
//! merge nor a rework was possible; the operator had to dismiss the stale
//! approval through the API by hand.

use super::tests::{seat, snap};
use super::*;
use crate::poll::{PrView, Snapshot};
use crate::review::Verdict;
use crate::types::Sha;
use proptest::prelude::*;

const QA: &str = "fwf-qa[bot]";
const IMPL: &str = "fwf-impl[bot]";
const HUMAN: &str = "tbaums";
const STRANGER: &str = "a-passer-by";

fn head() -> String {
    "e".repeat(40)
}
fn older() -> String {
    "0".repeat(40)
}

fn pr_with(reviews: Vec<(String, String, String)>) -> PrView {
    PrView {
        number: 689,
        head_sha: head(),
        head_ref: "impl1/issue-688-thin-slice".into(),
        base_ref: "staging".into(),
        draft: false,
        state: "open".into(),
        author: IMPL.into(),
        closes_issue: Some(688),
        reviews,
    }
}

/// The same history as GitHub's raw reviews list, which is what `merge_pr`
/// reads. Both sides must land on the same verdict from it.
fn as_api_json(reviews: &[(String, String, String)]) -> Vec<serde_json::Value> {
    reviews
        .iter()
        .map(|(l, s, c)| serde_json::json!({ "user": { "login": l }, "state": s, "commit_id": c }))
        .collect()
}

fn arb_review() -> impl Strategy<Value = (String, String, String)> {
    (
        prop_oneof![Just(QA), Just(IMPL), Just(HUMAN), Just(STRANGER)],
        prop_oneof![
            Just("APPROVED"),
            Just("CHANGES_REQUESTED"),
            Just("DISMISSED"),
            Just("COMMENTED"),
        ],
        prop_oneof![Just(head()), Just(older())],
    )
        .prop_map(|(l, s, c)| (l.to_string(), s.to_string(), c))
}

proptest! {
    /// AC2. Over arbitrary review histories — any logins, any states, any
    /// commits, in any order — the planner's reading and `merge_pr`'s are the
    /// same verdict, and the planner's two predicates are exactly that verdict
    /// and never both at once. This is the property the loop deadlocked for
    /// want of: it had two answers and believed the wrong one.
    #[test]
    fn the_planner_and_the_merge_path_never_disagree_about_one_head(
        reviews in prop::collection::vec(arb_review(), 0..6)
    ) {
        let p = pr_with(reviews.clone());
        let humans = BTreeSet::from([HUMAN.to_string()]);
        let merge_says = crate::merge::verdict_of(
            &as_api_json(&reviews),
            &Sha::parse(&head()).unwrap(),
            IMPL,
        );
        prop_assert_eq!(
            &merge_says,
            &head_verdict(&p),
            "the raw-JSON reading and the PrView reading parted ways"
        );

        let approved = pr_approved_at_head(&p);
        let changes = pr_changes_requested_at_head(&p, &humans);
        prop_assert!(!(approved && changes), "both at once: {:?}", merge_says);
        // The deadlock itself: the planner may never call a PR approved while
        // the merge path would refuse it.
        prop_assert_eq!(
            approved,
            matches!(&merge_says, Verdict::Approved { by } if by.ends_with("-qa[bot]"))
        );
        prop_assert_eq!(
            changes,
            matches!(&merge_says, Verdict::ChangesRequested { by }
                if by.ends_with("-qa[bot]") || humans.contains(by))
        );
    }
}

/// AC3 and AC5, through the real poller against the fake: approve, then
/// refuse at the same head, and the loop must route the PR to its impl seat —
/// not try the merge again. Then the rework's push lands a new head with a
/// fresh approval, and it merges (#576's path, now through the one verdict).
#[test]
fn an_approval_overturned_at_the_same_head_plans_rework_and_a_new_head_merges() {
    use crate::fake_github::FakeGitHub;
    use crate::poll::Poller;
    const O: &str = "tbaums";
    const R: &str = "fun-with-friends";
    let fake = FakeGitHub::start();
    let ops = fake.token("fwf-ops[bot]", &[]);
    let implr = fake.token(IMPL, &[]);
    let qa = fake.token(QA, &[]);
    fake.seed_ref(O, R, "heads/staging", &FakeGitHub::sha("s"));
    let head1 = FakeGitHub::sha("h1");
    fake.seed_ref(O, R, "heads/impl1/issue-688-thin-slice", &head1);
    let issue = fake.seed_issue(O, R, "the stalled QA seat", O, &[]);
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
            "title": "the stalled QA seat",
            "head": "impl1/issue-688-thin-slice",
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
    let plan_now =
        |s: &Snapshot, now: u64| plan_fifo(s, &seats, true, &all_reviewed(s), now).actions;

    // QA approves at the head: the loop's job is to finish it.
    post(
        &qa,
        &format!("/repos/{O}/{R}/pulls/{pr}/reviews"),
        serde_json::json!({ "event": "APPROVE", "commit_id": head1 }),
    );
    let s = poller.poll(1).unwrap();
    assert_eq!(plan_now(&s, 1), vec![Action::FinishPr { pr }]);

    // …and then, at that same head, the operator asks for changes instead.
    post(
        &qa,
        &format!("/repos/{O}/{R}/pulls/{pr}/reviews"),
        serde_json::json!({
            "event": "REQUEST_CHANGES",
            "commit_id": head1,
            "body": "size-check fails: src/main.rs is 921 lines"
        }),
    );
    let s = poller.poll(2).unwrap();
    let actions = plan_now(&s, 2);
    assert_eq!(
        actions,
        vec![Action::Rework {
            seat: 1,
            pr,
            issue: Some(issue),
        }],
        "the overturned approval must route to rework, not another refused merge"
    );
    assert!(
        !actions.iter().any(|a| matches!(a, Action::FinishPr { .. })),
        "the loop planned the merge GitHub would refuse: {actions:?}"
    );

    // AC5: the seat pushes the fix. The head moves, which dismisses the
    // reviews anchored to the old one, and QA approves the new head.
    let head2 = FakeGitHub::sha("h2");
    ureq::patch(&format!(
        "{}/repos/{O}/{R}/git/refs/heads/impl1/issue-688-thin-slice",
        fake.base_url()
    ))
    .set("Authorization", &format!("Bearer {implr}"))
    .set("X-Fake-Expect-Sha", &head1)
    .send_string(&serde_json::json!({ "sha": head2 }).to_string())
    .unwrap();
    post(
        &qa,
        &format!("/repos/{O}/{R}/pulls/{pr}/reviews"),
        serde_json::json!({ "event": "APPROVE", "commit_id": head2 }),
    );
    let s = poller.poll(3).unwrap();
    assert_eq!(
        plan_now(&s, 3),
        vec![Action::FinishPr { pr }],
        "a fresh approval at the new head is a merge again"
    );
}

/// The flip-flop the other way, and the stranger. Neither is a new rule —
/// both are what the shared verdict already says — but they are the two the
/// wrappers are easiest to get wrong.
#[test]
fn the_last_word_at_the_head_decides_and_a_stranger_gets_no_rework() {
    let humans = BTreeSet::from([HUMAN.to_string()]);
    let rv = |who: &str, what: &str| (who.to_string(), what.to_string(), head());

    // refused, then approved again by the same login: approved
    let p = pr_with(vec![rv(QA, "CHANGES_REQUESTED"), rv(QA, "APPROVED")]);
    assert!(pr_approved_at_head(&p));
    assert!(!pr_changes_requested_at_head(&p, &humans));

    // a human's refusal on top of QA's approval: rework, as #677 has it
    let p = pr_with(vec![rv(QA, "APPROVED"), rv(HUMAN, "CHANGES_REQUESTED")]);
    assert!(!pr_approved_at_head(&p));
    assert!(pr_changes_requested_at_head(&p, &humans));

    // a stranger's refusal is neither: `merge_pr` honours it, so this loop
    // must not plan the merge, and it has no rework to offer for it either
    let p = pr_with(vec![rv(QA, "APPROVED"), rv(STRANGER, "CHANGES_REQUESTED")]);
    assert!(!pr_approved_at_head(&p));
    assert!(!pr_changes_requested_at_head(&p, &humans));
    let s = snap(vec![], vec![p]);
    let seats = [
        seat(1, Role::Impl, SeatState::Idle),
        seat(1, Role::Qa, SeatState::Idle),
    ];
    assert_eq!(
        plan(
            &s,
            &seats,
            true,
            &all_reviewed(&s),
            &BTreeSet::new(),
            &humans,
            1
        )
        .actions,
        vec![Action::Nothing],
        "planning a merge here is the tick-forever loop #690 is about"
    );
}
