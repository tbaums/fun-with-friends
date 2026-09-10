//! T-12 — the QA cycle: a woken QA pane reviews one PR and returns a verdict;
//! the supervisor turns it into a GitHub review under the QA App, anchored to
//! the head it reviewed. The seat never touches GitHub.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::mirror::Mirror;
use crate::seat::{self, Pane, Verdict};
use crate::types::{JobRef, PrState, Role, SeatState, Sha};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

pub struct QaConfig {
    pub owner: String,
    pub repo: String,
    pub pr: u64,
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub seat_no: u8,
    pub floor_dir: PathBuf,
    pub mirror_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
    /// The repo's own fast check (manifest `[suites] fast`), shown to the seat.
    pub check_cmd: String,
}

#[derive(Debug)]
pub struct QaError(pub String);
impl<E: std::fmt::Display> From<E> for QaError {
    fn from(e: E) -> Self {
        QaError(e.to_string())
    }
}

fn now() -> u64 {
    seat::now()
}

fn record(log: &mut Log, repo: &str, kind: Kind) -> Result<(), QaError> {
    log.append(&Event {
        ts: now(),
        repo: repo.to_string(),
        kind,
    })?;
    Ok(())
}

/// Returns (review id, state) after posting the review.
pub fn run(cfg: &QaConfig, qa_app: &AppEntry) -> Result<(u64, String), QaError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mut log = Log::open(&cfg.run_log)?;

    // Read the PR with a read-only QA token.
    let read_perms = BTreeMap::from([
        ("pull_requests", "read"),
        ("contents", "read"),
        ("metadata", "read"),
    ]);
    let rtok = github::mint(qa_app, Some(&read_perms))?;
    let (code, body) = github::get_status(&rtok.token, &format!("/repos/{repo}/pulls/{}", cfg.pr))?;
    if code != 200 {
        return Err(QaError(format!("cannot read PR #{} ({code})", cfg.pr)));
    }
    let pr: serde_json::Value = serde_json::from_str(&body)?;
    let head = Sha::parse(pr["head"]["sha"].as_str().unwrap_or(""))?;
    let branch = pr["head"]["ref"].as_str().unwrap_or("").to_string();
    let base = pr["base"]["ref"].as_str().unwrap_or("staging").to_string();
    let title = pr["title"].as_str().unwrap_or("").to_string();
    let pr_body = pr["body"].as_str().unwrap_or("").to_string();
    let author = pr["user"]["login"].as_str().unwrap_or("").to_string();
    let issue = crate::poll::closes_issue(&pr_body).unwrap_or(0);
    if pr["state"].as_str() != Some("open") {
        return Err(QaError(format!("PR #{} is not open", cfg.pr)));
    }

    // Make sure the mirror has the branch at this head (the seat reads from the mirror only).
    let read_tok = github::mint(
        qa_app,
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
    let mirror_head = mirror.upstream_head(&branch)?;
    if mirror_head.as_ref() != Some(&head) {
        return Err(QaError(format!(
            "mirror upstream/{branch} is {:?}, PR head is {}",
            mirror_head.map(|s| s.short().to_string()),
            head.short()
        )));
    }

    // Render and wake.
    let job_text = std::fs::read_to_string(&cfg.job_template)?
        .replace("{{SEAT}}", &cfg.seat_no.to_string())
        .replace("{{PR}}", &cfg.pr.to_string())
        .replace("{{REPO}}", &repo)
        .replace("{{BRANCH}}", &branch)
        .replace("{{HEAD}}", head.as_str())
        .replace("{{ISSUE}}", &issue.to_string())
        .replace("{{TITLE}}", &title)
        .replace("{{BODY}}", &pr_body)
        .replace("{{BASE}}", &base)
        .replace("{{CHECK}}", &cfg.check_cmd);
    let pane = Pane {
        target: cfg.seat_target.clone(),
        role: Role::Qa,
        seat: cfg.seat_no,
    };
    let job = JobRef {
        role: Role::Qa,
        issue: Some(issue),
        pr: Some(cfg.pr),
    };
    let verdict_path = cfg.floor_dir.join(format!("verdict-pr-{}.json", cfg.pr));
    let st = seat::wake(
        &pane,
        &cfg.seat_expect_cmd,
        &job,
        &job_text,
        &verdict_path,
        cfg.timeout,
    )?;
    let deadline = match &st {
        SeatState::Working { deadline, .. } => *deadline,
        other => return Err(QaError(format!("unexpected seat state {other:?}"))),
    };
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: cfg.seat_no,
            role: Role::Qa,
            to: st.clone(),
            tokens_in: None,
            tokens_out: None,
        },
    )?;
    let (st, verdict) = seat::wait_verdict(&job, &verdict_path, deadline, Duration::from_secs(2))?;
    // Measured cost of this cycle: the seat's own transcript since the wake.
    let seat_home = cfg.floor_dir.join("home");
    let seat_wt = cfg.floor_dir.join(format!("wt-qa{}", cfg.seat_no));
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
            seat: cfg.seat_no,
            role: Role::Qa,
            to: st.clone(),
            tokens_in,
            tokens_out,
        },
    )?;
    let (v_head, approve, notes) = match verdict {
        Some(Verdict::Reviewed {
            head,
            approve,
            notes,
        }) => (head, approve, notes),
        Some(Verdict::Blocked { reason }) => {
            return Err(QaError(format!("QA seat blocked: {reason}")))
        }
        Some(other) => return Err(QaError(format!("unexpected verdict {other:?}"))),
        None => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.pr),
                    why: "QA seat stalled past deadline".into(),
                },
            )?;
            return Err(QaError("QA seat stalled; pane untouched".into()));
        }
    };
    let v_head = Sha::parse(&v_head)?;
    if v_head != head {
        return Err(QaError(format!(
            "verdict is for {} but PR head is {}",
            v_head.short(),
            head.short()
        )));
    }
    // Re-read the head right before posting: an approval must be anchored to
    // the commit that was reviewed, and GitHub will dismiss it if it moves.
    let (code, body) = github::get_status(&rtok.token, &format!("/repos/{repo}/pulls/{}", cfg.pr))?;
    let live_head = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| v["head"]["sha"].as_str().map(String::from))
        .unwrap_or_default();
    if code != 200 || live_head != head.as_str() {
        return Err(QaError(format!(
            "PR head moved during review ({} → {}); verdict discarded",
            head.short(),
            &live_head[..8.min(live_head.len())]
        )));
    }

    // Post the review under the QA App, anchored to the reviewed head.
    let write_perms = BTreeMap::from([
        ("pull_requests", "write"),
        ("contents", "read"),
        ("metadata", "read"),
    ]);
    let wtok = github::mint(qa_app, Some(&write_perms))?;
    let event = if approve {
        "APPROVE"
    } else {
        "REQUEST_CHANGES"
    };
    let text = format!("fwfd QA seat {} reviewed {} — {}\n\n{notes}\n\nfwf-Provenance: fwfd qa cycle · author {author}", cfg.seat_no, head.short(), if approve { "approved" } else { "changes requested" });
    let payload = serde_json::json!({ "commit_id": head.as_str(), "event": event, "body": text });
    let (code, body) = github::send_json(
        "POST",
        &wtok.token,
        &format!("/repos/{repo}/pulls/{}/reviews", cfg.pr),
        &payload,
    )?;
    if code != 200 && code != 201 {
        record(
            &mut log,
            &repo,
            Kind::Refused {
                what: format!("#{}", cfg.pr),
                why: format!(
                    "review refused ({code}): {}",
                    body.chars().take(160).collect::<String>()
                ),
            },
        )?;
        return Err(QaError(format!(
            "review refused ({code}): {}",
            body.chars().take(200).collect::<String>()
        )));
    }
    let v: serde_json::Value = serde_json::from_str(&body)?;
    let id = v["id"].as_u64().unwrap_or(0);
    let state = v["state"].as_str().unwrap_or("").to_string();
    let to = if approve {
        PrState::Approved {
            head: head.clone(),
            reviewer: Role::Qa,
        }
    } else {
        PrState::ChangesRequested { head: head.clone() }
    };
    record(
        &mut log,
        &repo,
        Kind::Pr {
            pr: cfg.pr,
            issue: Some(issue),
            to,
        },
    )?;
    Ok((id, state))
}
