//! T-08 — the thin slice, and the M0 kill criterion.
//!
//! One eligible issue → the scheduler plans one WakeImpl → the supervisor
//! records a claim (a `refs/claims/<n>` ref, the fence) → wakes ONE warm
//! pane → waits for the seat's verdict file → syncs the seat's branch from
//! the local mirror to GitHub under the supervisor's App token → opens the
//! draft PR under that App → writes every step to the run record.
//!
//! The seat never sees a GitHub token. Every GitHub write here is the
//! supervisor's. If anything is Unknown, the slice refuses rather than guesses.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::mirror::{self, Mirror};
use crate::poll::{Poller, Snapshot};
use crate::sched::{plan, Action, SeatSlot};
use crate::seat::{self, Pane, Verdict};
use crate::types::{IssueState, JobRef, PrState, Role, SeatState, Sha};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct SliceConfig {
    pub owner: String,
    pub repo: String,
    pub issue: u64,
    pub base_branch: String,
    pub gate_label: String,
    /// The impl seat this cycle is for — the one `run`'s plan picked. The
    /// recheck below plans over this seat, not a hardcoded 1 (#579).
    pub seat: u8,
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub floor_dir: PathBuf,
    pub mirror_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
    pub dry_run: bool,
    /// The repo's own fast check (manifest `[suites] fast`), shown to the seat.
    pub check_cmd: String,
}

#[derive(Debug)]
pub struct SliceError(pub String);
impl<E: std::fmt::Display> From<E> for SliceError {
    fn from(e: E) -> Self {
        SliceError(e.to_string())
    }
}

fn now() -> u64 {
    seat::now()
}

fn record(log: &mut Log, repo: &str, kind: Kind) -> Result<(), SliceError> {
    log.append(&Event {
        ts: now(),
        repo: repo.to_string(),
        kind,
    })?;
    Ok(())
}

/// Realign the seat's worktree onto `target`, so the seat starts from exactly
/// the sha the supervisor recorded.
///
/// `seats --up` clones `wt-impl{n}` once and leaves it alone afterwards, so if
/// the base moved since then the worktree's HEAD is stale and the seat would
/// branch from a pre-merge base (transom #1270). Fetch the mirror, then check
/// `target` out: `branch` None detaches (the impl slice cuts its own branch
/// next), `Some(b)` puts `b` there (the rework cycle, #576, keeps working on
/// the PR's own branch). A dirty worktree is refused, never cleaned or
/// stashed: the cycle blocks so a human can look at whatever was left behind.
/// `what` is the issue or PR number the refusal is recorded against.
pub(crate) fn align_seat_worktree(
    log: &mut Log,
    repo: &str,
    what: u64,
    wt: &Path,
    remote_url: &str,
    target: &str,
    branch: Option<&str>,
) -> Result<(), SliceError> {
    let refuse = |log: &mut Log, why: String| -> Result<(), SliceError> {
        record(
            log,
            repo,
            Kind::Refused {
                what: format!("#{what}"),
                why: why.clone(),
            },
        )?;
        Err(SliceError(why))
    };
    if !wt.join(".git").exists() {
        let why = format!(
            "seat worktree {} is absent; bring the seat up first",
            wt.display()
        );
        return refuse(log, why);
    }
    let dirty = match mirror::git_in(wt, &["status", "--porcelain"]) {
        Ok(s) => s,
        Err(e) => return refuse(log, format!("seat worktree {}: {e}", wt.display())),
    };
    if !dirty.trim().is_empty() {
        let why = format!(
            "seat worktree {} is dirty; left untouched for the operator: {}",
            wt.display(),
            dirty.split_whitespace().collect::<Vec<_>>().join(" ")
        );
        return refuse(log, why);
    }
    let sha = Sha::parse(target)?;
    // A branch name is a git argument: take only the shape seats are given.
    if branch.is_some_and(|b| !b.starts_with("impl") || b.contains("..")) {
        let why = format!(
            "{:?} is not a seat branch; refusing to check it out",
            branch
        );
        return refuse(log, why);
    }
    let checkout = match branch {
        Some(b) => vec!["checkout", "--quiet", "-B", b, sha.as_str()],
        None => vec!["checkout", "--quiet", "--detach", sha.as_str()],
    };
    for args in [
        vec![
            "fetch",
            "--quiet",
            remote_url,
            "+refs/heads/*:refs/remotes/origin/*",
        ],
        checkout,
    ] {
        if let Err(e) = mirror::git_in(wt, &args) {
            let why = format!(
                "seat worktree {} could not be realigned to {}: {e}",
                wt.display(),
                sha.short()
            );
            return refuse(log, why);
        }
    }
    record(
        log,
        repo,
        Kind::Note {
            text: format!(
                "seat worktree {} realigned to {} {}",
                wt.display(),
                branch.unwrap_or("(detached)"),
                sha.short()
            ),
        },
    )
}

/// The slice's own eligibility recheck, over the issue it was pointed at and
/// the seat it was dispatched to. `Ok(seat)` is the seat the scheduler agrees
/// should take it; `Err(why)` is what to record and tell the operator.
///
/// The seat matters: planning over a hardcoded seat 1 made the slice refuse
/// every issue whenever seat 1 was held by an open PR, even though `run` had
/// planned the wake for a free seat (#579) — claim, refuse, release, repeat.
fn recheck(snap: &Snapshot, cfg: &SliceConfig, now: u64) -> Result<u8, String> {
    let seats = [SeatSlot {
        seat: cfg.seat,
        role: Role::Impl,
        state: SeatState::Idle,
    }];
    let p = plan(snap, &seats, &cfg.gate_label, true, now);
    let wake = p.actions.iter().find_map(|a| match a {
        Action::WakeImpl { seat, issue } if *issue == cfg.issue => Some(*seat),
        _ => None,
    });
    wake.ok_or_else(|| {
        let why = snap
            .issues
            .iter()
            .find(|i| i.number == cfg.issue)
            .map(|i| {
                format!(
                    "labels={:?} assoc={} assignees={:?} claim={:?}",
                    i.labels, i.author_association, i.assignees, i.claim
                )
            })
            .unwrap_or_else(|| "issue not in the open set".into());
        format!(
            "seat {} cannot take #{}: {why}; plan was {:?}",
            cfg.seat, cfg.issue, p.actions
        )
    })
}

/// Record the seat's terminal state for this cycle with what the cycle cost.
///
/// The window is this cycle's own: `deadline` came from the `seat::wake` that
/// started it (`deadline = wake + timeout`, one call), so `deadline - timeout`
/// is that wake instant. A warm seat keeps one transcript across every cycle
/// and it only grows, so the window is the whole of the arithmetic that keeps
/// cycle N from being charged for cycles 1..N (#581). Within the window the
/// numbers still grow cycle over cycle — every request re-reads the
/// conversation the seat has grown — which is real cost, not double counting.
fn record_cycle(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    seat_no: u8,
    st: &SeatState,
    deadline: u64,
) -> Result<(), SliceError> {
    let usage = crate::cost::cycle_usage(
        &cfg.floor_dir.join("home"),
        &cfg.floor_dir.join(format!("wt-impl{seat_no}")),
        deadline.saturating_sub(cfg.timeout.as_secs()),
    );
    let (tokens_in, tokens_out) = usage
        .as_ref()
        .map(|u| (Some(u.tokens_in()), Some(u.tokens_out())))
        .unwrap_or((None, None));
    record(
        log,
        repo,
        Kind::Seat {
            seat: seat_no,
            role: Role::Impl,
            to: st.clone(),
            tokens_in,
            tokens_out,
        },
    )
}

pub fn run(cfg: &SliceConfig, app: &AppEntry) -> Result<String, SliceError> {
    run_with(cfg, app, None)
}

/// `ops` (contents:write) pushes the seat's branch and holds the claim ref;
/// `app` (the impl App, pull_requests:write + contents:read) authors the PR.
/// With no ops App the impl App does both (requires contents:write on it).
pub fn run_with(
    cfg: &SliceConfig,
    app: &AppEntry,
    ops: Option<&AppEntry>,
) -> Result<String, SliceError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mut log = Log::open(&cfg.run_log)?;
    record(
        &mut log,
        &repo,
        Kind::Note {
            text: format!("thin slice start: issue #{}", cfg.issue),
        },
    )?;

    // 1. Supervisor token: the narrowest set that can push a branch and open a PR.
    let perms = BTreeMap::from([
        ("contents", "read"),
        ("pull_requests", "write"),
        ("issues", "read"),
        ("metadata", "read"),
    ]);
    let tok = github::mint(app, Some(&perms))?;
    let push_perms = BTreeMap::from([("contents", "write"), ("metadata", "read")]);
    let push_tok = match ops {
        Some(o) => github::mint(o, Some(&push_perms))?,
        None => github::mint(app, Some(&push_perms))?,
    };

    // 2. Poll → plan, over this cycle's own seat.
    let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
    let mut snap = poller.poll(now())?;
    // The slice is a targeted demo: plan over the one issue we were pointed
    // at. The real supervisor plans over the whole open set (FIFO).
    snap.issues.retain(|i| i.number == cfg.issue);
    if !snap.known {
        return Err(SliceError("snapshot Unknown; refusing to plan".into()));
    }
    let seat_no = match recheck(&snap, cfg, now()) {
        Ok(seat) => seat,
        Err(why) => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.issue),
                    why: format!("scheduler did not plan it: {why}"),
                },
            )?;
            return Err(SliceError(format!(
                "issue #{} is not eligible: {why}",
                cfg.issue
            )));
        }
    };
    record(
        &mut log,
        &repo,
        Kind::Issue {
            issue: cfg.issue,
            to: IssueState::Ready,
        },
    )?;
    if cfg.dry_run {
        return Ok(format!(
            "dry run: would wake seat {seat_no} for #{}",
            cfg.issue
        ));
    }

    // 3. Claim = a ref the seat cannot forge, created expect-empty.
    let read_tok = github::mint(
        app,
        Some(&BTreeMap::from([
            ("contents", "read"),
            ("metadata", "read"),
        ])),
    )?
    .token;
    let mirror = Mirror::init_with(
        &cfg.mirror_dir,
        &format!("https://github.com/{repo}.git"),
        &read_tok,
    )?;
    let base = mirror
        .upstream_head(&cfg.base_branch)?
        .ok_or_else(|| SliceError(format!("no upstream {}", cfg.base_branch)))?;
    let fence = mirror.create_claim_ref(cfg.issue, &base, &push_tok.token)?;
    record(
        &mut log,
        &repo,
        Kind::Issue {
            issue: cfg.issue,
            to: IssueState::Claimed {
                seat: seat_no,
                fence: fence.clone(),
            },
        },
    )?;

    // 4. The seat branches from its worktree's HEAD, which `seats --up` may
    // have cloned several merges ago: realign it to the fence before the wake.
    let seat_wt = cfg.floor_dir.join(format!("wt-impl{seat_no}"));
    align_seat_worktree(
        &mut log,
        &repo,
        cfg.issue,
        &seat_wt,
        &mirror.seat_remote_url(),
        &fence.0,
        None,
    )?;

    // 5. Render the job and wake the pane.
    let issue_json = poller
        .get(&format!(
            "https://api.github.com/repos/{repo}/issues/{}",
            cfg.issue
        ))?
        .ok_or_else(|| SliceError("issue read returned nothing".into()))?;
    let title = issue_json["title"].as_str().unwrap_or("").to_string();
    let body = issue_json["body"].as_str().unwrap_or("").to_string();
    let branch = format!("impl{seat_no}/issue-{}-thin-slice", cfg.issue);
    let job_text = std::fs::read_to_string(&cfg.job_template)?
        .replace("{{SEAT}}", &seat_no.to_string())
        .replace("{{ISSUE}}", &cfg.issue.to_string())
        .replace("{{REPO}}", &repo)
        .replace("{{TITLE}}", &title)
        .replace("{{BODY}}", &body)
        .replace("{{CHECK}}", &cfg.check_cmd)
        .replace("{{BRANCH}}", &branch)
        // The seat is told when its cycle ends, so a long proof can be cut
        // short with a real verdict instead of parking on it (#589).
        .replace(
            "{{DEADLINE}}",
            &seat::local_hhmm(now() + cfg.timeout.as_secs()),
        );
    let pane = Pane {
        target: cfg.seat_target.clone(),
        role: Role::Impl,
        seat: seat_no,
    };
    let job = JobRef {
        role: Role::Impl,
        issue: Some(cfg.issue),
        pr: None,
    };
    let verdict_path = cfg
        .floor_dir
        .join(format!("verdict-issue-{}.json", cfg.issue));
    let st = match seat::wake(
        &pane,
        &cfg.seat_expect_cmd,
        &job,
        &job_text,
        &verdict_path,
        cfg.timeout,
    ) {
        Ok(s) => s,
        Err(e) => {
            let _ = mirror.release_claim_ref(cfg.issue, &fence, &push_tok.token);
            record(
                &mut log,
                &repo,
                Kind::Issue {
                    issue: cfg.issue,
                    to: IssueState::Ready,
                },
            )?;
            return Err(SliceError(format!("wake failed, claim released: {e}")));
        }
    };
    let deadline = match &st {
        SeatState::Working { deadline, .. } => *deadline,
        other => return Err(SliceError(format!("unexpected seat state {other:?}"))),
    };
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: seat_no,
            role: Role::Impl,
            to: st.clone(),
            tokens_in: None,
            tokens_out: None,
        },
    )?;

    // 6. Wait for the verdict; never kill.
    let (st, verdict) = seat::wait_verdict(&job, &verdict_path, deadline, Duration::from_secs(2))?;
    // Measured cost of this cycle: the seat's own transcript since the wake.
    record_cycle(&mut log, &repo, cfg, seat_no, &st, deadline)?;
    let (v_branch, v_head, summary) = match verdict {
        Some(Verdict::Implemented {
            branch,
            head,
            summary,
        }) => (branch, head, summary),
        Some(Verdict::Blocked { reason }) => {
            mirror.release_claim_ref(cfg.issue, &fence, &push_tok.token)?;
            record(
                &mut log,
                &repo,
                Kind::Issue {
                    issue: cfg.issue,
                    to: IssueState::Ready,
                },
            )?;
            return Err(SliceError(format!(
                "seat blocked: {reason}; claim released"
            )));
        }
        Some(other) => return Err(SliceError(format!("unexpected verdict {other:?}"))),
        None => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.issue),
                    why: "seat stalled past deadline; claim kept for the operator".into(),
                },
            )?;
            return Err(SliceError(
                "seat stalled; claim kept, pane untouched".into(),
            ));
        }
    };
    if v_branch != branch {
        return Err(SliceError(format!(
            "seat reported branch {v_branch}, expected {branch}"
        )));
    }
    let head = Sha::parse(&v_head)?;

    // 7. The seat pushed to the mirror; the supervisor syncs it upstream.
    let mirror_head = mirror
        .branch_head(&branch)?
        .ok_or_else(|| SliceError(format!("mirror has no {branch}")))?;
    if mirror_head != head {
        return Err(SliceError(format!(
            "mirror {} != verdict head {}",
            mirror_head.short(),
            head.short()
        )));
    }
    let pushed = mirror.sync_branch(&branch, None, &push_tok.token)?;
    record(
        &mut log,
        &repo,
        Kind::Promote {
            branch: branch.clone(),
            from: "".into(),
            to: pushed.to_string(),
        },
    )?;

    // 8. Draft PR under the supervisor's App.
    let pr_body = format!("Closes #{}\n\nfwf-Provenance: fwfd thin slice\nfwf-Seat: impl{seat_no}\nfwf-Fence: {}\n\n{summary}", cfg.issue, fence.0);
    let payload = serde_json::json!({ "title": format!("{title} (#{})", cfg.issue), "head": branch, "base": cfg.base_branch, "draft": true, "body": pr_body });
    let (code, body) = github::send_json(
        "POST",
        &tok.token,
        &format!("/repos/{repo}/pulls"),
        &payload,
    )?;
    if code != 201 {
        return Err(SliceError(format!(
            "PR create refused ({code}): {}",
            body.chars().take(200).collect::<String>()
        )));
    }
    let pr_json: serde_json::Value = serde_json::from_str(&body)?;
    let pr_num = pr_json["number"].as_u64().unwrap_or(0);
    let url = pr_json["html_url"].as_str().unwrap_or("").to_string();
    record(
        &mut log,
        &repo,
        Kind::Pr {
            pr: pr_num,
            issue: Some(cfg.issue),
            to: PrState::Draft {
                head: pushed.clone(),
            },
        },
    )?;
    record(
        &mut log,
        &repo,
        Kind::Note {
            text: format!("thin slice done: {url}"),
        },
    )?;
    Ok(url)
}

/// The seat number inside a tmux target like `fwf-one:impl2`. The loop knows
/// the number from its own plan; the `fwfd slice` verb is given a pane name, so
/// it reads the number back out of it. Anything unreadable is seat 1.
pub fn seat_no_of_target(target: &str) -> u8 {
    target
        .rsplit_once("impl")
        .and_then(|(_, n)| n.trim().parse().ok())
        .unwrap_or(1)
}

/// Resolve the slice's default paths under the floor dir.
pub fn defaults(floor: &Path) -> (PathBuf, PathBuf) {
    (floor.join("run.jsonl"), floor.join("mirror"))
}

#[cfg(test)]
mod tests {
    use super::*;
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
        // staging moves between `seats --up` and `fwfd slice`
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
        assert!(
            align_seat_worktree(&mut log, "o/r", 575, &wt, &url, &fence, Some("staging")).is_err()
        );
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
        let e =
            align_seat_worktree(&mut log, "o/r", 575, &missing, &url, &fence, None).unwrap_err();
        assert!(e.0.contains("absent"), "{}", e.0);
        assert_eq!(refusals(&run_log).len(), 1);
        let _ = std::fs::remove_dir_all(root);
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
        assert_eq!(recheck(&snap, &cfg_for(574, 2), 100), Ok(2));
        let e = recheck(&snap, &cfg_for(574, 1), 100).unwrap_err();
        assert!(e.contains("seat 1 cannot take #574"), "{e}");
        // the refusal still names what the scheduler saw, for the record
        assert!(e.contains("labels=[]") && e.contains("Nothing"), "{e}");
        // an issue the snapshot does not carry is refused, not woken
        let e = recheck(&snap, &cfg_for(999, 2), 100).unwrap_err();
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
            plan(&snap, &seats, "product-wip", true, 1)
                .actions
                .contains(&Action::WakeImpl { seat: 1, issue }),
            "{:?}",
            plan(&snap, &seats, "product-wip", true, 1).actions
        );
        // …and what the slice makes of it, over the one issue it was given
        snap.issues.retain(|i| i.number == issue);
        assert_eq!(recheck(&snap, &cfg_for(issue, 1), 1), Ok(1));
        // the floor's own PR on that seat still holds it
        snap.prs[0].author = "fwf-impl[bot]".into();
        assert!(recheck(&snap, &cfg_for(issue, 1), 1).is_err());
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
}
