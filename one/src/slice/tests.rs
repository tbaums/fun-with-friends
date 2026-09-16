//! The slice's tests: the eligibility recheck the loop's plan is re-run
//! through, the claim/branch/PR contract, and the prompt's own guarantees.
//! Split out of `slice.rs` to keep both files inside the 1,000-line rule
//! (T-30).

use super::*;
use crate::sched::plan_fifo;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

static N: AtomicU32 = AtomicU32::new(0);

fn git(dir: &Path, args: &[&str]) -> String {
    let o = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=staging",
        ])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        o.status.success(),
        "git {args:?} in {}: {}{}",
        dir.display(),
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

/// A floor stand-in: a bare mirror with `staging` at one commit, a work
/// clone that can advance it (as a merge to staging would), and the seat
/// worktree `seats --up` would have cloned — at that first commit.
fn floor() -> (PathBuf, String, PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "fwfd-slice-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "--bare", "mirror.git"]);
    let url = format!("file://{}", root.join("mirror.git").display());
    let work = root.join("work");
    git(&root, &["init", "-q", "work"]);
    std::fs::write(work.join("README"), "one").unwrap();
    git(&work, &["add", "."]);
    git(&work, &["commit", "-q", "-m", "one"]);
    git(&work, &["push", "-q", &url, "HEAD:refs/heads/staging"]);
    git(
        &root,
        &["clone", "-q", "--branch", "staging", &url, "wt-impl1"],
    );
    (root.clone(), url, work, root.join("wt-impl1"))
}

/// Land another commit on the mirror's `staging` and return it as the fence
/// the supervisor would claim.
fn advance(work: &Path, url: &str, name: &str) -> String {
    std::fs::write(work.join(name), name).unwrap();
    git(work, &["add", "."]);
    git(work, &["commit", "-q", "-m", name]);
    git(work, &["push", "-q", url, "HEAD:refs/heads/staging"]);
    git(work, &["rev-parse", "HEAD"])
}

fn refusals(run_log: &Path) -> Vec<String> {
    crate::log::read_all(run_log)
        .unwrap()
        .into_iter()
        .filter_map(|ev| match ev.kind {
            Kind::Refused { what, why } if what == "#575" => Some(why),
            _ => None,
        })
        .collect()
}

#[test]
fn the_seat_worktree_is_realigned_to_the_fence_before_the_wake() {
    let (root, url, work, wt) = floor();
    let stale = git(&wt, &["rev-parse", "HEAD"]);
    // staging moves between `seats --up` and `fwf slice`
    let fence = advance(&work, &url, "later.txt");
    assert_ne!(stale, fence);
    let run_log = root.join("run.jsonl");
    let mut log = Log::open(&run_log).unwrap();
    align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, None).unwrap();
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), fence);
    assert!(refusals(&run_log).is_empty());
    // so the branch the seat then cuts is rooted at the fence, which is
    // what the original bug broke: merge-base(PR head, fence) == fence
    git(&wt, &["checkout", "-q", "-b", "impl1/issue-575-thin-slice"]);
    std::fs::write(wt.join("fix.txt"), "fix").unwrap();
    git(&wt, &["add", "."]);
    git(&wt, &["commit", "-q", "-m", "fix"]);
    assert_eq!(git(&wt, &["merge-base", "HEAD", &fence]), fence);
    // a second realign onto the same fence is a harmless no-op
    git(&wt, &["checkout", "-q", "--detach", "HEAD"]);
    align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, None).unwrap();
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), fence);
    // named, the target lands on that branch (the rework cycle's use), and
    // a name that is not a seat branch is refused before any checkout
    align_seat_worktree(
        &mut log,
        "o/r",
        575,
        &wt,
        &url,
        &fence,
        Some("impl1/rework"),
    )
    .unwrap();
    assert_eq!(
        git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]),
        "impl1/rework"
    );
    assert!(align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, Some("staging")).is_err());
    assert_eq!(
        git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]),
        "impl1/rework"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_dirty_seat_worktree_refuses_the_cycle_instead_of_cleaning_it() {
    let (root, url, work, wt) = floor();
    let before = git(&wt, &["rev-parse", "HEAD"]);
    let fence = advance(&work, &url, "later.txt");
    std::fs::write(wt.join("README"), "the seat scribbled here").unwrap();
    let run_log = root.join("run.jsonl");
    let mut log = Log::open(&run_log).unwrap();
    // the wake is never reached: the refusal is returned to `run_with`
    // before it renders the job text
    let e = align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, None).unwrap_err();
    assert!(e.0.contains("dirty"), "{}", e.0);
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), before);
    assert_eq!(refusals(&run_log).len(), 1);
    assert!(refusals(&run_log)[0].contains("dirty"));
    // untracked-only is dirty too; nothing is stashed or cleaned away
    git(&wt, &["checkout", "-q", "--", "README"]);
    std::fs::write(wt.join("scratch.txt"), "x").unwrap();
    assert!(align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, None).is_err());
    assert!(wt.join("scratch.txt").exists());
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), before);
    assert_eq!(refusals(&run_log).len(), 2);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_seat_that_was_never_brought_up_is_refused_not_panicked_on() {
    let (root, url, work, _wt) = floor();
    let fence = advance(&work, &url, "later.txt");
    let run_log = root.join("run.jsonl");
    let mut log = Log::open(&run_log).unwrap();
    let missing = root.join("wt-impl9");
    let e = align_seat_worktree(&mut log, "o/r", 575, &missing, &url, &fence, None).unwrap_err();
    assert!(e.0.contains("absent"), "{}", e.0);
    assert_eq!(refusals(&run_log).len(), 1);
    let _ = std::fs::remove_dir_all(root);
}

/// #630: the sign-off these fixtures are about.
fn ok(n: u64) -> std::collections::BTreeSet<u64> {
    std::collections::BTreeSet::from([n])
}

fn cfg_for(issue: u64, seat: u8) -> SliceConfig {
    SliceConfig {
        owner: "tbaums".into(),
        repo: "fun-with-friends".into(),
        issue,
        base_branch: "staging".into(),
        gate_label: "product-wip".into(),
        seat,
        seat_target: format!("fwf-one:impl{seat}"),
        seat_expect_cmd: "claude".into(),
        floor_dir: PathBuf::from("/tmp/floor"),
        mirror_dir: PathBuf::from("/tmp/floor/mirror"),
        job_template: PathBuf::from("job.md"),
        run_log: PathBuf::from("/tmp/floor/run.jsonl"),
        timeout: Duration::from_secs(60),
        dry_run: false,
        check_cmd: "cargo test".into(),
    }
}

/// #579: the recheck must ask about the seat the loop dispatched to. With a
/// hardcoded 1 it refused every issue whenever seat 1 was held — claim,
/// refuse, release, repeat, three ticks running on #574.
#[test]
fn the_recheck_plans_over_the_seat_the_loop_picked_not_seat_one() {
    let issue = crate::poll::IssueView {
        number: 574,
        title: "the dash is a board again".into(),
        author_association: "OWNER".into(),
        labels: vec![],
        assignees: vec![],
        state: "open".into(),
        updated_at: String::new(),
        claim: None,
    };
    // seat 1 is held by its own open floor PR; seat 2 is free
    let held = crate::poll::PrView {
        number: 581,
        head_sha: "a".repeat(40),
        head_ref: "impl1/issue-575-thin-slice".into(),
        base_ref: "staging".into(),
        draft: true,
        state: "open".into(),
        author: "fwf-impl[bot]".into(),
        closes_issue: Some(575),
        reviews: vec![],
    };
    let snap = Snapshot {
        issues: vec![issue],
        prs: vec![held],
        fetched_at: 1,
        known: true,
    };
    assert_eq!(recheck(&snap, &cfg_for(574, 2), &ok(574), 100), Ok(2));
    let e = recheck(&snap, &cfg_for(574, 1), &ok(574), 100).unwrap_err();
    assert!(e.contains("seat 1 cannot take #574"), "{e}");
    // the refusal still names what the scheduler saw, for the record
    assert!(e.contains("labels=[]") && e.contains("Nothing"), "{e}");
    // an issue the snapshot does not carry is refused, not woken
    let e = recheck(&snap, &cfg_for(999, 2), &ok(999), 100).unwrap_err();
    assert!(e.contains("issue not in the open set"), "{e}");
}

/// Tonight's shape, through the real poller: a legacy 0.x draft on
/// `impl1/…` that the floor did not author, and one eligible issue. The
/// loop plans the wake and the slice's recheck agrees with it, instead of
/// refusing "not eligible … plan was [Nothing]" every tick (#579).
#[test]
fn a_legacy_impl_branch_no_longer_makes_the_slice_refuse_what_run_planned() {
    use crate::fake_github::FakeGitHub;
    const O: &str = "tbaums";
    const R: &str = "fun-with-friends";
    let fake = FakeGitHub::start();
    let ops = fake.token("fwf-ops[bot]", &[]);
    let human = fake.token("tbaums", &[]);
    fake.seed_ref(O, R, "heads/staging", &FakeGitHub::sha("s"));
    fake.seed_ref(O, R, "heads/impl1/issue-473-old", &FakeGitHub::sha("old"));
    let issue = fake.seed_issue(O, R, "the dash is a board again", O, &[]);
    // #540: opened by a person in July, on the prefix the 0.x factory used
    let legacy = ureq::post(&format!("{}/repos/{O}/{R}/pulls", fake.base_url()))
        .set("Authorization", &format!("Bearer {human}"))
        .send_string(
            &serde_json::json!({"title":"0.x leftover","head":"impl1/issue-473-old","base":"staging","draft":true})
                .to_string(),
        )
        .unwrap()
        .into_json::<serde_json::Value>()
        .unwrap();
    assert_eq!(legacy["user"]["login"], "tbaums");
    let poller = Poller::new(fake.base_url(), &ops, O, R);
    let mut snap = poller.poll(1).unwrap();
    assert_eq!(snap.prs[0].author, "tbaums");
    let seats = [SeatSlot {
        seat: 1,
        role: Role::Impl,
        state: SeatState::Idle,
    }];
    // what `run` plans…
    assert!(
        plan_fifo(&snap, &seats, true, &crate::sched::all_reviewed(&snap), 1)
            .actions
            .contains(&Action::WakeImpl { seat: 1, issue }),
        "{:?}",
        plan_fifo(&snap, &seats, true, &crate::sched::all_reviewed(&snap), 1).actions
    );
    // …and what the slice makes of it, over the one issue it was given
    snap.issues.retain(|i| i.number == issue);
    assert_eq!(recheck(&snap, &cfg_for(issue, 1), &ok(issue), 1), Ok(1));
    // the floor's own PR on that seat still holds it
    snap.prs[0].author = "fwf-impl[bot]".into();
    assert!(recheck(&snap, &cfg_for(issue, 1), &ok(issue), 1).is_err());
}

/// #581 — two cycles of the same warm seat, one growing transcript, the
/// shape transom reported (7M → 22M → 58M → 95M tokens in and a dash that
/// read like a cumulative counter). What the run record stores for cycle 2
/// must be cycle 2's own requests, measured from its own wake.
#[test]
fn a_seats_second_cycle_is_not_charged_for_its_first() {
    let floor = std::env::temp_dir().join(format!(
        "fwfd-slice-cost-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&floor);
    std::fs::create_dir_all(&floor).unwrap();
    let mut cfg = cfg_for(574, 1);
    cfg.floor_dir = floor.clone();
    cfg.run_log = floor.join("run.jsonl");
    cfg.timeout = Duration::from_secs(1800);
    // the transcript `cost` will read: one session file for the seat's
    // whole life, as `seats --up` leaves it
    let proj = crate::cost::project_dir(&floor.join("home"), &floor.join("wt-impl1"));
    std::fs::create_dir_all(&proj).unwrap();
    let transcript = proj.join("session.jsonl");
    let turn = |ts: &str, cache_read: u64, output: u64| {
        format!("{{\"type\":\"assistant\",\"timestamp\":\"{ts}\",\"message\":{{\"usage\":{{\"input_tokens\":3,\"cache_read_input_tokens\":{cache_read},\"cache_creation_input_tokens\":0,\"output_tokens\":{output}}}}}}}\n")
    };
    let iso = |s: &str| crate::cost::iso_to_epoch(s).unwrap();
    let job = JobRef {
        role: Role::Impl,
        issue: Some(574),
        pr: None,
    };
    let reported = SeatState::Reported { job: job.clone() };

    // cycle 1: woken 01:00:00, two turns, verdict in
    let mut text = turn("2026-09-12T01:10:00Z", 1_000_000, 40);
    text.push_str(&turn("2026-09-12T01:20:00Z", 2_000_000, 60));
    std::fs::write(&transcript, &text).unwrap();
    let mut log = Log::open(&cfg.run_log).unwrap();
    let wake1 = iso("2026-09-12T01:00:00Z");
    record_cycle(&mut log, "o/r", &cfg, 1, &reported, wake1 + 1800).unwrap();

    // cycle 2: the same seat, the same file, a bigger context per request
    text.push_str(&turn("2026-09-12T02:00:00Z", 5_000_000, 100));
    text.push_str(&turn("2026-09-12T02:20:00Z", 7_000_000, 150));
    std::fs::write(&transcript, &text).unwrap();
    let wake2 = iso("2026-09-12T02:00:00Z");
    record_cycle(&mut log, "o/r", &cfg, 1, &reported, wake2 + 1800).unwrap();

    let logged: Vec<(Option<u64>, Option<u64>)> = crate::log::read_all(&cfg.run_log)
        .unwrap()
        .into_iter()
        .filter_map(|e| match e.kind {
            Kind::Seat {
                tokens_in,
                tokens_out,
                ..
            } => Some((tokens_in, tokens_out)),
            _ => None,
        })
        .collect();
    assert_eq!(
        logged,
        vec![(Some(3_000_006), Some(100)), (Some(12_000_006), Some(250))],
        "cycle 2 must not carry cycle 1's 3M in / 100 out"
    );
    // the growth between them is real (each request re-reads more), but it
    // is not the sum: that would be 15M in / 350 out
    assert_ne!(logged[1], (Some(15_000_012), Some(350)));
    // a seat that never answered records the zero it measured, not the
    // transcript it was left beside
    record_cycle(
        &mut log,
        "o/r",
        &cfg,
        1,
        &SeatState::Stalled { job },
        iso("2026-09-12T03:00:00Z") + 1800,
    )
    .unwrap();
    let last = crate::log::read_all(&cfg.run_log).unwrap().pop().unwrap();
    assert!(matches!(
        last.kind,
        Kind::Seat {
            tokens_in: Some(0),
            tokens_out: Some(0),
            to: SeatState::Stalled { .. },
            ..
        }
    ));
    let _ = std::fs::remove_dir_all(&floor);
}

#[test]
fn a_pane_name_yields_its_seat_number_and_anything_else_is_seat_one() {
    assert_eq!(seat_no_of_target("fwf-one:impl2"), 2);
    assert_eq!(seat_no_of_target("fwf-one:impl11"), 11);
    assert_eq!(seat_no_of_target("impl3"), 3);
    assert_eq!(seat_no_of_target("fwf-one:qa1"), 1);
    assert_eq!(seat_no_of_target("%7"), 1);
    assert_eq!(seat_no_of_target(""), 1);
}

#[test]
fn from_error_carries_the_message() {
    let e: SliceError = std::io::Error::other("boom").into();
    assert!(e.0.contains("boom"));
}

#[test]
fn the_push_token_is_minted_from_the_impl_app_and_asks_for_workflows_write() {
    let app = AppEntry {
        app_id: 1,
        installation_id: 11,
        key: "impl.pem".into(),
    };
    let ops = AppEntry {
        app_id: 2,
        installation_id: 22,
        key: "ops.pem".into(),
    };
    // With an ops App configured or without it, the impl App mints it: ops
    // has no `workflows` permission to request (#636).
    for o in [Some(&ops), None] {
        let (entry, perms) = push_token_mint(&app, o);
        assert_eq!(entry.installation_id, app.installation_id);
        assert_eq!(perms.get("contents"), Some(&"write"));
        assert_eq!(perms.get("workflows"), Some(&"write"));
        assert_eq!(perms.get("metadata"), Some(&"read"));
    }

    // And that is the scope GitHub is actually asked for.
    let fake = crate::fake_github::FakeGitHub::start();
    fake.add_installation(app.installation_id, "fwf-impl[bot]");
    fake.add_installation(ops.installation_id, "fwf-ops[bot]");
    let (entry, perms) = push_token_mint(&app, Some(&ops));
    let (code, body) = fake.mint_request(entry.installation_id, &perms);
    assert_eq!(code, 201, "{body}");
    assert_eq!(body["permissions"]["workflows"], "write");
    let w = fake.writes();
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].actor, "fwf-impl[bot]", "never fwf-ops[bot]");
    assert_eq!(w[0].body["permissions"]["workflows"], "write");
}

#[test]
fn a_fence_never_leaves_the_supervisor_in_the_job_text() {
    // The job template must not mention the fence or any token placeholder.
    let t = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/prompts/dev/impl-job.md"
    ))
    .unwrap();
    assert!(!t.contains("{{FENCE}}") && !t.contains("TOKEN"));
    for ph in ["{{SEAT}}", "{{ISSUE}}", "{{REPO}}", "{{BRANCH}}"] {
        assert!(t.contains(ph), "template lacks {ph}");
    }
}

/// #656, fwf floor 2026-09-15: a dirty seat worktree refused the cycle
/// *after* `refs/claims/653` was taken, and the `?` walked straight out
/// without giving it back. The record's next word was nothing, so after a
/// restart `claim`'s reuse path could not prove the ref was this floor's and
/// every later tick refused with "exists upstream and this floor's record
/// does not own it" — wedged until somebody deleted the ref by hand.
#[test]
fn a_refusal_after_the_claim_gives_the_claim_ref_back() {
    let (root, url, work, _wt) = floor();
    let fence_sha = advance(&work, &url, "later.txt");
    // the mirror clones a default branch; the floor harness only publishes
    // `staging`, so give this throwaway upstream one to land on
    git(&work, &["push", "-q", &url, "HEAD:refs/heads/main"]);
    let m = crate::mirror::Mirror::init(&root.join("mirror-clone"), &url).unwrap();
    let base = crate::types::Sha::parse(&fence_sha).unwrap();
    let fence = m.create_claim_ref(653, &base, "").unwrap();
    assert_eq!(m.upstream_claim_ref(653, "").unwrap(), Some(base.clone()));

    let run_log = root.join("run.jsonl");
    let mut log = Log::open(&run_log).unwrap();
    let mut cfg = cfg_for(653, 1);
    cfg.run_log = run_log.clone();
    let e = super::deliver::release_and_refuse(
        &mut log,
        "o/r",
        &cfg,
        &m,
        &fence,
        "",
        "seat worktree is dirty".into(),
    );
    assert!(e.0.contains("claim released"), "{}", e.0);
    assert_eq!(
        m.upstream_claim_ref(653, "").unwrap(),
        None,
        "the ref is still upstream after a refusal"
    );
    // and the record says both halves: why it refused, and that the issue is
    // no longer claimed — so the next tick plans it clean
    let evs = crate::log::read_all(&run_log).unwrap();
    assert!(evs.iter().any(
        |e| matches!(&e.kind, Kind::Refused { what, why } if what == "#653" && why.contains("dirty"))
    ));
    assert!(!crate::log::claimed_issues(&evs).contains_key(&653));

    // A leak from before the fix (or a crash between the two) is still
    // adoptable: the record owns that fence, so `claim` reuses it rather than
    // walking into ClaimTaken.
    let again = m.create_claim_ref(653, &base, "").unwrap();
    crate::slice::record(
        &mut log,
        "o/r",
        Kind::Issue {
            issue: 653,
            to: IssueState::Claimed {
                seat: 1,
                fence: again.clone(),
            },
        },
    )
    .unwrap();
    assert!(matches!(
        m.create_claim_ref(653, &base, ""),
        Err(crate::mirror::MirrorError::ClaimTaken(653))
    ));
    let reused = super::deliver::claim(&mut log, "o/r", &cfg, &m, &base, "").unwrap();
    assert_eq!(reused, again, "the floor's own fence, adopted not refused");
    let _ = std::fs::remove_dir_all(root);
}
