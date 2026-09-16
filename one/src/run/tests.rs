//! The run loop's tests: what the record makes ineligible, the meter stamp,
//! and the two candidate lists the spec cycle plans from. Split out of
//! `run.rs` to keep both files inside the 1,000-line rule (T-30).

use super::*;
use crate::log::{Event, Kind};
use crate::poll::{IssueView, Snapshot};
use crate::sched::plan;
use crate::types::IssueState;

/// #630: what makes an issue claimable is the `Ready` event `fwf ungate`
/// writes — the same pair the delegated un-gate writes — and the fast-track
/// bypass is said in the record once, not once per tick.
#[test]
fn the_record_is_what_makes_an_issue_claimable() {
    let mut evs = vec![Event {
        ts: 1,
        repo: "o/r".into(),
        kind: Kind::Issue {
            issue: 10,
            to: IssueState::Gated,
        },
    }];
    assert!(reviewed_issues(&evs).is_empty(), "a gate is not a sign-off");
    evs.extend(crate::triage::ungate_events("o/r", 10, "tbaums", 5));
    assert_eq!(
        reviewed_issues(&evs).into_iter().collect::<Vec<_>>(),
        vec![10]
    );
    assert!(fast_track_noted(&evs).is_empty());
    evs.push(Event {
        ts: 6,
        repo: "o/r".into(),
        kind: Kind::Note {
            text: crate::sched::fast_track_note(11),
        },
    });
    assert_eq!(
        fast_track_noted(&evs).into_iter().collect::<Vec<_>>(),
        vec![11]
    );
    assert!(!reviewed_issues(&evs).contains(&11));
}

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
        plan(&snap, &seats, true, &crate::sched::all_reviewed(&snap), 10)
            .actions
            .first(),
        Some(&Action::WakeImpl {
            seat: 1,
            issue: 583
        })
    );
    let owed = unpushed_issues(&evs);
    assert!(owed.contains(&583));
    snap.issues.retain(|i| !owed.contains(&i.number));
    let actions = plan(&snap, &seats, true, &crate::sched::all_reviewed(&snap), 10).actions;
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
            issue(15, &["product-wip", "tracking", "discovery"], false),
            issue(16, &["product-wip"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let skip = skip_labels();
    let f = ReviewFilter::all_gated("product-wip", &skip);
    let mut evs: Vec<Event> = vec![];
    assert_eq!(
        gv_gated_candidates(&snap, &f, &gv_verdicts(&evs)),
        vec![10, 11, 16],
        "every gated, unparked, unjudged issue — oldest first"
    );
    assert!(
        pm_candidates(&snap, &f, &gv_verdicts(&evs), &specced_issues(&evs)).is_empty(),
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
        gv_gated_candidates(&snap, &f, &judged),
        vec![16],
        "a judged issue is never re-triaged, ready or not"
    );
    assert_eq!(
        pm_candidates(&snap, &f, &judged, &specced_issues(&evs)),
        vec![11],
        "only the ready one; #10 waits for a human edit"
    );
    // and once PM has written the spec, nobody is offered it again
    evs.push(note(crate::spec::spec_note(11, 900, false, 2)));
    assert!(pm_candidates(&snap, &f, &gv_verdicts(&evs), &specced_issues(&evs)).is_empty());
}

/// #652, fwf floor 2026-09-15: a floor allow-listed to a single ticket woke
/// GV and then PM on transom's #1371 — `discovery`-labelled, parked by its
/// owner, not on the list — because this cycle read neither the skip labels
/// nor the allow-list. A skip label parks a gated issue under either scope;
/// the allow-list narrows the rest only when the manifest opts in.
#[test]
fn the_spec_cycle_honours_skip_labels_always_and_the_allow_list_when_scoped() {
    let snap = Snapshot {
        issues: vec![
            issue(1123, &["product-wip", "needs-human"], false),
            // the #1371 shape: parked as `discovery`, and off the list
            issue(1371, &["product-wip", "discovery"], false),
            issue(1381, &["product-wip"], false),
            issue(1400, &["product-wip"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let mut skip = skip_labels();
    skip.push("discovery".into());
    let none: BTreeMap<u64, bool> = BTreeMap::new();
    let ready: BTreeMap<u64, bool> = snap.issues.iter().map(|i| (i.number, true)).collect();
    let specced = std::collections::BTreeSet::new();

    // (2) default scope: every gated issue no skip label parks, list or no list
    let all = ReviewFilter {
        gate_label: "product-wip",
        skip_labels: &skip,
        scope: ReviewScope::AllGated,
        allow_issues: &[1381],
    };
    assert_eq!(
        gv_gated_candidates(&snap, &all, &none),
        vec![1381, 1400],
        "#629's default is preserved: an off-list ticket is still reviewed"
    );
    // (3) opt-in scope: the allow-list decides, for GV and for PM alike
    let scoped = ReviewFilter {
        scope: ReviewScope::AllowList,
        ..all
    };
    assert_eq!(gv_gated_candidates(&snap, &scoped, &none), vec![1381]);
    assert_eq!(
        pm_candidates(&snap, &scoped, &ready, &specced),
        vec![1381],
        "a skip label added between GV's verdict and PM's wake still blocks it"
    );
    // an empty allow-list means unrestricted here, as it does on the impl path
    let unrestricted = ReviewFilter {
        allow_issues: &[],
        ..scoped
    };
    assert_eq!(
        gv_gated_candidates(&snap, &unrestricted, &none),
        vec![1381, 1400]
    );
    // (1) and under no scope is a parked ticket ever woken
    for f in [&all, &scoped, &unrestricted] {
        for n in [1123, 1371] {
            assert!(
                !gv_gated_candidates(&snap, f, &none).contains(&n)
                    && !pm_candidates(&snap, f, &ready, &specced).contains(&n),
                "#{n} is parked by a skip label and was offered anyway"
            );
        }
    }
    // each skipped issue is named once, with the first matching label
    let seen = std::collections::BTreeSet::new();
    assert_eq!(
        gated_skips(&snap, &scoped, &seen),
        vec![
            (1123, SkipReason::Label("needs-human".into())),
            (1371, SkipReason::Label("discovery".into())),
            (1400, SkipReason::NotAllowListed),
        ]
    );
    assert_eq!(
        gated_skips(&snap, &all, &seen),
        vec![
            (1123, SkipReason::Label("needs-human".into())),
            (1371, SkipReason::Label("discovery".into())),
        ],
        "nothing is `not in allow-list` under the default scope"
    );
}

/// The reason is said once, not once per tick: an operator needs to know why
/// a gated ticket is sitting there, and a line every minute is how that gets
/// tuned out. The dedup is the run log's seen-set, as triage's is.
#[test]
fn a_skipped_gated_issue_is_named_once_and_not_again_next_tick() {
    let why = SkipReason::Label("discovery".into());
    let evs = vec![note(skip_note(1371, &why))];
    assert_eq!(
        skip_noted(&evs).into_iter().collect::<Vec<_>>(),
        vec![1371],
        "{}",
        skip_note(1371, &why)
    );
    let snap = Snapshot {
        issues: vec![
            issue(1371, &["product-wip", "discovery"], false),
            issue(1372, &["product-wip", "idea"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    let mut skip = skip_labels();
    skip.push("discovery".into());
    let f = ReviewFilter::all_gated("product-wip", &skip);
    assert_eq!(
        gated_skips(&snap, &f, &skip_noted(&evs)),
        vec![(1372, SkipReason::Label("idea".into()))],
        "only the one the record has not named yet"
    );
    assert!(skip_note(1371, &SkipReason::NotAllowListed).contains("not in allow-list"));
}

/// The same, through the loop's own writer: two ticks over an unchanged
/// snapshot leave one note per skipped issue in `run.jsonl`, naming it and
/// the reason.
#[test]
fn the_loop_writes_one_skip_note_per_issue_however_many_ticks_run() {
    let dir = std::env::temp_dir().join(format!("fwfd-skipnote-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let _ = std::fs::remove_file(&run_log);
    let cfg = RunConfig {
        run_log: run_log.clone(),
        skip_labels: skip_labels(),
        allow_issues: vec![1381],
        review_scope: ReviewScope::AllowList,
        ..test_config()
    };
    let snap = Snapshot {
        issues: vec![
            issue(1371, &["product-wip", "needs-human"], false),
            issue(1381, &["product-wip"], false),
            issue(1400, &["product-wip"], false),
        ],
        prs: vec![],
        fetched_at: 0,
        known: true,
    };
    note_gated_skips(&cfg, &snap);
    note_gated_skips(&cfg, &snap);
    let notes: Vec<String> = crate::log::read_all(&run_log)
        .unwrap()
        .into_iter()
        .filter_map(|e| match e.kind {
            Kind::Note { text } if text.starts_with(SKIP_NOTE_PREFIX) => Some(text),
            _ => None,
        })
        .collect();
    assert_eq!(
        notes,
        vec![
            skip_note(1371, &SkipReason::Label("needs-human".into())),
            skip_note(1400, &SkipReason::NotAllowListed),
        ],
        "one line each, and nothing about the allow-listed #1381"
    );
    let _ = std::fs::remove_file(&run_log);
}

/// A `RunConfig` with nothing in it that matters: the fields a test cares
/// about are the ones it overrides.
fn test_config() -> RunConfig {
    RunConfig {
        owner: "tbaums".into(),
        repo: "transom".into(),
        base_branch: "staging".into(),
        gate_label: "product-wip".into(),
        floor_dir: PathBuf::new(),
        mirror_dir: PathBuf::new(),
        run_log: PathBuf::new(),
        impl_seats: vec![],
        qa_seats: vec![],
        seat_expect_cmd: "claude".into(),
        interval: Duration::from_secs(60),
        job_timeout: Duration::from_secs(60),
        once: true,
        prompts_dir: PathBuf::new(),
        template: "dev".into(),
        allow_issues: vec![],
        skip_labels: vec![],
        triage_new: false,
        gv_seat: None,
        auto_spec: true,
        pm_seat: None,
        review_scope: ReviewScope::AllGated,
        delegate_ungate: None,
        park_at_weekly_pct: 85,
        rework_cap: 2,
        gate_suite: "fast".into(),
        gate_cmd: String::new(),
        gate_venue: "local".into(),
        gate_memory_gb: 8,
        gate_timeout: Duration::from_secs(60),
    }
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
    let skip = skip_labels();
    let f = ReviewFilter::all_gated("product-wip", &skip);
    assert!(gv_gated_candidates(&snap, &f, &judged).is_empty());
    assert!(pm_candidates(&snap, &f, &judged, &specced_issues(&evs)).is_empty());
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
    let f = ReviewFilter::all_gated("product-wip", &skip);
    let snap = poller.poll(10).unwrap();
    let evs = read();
    assert_eq!(gv_gated_candidates(&snap, &f, &gv_verdicts(&evs)), vec![n]);
    assert!(pm_candidates(&snap, &f, &gv_verdicts(&evs), &specced_issues(&evs)).is_empty());
    // GV says ready; `triage::run` writes exactly this note
    append(Kind::Note {
        text: crate::triage::ready_note(n),
    });

    // tick 2: GV is done with it, PM is not
    let snap = poller.poll(11).unwrap();
    let evs = read();
    assert!(gv_gated_candidates(&snap, &f, &gv_verdicts(&evs)).is_empty());
    assert_eq!(
        pm_candidates(&snap, &f, &gv_verdicts(&evs), &specced_issues(&evs)),
        vec![n]
    );
    append(Kind::Note {
        text: crate::spec::spec_note(n, 1200, false, 1),
    });

    // tick 3: nothing owed, and the ticket is still gated
    let snap = poller.poll(12).unwrap();
    let evs = read();
    assert!(gv_gated_candidates(&snap, &f, &gv_verdicts(&evs)).is_empty());
    assert!(pm_candidates(&snap, &f, &gv_verdicts(&evs), &specced_issues(&evs)).is_empty());
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
