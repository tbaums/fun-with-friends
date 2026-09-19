//! `fwf status`'s own tests: what the record and the snapshot make of a
//! floor, and the four screens' worth of lines it prints.
//!
//! Split out of `status.rs` to keep that file inside the 1,000-line rule
//! (T-30), the same way `sched/tests.rs` and `run/tests.rs` are.

use super::*;
use crate::poll::IssueView;
use crate::types::{Fence, IssueState, Sha};

fn open_issue(n: u64) -> IssueView {
    IssueView {
        number: n,
        title: format!("issue {n}"),
        author_association: "OWNER".into(),
        labels: vec![],
        assignees: vec![],
        state: "open".into(),
        updated_at: String::new(),
        claim: None,
    }
}

/// #588, transom 11:33 PDT: `refs/claims/1268` live and impl1 Working on it,
/// yet the issue carried no `claimed` label — so the poller never filled
/// `IssueView.claim`, and status called it `ready` with `claimed 0`.
#[test]
fn a_claim_in_the_record_is_claimed_even_when_the_snapshot_says_nothing() {
    let s = Snapshot {
        issues: vec![open_issue(1268), open_issue(1269)],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    assert!(
        s.issues.iter().all(|i| i.claim.is_none()),
        "the snapshot is the broken half of this bug"
    );
    let dir = std::env::temp_dir().join(format!("fwfd-status-claim-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    let render_now = |run_log: &Path| {
        render(&StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![],
            run_log,
            pidfile: Path::new("/nonexistent/run.pid"),
            now: 5,
            rework_cap: 2,
        })
    };
    // before any claim: both issues are the loop's to take
    let r = render_now(&run_log);
    assert!(r.contains("eligible 2 · gated 0 · claimed 0"), "{r}");
    assert!(r.contains("ready #1268"), "{r}");
    l.append(&issue_ev(
        2,
        1268,
        IssueState::Claimed {
            seat: 1,
            fence: Fence("7d39b3c4".to_string() + &"0".repeat(32)),
        },
    ))
    .unwrap();
    let r = render_now(&run_log);
    assert!(r.contains("eligible 1 · gated 0 · claimed 1"), "{r}");
    assert!(r.contains("claimed #1268 → impl1 (fence 7d39b3c4)"), "{r}");
    assert!(
        !r.contains("ready #1268"),
        "a claimed issue is not ready: {r}"
    );
    assert!(r.contains("ready #1269"), "{r}");
    // released again, it goes back on the queue
    l.append(&issue_ev(3, 1268, IssueState::Ready)).unwrap();
    let r = render_now(&run_log);
    assert!(r.contains("eligible 2 · gated 0 · claimed 0"), "{r}");
    assert!(r.contains("ready #1268"), "{r}");
    // an unreadable record degrades to "nothing claimed", never an error
    let r = render_now(Path::new("/nonexistent/run.jsonl"));
    assert!(r.contains("claimed 0"), "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// #588: every seat window the manifest defines is listed, gv and pm too.
#[test]
fn the_seat_list_is_whatever_the_manifest_defines() {
    let mut m = crate::manifest::Manifest::parse(crate::manifest::EXAMPLE).unwrap();
    assert_eq!(
        m.seats(),
        vec![("impl", 1), ("qa", 1), ("gv", 1), ("pm", 1)],
        "the example manifest names a gv and a pm model"
    );
    m.pairs = 2;
    m.models.remove("gv");
    assert_eq!(
        m.seats(),
        vec![("impl", 1), ("qa", 1), ("impl", 2), ("qa", 2), ("pm", 1)]
    );
    // …and they reach the screen as their own targets
    let targets: Vec<String> = m
        .seats()
        .iter()
        .map(|(r, n)| m.seat_target(r, *n))
        .collect();
    let s = Snapshot {
        issues: vec![],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let r = render(&StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: targets
            .iter()
            .map(|t| (t.clone(), "claude".into()))
            .collect(),
        run_log: Path::new("/nonexistent"),
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 5,
        rework_cap: 2,
    });
    for t in ["fwf-one:impl2", "fwf-one:qa2", "fwf-one:pm1"] {
        assert!(r.contains(t), "{t} missing from\n{r}");
    }
}

fn refused(ts: u64, what: &str, why: &str) -> log::Event {
    log::Event {
        ts,
        repo: "o/r".into(),
        kind: Kind::Refused {
            what: what.into(),
            why: why.into(),
        },
    }
}

fn issue_ev(ts: u64, issue: u64, to: IssueState) -> log::Event {
    log::Event {
        ts,
        repo: "o/r".into(),
        kind: Kind::Issue { issue, to },
    }
}

/// #602: work that is finished and unpushed is the operator's to clear.
/// It is not a refusal and not a stall — the seat did its job — so it
/// gets its own line, naming the branch and what would unblock it.
#[test]
fn a_refused_push_is_a_needs_you_line_naming_the_branch_and_the_permission() {
    let s = Snapshot {
        issues: vec![open_issue(583)],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let dir = std::env::temp_dir().join(format!("fwfd-status-push-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    let pending = log::PendingPush {
        issue: 583,
        seat: 1,
        branch: "impl1/issue-583-thin-slice".into(),
        head: "a".repeat(40),
        why: "[remote rejected] (refusing to allow a GitHub App to create or update workflow .github/workflows/ci.yml without `workflows` permission)".into(),
    };
    l.append(&log::Event {
        ts: 2,
        repo: "o/r".into(),
        kind: Kind::Note {
            text: pending.note(),
        },
    })
    .unwrap();
    let r = render(&StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: &run_log,
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 5,
        rework_cap: 2,
    });
    assert!(
        r.contains("#583 is implemented on impl1/issue-583-thin-slice"),
        "{r}"
    );
    assert!(r.contains("the push was refused"), "{r}");
    assert!(r.contains("`workflows: write`"), "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// #579: a refusal the loop repeats every tick has to stay visible — it
/// used to scroll out of "recent" and leave the floor looking busy.
#[test]
fn a_repeating_refusal_stays_in_needs_you_until_the_issue_moves() {
    let s = Snapshot {
        issues: vec![open_issue(574), open_issue(575)],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let why = "scheduler did not plan it: seat 1 cannot take #574";
    let mut evs = vec![refused(10, "#574", why)];
    let line = |evs: &[log::Event]| {
        stuck_refusals(&s, evs)
            .into_iter()
            .map(|(n, w, t)| format!("#{n} {t}× {w}"))
            .collect::<Vec<_>>()
    };
    assert_eq!(line(&evs), vec![format!("#574 1× {why}")]);
    // every tick refuses it again: still one line, with the count and the
    // newest reason
    evs.push(refused(70, "#574", why));
    evs.push(refused(130, "#574", "and again"));
    assert_eq!(line(&evs), vec!["#574 3× and again".to_string()]);
    // a claim after the refusal means the loop got past it
    let mut claimed = evs.clone();
    claimed.push(issue_ev(
        140,
        574,
        IssueState::Claimed {
            seat: 2,
            fence: Fence("f".repeat(40)),
        },
    ));
    assert!(line(&claimed).is_empty());
    // so does a ship, and a claim the snapshot still holds
    let mut shipped = evs.clone();
    shipped.push(issue_ev(
        140,
        574,
        IssueState::Shipped {
            pr: 581,
            sha: Sha::parse(&"b".repeat(40)).unwrap(),
        },
    ));
    assert!(line(&shipped).is_empty());
    let mut live_claim = s.clone();
    live_claim.issues[0].claim = Some(Fence("c".repeat(40)));
    assert!(stuck_refusals(&live_claim, &evs).is_empty());
    // a closed issue, and a refusal naming a PR rather than an issue, are
    // nobody's needs-you line
    let mut closed = s.clone();
    closed.issues[0].state = "closed".into();
    assert!(stuck_refusals(&closed, &evs).is_empty());
    assert!(stuck_refusals(&s, &[refused(10, "#1270", "QA seat stalled")]).is_empty());
    // the loop's own claim → refuse → release, all within one second, is
    // the shape this line is for: it does not count as having moved on
    let churn = vec![
        issue_ev(
            200,
            574,
            IssueState::Claimed {
                seat: 1,
                fence: Fence("f".repeat(40)),
            },
        ),
        refused(200, "#574", "seat worktree is dirty"),
        issue_ev(200, 574, IssueState::Ready),
    ];
    assert_eq!(
        line(&churn),
        vec!["#574 1× seat worktree is dirty".to_string()]
    );
    // an older claim does not clear a newer refusal
    let mut reclaimed = vec![issue_ev(
        5,
        574,
        IssueState::Claimed {
            seat: 1,
            fence: Fence("f".repeat(40)),
        },
    )];
    reclaimed.extend(evs.clone());
    assert_eq!(line(&reclaimed), vec!["#574 3× and again".to_string()]);
    // and it reaches the rendered page, once
    let dir = std::env::temp_dir().join(format!("fwfd-status-refused-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    for e in &evs {
        l.append(e).unwrap();
    }
    let r = render(&StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: &run_log,
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 200,
        rework_cap: 2,
    });
    let lines: Vec<&str> = r
        .lines()
        .filter(|l| l.contains("the loop refused it"))
        .collect();
    assert_eq!(lines.len(), 1, "{r}");
    assert!(
        lines[0].contains("#574 is still open but the loop refused it 3× in this record"),
        "{r}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn unknown_snapshot_renders_a_warning_and_nothing_else() {
    let s = Snapshot::unknown();
    let inp = StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: Path::new("/nonexistent"),
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 0,
        rework_cap: 2,
    };
    let r = render(&inp);
    assert!(r.starts_with("snapshot: UNKNOWN"));
    assert!(!r.contains("needs you"));
}

#[test]
fn needs_you_lists_gone_seats_gated_issues_and_approved_prs() {
    let s = Snapshot {
        issues: vec![
            IssueView {
                number: 1,
                title: "gated".into(),
                author_association: "OWNER".into(),
                labels: vec!["product-wip".into()],
                assignees: vec![],
                state: "open".into(),
                updated_at: String::new(),
                claim: None,
            },
            IssueView {
                number: 2,
                title: "ready".into(),
                author_association: "OWNER".into(),
                labels: vec![],
                assignees: vec![],
                state: "open".into(),
                updated_at: String::new(),
                claim: None,
            },
        ],
        prs: vec![PrView {
            number: 9,
            head_sha: "a".repeat(40),
            head_ref: "impl1/x".into(),
            base_ref: "staging".into(),
            draft: false,
            state: "open".into(),
            author: "fwf-impl[bot]".into(),
            closes_issue: Some(2),
            reviews: vec![("fwf-qa[bot]".into(), "APPROVED".into(), "a".repeat(40))],
        }],
        fetched_at: 1,
        known: true,
    };
    let inp = StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![("fwf-one:impl1".into(), "bash".into())],
        run_log: Path::new("/nonexistent"),
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 5,
        rework_cap: 2,
    };
    let r = render(&inp);
    assert!(!r.contains("rework cap"), "nothing is refused here");
    assert!(r.contains("GONE (bash)"));
    assert!(r.contains("ready #2"));
    assert!(r.contains("approved at head by fwf-qa[bot]"));
    assert!(r.contains("fwf merge --pr 9"));
    assert!(r.contains("un-gate the ones worth building"));
}

/// #576: a refused PR is the loop's work (it re-wakes the seat) until the
/// rounds in the record reach the cap; only then is it a human's problem.
#[test]
fn a_refused_pr_reaches_needs_you_only_at_the_rework_cap() {
    let head = "b".repeat(40);
    let s = Snapshot {
        issues: vec![],
        prs: vec![PrView {
            number: 1270,
            head_sha: head.clone(),
            head_ref: "impl1/issue-575-thin-slice".into(),
            base_ref: "staging".into(),
            draft: true,
            state: "open".into(),
            author: "fwf-impl[bot]".into(),
            closes_issue: Some(575),
            reviews: vec![(
                "fwf-qa[bot]".into(),
                "CHANGES_REQUESTED".into(),
                head.clone(),
            )],
        }],
        fetched_at: 1,
        known: true,
    };
    let dir = std::env::temp_dir().join(format!("fwfd-status-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    let inp = || StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: &run_log,
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 5,
        rework_cap: 2,
    };
    let wake = |n: u64| log::Event {
        ts: n,
        repo: "o/r".into(),
        kind: Kind::Seat {
            seat: 1,
            role: crate::types::Role::Impl,
            to: crate::types::SeatState::Working {
                job: crate::types::JobRef {
                    role: crate::types::Role::Impl,
                    issue: Some(575),
                    pr: Some(1270),
                },
                deadline: n + 10,
            },
            tokens_in: None,
            tokens_out: None,
        },
    };
    let r = render(&inp());
    assert!(r.contains("changes requested at head by fwf-qa[bot]"));
    assert!(!r.contains("rework cap"), "round 1 is the loop's to do");
    l.append(&wake(1)).unwrap();
    assert!(!render(&inp()).contains("rework cap"));
    l.append(&wake(2)).unwrap();
    let r = render(&inp());
    assert!(
        r.contains("PR #1270 hit the rework cap (2): close it or push a fix yourself"),
        "{r}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// #677: an approved PR GitHub will not merge used to leave no trace on
/// this screen — the operator had to read the run record to find out that
/// `merge #1419` was refused as not mergeable, three ticks running. The
/// PR's own line now carries the newest refusal and how often it happened,
/// beside the rework rounds the loop has spent answering it.
#[test]
fn a_pr_whose_merge_was_refused_says_so_on_its_own_line() {
    let head = "c".repeat(40);
    let s = Snapshot {
        issues: vec![],
        prs: vec![PrView {
            number: 1419,
            head_sha: head.clone(),
            head_ref: "impl3/issue-1411-thin-slice".into(),
            base_ref: "staging".into(),
            draft: false,
            state: "open".into(),
            author: "fwf-impl[bot]".into(),
            closes_issue: Some(1411),
            reviews: vec![("fwf-qa[bot]".into(), "APPROVED".into(), head.clone())],
        }],
        fetched_at: 1,
        known: true,
    };
    let dir = std::env::temp_dir().join(format!("fwfd-status-merge-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    let inp = || StatusInput {
        snapshot: &s,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: &run_log,
        pidfile: Path::new("/nonexistent/run.pid"),
        now: 5,
        rework_cap: 2,
    };
    assert!(
        !render(&inp()).contains("merge refused"),
        "nothing has been refused yet"
    );
    // what `merge_pr` records when the PUT comes back 405
    let why = "PUT pulls/1419/merge: HTTP 405: Pull Request is not mergeable";
    l.append(&refused(10, "merge #1419", why)).unwrap();
    l.append(&refused(70, "merge #1419", why)).unwrap();
    // and one belonging to another PR, which must not be counted here
    l.append(&refused(71, "merge #1420", "something else"))
        .unwrap();
    let r = render(&inp());
    assert!(r.contains(why), "the refusal text is missing from\n{r}");
    assert!(r.contains("merge refused ×2 (0 rework round(s))"), "{r}");
    // another PR's refusal is not counted into this one's line
    let line = r
        .lines()
        .find(|l| l.contains("merge refused"))
        .unwrap_or_default();
    assert!(!line.contains("something else"), "{line}");
    assert_eq!(
        r.lines().filter(|l| l.contains("merge refused")).count(),
        1,
        "{r}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// #675: over ssh the two questions are "is the floor moving?" and "is
/// there a loop at all?", and neither had an answer on this screen — the
/// operator read stdout instead, which is silent for the whole of a seat
/// wait, and restarted a healthy loop. Both answers are now the first two
/// lines, before anything that needs GitHub.
#[test]
fn the_first_two_lines_are_the_record_age_and_the_loop_pid() {
    let dir = std::env::temp_dir().join(format!("fwfd-status-pid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let pidfile = dir.join("run.pid");
    let s = Snapshot {
        issues: vec![],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let head = |now: u64| -> Vec<String> {
        render(&StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![],
            run_log: &run_log,
            pidfile: &pidfile,
            now,
            rework_cap: 2,
        })
        .lines()
        .take(2)
        .map(str::to_string)
        .collect()
    };
    // an empty record and no pidfile: both say so rather than guessing
    assert_eq!(head(500), vec!["record age: no events", "loop: no pidfile"]);

    let mut l = log::Log::open(&run_log).unwrap();
    l.append(&refused(100, "#574", "nothing")).unwrap();
    l.append(&refused(440, "#574", "nothing")).unwrap();
    assert_eq!(
        head(500)[0],
        "record age 60s",
        "the NEWEST event is the age"
    );

    // a live loop, then one that is gone: the pidfile alone cannot tell
    let mut live = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    std::fs::write(&pidfile, format!("{}\n", live.id())).unwrap();
    assert_eq!(head(500)[1], format!("loop: pid {} (alive)", live.id()));
    live.kill().unwrap();
    live.wait().unwrap();
    assert_eq!(head(500)[1], format!("loop: pid {} (missing)", live.id()));

    // an unknown snapshot still says only that: nothing below it is true
    let unknown = Snapshot::unknown();
    let r = render(&StatusInput {
        snapshot: &unknown,
        gate_label: "product-wip",
        owner_only: true,
        seats: vec![],
        run_log: &run_log,
        pidfile: &pidfile,
        now: 500,
        rework_cap: 2,
    });
    assert!(r.starts_with("snapshot: UNKNOWN"), "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}
/// #676: the leak was invisible — `fwf status` showed eight live seats and
/// four eligible issues while the loop planned onto one pair. A seat the
/// replay frees now says so on this screen, under the seats it belongs to.
#[test]
fn a_seat_freed_by_the_replay_says_so_under_seats() {
    let dir = std::env::temp_dir().join(format!("fwfd-status-ghost-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let run_log = dir.join("run.jsonl");
    let mut l = log::Log::open(&run_log).unwrap();
    let s = Snapshot {
        issues: vec![],
        prs: vec![],
        fetched_at: 1,
        known: true,
    };
    let render_now = || {
        render(&StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![("fwf-one:impl1".into(), "claude".into())],
            run_log: &run_log,
            pidfile: Path::new("/nonexistent/run.pid"),
            now: 500,
            rework_cap: 2,
        })
    };
    let job = crate::types::JobRef {
        role: crate::types::Role::Impl,
        issue: Some(1412),
        pr: None,
    };
    let seat_ev = |ts: u64, to: crate::types::SeatState| log::Event {
        ts,
        repo: "o/r".into(),
        kind: Kind::Seat {
            seat: 1,
            role: crate::types::Role::Impl,
            to,
            tokens_in: None,
            tokens_out: None,
        },
    };
    l.append(&issue_ev(
        10,
        1412,
        IssueState::Claimed {
            seat: 1,
            fence: Fence("f".repeat(40)),
        },
    ))
    .unwrap();
    l.append(&seat_ev(
        20,
        crate::types::SeatState::Stalled { job: job.clone() },
    ))
    .unwrap();
    // while the claim is still this seat's, it is stalled, not a ghost
    assert!(!render_now().contains("ghost:"), "{}", render_now());

    l.append(&issue_ev(
        30,
        1412,
        IssueState::Shipped {
            pr: 1416,
            sha: Sha::parse(&"a".repeat(40)).unwrap(),
        },
    ))
    .unwrap();
    let r = render_now();
    let ghost: &str = r
        .lines()
        .find(|l| l.contains("ghost:"))
        .unwrap_or_else(|| panic!("no ghost line in\n{r}"));
    assert_eq!(
        ghost.trim(),
        "ghost: impl1 was stalled on #1412 (now resolved) — idle"
    );
    // it belongs to the seats block, above the issues it frees capacity for
    assert!(
        r.find("ghost:").unwrap() < r.find("issues\n").unwrap(),
        "{r}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
