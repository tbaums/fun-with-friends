//! #713 — QA is held to the spec: the supervisor reads it and injects it, a
//! missing spec fails closed, and an approval must carry the per-criterion
//! review.

use super::*;
use crate::fake_github::FakeGitHub;
use std::sync::atomic::{AtomicU32, Ordering};

const O: &str = "tbaums";
const R: &str = "fun-with-friends";
static N: AtomicU32 = AtomicU32::new(0);

const SPEC: &str = "## Problem\n\nQA never sees the spec.\n\n## Acceptance criteria\n\n1. The QA job carries the issue body.\n2. An approval without criteria is rejected.\n";

fn floor() -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "fwfd-qa-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn crit(criterion: &str, status: &str, evidence: &str) -> Criterion {
    Criterion {
        criterion: criterion.into(),
        status: status.into(),
        evidence: evidence.into(),
    }
}

/// The dev QA template, rendered the way `run` renders it.
fn rendered(spec: &str) -> String {
    let template = std::fs::read_to_string(crate::prompts::path(
        Path::new(crate::prompts::ROOT),
        "dev",
        "qa",
    ))
    .unwrap();
    render(
        &template,
        &Job {
            seat_no: 1,
            pr: 714,
            repo: "tbaums/fun-with-friends",
            branch: "impl1/issue-713-thin-slice",
            head: &"a".repeat(40),
            issue: 713,
            title: "QA never sees the spec",
            body: "Closes #713\n\nfwf-Provenance: fwf thin slice",
            base: "staging",
            check: "cargo test",
            deadline: "12:34",
            spec,
        },
    )
}

#[test]
fn the_spec_is_read_from_the_issue_and_injected_into_the_qa_job() {
    let fake = FakeGitHub::start();
    let tok = fake.token("fwf-qa[bot]", &[("issues", "read"), ("metadata", "read")]);
    let n = fake.seed_issue_with_body(O, R, "QA never sees the spec", SPEC, O, &[]);
    let fetched = issue_body(fake.base_url(), &tok, &format!("{O}/{R}"), n);
    assert_eq!(fetched.as_deref(), Ok(SPEC));

    // The local copy is there too, and older: GitHub's body wins.
    let f = floor();
    let stale = serde_json::json!({"verdict":"specced","title":"t","body":"an older spec"});
    std::fs::write(f.join(format!("verdict-spec-{n}.json")), stale.to_string()).unwrap();
    let spec = resolve_spec(n, fetched, &f).unwrap();
    assert_eq!(spec.source, SpecSource::Issue);

    let text = rendered(&spec_block(n, &spec));
    assert!(
        text.contains("2. An approval without criteria is rejected."),
        "{text}"
    );
    assert!(text.contains(&format!("Source: issue #{n} as it reads on GitHub")));
    assert!(!text.contains("an older spec"));
    // the PR body is still there, as the implementer's claim, not the spec
    assert!(text.contains("Closes #713"));
    // and the verdict shape the supervisor enforces is spelled out
    assert!(text.contains("\"criteria\":[{\"criterion\""), "{text}");
    assert!(
        !text.contains("{{"),
        "a placeholder reached the seat: {text}"
    );
    let _ = std::fs::remove_dir_all(f);
}

#[test]
fn the_local_spec_verdict_is_only_the_fallback_when_github_yields_nothing() {
    let fake = FakeGitHub::start();
    let tok = fake.token("fwf-qa[bot]", &[("issues", "read")]);
    // an issue with no body, and one that does not exist
    let empty = fake.seed_issue(O, R, "no body yet", O, &[]);
    let f = floor();
    for (n, fetched) in [
        (
            empty,
            issue_body(fake.base_url(), &tok, &format!("{O}/{R}"), empty),
        ),
        (
            999,
            issue_body(fake.base_url(), &tok, &format!("{O}/{R}"), 999),
        ),
    ] {
        let v = serde_json::json!({"verdict":"specced","title":"t","body":SPEC});
        std::fs::write(f.join(format!("verdict-spec-{n}.json")), v.to_string()).unwrap();
        let spec = resolve_spec(n, fetched, &f).unwrap();
        assert_eq!(spec.source, SpecSource::LocalVerdict);
        assert_eq!(spec.text, SPEC);
        assert!(spec_block(n, &spec).contains("local spec verdict"));
    }
    let _ = std::fs::remove_dir_all(f);
}

#[test]
fn no_spec_anywhere_fails_closed_and_says_why() {
    let fake = FakeGitHub::start();
    let tok = fake.token("fwf-qa[bot]", &[("issues", "read")]);
    let f = floor();
    // GitHub 404s and the floor has no verdict-spec file
    let fetched = issue_body(fake.base_url(), &tok, &format!("{O}/{R}"), 999);
    assert!(fetched.as_ref().unwrap_err().contains("404"), "{fetched:?}");
    let e = resolve_spec(999, fetched, &f).unwrap_err();
    assert!(e.0.contains("spec unavailable for #999"), "{}", e.0);
    assert!(e.0.contains("HTTP 404"), "{}", e.0);
    assert!(e.0.contains("not woken"), "{}", e.0);
    // an empty body with no fallback is the same refusal, named as such
    let empty = fake.seed_issue(O, R, "no body yet", O, &[]);
    let fetched = issue_body(fake.base_url(), &tok, &format!("{O}/{R}"), empty);
    let e = resolve_spec(empty, fetched, &f).unwrap_err();
    assert!(e.0.contains("empty body"), "{}", e.0);
    // a PR that closes no issue has nothing to be held to
    let e = resolve_spec(0, Ok(SPEC.into()), &f).unwrap_err();
    assert!(e.0.contains("closes no issue"), "{}", e.0);
    // an unreadable local verdict is no spec either
    std::fs::write(f.join("verdict-spec-999.json"), "{not json").unwrap();
    assert!(resolve_spec(999, Err("HTTP 502".into()), &f).is_err());
    let _ = std::fs::remove_dir_all(f);
}

#[test]
fn an_oversized_spec_is_cut_with_a_note() {
    let spec = Spec {
        text: "x".repeat(SPEC_MAX_CHARS + 500),
        source: SpecSource::Issue,
    };
    let b = spec_block(1, &spec);
    assert!(b.contains(&format!(
        "truncated at {SPEC_MAX_CHARS} of {} characters",
        SPEC_MAX_CHARS + 500
    )));
    assert!(b.chars().filter(|c| *c == 'x').count() == SPEC_MAX_CHARS);
    let small = Spec {
        text: SPEC.into(),
        source: SpecSource::Issue,
    };
    assert!(!spec_block(1, &small).contains("truncated"));
}

#[test]
fn an_approval_without_the_criteria_section_is_rejected() {
    let e = check_verdict(true, &[]).unwrap_err();
    assert!(e.contains("`criteria` list"), "{e}");
    // the same shape, as a seat would write it: parses, then is refused
    let v: Verdict = serde_json::from_str(&format!(
        "{{\"verdict\":\"reviewed\",\"head\":\"{}\",\"approve\":true,\"notes\":\"looks fine\"}}",
        "a".repeat(40)
    ))
    .unwrap();
    let Verdict::Reviewed {
        approve, criteria, ..
    } = v
    else {
        panic!("not a review")
    };
    assert!(check_verdict(approve, &criteria).is_err());
    // malformed entries are named, not guessed at
    for (bad, says) in [
        (crit("", "met", "test a"), "no `criterion`"),
        (crit("carries the body", "done", "test a"), "status `done`"),
        (crit("carries the body", "met", "  "), "no `evidence`"),
        (
            crit("carries the body", "not_met", "missing"),
            "a request for changes",
        ),
    ] {
        let list = [crit("rejects a bare approval", "met", "test b"), bad];
        let e = check_verdict(true, &list).unwrap_err();
        assert!(e.contains("criteria[1]") && e.contains(says), "{e}");
    }
}

#[test]
fn an_approval_with_the_criteria_section_is_accepted_and_posted_as_a_checklist() {
    let raw = serde_json::json!({
        "verdict": "reviewed",
        "head": "a".repeat(40),
        "approve": true,
        "notes": "both criteria hold",
        "criteria": [
            {"criterion": "The QA job carries the issue body.", "status": "met",
             "evidence": "qa::tests::the_spec_is_read_from_the_issue_and_injected_into_the_qa_job passes"},
            {"criterion": "Works on a real floor.", "status": "not_verifiable",
             "evidence": "needs a live floor; read qa::run's call order instead"}
        ]
    });
    let Verdict::Reviewed {
        approve, criteria, ..
    } = serde_json::from_value(raw).unwrap()
    else {
        panic!("not a review")
    };
    assert_eq!(check_verdict(approve, &criteria), Ok(()));
    let md = checklist(&criteria);
    assert!(md.starts_with("**Acceptance criteria**"));
    assert!(md.contains("- [x] The QA job carries the issue body. — **met**: qa::tests::"));
    assert!(md.contains("- [ ] Works on a real floor. — **not verifiable**: needs a live floor"));
}

#[test]
fn a_request_for_changes_still_needs_no_criteria() {
    assert_eq!(check_verdict(false, &[]), Ok(()));
    let unmet = [crit("carries the body", "not_met", "the body is the PR's")];
    assert_eq!(check_verdict(false, &unmet), Ok(()));
    assert!(checklist(&unmet).contains("- [ ] carries the body — **not met**"));
    assert_eq!(checklist(&[]), "");
    // a verdict written before #713 still parses, and round-trips unchanged
    let old = format!(
        "{{\"verdict\":\"reviewed\",\"head\":\"{}\",\"approve\":false,\"notes\":\"fix it\"}}",
        "b".repeat(40)
    );
    let v: Verdict = serde_json::from_str(&old).unwrap();
    assert_eq!(serde_json::to_string(&v).unwrap(), old);
}
