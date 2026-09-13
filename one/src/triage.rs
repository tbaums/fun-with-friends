//! T-23 — the cheap coordination cycle and the human un-gate.
//!
//! GV triage: a woken GV pane (Haiku/Sonnet per the manifest) judges one
//! issue and returns `Triaged { ready, reason }`. If not ready, the supervisor
//! applies the gate label and posts the reason under the ops App. "Ready" is
//! never granted by a model: the only way an issue becomes eligible is the
//! human un-gate, `fwfd ungate <n>`, which removes the label under ops and
//! records a Human event. That is the design's one human decision, made
//! mechanical and attributable.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::seat::{self, Pane, Verdict};
use crate::types::{IssueState, JobRef, Role, SeatState};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct TriageConfig {
    pub owner: String,
    pub repo: String,
    pub issue: u64,
    pub gate_label: String,
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub floor_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
}

#[derive(Debug)]
pub struct TriageError(pub String);
impl<E: std::fmt::Display> From<E> for TriageError {
    fn from(e: E) -> Self {
        TriageError(e.to_string())
    }
}

fn record(log: &mut Log, repo: &str, kind: Kind) -> Result<(), TriageError> {
    log.append(&Event {
        ts: seat::now(),
        repo: repo.to_string(),
        kind,
    })?;
    Ok(())
}

/// Wake the GV seat on one issue; apply the gate label with the reason if the
/// verdict is not-ready. Returns (ready, reason).
pub fn run(cfg: &TriageConfig, ops: &AppEntry) -> Result<(bool, String), TriageError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mut log = Log::open(&cfg.run_log)?;
    let read = BTreeMap::from([("issues", "read"), ("metadata", "read")]);
    let rtok = github::mint(ops, Some(&read))?;
    let (code, body) =
        github::get_status(&rtok.token, &format!("/repos/{repo}/issues/{}", cfg.issue))?;
    if code != 200 {
        return Err(TriageError(format!(
            "cannot read issue #{} ({code})",
            cfg.issue
        )));
    }
    let v: serde_json::Value = serde_json::from_str(&body)?;
    if v["pull_request"].is_object() {
        return Err(TriageError(format!("#{} is a pull request", cfg.issue)));
    }
    let title = v["title"].as_str().unwrap_or("").to_string();
    let issue_body = v["body"].as_str().unwrap_or("").to_string();

    let job_text = std::fs::read_to_string(&cfg.job_template)?
        .replace("{{ISSUE}}", &cfg.issue.to_string())
        .replace("{{REPO}}", &repo)
        .replace("{{TITLE}}", &title)
        .replace("{{BODY}}", &issue_body)
        // When this cycle ends, so a long proof can be cut short (#589).
        .replace(
            "{{DEADLINE}}",
            &seat::local_hhmm(seat::now() + cfg.timeout.as_secs()),
        );
    let pane = Pane {
        target: cfg.seat_target.clone(),
        role: Role::Gv,
        seat: 1,
    };
    let job = JobRef {
        role: Role::Gv,
        issue: Some(cfg.issue),
        pr: None,
    };
    let verdict_path = cfg
        .floor_dir
        .join(format!("verdict-triage-{}.json", cfg.issue));
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
        other => return Err(TriageError(format!("unexpected seat state {other:?}"))),
    };
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: 1,
            role: Role::Gv,
            to: st,
            tokens_in: None,
            tokens_out: None,
        },
    )?;
    let (st, verdict) = seat::wait_verdict(&job, &verdict_path, deadline, Duration::from_secs(2))?;
    let usage = crate::cost::cycle_usage(
        &cfg.floor_dir.join("home"),
        &cfg.floor_dir.join("wt-gv1"),
        deadline.saturating_sub(cfg.timeout.as_secs()),
    );
    let (ti, to) = usage
        .as_ref()
        .map(|u| (Some(u.tokens_in()), Some(u.tokens_out())))
        .unwrap_or((None, None));
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: 1,
            role: Role::Gv,
            to: st,
            tokens_in: ti,
            tokens_out: to,
        },
    )?;
    let (ready, reason) = match verdict {
        Some(Verdict::Triaged { ready, reason }) => (ready, reason),
        Some(Verdict::Blocked { reason }) => {
            return Err(TriageError(format!("GV seat blocked: {reason}")))
        }
        Some(other) => return Err(TriageError(format!("unexpected verdict {other:?}"))),
        None => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.issue),
                    why: "GV seat stalled".into(),
                },
            )?;
            return Err(TriageError("GV seat stalled; pane untouched".into()));
        }
    };
    if !ready {
        let write = BTreeMap::from([("issues", "write"), ("metadata", "read")]);
        let wtok = github::mint(ops, Some(&write))?;
        let (c1, _) = github::send_json(
            "POST",
            &wtok.token,
            &format!("/repos/{repo}/issues/{}/labels", cfg.issue),
            &serde_json::json!({ "labels": [cfg.gate_label] }),
        )?;
        let (c2, _) = github::send_json(
            "POST",
            &wtok.token,
            &format!("/repos/{repo}/issues/{}/comments", cfg.issue),
            &serde_json::json!({ "body": format!("**fwfd GV triage: not ready.** {reason}\n\nGated with `{}` under the ops identity. A human un-gate (`fwfd ungate {}`) makes it eligible.\n\nfwf-Provenance: fwfd triage cycle", cfg.gate_label, cfg.issue) }),
        )?;
        if c1 != 200 || (c2 != 201 && c2 != 200) {
            return Err(TriageError(format!(
                "gate label/comment refused ({c1}/{c2})"
            )));
        }
        record(
            &mut log,
            &repo,
            Kind::Issue {
                issue: cfg.issue,
                to: IssueState::Gated,
            },
        )?;
    } else {
        record(
            &mut log,
            &repo,
            Kind::Note {
                text: format!(
                    "GV triage: #{} judged ready — awaiting the human un-gate",
                    cfg.issue
                ),
            },
        )?;
    }
    Ok((ready, reason))
}

/// The human un-gate: remove the gate label under ops and record who did it.
/// The label event on GitHub carries the ops App as actor; the run record
/// carries the human's name from the command line.
pub fn ungate(
    owner: &str,
    repo: &str,
    issue: u64,
    gate_label: &str,
    actor: &str,
    run_log: &Path,
    ops: &AppEntry,
) -> Result<(), TriageError> {
    let full = format!("{owner}/{repo}");
    let write = BTreeMap::from([("issues", "write"), ("metadata", "read")]);
    let tok = github::mint(ops, Some(&write))?;
    let (code, body) = github::send_json(
        "DELETE",
        &tok.token,
        &format!("/repos/{full}/issues/{issue}/labels/{gate_label}"),
        &serde_json::json!({}),
    )?;
    if code != 200 && code != 404 {
        return Err(TriageError(format!(
            "un-gate refused ({code}): {}",
            body.chars().take(120).collect::<String>()
        )));
    }
    let (c2, _) = github::send_json(
        "POST",
        &tok.token,
        &format!("/repos/{full}/issues/{issue}/comments"),
        &serde_json::json!({ "body": format!("**OPERATOR-UNGATE #{issue}** by {actor} via `fwfd ungate` — eligible for the factory.\n\nfwf-Provenance: fwfd ungate") }),
    )?;
    if c2 != 201 && c2 != 200 {
        return Err(TriageError(format!("un-gate comment refused ({c2})")));
    }
    let mut log = Log::open(run_log)?;
    log.append(&Event {
        ts: seat::now(),
        repo: full.clone(),
        kind: Kind::Human {
            actor: actor.to_string(),
            action: "ungate".into(),
            target: format!("#{issue}"),
        },
    })?;
    log.append(&Event {
        ts: seat::now(),
        repo: full,
        kind: Kind::Issue {
            issue,
            to: IssueState::Ready,
        },
    })?;
    Ok(())
}
