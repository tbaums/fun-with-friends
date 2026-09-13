//! #576 — the rework cycle: QA asked for changes, so the impl seat that owns
//! the branch gets another pass at it.
//!
//! No new claim and no new PR: the seat is woken on its own branch, at the
//! head QA reviewed, with the review body as the job. When the verdict lands
//! the supervisor force-pushes the branch upstream under a lease on that same
//! head, which drops the review off the head and makes the PR QA work again.
//!
//! Rounds are capped (manifest `rework_cap`, default 2) and counted from the
//! run record. At the cap nothing is woken and nothing is closed: a refused PR
//! that two passes could not fix is a human's decision, like a stale claim.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::mirror::Mirror;
use crate::seat::{self, Pane, Verdict};
use crate::types::{JobRef, PrState, Role, SeatState, Sha};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

pub struct ReworkConfig {
    pub owner: String,
    pub repo: String,
    pub pr: u64,
    pub seat_no: u8,
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub base_branch: String,
    pub floor_dir: PathBuf,
    pub mirror_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
    /// The repo's own fast check (manifest `[suites] fast`), shown to the seat.
    pub check_cmd: String,
    /// How many rounds one PR may have (manifest `rework_cap`).
    pub cap: u32,
}

#[derive(Debug)]
pub struct ReworkError(pub String);
impl<E: std::fmt::Display> From<E> for ReworkError {
    fn from(e: E) -> Self {
        ReworkError(e.to_string())
    }
}

/// What one planned rework came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The seat worked it and the branch now sits at `head` upstream.
    Pushed { head: Sha, round: u32 },
    /// At the cap: no pane woken, nothing closed, a human decides.
    AtCap { rounds: u32 },
    /// The PR closed or merged between the plan and the wake. Not an error.
    Gone,
}

fn now() -> u64 {
    seat::now()
}

fn record(log: &mut Log, repo: &str, kind: Kind) -> Result<(), ReworkError> {
    log.append(&Event {
        ts: now(),
        repo: repo.to_string(),
        kind,
    })?;
    Ok(())
}

/// How many rework rounds this PR has already had, per the run record: one
/// `Working` event per wake, on an impl seat, whose job names the PR (only a
/// rework job does — the slice's impl job names the issue). Counted by PR, so
/// every CHANGES_REQUESTED round draws from the same cap.
pub fn rounds(events: &[Event], pr: u64) -> u32 {
    events
        .iter()
        .filter(|e| match &e.kind {
            Kind::Seat {
                role: Role::Impl,
                to: SeatState::Working { job, .. },
                ..
            } => job.pr == Some(pr),
            _ => false,
        })
        .count() as u32
}

/// The rounds a PR has had, read from the run record at `run_log`.
pub fn rounds_in(run_log: &std::path::Path, pr: u64) -> u32 {
    crate::log::read_all(run_log)
        .map(|evs| rounds(&evs, pr))
        .unwrap_or(0)
}

/// The review the seat has to answer: the newest CHANGES_REQUESTED body the QA
/// App left on `head`. Reviews arrive oldest first, so the last one wins.
pub fn latest_refusal(reviews: &serde_json::Value, head: &str) -> Option<String> {
    reviews
        .as_array()?
        .iter()
        .filter(|r| {
            r["state"].as_str() == Some("CHANGES_REQUESTED")
                && r["commit_id"].as_str() == Some(head)
                && r["user"]["login"]
                    .as_str()
                    .is_some_and(|l| l.ends_with("-qa[bot]"))
        })
        .filter_map(|r| r["body"].as_str().map(str::to_string))
        .next_back()
}

/// Everything the supervisor read from GitHub before the seat is woken.
pub struct ReworkJob {
    pub issue: Option<u64>,
    pub branch: String,
    pub head: Sha,
    pub title: String,
    pub review: String,
}

/// The job text for one rework round. Every placeholder the prompt may use is
/// filled here; `prompts::PLACEHOLDERS` is the list the test checks against.
pub fn render(template: &str, cfg: &ReworkConfig, j: &ReworkJob) -> String {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    template
        .replace("{{SEAT}}", &cfg.seat_no.to_string())
        .replace("{{PR}}", &cfg.pr.to_string())
        .replace("{{REPO}}", &repo)
        .replace("{{BRANCH}}", &j.branch)
        .replace("{{HEAD}}", j.head.as_str())
        .replace(
            "{{ISSUE}}",
            &j.issue.map(|i| i.to_string()).unwrap_or_default(),
        )
        .replace("{{TITLE}}", &j.title)
        .replace("{{BODY}}", &j.review)
        .replace("{{REVIEW}}", &j.review)
        .replace("{{BASE}}", &cfg.base_branch)
        .replace("{{CHECK}}", &cfg.check_cmd)
        // When this cycle ends, so a long proof can be cut short (#589).
        .replace(
            "{{DEADLINE}}",
            &seat::local_hhmm(now() + cfg.timeout.as_secs()),
        )
}

/// `app` (impl) reads the PR and its reviews; `ops` (contents:write) pushes the
/// reworked branch upstream. With no ops App the impl App does both.
pub fn run(
    cfg: &ReworkConfig,
    app: &AppEntry,
    ops: Option<&AppEntry>,
) -> Result<Outcome, ReworkError> {
    // The cap is a record question, so it is answered before any token is
    // minted: at the cap this cycle costs nothing and wakes nobody.
    let rounds = rounds_in(&cfg.run_log, cfg.pr);
    if rounds >= cfg.cap {
        return Ok(Outcome::AtCap { rounds });
    }
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mut log = Log::open(&cfg.run_log)?;

    let read_perms = BTreeMap::from([
        ("pull_requests", "read"),
        ("contents", "read"),
        ("metadata", "read"),
    ]);
    let rtok = github::mint(app, Some(&read_perms))?;
    let (code, body) = github::get_status(&rtok.token, &format!("/repos/{repo}/pulls/{}", cfg.pr))?;
    if code != 200 {
        return Err(ReworkError(format!("cannot read PR #{} ({code})", cfg.pr)));
    }
    let pr: serde_json::Value = serde_json::from_str(&body)?;
    if pr["state"].as_str() != Some("open") {
        return Ok(Outcome::Gone);
    }
    let head = Sha::parse(pr["head"]["sha"].as_str().unwrap_or(""))?;
    let branch = pr["head"]["ref"].as_str().unwrap_or("").to_string();
    if !branch.starts_with(&format!("impl{}/", cfg.seat_no)) {
        return Err(ReworkError(format!(
            "PR #{} is on {branch}, not a branch of impl seat {}",
            cfg.pr, cfg.seat_no
        )));
    }
    let (code, body) = github::get_status(
        &rtok.token,
        &format!("/repos/{repo}/pulls/{}/reviews", cfg.pr),
    )?;
    if code != 200 {
        return Err(ReworkError(format!(
            "cannot read the reviews of #{} ({code})",
            cfg.pr
        )));
    }
    let review = latest_refusal(&serde_json::from_str(&body)?, head.as_str()).ok_or_else(|| {
        ReworkError(format!(
            "#{} has no CHANGES_REQUESTED review at {}",
            cfg.pr,
            head.short()
        ))
    })?;
    let job = ReworkJob {
        issue: crate::poll::closes_issue(pr["body"].as_str().unwrap_or("")),
        branch,
        head,
        title: pr["title"].as_str().unwrap_or("").to_string(),
        review,
    };

    let push_tok = match ops {
        Some(o) => github::mint(
            o,
            Some(&BTreeMap::from([
                ("contents", "write"),
                ("metadata", "read"),
            ])),
        )?,
        None => github::mint(
            app,
            Some(&BTreeMap::from([
                ("contents", "write"),
                ("metadata", "read"),
            ])),
        )?,
    };
    let mirror = Mirror::init_with(
        &cfg.mirror_dir,
        &format!("https://github.com/{repo}.git"),
        &rtok.token,
    )?;
    let head = cycle(cfg, &mirror, &job, &push_tok.token, &mut log)?;
    Ok(Outcome::Pushed {
        head,
        round: rounds + 1,
    })
}

/// The half that needs no GitHub API: realign the seat's worktree onto the
/// branch at the head QA reviewed, wake it with the review, wait for the
/// verdict, then push the branch upstream under a lease on that head.
pub fn cycle(
    cfg: &ReworkConfig,
    mirror: &Mirror,
    j: &ReworkJob,
    push_token: &str,
    log: &mut Log,
) -> Result<Sha, ReworkError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    // The branch exists; the worktree may not be on it, and the base may have
    // moved since the PR opened (#575's discipline: refuse a dirty tree).
    let wt = cfg.floor_dir.join(format!("wt-impl{}", cfg.seat_no));
    crate::slice::align_seat_worktree(
        log,
        &repo,
        cfg.pr,
        &wt,
        &mirror.seat_remote_url(),
        j.head.as_str(),
        Some(&j.branch),
    )
    .map_err(|e| ReworkError(e.0))?;

    let job_text = render(&std::fs::read_to_string(&cfg.job_template)?, cfg, j);
    let pane = Pane {
        target: cfg.seat_target.clone(),
        role: Role::Impl,
        seat: cfg.seat_no,
    };
    let jref = JobRef {
        role: Role::Impl,
        issue: j.issue,
        pr: Some(cfg.pr),
    };
    let verdict_path = cfg
        .floor_dir
        .join(format!("verdict-rework-pr-{}.json", cfg.pr));
    let st = seat::wake(
        &pane,
        &cfg.seat_expect_cmd,
        &jref,
        &job_text,
        &verdict_path,
        cfg.timeout,
    )?;
    let deadline = match &st {
        SeatState::Working { deadline, .. } => *deadline,
        other => return Err(ReworkError(format!("unexpected seat state {other:?}"))),
    };
    record(
        log,
        &repo,
        Kind::Seat {
            seat: cfg.seat_no,
            role: Role::Impl,
            to: st.clone(),
            tokens_in: None,
            tokens_out: None,
        },
    )?;
    let (st, verdict) = seat::wait_verdict(&jref, &verdict_path, deadline, Duration::from_secs(2))?;
    let usage = crate::cost::cycle_usage(
        &cfg.floor_dir.join("home"),
        &wt,
        deadline.saturating_sub(cfg.timeout.as_secs()),
    );
    let (tokens_in, tokens_out) = usage
        .as_ref()
        .map(|u| (Some(u.tokens_in()), Some(u.tokens_out())))
        .unwrap_or((None, None));
    record(
        log,
        &repo,
        Kind::Seat {
            seat: cfg.seat_no,
            role: Role::Impl,
            to: st.clone(),
            tokens_in,
            tokens_out,
        },
    )?;
    let (v_branch, v_head) = match verdict {
        Some(Verdict::Implemented { branch, head, .. }) => (branch, head),
        Some(Verdict::Blocked { reason }) => {
            record(
                log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.pr),
                    why: format!("seat blocked on the rework: {reason}"),
                },
            )?;
            return Err(ReworkError(format!("seat blocked: {reason}")));
        }
        Some(other) => return Err(ReworkError(format!("unexpected verdict {other:?}"))),
        None => {
            record(
                log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.pr),
                    why: "seat stalled past deadline on the rework".into(),
                },
            )?;
            return Err(ReworkError("seat stalled; pane untouched".into()));
        }
    };
    if v_branch != j.branch {
        return Err(ReworkError(format!(
            "seat reported branch {v_branch}, expected {}",
            j.branch
        )));
    }
    let new_head = Sha::parse(&v_head)?;
    let in_mirror = mirror
        .branch_head(&j.branch)?
        .ok_or_else(|| ReworkError(format!("mirror has no {}", j.branch)))?;
    if in_mirror != new_head {
        return Err(ReworkError(format!(
            "mirror {} != verdict head {}",
            in_mirror.short(),
            new_head.short()
        )));
    }
    if new_head == j.head {
        return Err(ReworkError(format!(
            "#{} is still at {}; the seat changed nothing",
            cfg.pr,
            j.head.short()
        )));
    }
    // The rework may have rebased, so this is a force-push — leased on the head
    // QA reviewed, so a head that moved under us stops the push, never a guess.
    let pushed = mirror.sync_branch(&j.branch, Some(&j.head), push_token)?;
    record(
        log,
        &repo,
        Kind::Promote {
            branch: j.branch.clone(),
            from: j.head.as_str().to_string(),
            to: pushed.to_string(),
        },
    )?;
    record(
        log,
        &repo,
        Kind::Pr {
            pr: cfg.pr,
            issue: j.issue,
            to: PrState::Open {
                head: pushed.clone(),
            },
        },
    )?;
    Ok(pushed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::process::Command;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn ev(kind: Kind) -> Event {
        Event {
            ts: 1,
            repo: "o/r".into(),
            kind,
        }
    }

    fn seat_ev(role: Role, pr: Option<u64>, issue: Option<u64>, working: bool) -> Event {
        let job = JobRef { role, issue, pr };
        ev(Kind::Seat {
            seat: 1,
            role,
            to: if working {
                SeatState::Working {
                    job,
                    deadline: 1000,
                }
            } else {
                SeatState::Reported { job }
            },
            tokens_in: None,
            tokens_out: None,
        })
    }

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

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fwfd-rework-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn cfg(floor: &Path, target: &str, cap: u32) -> ReworkConfig {
        ReworkConfig {
            owner: "o".into(),
            repo: "r".into(),
            pr: 1270,
            seat_no: 1,
            seat_target: target.into(),
            seat_expect_cmd: "bash".into(),
            base_branch: "staging".into(),
            floor_dir: floor.to_path_buf(),
            mirror_dir: floor.join("mirror"),
            job_template: floor.join("job.md"),
            run_log: floor.join("run.jsonl"),
            timeout: Duration::from_secs(20),
            check_cmd: "cargo test".into(),
            cap,
        }
    }

    #[test]
    fn rounds_count_impl_wakes_on_that_pr_and_nothing_else() {
        let evs = vec![
            seat_ev(Role::Impl, Some(1270), Some(575), true), // round 1
            seat_ev(Role::Impl, Some(1270), Some(575), false), // its report
            seat_ev(Role::Qa, Some(1270), Some(575), true),   // QA, not rework
            seat_ev(Role::Impl, Some(9), None, true),         // another PR
            seat_ev(Role::Impl, None, Some(575), true),       // the slice itself
            ev(Kind::Note { text: "x".into() }),
        ];
        assert_eq!(rounds(&evs, 1270), 1);
        let mut evs2 = evs.clone();
        evs2.push(seat_ev(Role::Impl, Some(1270), Some(575), true));
        assert_eq!(rounds(&evs2, 1270), 2);
        assert_eq!(rounds(&evs, 9), 1);
        assert_eq!(rounds(&[], 1270), 0);
    }

    #[test]
    fn at_the_cap_nothing_is_woken_and_no_token_is_minted() {
        let floor = tmp();
        let mut log = Log::open(&floor.join("run.jsonl")).unwrap();
        for _ in 0..2 {
            log.append(&seat_ev(Role::Impl, Some(1270), Some(575), true))
                .unwrap();
        }
        // A key that cannot be read: any GitHub call would fail here, and a
        // target that is no pane: any wake would fail too.
        let app = AppEntry {
            app_id: 1,
            installation_id: 2,
            key: "/nonexistent/key.pem".into(),
        };
        let c = cfg(&floor, "no-such-session:impl1", 2);
        assert_eq!(run(&c, &app, None).unwrap(), Outcome::AtCap { rounds: 2 });
        // under the cap it gets as far as the token, and fails there
        let c = cfg(&floor, "no-such-session:impl1", 3);
        assert!(run(&c, &app, None).is_err());
        assert!(!floor.join("verdict-rework-pr-1270.json").exists());
        let _ = std::fs::remove_dir_all(floor);
    }

    #[test]
    fn the_job_text_carries_the_review_and_leaves_no_placeholder() {
        let floor = tmp();
        let c = cfg(&floor, "t", 2);
        let j = ReworkJob {
            issue: Some(575),
            branch: "impl1/issue-575-thin-slice".into(),
            head: Sha::parse(&"a".repeat(40)).unwrap(),
            title: "the seat branches from a stale worktree HEAD".into(),
            review: "the fence is not the base you pushed from".into(),
        };
        let template = std::fs::read_to_string(crate::prompts::rework_path(
            Path::new(crate::prompts::ROOT),
            "dev",
        ))
        .unwrap();
        let text = render(&template, &c, &j);
        assert!(text.contains("the fence is not the base you pushed from"));
        assert!(text.contains("PR #1270"));
        assert!(text.contains("impl1/issue-575-thin-slice"));
        assert!(text.contains("cargo test"));
        assert!(text.contains(&"a".repeat(40)));
        assert!(!text.contains("{{"), "{text}");
        let _ = std::fs::remove_dir_all(floor);
    }

    /// The cycle without GitHub: a bare upstream, a mirror of it, the seat's
    /// worktree, and a fake seat pane. The "seat's work" is pushed to the
    /// mirror the way a real seat pushes it; the verdict names that sha.
    #[test]
    fn a_rework_round_realigns_wakes_and_force_pushes_under_a_lease() {
        if !seat::tmux_available() {
            eprintln!("skip: no tmux");
            return;
        }
        let root = tmp();
        let up = root.join("up.git");
        git(&root, &["init", "-q", "--bare", "up.git"]);
        let up_url = format!("file://{}", up.display());
        // staging, then the seat's branch one commit on top: the PR head.
        let work = root.join("work");
        git(&root, &["init", "-q", "work"]);
        std::fs::write(work.join("README"), "one").unwrap();
        git(&work, &["add", "."]);
        git(&work, &["commit", "-q", "-m", "one"]);
        git(
            &work,
            &[
                "push",
                "-q",
                &up_url,
                "HEAD:refs/heads/staging",
                "HEAD:refs/heads/main",
            ],
        );
        let branch = "impl1/issue-575-thin-slice";
        git(&work, &["checkout", "-q", "-b", branch]);
        std::fs::write(work.join("fix.txt"), "first pass").unwrap();
        git(&work, &["add", "."]);
        git(&work, &["commit", "-q", "-m", "first pass"]);
        let pr_head = git(&work, &["rev-parse", "HEAD"]);
        git(
            &work,
            &["push", "-q", &up_url, &format!("HEAD:refs/heads/{branch}")],
        );
        let floor = root.join("floor");
        std::fs::create_dir_all(&floor).unwrap();
        let mirror = Mirror::init(&floor.join("mirror"), &up_url).unwrap();
        // the seat's worktree, left on stale staging by `seats --up`
        git(
            &floor,
            &[
                "clone",
                "-q",
                "--branch",
                "staging",
                &mirror.seat_remote_url(),
                "wt-impl1",
            ],
        );
        let wt = floor.join("wt-impl1");
        assert_ne!(git(&wt, &["rev-parse", "HEAD"]), pr_head);
        // the second pass, as the seat would push it to the mirror
        std::fs::write(work.join("fix.txt"), "second pass").unwrap();
        git(&work, &["add", "."]);
        git(&work, &["commit", "-q", "-m", "address the review"]);
        let reworked = git(&work, &["rev-parse", "HEAD"]);
        git(
            &work,
            &[
                "push",
                "-q",
                &mirror.seat_remote_url(),
                &format!("HEAD:refs/heads/{branch}"),
            ],
        );

        // Seat 1, the same number `seat.rs`'s own wake test uses: these run
        // concurrently in one `cargo test` process, which is how the buffer and
        // job-file collision of #586 showed up on CI. Both must still land.
        let fake = seat::FakeSeat::spawn(Role::Impl, 1).unwrap();
        let verdict = serde_json::json!({"verdict":"implemented","branch":branch,"head":reworked,"summary":"addressed it"}).to_string();
        std::fs::write(
            floor.join("job.md"),
            format!("JOB verdict={verdict} mode=answer\nreview: {{{{REVIEW}}}}"),
        )
        .unwrap();
        let c = cfg(&floor, &fake.pane.target, 2);
        let j = ReworkJob {
            issue: Some(575),
            branch: branch.into(),
            head: Sha::parse(&pr_head).unwrap(),
            title: "t".into(),
            review: "please fix it".into(),
        };
        let mut log = Log::open(&c.run_log).unwrap();
        let pushed = cycle(&c, &mirror, &j, "", &mut log).unwrap();

        assert_eq!(pushed.as_str(), reworked);
        // the worktree was put on the branch (not left on stale staging)
        assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), branch);
        // and the branch moved upstream: the force-push landed
        assert_eq!(
            git(&up, &["rev-parse", &format!("refs/heads/{branch}")]),
            reworked
        );
        let evs = crate::log::read_all(&c.run_log).unwrap();
        assert_eq!(rounds(&evs, 1270), 1);
        assert!(evs.iter().any(|e| matches!(&e.kind,
            Kind::Pr { pr: 1270, to: PrState::Open { head }, .. } if head.as_str() == reworked)));
        assert!(evs
            .iter()
            .any(|e| matches!(&e.kind, Kind::Promote { branch: b, from, .. }
                if b == branch && from == &pr_head)));
        // a second round against the head QA reviewed is a stale lease now:
        // the push is refused rather than forced over what already landed
        let e = cycle(&c, &mirror, &j, "", &mut log).unwrap_err();
        assert!(e.0.contains("lease lost"), "{}", e.0);
        drop(fake);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_dirty_worktree_is_refused_before_the_pane_is_touched() {
        let root = tmp();
        let up = root.join("up.git");
        git(&root, &["init", "-q", "--bare", "up.git"]);
        let up_url = format!("file://{}", up.display());
        let work = root.join("work");
        git(&root, &["init", "-q", "work"]);
        std::fs::write(work.join("README"), "one").unwrap();
        git(&work, &["add", "."]);
        git(&work, &["commit", "-q", "-m", "one"]);
        git(
            &work,
            &[
                "push",
                "-q",
                &up_url,
                "HEAD:refs/heads/staging",
                "HEAD:refs/heads/main",
            ],
        );
        let head = git(&work, &["rev-parse", "HEAD"]);
        let floor = root.join("floor");
        std::fs::create_dir_all(&floor).unwrap();
        let mirror = Mirror::init(&floor.join("mirror"), &up_url).unwrap();
        git(
            &floor,
            &[
                "clone",
                "-q",
                "--branch",
                "staging",
                &mirror.seat_remote_url(),
                "wt-impl1",
            ],
        );
        std::fs::write(floor.join("wt-impl1").join("README"), "left behind").unwrap();
        std::fs::write(floor.join("job.md"), "JOB").unwrap();
        let c = cfg(&floor, "no-such-session:impl1", 2);
        let j = ReworkJob {
            issue: Some(575),
            branch: "impl1/issue-575-thin-slice".into(),
            head: Sha::parse(&head).unwrap(),
            title: "t".into(),
            review: "fix it".into(),
        };
        let mut log = Log::open(&c.run_log).unwrap();
        let e = cycle(&c, &mirror, &j, "", &mut log).unwrap_err();
        assert!(e.0.contains("dirty"), "{}", e.0);
        let evs = crate::log::read_all(&c.run_log).unwrap();
        assert_eq!(rounds(&evs, 1270), 0, "no wake was recorded");
        assert!(evs
            .iter()
            .any(|e| matches!(&e.kind, Kind::Refused { what, .. } if what == "#1270")));
        assert_eq!(
            std::fs::read_to_string(floor.join("wt-impl1").join("README")).unwrap(),
            "left behind"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_refusal_body_is_the_newest_one_at_this_head() {
        let head = "a".repeat(40);
        let reviews = serde_json::json!([
            {"state":"CHANGES_REQUESTED","commit_id":head,"user":{"login":"fwf-qa[bot]"},"body":"first round"},
            {"state":"COMMENTED","commit_id":head,"user":{"login":"fwf-qa[bot]"},"body":"a note"},
            {"state":"CHANGES_REQUESTED","commit_id":"b".repeat(40),"user":{"login":"fwf-qa[bot]"},"body":"an older head"},
            {"state":"CHANGES_REQUESTED","commit_id":head,"user":{"login":"jamie"},"body":"a human"},
            {"state":"CHANGES_REQUESTED","commit_id":head,"user":{"login":"fwf-qa[bot]"},"body":"second round"},
        ]);
        assert_eq!(latest_refusal(&reviews, &head).unwrap(), "second round");
        assert_eq!(latest_refusal(&reviews, &"c".repeat(40)), None);
        assert_eq!(latest_refusal(&serde_json::json!([]), &head), None);
        assert_eq!(latest_refusal(&serde_json::json!({}), &head), None);
    }
}
