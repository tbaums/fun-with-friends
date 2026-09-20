//! #677 — whose CHANGES_REQUESTED the planner answers. Its own file so
//! `sched/tests.rs` stays inside the 1,000-line rule (T-30).

use super::tests::{issue, seat, snap};
use super::*;
use crate::poll::{PrView, CLAIM_LABEL};
use crate::types::{Fence, Role, SeatState};

/// #677, transom PR #1419: the operator posted a changes-requested review
/// asking for a rebase. GitHub let it dismiss QA's approval, so `merge_pr`
/// refused "no approval anchored to head" every tick — and the planner, which
/// only ever read `-qa[bot]`, planned nothing. The seat sat idle with a PR
/// nobody could move. The owner's login and the manifest's `reviewers` now
/// read exactly like QA's; a stranger's review still plans nothing.
#[test]
fn a_changes_requested_by_the_owner_or_a_named_reviewer_plans_a_rework() {
    let head = "d".repeat(40);
    let pr_by = |login: &str| PrView {
        number: 1419,
        head_sha: head.clone(),
        head_ref: "impl3/issue-1411-thin-slice".into(),
        base_ref: "staging".into(),
        draft: false,
        state: "open".into(),
        author: "fwf-impl[bot]".into(),
        closes_issue: Some(1411),
        reviews: vec![(
            login.to_string(),
            "CHANGES_REQUESTED".to_string(),
            head.clone(),
        )],
    };
    let seats = [
        seat(3, Role::Impl, SeatState::Idle),
        seat(3, Role::Qa, SeatState::Idle),
    ];
    let mut claimed = issue(1411, &[CLAIM_LABEL], "OWNER");
    claimed.claim = Some(Fence("f".repeat(40)));
    let rework = vec![Action::Rework {
        seat: 3,
        pr: 1419,
        issue: Some(1411),
    }];
    let humans = BTreeSet::from(["tbaums".to_string(), "a-colleague".to_string()]);
    let planned = |login: &str, humans: &BTreeSet<String>| {
        let s = snap(vec![claimed.clone()], vec![pr_by(login)]);
        plan(
            &s,
            &seats,
            true,
            &all_reviewed(&s),
            &BTreeSet::new(),
            humans,
            100,
        )
        .actions
    };
    // the repo owner, and anyone the manifest names beside them
    assert_eq!(planned("tbaums", &humans), rework);
    assert_eq!(planned("a-colleague", &humans), rework);
    // QA is unchanged, named or not
    assert_eq!(planned("fwf-qa[bot]", &BTreeSet::new()), rework);
    // and a login in neither set plans nothing new: not a rework, and not a
    // finish either — there is no approval at this head to act on.
    for a in planned("a-stranger", &humans) {
        assert!(
            matches!(a, Action::WakeQa { .. } | Action::Nothing),
            "a stranger's review planned {a:?}"
        );
    }
    assert!(!planned("a-stranger", &humans)
        .iter()
        .any(|a| matches!(a, Action::Rework { .. })));
    // the same review with nobody named is the same non-event
    assert!(!planned("tbaums", &BTreeSet::new())
        .iter()
        .any(|a| matches!(a, Action::Rework { .. })));
}

/// The shape #1419 actually had: QA approved at head, and *then* the operator
/// asked for changes at the same head. `merge::verdict` gives the refusal
/// precedence, so the merge was refused "no approval anchored to head" every
/// tick — while the planner, which preferred finishing, kept planning that
/// same merge and never a rework. The seat sat idle for hours.
#[test]
fn a_human_refusal_outranks_the_qa_approval_it_landed_on_top_of() {
    let head = "e".repeat(40);
    let with = |reviews: Vec<(&str, &str)>| PrView {
        number: 1419,
        head_sha: head.clone(),
        head_ref: "impl3/issue-1411-thin-slice".into(),
        base_ref: "staging".into(),
        draft: false,
        state: "open".into(),
        author: "fwf-impl[bot]".into(),
        closes_issue: Some(1411),
        reviews: reviews
            .into_iter()
            .map(|(who, what)| (who.to_string(), what.to_string(), head.clone()))
            .collect(),
    };
    let seats = [
        seat(3, Role::Impl, SeatState::Idle),
        seat(3, Role::Qa, SeatState::Idle),
    ];
    let mut claimed = issue(1411, &[CLAIM_LABEL], "OWNER");
    claimed.claim = Some(Fence("f".repeat(40)));
    let humans = BTreeSet::from(["tbaums".to_string()]);
    let actions = |pr: PrView, humans: &BTreeSet<String>| {
        let s = snap(vec![claimed.clone()], vec![pr]);
        plan(
            &s,
            &seats,
            true,
            &all_reviewed(&s),
            &BTreeSet::new(),
            humans,
            100,
        )
        .actions
    };
    let both = vec![("fwf-qa[bot]", "APPROVED"), ("tbaums", "CHANGES_REQUESTED")];
    assert_eq!(
        actions(with(both.clone()), &humans),
        vec![Action::Rework {
            seat: 3,
            pr: 1419,
            issue: Some(1411),
        }],
        "the human's refusal is the live verdict, as it is for merge_pr"
    );
    // With nobody named, that login is a stranger: the loop has no rework to
    // plan for it. Before #690 this planned the merge anyway — the comment
    // here read "the old behaviour: a merge that will be refused", and that is
    // precisely the tick-forever loop #690 is about, since `merge_pr` honours
    // a CHANGES_REQUESTED at head whoever left it. Planning nothing is the
    // honest answer: the refusal is real, and clearing it is the stranger's.
    assert_eq!(actions(with(both), &BTreeSet::new()), vec![Action::Nothing]);
    // and QA's own approval alone is still simply finished
    assert_eq!(
        actions(with(vec![("fwf-qa[bot]", "APPROVED")]), &humans),
        vec![Action::FinishPr { pr: 1419 }]
    );
}
