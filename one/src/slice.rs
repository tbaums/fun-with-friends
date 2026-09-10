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
use crate::mirror::Mirror;
use crate::poll::Poller;
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
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub floor_dir: PathBuf,
    pub mirror_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
    pub dry_run: bool,
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

    // 2. Poll → plan. One idle implementer seat.
    let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
    let mut snap = poller.poll(now())?;
    // The slice is a targeted demo: plan over the one issue we were pointed
    // at. The real supervisor plans over the whole open set (FIFO).
    snap.issues.retain(|i| i.number == cfg.issue);
    if !snap.known {
        return Err(SliceError("snapshot Unknown; refusing to plan".into()));
    }
    let seats = [SeatSlot {
        seat: 1,
        role: Role::Impl,
        state: SeatState::Idle,
    }];
    let p = plan(&snap, &seats, &cfg.gate_label, true, now());
    let wake = p.actions.iter().find_map(|a| match a {
        Action::WakeImpl { seat, issue } if *issue == cfg.issue => Some(*seat),
        _ => None,
    });
    let Some(seat_no) = wake else {
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
        record(
            &mut log,
            &repo,
            Kind::Refused {
                what: format!("#{}", cfg.issue),
                why: format!("scheduler did not plan it: {why}"),
            },
        )?;
        return Err(SliceError(format!(
            "issue #{} is not eligible: {why}; plan was {:?}",
            cfg.issue, p.actions
        )));
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
    let mirror = Mirror::init(&cfg.mirror_dir, &format!("https://github.com/{repo}.git"))?;
    mirror.fetch()?;
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

    // 4. Render the job and wake the pane.
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
        .replace("{{BRANCH}}", &branch);
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

    // 5. Wait for the verdict; never kill.
    let (st, verdict) = seat::wait_verdict(&job, &verdict_path, deadline, Duration::from_secs(2))?;
    // Measured cost of this cycle: the seat's own transcript since the wake.
    let seat_home = cfg.floor_dir.join("home");
    let seat_wt = cfg.floor_dir.join(format!("wt-impl{}", seat_no));
    let usage = crate::cost::cycle_usage(
        &seat_home,
        &seat_wt,
        deadline.saturating_sub(cfg.timeout.as_secs()),
    );
    let (tokens_in, tokens_out) = usage
        .as_ref()
        .map(|u| (Some(u.tokens_in()), Some(u.tokens_out())))
        .unwrap_or((None, None));
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: seat_no,
            role: Role::Impl,
            to: st.clone(),
            tokens_in,
            tokens_out,
        },
    )?;
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

    // 6. The seat pushed to the mirror; the supervisor syncs it upstream.
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

    // 7. Draft PR under the supervisor's App.
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

/// Resolve the slice's default paths under the floor dir.
pub fn defaults(floor: &Path) -> (PathBuf, PathBuf) {
    (floor.join("run.jsonl"), floor.join("mirror"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_error_carries_the_message() {
        let e: SliceError = std::io::Error::other("boom").into();
        assert!(e.0.contains("boom"));
    }

    #[test]
    fn a_fence_never_leaves_the_supervisor_in_the_job_text() {
        // The job template must not mention the fence or any token placeholder.
        let t =
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/prompts/dev/impl-job.md"))
                .unwrap();
        assert!(!t.contains("{{FENCE}}") && !t.contains("TOKEN"));
        for ph in ["{{SEAT}}", "{{ISSUE}}", "{{REPO}}", "{{BRANCH}}"] {
            assert!(t.contains(ph), "template lacks {ph}");
        }
    }
}
