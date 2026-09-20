//! `merge_pr` against the fake GitHub, through the shim that models the
//! merge itself: every precondition, every refusal, and the record each
//! one leaves.
//!
//! Split out of `merge.rs` by the size ratchet (T-30), the same way
//! `sched/tests.rs` and `run/tests.rs` were: merge.rs is grandfathered at
//! 1,382 lines and may only shrink, and #690 has business in both halves.
//! A pure move — no test changed in it.

use super::shim::Shim;
use super::*;
use crate::fake_github::FakeGitHub;
use crate::log::read_all;
use std::path::PathBuf;

const O: &str = "tbaums";
const R: &str = "scratch";
const REPO: &str = "tbaums/scratch";
const IMPL: &str = "fwf-impl[bot]";
const QA: &str = "fwf-qa[bot]";
const OPS: &str = "fwf-ops[bot]";

/// One PR closing one claimed issue, ready for review, plus a log.
struct Rig {
    fake: FakeGitHub,
    shim: Shim,
    client: Client,
    impl_tok: String,
    qa_tok: String,
    pr: u64,
    issue: u64,
    head: String,
    fence: Fence,
    log: Log,
    log_path: PathBuf,
}

fn rig(name: &str, draft: bool) -> Rig {
    let fake = FakeGitHub::start();
    fake.add_repo(O, R);
    let shim = Shim::start(&fake);
    let impl_tok = fake.token(IMPL, &[]);
    let qa_tok = fake.token(QA, &[]);
    let ops_tok = fake.token(OPS, &[]);
    let a = FakeGitHub::sha("A");
    let b = FakeGitHub::sha("B");
    shim.add_commit(&a, &[]);
    shim.add_commit(&b, &[&a]);
    fake.seed_ref(O, R, "heads/staging", &a);
    fake.seed_ref(O, R, "heads/feat", &b);
    let issue = fake.seed_issue(O, R, "the work", "tbaums", &["claimed"]);
    let fence_sha = FakeGitHub::sha("claim");
    fake.seed_ref(O, R, &format!("claims/{issue}"), &fence_sha);
    let client = Client::new(shim.base_url(), &ops_tok);
    let seat = Client::new(shim.base_url(), &impl_tok);
    let r = seat
        .post(
            &format!("/repos/{REPO}/pulls"),
            &json!({
                "title": "do the work",
                "head": "feat",
                "base": "staging",
                "body": format!("Closes #{issue}"),
                "draft": draft,
            }),
        )
        .unwrap();
    assert_eq!(r.status, 201, "{}", r.body);
    let pr = r.body["number"].as_u64().unwrap();
    let dir = std::env::temp_dir().join(format!("fwfd-merge-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let log_path = dir.join("run.jsonl");
    let log = Log::open(&log_path).unwrap();
    Rig {
        fake,
        shim,
        client,
        impl_tok,
        qa_tok,
        pr,
        issue,
        head: b,
        fence: Fence(fence_sha),
        log,
        log_path,
    }
}

impl Rig {
    fn approve(&self, by: &str) {
        let tok = if by == QA {
            &self.qa_tok
        } else {
            &self.impl_tok
        };
        let c = Client::new(self.shim.base_url(), tok);
        let r = c
            .post(
                &format!("/repos/{REPO}/pulls/{}/reviews", self.pr),
                &json!({ "event": "APPROVE" }),
            )
            .unwrap();
        assert_eq!(r.status, 200, "{}", r.body);
    }
    fn events(&self) -> Vec<Event> {
        read_all(&self.log_path).unwrap()
    }
    fn refusals(&self) -> Vec<String> {
        self.events()
            .into_iter()
            .filter_map(|e| match e.kind {
                Kind::Refused { what, why } => Some(format!("{what}: {why}")),
                _ => None,
            })
            .collect()
    }
    fn merge(&mut self) -> Result<Sha, MergeError> {
        let fence = self.fence.clone();
        merge_pr(&self.client, REPO, self.pr, &fence, &mut self.log)
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        if let Some(d) = self.log_path.parent() {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

#[test]
fn happy_path_squash_merges_releases_claim_and_records() {
    let mut g = rig("happy", false);
    g.approve(QA);
    let sha = g.merge().unwrap();
    assert_eq!(
        sha.as_str(),
        FakeGitHub::sha(&format!("merge-{}-{}", g.pr, g.head))
    );

    // exactly one merge call, squash, anchored to the head, with the card
    let merges = g.shim.merges();
    assert_eq!(merges.len(), 1);
    let (n, body) = &merges[0];
    assert_eq!(*n, g.pr);
    assert_eq!(body["merge_method"], "squash");
    assert_eq!(body["sha"], g.head.as_str());
    let msg = body["commit_message"].as_str().unwrap();
    assert!(msg.contains(&format!("Closes #{}", g.issue)), "{msg}");
    assert!(msg.contains(&format!("fence={}", g.fence.0)), "{msg}");
    assert!(msg.contains(&format!("reviewer={QA}")), "{msg}");
    assert!(msg.contains(&format!("head={}", g.head)), "{msg}");

    // the claim ref is gone, released by exactly one DELETE under ops
    assert_eq!(g.fake.ref_sha(O, R, &format!("claims/{}", g.issue)), None);
    let deletes: Vec<_> = g
        .fake
        .writes()
        .into_iter()
        .filter(|w| w.method == "DELETE")
        .collect();
    assert_eq!(deletes.len(), 1, "{deletes:?}");
    assert_eq!(deletes[0].actor, OPS);
    assert!(deletes[0]
        .path
        .ends_with(&format!("/git/refs/claims/{}", g.issue)));

    // staging advanced to the merge sha; the PR is closed
    assert_eq!(g.fake.ref_sha(O, R, "heads/staging").unwrap(), sha.as_str());
    assert_eq!(g.fake.issue_json(O, R, g.pr).unwrap()["state"], "closed");

    // the record: a Note for the missing check-runs, then Merged, Shipped
    let evs = g.events();
    assert!(evs
        .iter()
        .any(|e| matches!(&e.kind, Kind::Note { text } if text.contains("no check-runs"))));
    assert!(evs.iter().any(|e| matches!(&e.kind,
        Kind::Pr { pr, issue, to: PrState::Merged { sha: s } } if *pr == g.pr && *issue == Some(g.issue) && *s == sha)));
    assert!(evs.iter().any(|e| matches!(&e.kind,
        Kind::Issue { issue, to: IssueState::Shipped { pr, sha: s } } if *issue == g.issue && *pr == g.pr && *s == sha)));
    assert!(g.refusals().is_empty());

    // a second merge of the same PR is refused: it is closed now
    assert!(matches!(
        g.merge(),
        Err(MergeError::Refused(Refusal::NotReady(_)))
    ));
    assert_eq!(g.shim.merges().len(), 1);
}

#[test]
fn draft_is_refused_before_anything_is_read_or_written() {
    let mut g = rig("draft", true);
    g.approve(QA);
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::NotReady(ref w)) if w.contains("draft")),
        "{e}"
    );
    assert!(g.shim.merges().is_empty());
    assert!(g
        .fake
        .ref_sha(O, R, &format!("claims/{}", g.issue))
        .is_some());
    let r = g.refusals();
    assert_eq!(r.len(), 1);
    assert!(r[0].starts_with(&format!("merge #{}", g.pr)), "{}", r[0]);
    assert!(r[0].contains("draft"));
}

#[test]
fn fence_mismatch_is_refused() {
    let mut g = rig("fence", false);
    g.approve(QA);
    g.fence = Fence(FakeGitHub::sha("someone-elses-claim"));
    let e = g.merge().unwrap_err();
    match e {
        MergeError::Refused(Refusal::FenceMismatch { expected, got }) => {
            assert_eq!(expected.0, FakeGitHub::sha("claim"));
            assert_eq!(got, g.fence);
        }
        other => panic!("{other}"),
    }
    assert!(g.shim.merges().is_empty());
    assert!(g.refusals()[0].contains("fence mismatch"));
}

#[test]
fn missing_claim_ref_is_refused() {
    let mut g = rig("noclaim", false);
    g.approve(QA);
    let r = g
        .client
        .delete(&format!("/repos/{REPO}/git/refs/claims/{}", g.issue))
        .unwrap();
    assert_eq!(r.status, 204);
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::NotReady(ref w)) if w.contains("no live claim")),
        "{e}"
    );
    assert!(g.shim.merges().is_empty());
}

#[test]
fn self_approval_never_counts() {
    let mut g = rig("selfapprove", false);
    // the fake refuses an author's APPROVE (422) — so inject one, as a
    // compromised or lying API would return it
    g.shim.inject_review(g.pr, IMPL, "APPROVED", &g.head);
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::NotApproved { ref head }) if head.as_str() == g.head),
        "{e}"
    );
    assert!(g.shim.merges().is_empty());
    assert!(g.refusals()[0].contains("no approval anchored"));
}

#[test]
fn no_review_at_all_is_not_approved() {
    let mut g = rig("noreview", false);
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::NotApproved { .. })),
        "{e}"
    );
}

#[test]
fn changes_requested_at_head_outranks_an_approval() {
    let mut g = rig("changes", false);
    g.approve(QA);
    // a second reviewer requests changes at the same head
    let tok = g.fake.token("fwf-pm[bot]", &[]);
    let c = Client::new(g.shim.base_url(), &tok);
    let r = c
        .post(
            &format!("/repos/{REPO}/pulls/{}/reviews", g.pr),
            &json!({ "event": "REQUEST_CHANGES", "body": "no" }),
        )
        .unwrap();
    assert_eq!(r.status, 200, "{}", r.body);
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::NotApproved { .. })),
        "{e}"
    );
    assert!(g.shim.merges().is_empty());
}

#[test]
fn approval_goes_stale_when_the_head_moves() {
    let mut g = rig("stale", false);
    g.approve(QA);
    let c = FakeGitHub::sha("C");
    g.shim.add_commit(&c, &[&g.head]);
    let seat = Client::new(g.shim.base_url(), &g.impl_tok);
    let r = seat
        .patch(
            &format!("/repos/{REPO}/pulls/{}", g.pr),
            &json!({ "head_sha": c }),
        )
        .unwrap();
    assert_eq!(r.status, 200, "{}", r.body);
    let e = g.merge().unwrap_err();
    match e {
        MergeError::Refused(Refusal::ApprovalStale {
            head,
            approved_head,
        }) => {
            assert_eq!(head.as_str(), c);
            assert_eq!(approved_head.as_str(), g.head);
        }
        other => panic!("{other}"),
    }
    assert!(g.shim.merges().is_empty());
    assert!(g.refusals()[0].contains("approval is for"));

    // re-approval at the new head restores mergeability
    g.approve(QA);
    let sha = g.merge().unwrap();
    assert_eq!(
        sha.as_str(),
        FakeGitHub::sha(&format!("merge-{}-{c}", g.pr))
    );
}

fn named_check_run(g: &Rig, name: &str, status: &str, conclusion: Option<&str>) {
    let r = g
        .client
        .post(
            &format!("/repos/{REPO}/check-runs"),
            &json!({
                "name": name,
                "head_sha": g.head,
                "status": status,
                "conclusion": conclusion,
            }),
        )
        .unwrap();
    assert_eq!(r.status, 201, "{}", r.body);
}

fn check_run(g: &Rig, status: &str, conclusion: Option<&str>) {
    named_check_run(g, "gate/fast", status, conclusion)
}

#[test]
fn failing_or_unfinished_check_run_is_refused() {
    let mut g = rig("checkfail", false);
    g.approve(QA);
    // the CI job that actually blocked PR #689, by name
    named_check_run(&g, "no file > 1000 lines", "completed", Some("failure"));
    let e = g.merge().unwrap_err();
    assert!(
        matches!(e, MergeError::Refused(Refusal::GateNotGreen { ref sha, .. }) if sha.as_str() == g.head),
        "{e}"
    );
    // #690: the refusal says which check-run, not just that no gate was
    // green. The operator used to have to go digging in the record for the
    // Note beside it to learn what to fix.
    assert_eq!(
        e.to_string(),
        format!(
            "refused: no green gate recorded for {}: check-run \"no file > 1000 lines\" is completed/failure",
            Sha::parse(&g.head).unwrap().short()
        ),
        "{e}"
    );
    // and that is the line the record shows, beside the unchanged Note
    let refusals = g.refusals();
    assert!(
        refusals
            .iter()
            .any(|r| r.contains("check-run \"no file > 1000 lines\" is completed/failure")),
        "{refusals:?}"
    );
    assert!(g.events().iter().any(|e| matches!(&e.kind,
        Kind::Note { text } if text == &format!(
            "merge #{}: check-run \"no file > 1000 lines\" is completed/failure", g.pr))));
    assert!(g.shim.merges().is_empty());
    assert!(g
        .fake
        .ref_sha(O, R, &format!("claims/{}", g.issue))
        .is_some());

    let mut g = rig("checkpending", false);
    g.approve(QA);
    check_run(&g, "in_progress", None);
    let e = g.merge().unwrap_err();
    assert!(matches!(
        e,
        MergeError::Refused(Refusal::GateNotGreen { .. })
    ));
    // a run still going says so too, with the null conclusion spelled out
    assert!(
        e.to_string()
            .ends_with("check-run \"gate/fast\" is in_progress/null"),
        "{e}"
    );
}

#[test]
fn green_check_run_merges_without_the_m1_note() {
    let mut g = rig("checkgreen", false);
    g.approve(QA);
    check_run(&g, "completed", Some("success"));
    g.merge().unwrap();
    assert_eq!(g.shim.merges().len(), 1);
    assert!(!g
        .events()
        .iter()
        .any(|e| matches!(&e.kind, Kind::Note { text } if text.contains("no check-runs"))));
}

#[test]
fn a_head_that_moves_under_the_merge_is_a_409_not_a_merge() {
    // The read→PUT window: the client sends `sha: <head it verified>`,
    // GitHub's own precondition. Simulate the race by moving the head
    // through the shim's pre-PATCH hook on the head branch is not
    // possible (the PUT is not a ref PATCH), so drive the shim's merge
    // route directly with a stale sha and assert the 409 is surfaced as
    // an Api error, never as success.
    let mut g = rig("race", false);
    g.approve(QA);
    let stale = FakeGitHub::sha("stale");
    let r = g
        .client
        .put(
            &format!("/repos/{REPO}/pulls/{}/merge", g.pr),
            &json!({ "merge_method": "squash", "sha": stale }),
        )
        .unwrap();
    assert_eq!(r.status, 409);
    assert!(g.shim.merges().is_empty());
    assert_eq!(g.fake.issue_json(O, R, g.pr).unwrap()["state"], "open");
    // and the real path still merges with the live head
    g.merge().unwrap();
    assert_eq!(g.shim.merges()[0].1["sha"], g.head.as_str());
}

#[test]
fn verdict_is_latest_per_login_and_ignores_the_author() {
    let h = Sha::parse(&FakeGitHub::sha("h")).unwrap();
    let old = FakeGitHub::sha("old");
    let rv = |login: &str, state: &str, commit: &str| json!({ "user": { "login": login }, "state": state, "commit_id": commit });
    // approve then request changes by the same login: latest wins
    assert_eq!(
        verdict_of(
            &[
                rv(QA, "APPROVED", h.as_str()),
                rv(QA, "CHANGES_REQUESTED", h.as_str())
            ],
            &h,
            IMPL
        ),
        Verdict::ChangesRequested { by: QA.into() }
    );
    // request changes then approve: latest wins
    assert_eq!(
        verdict_of(
            &[
                rv(QA, "CHANGES_REQUESTED", h.as_str()),
                rv(QA, "APPROVED", h.as_str())
            ],
            &h,
            IMPL
        ),
        Verdict::Approved { by: QA.into() }
    );
    // an author approval at head plus a dismissed qa approval at old head
    assert_eq!(
        verdict_of(
            &[rv(QA, "DISMISSED", &old), rv(IMPL, "APPROVED", h.as_str())],
            &h,
            IMPL
        ),
        Verdict::Stale {
            approved_head: Sha::parse(&old).unwrap()
        }
    );
    // a COMMENTED review is nothing
    assert_eq!(
        verdict_of(&[rv(QA, "COMMENTED", h.as_str())], &h, IMPL),
        Verdict::None
    );
}

#[test]
fn client_reports_status_as_a_value_and_transport_as_an_error() {
    let fake = FakeGitHub::start();
    fake.add_repo(O, R);
    let c = Client::new(fake.base_url(), "not-a-token");
    let r = c.get(&format!("/repos/{REPO}/pulls/1")).unwrap();
    assert_eq!(r.status, 401);
    let dead = Client::new("http://127.0.0.1:9", "x");
    assert!(matches!(dead.get("/x"), Err(HttpError::Transport(_))));
    assert!(matches!(
        c.send("HEAD", "/x", &Value::Null, &[]),
        Err(HttpError::UnsupportedMethod(_))
    ));
}
