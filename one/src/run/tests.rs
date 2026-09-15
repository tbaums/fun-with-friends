//! The run loop's tests: what the record makes ineligible, the meter stamp,
//! and the two candidate lists the spec cycle plans from. Split out of
//! `run.rs` to keep both files inside the 1,000-line rule (T-30).

use super::*;
use crate::log::{Event, Kind};
use crate::poll::{IssueView, Snapshot};
use crate::types::IssueState;

fn issue(n: u64, labels: &[&str], claimed: bool) -> IssueView {
    IssueView {
        number: n,
        title: format!("issue {n}"),
        author_association: "OWNER".into(),
        labels: labels.iter().map(|s| s.to_string()).collect(),
        assignees: vec![],
        state: "open".into(),
        updated_at: String::new(),
        claim: if claimed {
            Some(crate::types::Fence("f".repeat(40)))
        } else {
            None
        },
    }
}

/// #602, fwf floor 2026-09-12: impl1 finished #583, its verdict was
/// valid, and the push upstream was rejected. The cycle was logged as a
/// failure, the issue went back to `ready`, and the next tick re-sliced
/// it — a 29-minute Opus cycle about to be run twice. The record is what
/// stops it: the work exists, only the write is owed.
#[test]
fn an_implemented_but_unpushed_issue_is_never_woken_a_second_time() {
    let pending = crate::log::PendingPush {
        issue: 583,
        seat: 1,
        branch: "impl1/issue-583-thin-slice".into(),
        head: "a".repeat(40),
        why: "[remote rejected] (refusing to allow a GitHub App to create or update workflow .github/workflows/ci.yml without `workflows` permission)".into(),
    };
    let evs = vec![Event {
        ts: 1,
        repo: "o/r".into(),
        kind: Kind::Note {
            text: pending.note(),
        },
    }];
    let mut snap = Snapshot {
        issues: vec![issue(583, &[], false), issue(584, &[], false)],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let seats = vec![SeatSlot {
        seat: 1,
        role: Role::Impl,
        state: SeatState::Idle,
    }];
    // the snapshot alone still offers the finished issue — GitHub has no
    // idea the verdict exists
    assert_eq!(
        plan(&snap, &seats, "product-wip", true, 10).actions.first(),
        Some(&Action::WakeImpl {
            seat: 1,
            issue: 583
        })
    );
    let owed = unpushed_issues(&evs);
    assert!(owed.contains(&583));
    snap.issues.retain(|i| !owed.contains(&i.number));
    let actions = plan(&snap, &seats, "product-wip", true, 10).actions;
    assert!(
        !actions.iter().any(|a| a.issue() == Some(583)),
        "#583 was planned again: {actions:?}"
    );
    // and the floor is not parked by it: the next issue takes the seat
    assert_eq!(
        actions.first(),
        Some(&Action::WakeImpl {
            seat: 1,
            issue: 584
        })
    );
}

#[test]
fn meter_age_parses_a_local_stamp_and_rejects_garbage() {
    let now = crate::seat::now();
    // Render `now - 600` as a local stamp with whichever `date` this is
    // (BSD `-r`, GNU `-d @`), so the test exercises the same fallback path
    // the brake uses on Linux runners.
    let then = (now - 600).to_string();
    let attempts: [Vec<String>; 2] = [
        vec!["-r".into(), then.clone()],
        vec!["-d".into(), format!("@{then}")],
    ];
    let stamp = attempts
        .iter()
        .find_map(|a| {
            let out = std::process::Command::new("date")
                .args(a)
                .arg("+%Y-%m-%d %H:%M:%S")
                .output()
                .ok()?;
            out.status
                .success()
                .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        })
        .expect("a date that renders epoch seconds as a local stamp");
    let age = meter_age_secs(&stamp, now).unwrap();
    assert!((595..=605).contains(&age), "{age}");
    assert_eq!(meter_age_secs("not a date", now), None);
}

fn skip_labels() -> Vec<String> {
    ["idea", "release-hold", "tracking", "needs-human"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

fn note(text: String) -> Event {
    Event {
        ts: 1,
        repo: "o/r".into(),
        kind: Kind::Note { text },
    }
}

/// #629: a ticket filed with the gate label — the operator's own
/// convention — was invisible to the loop, because the only in-loop GV
/// filter looked at *un-gated* issues. These two lists are the fix, and
/// they are the whole of the cycle's judgement.
#[test]
fn the_spec_cycle_offers_unjudged_gated_issues_then_the_ones_gv_called_ready() {
    let snap = Snapshot {
        issues: vec![
            issue(10, &["product-wip"], false),
            issue(11, &["product-wip"], false),
            // un-gated: triage_new's business, never this cycle's
            issue(12, &[], false),
            issue(13, &["product-wip", "idea"], false),
            issue(14, &["product-wip", "needs-human"], false),
            // parked by `tracking`, yet a discovery ticket is exactly what
            // PM turns into a proposal: never skipped here
            issue(15, &["product-wip", "tracking", "discovery"], false),
            issue(16, &["product-wip"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let skip = skip_labels();
    let mut evs: Vec<Event> = vec![];
    assert_eq!(
        gv_gated_candidates(&snap, "product-wip", &skip, &gv_verdicts(&evs)),
        vec![10, 11, 15, 16],
        "every gated, unparked, unjudged issue — oldest first"
    );
    assert!(
        pm_candidates(
            &snap,
            "product-wip",
            &skip,
            &gv_verdicts(&evs),
            &specced_issues(&evs)
        )
        .is_empty(),
        "PM waits for a GV verdict"
    );
    // GV gates #10 ("not ready") and judges #11 ready — the two shapes
    // `triage::run` records.
    evs.push(Event {
        ts: 2,
        repo: "o/r".into(),
        kind: Kind::Issue {
            issue: 10,
            to: IssueState::Gated,
        },
    });
    evs.push(note(crate::triage::ready_note(11)));
    let judged = gv_verdicts(&evs);
    assert_eq!(
        gv_gated_candidates(&snap, "product-wip", &skip, &judged),
        vec![15, 16],
        "a judged issue is never re-triaged, ready or not"
    );
    assert_eq!(
        pm_candidates(&snap, "product-wip", &skip, &judged, &specced_issues(&evs)),
        vec![11],
        "only the ready one; #10 waits for a human edit"
    );
    // and once PM has written the spec, nobody is offered it again
    evs.push(note(crate::spec::spec_note(11, 900, false, 2)));
    assert!(pm_candidates(
        &snap,
        "product-wip",
        &skip,
        &gv_verdicts(&evs),
        &specced_issues(&evs)
    )
    .is_empty());
}

/// `delegate_ungate = "name"`: the loop un-gates after the spec, and what
/// it leaves in the record is the same human act `fwf ungate` writes —
/// attributable, and enough to end the cycle for that issue.
#[test]
fn a_delegated_ungate_records_the_actor_and_ends_the_cycle() {
    let mut evs = vec![
        note(crate::triage::ready_note(11)),
        note(crate::spec::spec_note(11, 900, false, 0)),
    ];
    evs.extend(crate::triage::ungate_events("o/r", 11, "tbaums", 5));
    assert!(
        evs.iter()
            .any(|e| matches!(&e.kind, Kind::Human { actor, action, target }
            if actor == "tbaums" && action == "ungate" && target == "#11")),
        "the un-gate names who approved it: {evs:?}"
    );
    // the label is gone on GitHub, so the next poll's snapshot drops the
    // issue out of both halves of the cycle
    let snap = Snapshot {
        issues: vec![issue(11, &[], false)],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let judged = gv_verdicts(&evs);
    assert!(gv_gated_candidates(&snap, "product-wip", &skip_labels(), &judged).is_empty());
    assert!(pm_candidates(
        &snap,
        "product-wip",
        &skip_labels(),
        &judged,
        &specced_issues(&evs)
    )
    .is_empty());
}

/// The #629 walk, against a real (fake) GitHub: an operator files a gated
/// ticket and never types another verb. Tick one offers it to GV; GV's
/// verdict lands in `run.jsonl`; tick two offers it to PM; PM's spec lands;
/// tick three has nothing to do, and the issue is still gated — "specced,
/// awaiting un-gate".
#[test]
fn a_filed_gated_issue_walks_to_specced_awaiting_ungate_with_no_manual_verb() {
    use crate::fake_github::FakeGitHub;
    use crate::poll::Poller;
    const O: &str = "tbaums";
    const R: &str = "scratch";
    let fake = FakeGitHub::start();
    fake.add_repo(O, R);
    let tok = fake.token("fwf-ops[bot]", &[]);
    let n = fake.seed_issue(O, R, "the operator files a ticket", O, &["product-wip"]);
    let poller = Poller::new(fake.base_url(), &tok, O, R);
    let dir = std::env::temp_dir().join(format!("fwfd-autospec-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let _ = std::fs::remove_file(&run_log);
    let skip = skip_labels();
    let read = || crate::log::read_all(&run_log).unwrap_or_default();
    let append = |kind: Kind| {
        crate::log::Log::open(&run_log)
            .unwrap()
            .append(&Event {
                ts: 1,
                repo: format!("{O}/{R}"),
                kind,
            })
            .unwrap();
    };

    // tick 1: the gated ticket is GV's, and only GV's
    let snap = poller.poll(10).unwrap();
    let evs = read();
    assert_eq!(
        gv_gated_candidates(&snap, "product-wip", &skip, &gv_verdicts(&evs)),
        vec![n]
    );
    assert!(pm_candidates(
        &snap,
        "product-wip",
        &skip,
        &gv_verdicts(&evs),
        &specced_issues(&evs)
    )
    .is_empty());
    // GV says ready; `triage::run` writes exactly this note
    append(Kind::Note {
        text: crate::triage::ready_note(n),
    });

    // tick 2: GV is done with it, PM is not
    let snap = poller.poll(11).unwrap();
    let evs = read();
    assert!(gv_gated_candidates(&snap, "product-wip", &skip, &gv_verdicts(&evs)).is_empty());
    assert_eq!(
        pm_candidates(
            &snap,
            "product-wip",
            &skip,
            &gv_verdicts(&evs),
            &specced_issues(&evs)
        ),
        vec![n]
    );
    append(Kind::Note {
        text: crate::spec::spec_note(n, 1200, false, 1),
    });

    // tick 3: nothing owed, and the ticket is still gated
    let snap = poller.poll(12).unwrap();
    let evs = read();
    assert!(gv_gated_candidates(&snap, "product-wip", &skip, &gv_verdicts(&evs)).is_empty());
    assert!(pm_candidates(
        &snap,
        "product-wip",
        &skip,
        &gv_verdicts(&evs),
        &specced_issues(&evs)
    )
    .is_empty());
    let labels: Vec<String> = fake.issue_json(O, R, n).unwrap()["labels"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|l| l["name"].as_str().map(String::from))
        .collect();
    assert_eq!(labels, vec!["product-wip".to_string()], "gate untouched");
    assert!(
        fake.writes().is_empty(),
        "the walk is driven by the record, not by a hand-run verb: {:?}",
        fake.writes()
    );
    let _ = std::fs::remove_file(&run_log);
}

#[test]
fn triage_candidates_skip_gated_claimed_parked_and_already_judged() {
    // #374 is the shape that started #585: parked as an `idea`, and offered
    // to GV anyway because this filter never read the skip labels.
    let snap = Snapshot {
        issues: vec![
            issue(5, &[], false),
            issue(3, &["product-wip"], false),
            issue(4, &[], true),
            issue(2, &[], false),
            issue(9, &[], false),
            issue(374, &["idea"], false),
            issue(375, &["tracking", "product-wip"], false),
            issue(376, &["needs-human"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let skip: Vec<String> = ["idea", "release-hold", "tracking", "needs-human"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let evs = vec![
        Event {
            ts: 1,
            repo: "o/r".into(),
            kind: Kind::Issue {
                issue: 9,
                to: IssueState::Gated,
            },
        },
        Event {
            ts: 2,
            repo: "o/r".into(),
            kind: Kind::Note {
                text: "GV triage: #2 judged ready — awaiting the human un-gate".into(),
            },
        },
    ];
    let seen = triaged_issues(&evs);
    assert_eq!(seen.into_iter().collect::<Vec<_>>(), vec![2, 9]);
    let seen = triaged_issues(&evs);
    assert_eq!(
        triage_candidates(&snap, "product-wip", &skip, &seen),
        vec![5],
        "a parked ticket is not GV's to judge"
    );
    // #5 is only in because it carries no skip label: take the list away
    // and the parked ones come back (the default-off behaviour, unchanged).
    assert_eq!(
        triage_candidates(&snap, "product-wip", &[], &seen),
        vec![5, 374, 376]
    );
    // a skip label alone is enough, with or without the gate label
    assert_eq!(
        triage_candidates(&snap, "no-such-gate", &skip, &seen),
        vec![3, 5]
    );
}
