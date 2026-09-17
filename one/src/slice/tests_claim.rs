//! #667 — the claim a seat is still holding, from the slice's side.
//!
//! Two shapes of the same bug: a seat the record says is Working or Stalled on
//! an issue was re-dispatched to that same issue, and the re-dispatch wrote
//! `Ready` over the live claim. Split from `tests.rs` to keep both files
//! inside the 1,000-line rule (T-30).

use super::tests::{advance, cfg_for, floor, git, ok, N};
use super::*;
use crate::log::Kind;
use crate::types::{IssueState, JobRef, Role, SeatState};
use std::sync::atomic::Ordering;

/// #667, transom #1383 and fwf #669 (2026-09-16): the record said a seat was
/// holding the issue, and every tick offered it again anyway — the recheck
/// planned over a `SeatSlot` someone had hardcoded `Idle`. The stall shape and
/// the bare supervisor-restart shape are the same bug, so both are here: what
/// the second process reads is the record, and the record says the seat is on
/// it.
#[test]
fn a_seat_the_record_still_holds_is_never_re_dispatched_to_its_own_issue() {
    let floor = std::env::temp_dir().join(format!(
        "fwfd-slice-held-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&floor);
    std::fs::create_dir_all(&floor).unwrap();
    let mut cfg = cfg_for(1383, 1);
    cfg.run_log = floor.join("run.jsonl");
    let snap = Snapshot {
        issues: vec![crate::poll::IssueView {
            number: 1383,
            title: "the ticket a seat is already building".into(),
            author_association: "OWNER".into(),
            labels: vec![],
            assignees: vec![],
            state: "open".into(),
            updated_at: String::new(),
            claim: None,
        }],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    // an empty record: the first dispatch is exactly as it was
    assert_eq!(recheck(&snap, &cfg, &ok(1383), 100), Ok(1));

    let job = JobRef {
        role: Role::Impl,
        issue: Some(1383),
        pr: None,
    };
    let fence = crate::types::Fence("f".repeat(40));
    let mut log = Log::open(&cfg.run_log).unwrap();
    let mut append = |k| crate::slice::record(&mut log, "tbaums/transom", k).unwrap();
    append(Kind::Issue {
        issue: 1383,
        to: IssueState::Claimed {
            seat: 1,
            fence: fence.clone(),
        },
    });
    append(Kind::Seat {
        seat: 1,
        role: Role::Impl,
        to: SeatState::Working {
            job: job.clone(),
            deadline: 9_000,
        },
        tokens_in: None,
        tokens_out: None,
    });

    // the supervisor restarts here: a fresh SliceConfig over the same record
    let restarted = SliceConfig {
        run_log: cfg.run_log.clone(),
        ..cfg_for(1383, 1)
    };
    let e = recheck(&snap, &restarted, &ok(1383), 100).unwrap_err();
    assert!(e.contains("seat 1 cannot take #1383"), "{e}");
    // nothing was written over it: the claim the running seat holds is still
    // the record's to prove
    let claimed = |p: &Path| crate::log::claimed_issues(&crate::log::read_all(p).unwrap());
    assert_eq!(
        claimed(&cfg.run_log).get(&1383),
        Some(&(1, fence.clone())),
        "a re-dispatch that refuses writes no Ready"
    );

    // the same after the wait gives up: Stalled is not "free to re-dispatch"
    append(Kind::Seat {
        seat: 1,
        role: Role::Impl,
        to: SeatState::Stalled { job: job.clone() },
        tokens_in: None,
        tokens_out: None,
    });
    assert!(recheck(&snap, &restarted, &ok(1383), 100).is_err());
    assert_eq!(claimed(&cfg.run_log).get(&1383), Some(&(1, fence)));

    // and once the cycle reports, the seat is free again — nothing writes an
    // `Idle` event, so this is the mapping that keeps the floor moving
    append(Kind::Seat {
        seat: 1,
        role: Role::Impl,
        to: SeatState::Reported { job },
        tokens_in: None,
        tokens_out: None,
    });
    assert_eq!(recheck(&snap, &restarted, &ok(1383), 100), Ok(1));
    let _ = std::fs::remove_dir_all(&floor);
}

/// The other half of #667: what the cycle says to the record when it does get
/// there. `Ready` is a release — `claimed_issues` reads it as one — so a cycle
/// re-entering a claim this floor still holds must not write it, or the
/// re-claim can no longer prove the ref upstream is ours and every later tick
/// refuses with "does not own it".
#[test]
fn re_entering_this_floors_own_live_claim_writes_no_ready_and_reuses_the_fence() {
    let (root, url, work, _wt) = floor();
    let fence_sha = advance(&work, &url, "later.txt");
    // the mirror clones a default branch; the floor harness only publishes
    // `staging`, so give this throwaway upstream one to land on
    git(&work, &["push", "-q", &url, "HEAD:refs/heads/main"]);
    let m = crate::mirror::Mirror::init(&root.join("mirror-clone"), &url).unwrap();
    let base = Sha::parse(&fence_sha).unwrap();
    let fence = m.create_claim_ref(1383, &base, "").unwrap();
    let held = (1u8, fence.clone());
    let upstream = m.upstream_claim_ref(1383, "").unwrap();
    assert_eq!(
        upstream.as_ref().map(|s| s.as_str()),
        Some(fence.0.as_str())
    );

    // the record owns it and upstream still stands at that fence: a re-entry
    assert!(super::reentering_claim(Some(&held), upstream.as_ref()));
    // a fresh cycle: nothing in the record, or no ref upstream
    assert!(!super::reentering_claim(None, upstream.as_ref()));
    assert!(!super::reentering_claim(Some(&held), None));
    // a stale record — upstream moved on — is a fresh claim too, and the
    // `Ready` that cycle writes is its own
    let other = Sha::parse(&"b".repeat(40)).unwrap();
    assert!(!super::reentering_claim(Some(&held), Some(&other)));

    // and `claim` adopts that very fence rather than refusing it (#602)
    let run_log = root.join("run.jsonl");
    let mut log = Log::open(&run_log).unwrap();
    let mut cfg = cfg_for(1383, 1);
    cfg.run_log = run_log.clone();
    crate::slice::record(
        &mut log,
        "o/r",
        Kind::Issue {
            issue: 1383,
            to: IssueState::Claimed {
                seat: 1,
                fence: fence.clone(),
            },
        },
    )
    .unwrap();
    assert_eq!(
        super::deliver::claim(&mut log, "o/r", &cfg, &m, &base, "").unwrap(),
        fence,
        "the floor's own fence, reused not refused"
    );
    // the record still says Claimed: no Ready was written over it
    let evs = crate::log::read_all(&run_log).unwrap();
    assert_eq!(crate::log::claimed_issues(&evs).get(&1383), Some(&held));
    let _ = std::fs::remove_dir_all(root);
}
