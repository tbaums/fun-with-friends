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
use crate::types::{IssueState, JobRef, Role, SeatState, Sha};
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
    /// The quiet limit for this cycle's liveness watch (#668); 0 turns the
    /// early stall off and leaves `timeout` as the only bound.
    pub stall_quiet: Duration,
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
fn recheck(
    snap: &Snapshot,
    cfg: &SliceConfig,
    reviewed: &std::collections::BTreeSet<u64>,
    now: u64,
) -> Result<u8, String> {
    // The seat as the record last left it, not a hardcoded Idle (#667): a
    // slice dispatched at the same issue a seat is still Working or Stalled on
    // refuses here instead of re-claiming it.
    let recorded = crate::log::seat_states(&events(cfg));
    let seats = [SeatSlot::from_record(
        cfg.seat,
        Role::Impl,
        recorded.get(&(cfg.seat, Role::Impl)),
    )];
    // A targeted slice plans over the one issue it was pointed at, so there
    // is nothing for #656's refusal tie-break to reorder here.
    // No reviewer set either: a slice is looking for its own WakeImpl, and
    // whose CHANGES_REQUESTED counts (#677) decides nothing about that.
    let p = plan(
        snap,
        &seats,
        true,
        reviewed,
        &std::collections::BTreeSet::new(),
        &std::collections::BTreeSet::new(),
        now,
    );
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

mod deliver;

pub use deliver::{adopt_stalled_verdict, retry_pending_push, Adopted};
use deliver::{claim, push_and_open_pr};

/// Read the run record, or an empty record if it cannot be read.
pub(super) fn events(cfg: &SliceConfig) -> Vec<crate::log::Event> {
    crate::log::read_all(&cfg.run_log).unwrap_or_default()
}

/// Where this cycle's seat writes its verdict. Deterministic from the issue,
/// so the loop can re-read it long after the wait gave up (#669).
pub(super) fn verdict_path(cfg: &SliceConfig) -> PathBuf {
    cfg.floor_dir
        .join(format!("verdict-issue-{}.json", cfg.issue))
}

/// Is this cycle re-entering a claim this floor already holds (#667), rather
/// than taking a fresh one?
///
/// Both halves have to agree: the record says this floor claimed the issue,
/// and `refs/claims/<n>` upstream is still standing at exactly that fence. A
/// record with no claim is a fresh cycle, and a fence that no longer matches
/// upstream is a stale record — either way the claim below is a new one and
/// the `Ready` above is this cycle's to write.
pub(crate) fn reentering_claim(
    held: Option<&(u8, crate::types::Fence)>,
    upstream: Option<&Sha>,
) -> bool {
    matches!((held, upstream), (Some((_, f)), Some(up)) if f.0 == up.as_str())
}

/// Where a seat's liveness notes go (#668): into the run record, on their own
/// handle, because the wait that produces them holds none. A note that cannot
/// be written is not worth failing a cycle over — the seat is working either
/// way, and the `Seat` event still lands.
pub(crate) fn liveness_note(run_log: &Path, repo: &str, text: String) {
    if let Ok(mut l) = Log::open(run_log) {
        let _ = record(&mut l, repo, Kind::Note { text });
    }
}

/// Everything between the claim and the wake: realign the seat's worktree to
/// the fence (`seats --up` may have cloned it several merges ago), read the
/// issue GitHub has right now, and render the job from the template.
///
/// One function because every failure in it owes the same thing — the claim
/// back (#656). The caller releases; this one only says what went wrong.
#[allow(clippy::too_many_arguments)]
fn stage_cycle(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    poller: &Poller,
    mirror: &Mirror,
    seat_no: u8,
    fence: &crate::types::Fence,
) -> Result<(String, String), SliceError> {
    let seat_wt = cfg.floor_dir.join(format!("wt-impl{seat_no}"));
    align_seat_worktree(
        log,
        repo,
        cfg.issue,
        &seat_wt,
        &mirror.seat_remote_url(),
        &fence.0,
        None,
    )?;
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
        .replace("{{REPO}}", repo)
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
    Ok((job_text, title))
}
/// Branch-push token: always the impl App with `contents`+`workflows` write — a push under `.github/workflows/` needs `workflows`, which `ops` is not granted (#636). `ops` stays a param (it still backs merges/labels/check-runs).
pub(super) fn push_token_mint<'a>(
    app: &'a AppEntry,
    _ops: Option<&AppEntry>,
) -> (&'a AppEntry, BTreeMap<&'static str, &'static str>) {
    (
        app,
        BTreeMap::from([
            ("contents", "write"),
            ("workflows", "write"),
            ("metadata", "read"),
        ]),
    )
}

/// `app` (impl App) pushes the branch (see [`push_token_mint`]) and authors the PR; `ops` is accepted but mints nothing here.
pub fn run_with(
    cfg: &SliceConfig,
    app: &AppEntry,
    ops: Option<&AppEntry>,
) -> Result<String, SliceError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    // An issue whose seat worktree already holds an unpushed `implemented`
    // verdict is never re-sliced (#602): a 29-minute cycle is not repeated
    // because a push was refused. `retry_pending_push` owes it the write.
    if let Some(p) = crate::log::pending_pushes(&events(cfg)).get(&cfg.issue) {
        return Err(SliceError(format!(
            "#{} is implemented on {} but unpushed ({}); retrying the push, not re-slicing",
            cfg.issue, p.branch, p.why
        )));
    }
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
    let (push_app, push_perms) = push_token_mint(app, ops);
    let push_tok = github::mint(push_app, Some(&push_perms))?;

    // 2. Poll → plan, over this cycle's own seat.
    let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
    let mut snap = poller.poll(now())?;
    // The slice is a targeted demo: plan over the one issue we were pointed
    // at. The real supervisor plans over the whole open set (FIFO).
    snap.issues.retain(|i| i.number == cfg.issue);
    if !snap.known {
        return Err(SliceError("snapshot Unknown; refusing to plan".into()));
    }
    // The same policy the loop plans by (#630): the record decides, so a
    // slice dispatched before a sign-off landed refuses here rather than
    // claiming an unreviewed issue.
    let reviewed =
        crate::run::reviewed_issues(&crate::log::read_all(&cfg.run_log).unwrap_or_default());
    let seat_no = match recheck(&snap, cfg, &reviewed, now()) {
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
    // `Ready` is this cycle's own word that the issue is free to claim — and
    // it is exactly the word that used to erase a claim this floor still held
    // (#667). `claimed_issues` reads it as a release, so writing it ahead of a
    // re-entry left `claim`'s reuse path unable to prove the upstream ref was
    // ours, and every later tick refused with "does not own it". Say it only
    // for a claim that really is fresh; re-entering our own live claim says
    // nothing and reuses the fence (the #602 path).
    let held = crate::log::claimed_issues(&events(cfg))
        .get(&cfg.issue)
        .cloned();
    let upstream = mirror.upstream_claim_ref(cfg.issue, &push_tok.token)?;
    if !reentering_claim(held.as_ref(), upstream.as_ref()) {
        record(
            &mut log,
            &repo,
            Kind::Issue {
                issue: cfg.issue,
                to: IssueState::Ready,
            },
        )?;
    }
    let fence = claim(&mut log, &repo, cfg, &mirror, &base, &push_tok.token)?;
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

    // 4 and 5. Realign the seat's worktree to the fence and render its job.
    // Both can fail, and from here on a failure owes the claim back (#656):
    // one exit, one release, one `Refused` in the record.
    let staged = stage_cycle(&mut log, &repo, cfg, &poller, &mirror, seat_no, &fence);
    let (job_text, title) = match staged {
        Ok(v) => v,
        Err(e) => {
            return Err(deliver::release_and_refuse(
                &mut log,
                &repo,
                cfg,
                &mirror,
                &fence,
                &push_tok.token,
                e.0,
            ))
        }
    };
    let branch = format!("impl{seat_no}/issue-{}-thin-slice", cfg.issue);
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
    let verdict_path = verdict_path(cfg);
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

    // 6. Wait for the verdict; never kill. The clock is the ceiling, but it is
    // not the only thing watched (#668): a seat that has stopped moving on
    // both signals is called Stalled before it, and a seat mid-`cargo test`
    // is not called Stalled at all. Every note this writes goes through the
    // same log, so the record explains the verdict afterwards.
    let (st, verdict) = {
        let seat_wt = cfg.floor_dir.join(format!("wt-impl{seat_no}"));
        let target = cfg.seat_target.clone();
        let who = format!("impl{seat_no} #{}", cfg.issue);
        let mut watch = seat::Watch::new(
            who,
            cfg.stall_quiet.as_secs(),
            deadline.saturating_sub(cfg.timeout.as_secs()),
            move || seat::worktree_signal(&seat_wt),
            move || seat::pane_signal(&target),
            |text| liveness_note(&cfg.run_log, &repo, text),
        );
        seat::wait_verdict_watched(
            &job,
            seat_no,
            &verdict_path,
            deadline,
            Duration::from_secs(2),
            Some(&mut watch),
        )?
    };
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

    // 7 + 8. Sync the branch upstream and open the draft PR. A refused push
    // leaves the claim, the branch and a `pending-push` note behind and the
    // loop retries the write every tick — the cycle is not re-run (#602).
    let url = match push_and_open_pr(
        &mut log,
        &repo,
        cfg,
        &mirror,
        &tok.token,
        &push_tok.token,
        seat_no,
        &branch,
        &head,
        &fence,
        &title,
        &summary,
    )? {
        Some(url) => url,
        None => {
            let p = crate::log::pending_pushes(&events(cfg))
                .get(&cfg.issue)
                .map(|p| p.why.clone())
                .unwrap_or_default();
            return Ok(format!(
                "#{} is implemented on {branch}; upstream refused the push ({p}) — claim and branch kept, retrying each tick",
                cfg.issue
            ));
        }
    };
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
/// the number from its own plan; the `fwf slice` verb is given a pane name, so
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
mod tests;
#[cfg(test)]
mod tests_claim;
