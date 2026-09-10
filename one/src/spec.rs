//! T-26 — the PM cycle: a woken PM pane turns a gated issue into a spec.
//!
//! The seat returns `Specced { title, body, discovery, questions }`; the
//! supervisor edits the issue under the ops identity (title + body), adds the
//! discovery label when asked, and posts the open questions as one comment.
//! The gate label is never touched here: only `fwfd ungate` does that.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::seat::{self, Pane, Verdict};
use crate::types::{JobRef, Role, SeatState};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

pub struct SpecConfig {
    pub owner: String,
    pub repo: String,
    pub issue: u64,
    pub gate_label: String,
    pub discovery_label: String,
    pub seat_target: String,
    pub seat_expect_cmd: String,
    pub floor_dir: PathBuf,
    pub job_template: PathBuf,
    pub run_log: PathBuf,
    pub timeout: Duration,
}

#[derive(Debug)]
pub struct SpecError(pub String);
impl<E: std::fmt::Display> From<E> for SpecError {
    fn from(e: E) -> Self {
        SpecError(e.to_string())
    }
}

fn record(log: &mut Log, repo: &str, kind: Kind) -> Result<(), SpecError> {
    log.append(&Event {
        ts: seat::now(),
        repo: repo.to_string(),
        kind,
    })?;
    Ok(())
}

/// The issue edit the supervisor performs from a `Specced` verdict. Pure, so
/// the shape is testable without a seat: the body carries a provenance
/// trailer and the label list only ever ADDS discovery (never removes the
/// gate).
pub fn edit_payload(
    title: &str,
    body: &str,
    discovery: bool,
    discovery_label: &str,
    existing_labels: &[String],
    original: &str,
) -> serde_json::Value {
    let mut labels: Vec<String> = existing_labels.to_vec();
    if discovery && !labels.iter().any(|l| l == discovery_label) {
        labels.push(discovery_label.to_string());
    }
    serde_json::json!({
        "title": title,
        "body": format!(
            "{}\n\n<details><summary>Original text before the PM spec</summary>\n\n{}\n\n</details>\n\n<!-- fwf-Provenance: fwfd spec (PM seat); gate untouched -->",
            body.trim_end(),
            original.trim()
        ),
        "labels": labels,
    })
}

pub fn run(cfg: &SpecConfig, ops: &AppEntry) -> Result<(String, Vec<String>), SpecError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mut log = Log::open(&cfg.run_log)?;
    let read = BTreeMap::from([("issues", "read"), ("metadata", "read")]);
    let rtok = github::mint(ops, Some(&read))?;
    let (code, body) =
        github::get_status(&rtok.token, &format!("/repos/{repo}/issues/{}", cfg.issue))?;
    if code != 200 {
        return Err(SpecError(format!(
            "cannot read issue #{} ({code})",
            cfg.issue
        )));
    }
    let v: serde_json::Value = serde_json::from_str(&body)?;
    if v["pull_request"].is_object() {
        return Err(SpecError(format!("#{} is a pull request", cfg.issue)));
    }
    let labels: Vec<String> = v["labels"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|l| l["name"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if !labels.iter().any(|l| l == &cfg.gate_label) {
        return Err(SpecError(format!(
            "#{} is not gated ({:?} missing): a spec cycle only runs on gated issues, so an approved issue is never rewritten under a builder",
            cfg.issue, cfg.gate_label
        )));
    }
    let title = v["title"].as_str().unwrap_or("").to_string();
    let issue_body = v["body"].as_str().unwrap_or("").to_string();

    let job_text = std::fs::read_to_string(&cfg.job_template)?
        .replace("{{ISSUE}}", &cfg.issue.to_string())
        .replace("{{REPO}}", &repo)
        .replace("{{TITLE}}", &title)
        .replace("{{BODY}}", &issue_body);
    let pane = Pane {
        target: cfg.seat_target.clone(),
        role: Role::Pm,
        seat: 1,
    };
    let job = JobRef {
        role: Role::Pm,
        issue: Some(cfg.issue),
        pr: None,
    };
    let verdict_path = cfg
        .floor_dir
        .join(format!("verdict-spec-{}.json", cfg.issue));
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
        other => return Err(SpecError(format!("unexpected seat state {other:?}"))),
    };
    record(
        &mut log,
        &repo,
        Kind::Seat {
            seat: 1,
            role: Role::Pm,
            to: st,
            tokens_in: None,
            tokens_out: None,
        },
    )?;
    let (st, verdict) = seat::wait_verdict(&job, &verdict_path, deadline, Duration::from_secs(2))?;
    let usage = crate::cost::cycle_usage(
        &cfg.floor_dir.join("home"),
        &cfg.floor_dir.join("wt-pm1"),
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
            role: Role::Pm,
            to: st,
            tokens_in: ti,
            tokens_out: to,
        },
    )?;
    let (new_title, spec, discovery, questions) = match verdict {
        Some(Verdict::Specced {
            title,
            body,
            discovery,
            questions,
        }) => (title, body, discovery, questions),
        Some(Verdict::Blocked { reason }) => {
            return Err(SpecError(format!("PM seat blocked: {reason}")))
        }
        Some(other) => return Err(SpecError(format!("unexpected verdict {other:?}"))),
        None => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.issue),
                    why: "PM seat stalled".into(),
                },
            )?;
            return Err(SpecError("PM seat stalled; pane untouched".into()));
        }
    };
    if spec.trim().len() < 80 || !spec.contains("Acceptance") {
        return Err(SpecError(
            "PM verdict is not a spec (no Acceptance section or too short); issue untouched".into(),
        ));
    }
    let write = BTreeMap::from([("issues", "write"), ("metadata", "read")]);
    let wtok = github::mint(ops, Some(&write))?;
    let title_final = if new_title.trim().is_empty() {
        title.clone()
    } else {
        new_title
    };
    let payload = edit_payload(
        &title_final,
        &spec,
        discovery,
        &cfg.discovery_label,
        &labels,
        &issue_body,
    );
    let (c1, b1) = github::send_json(
        "PATCH",
        &wtok.token,
        &format!("/repos/{repo}/issues/{}", cfg.issue),
        &payload,
    )?;
    if c1 != 200 {
        return Err(SpecError(format!(
            "issue edit refused ({c1}): {}",
            b1.chars().take(120).collect::<String>()
        )));
    }
    let mut comment = format!(
        "**fwfd spec: PM seat drafted the spec** (issue body replaced; still gated with `{}`{}).",
        cfg.gate_label,
        if discovery {
            format!(", marked `{}`", cfg.discovery_label)
        } else {
            String::new()
        }
    );
    if !questions.is_empty() {
        comment.push_str("\n\nQuestions that change what gets built:\n");
        for q in &questions {
            comment.push_str(&format!("- {q}\n"));
        }
    }
    comment.push_str(&format!(
        "\nA human un-gate (`fwfd ungate {}`) makes it eligible.\n\nfwf-Provenance: fwfd spec cycle",
        cfg.issue
    ));
    let (c2, _) = github::send_json(
        "POST",
        &wtok.token,
        &format!("/repos/{repo}/issues/{}/comments", cfg.issue),
        &serde_json::json!({ "body": comment }),
    )?;
    if c2 != 201 && c2 != 200 {
        return Err(SpecError(format!("spec comment refused ({c2})")));
    }
    record(
        &mut log,
        &repo,
        Kind::Note {
            text: format!(
                "PM spec written into #{} ({} chars, discovery={discovery}, {} question(s)); gate untouched",
                cfg.issue,
                spec.len(),
                questions.len()
            ),
        },
    )?;
    Ok((title_final, questions))
}

pub fn default_template(family: &str) -> PathBuf {
    crate::prompts::job_path(family, "pm")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edit_payload_adds_discovery_only_and_keeps_the_gate() {
        let labels = vec!["product-wip".to_string(), "bug".to_string()];
        let p = edit_payload("T", "body", true, "discovery", &labels, "orig");
        let got: Vec<&str> = p["labels"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap())
            .collect();
        assert_eq!(got, vec!["product-wip", "bug", "discovery"]);
        assert!(p["body"]
            .as_str()
            .unwrap()
            .contains("fwf-Provenance: fwfd spec"));
        let p2 = edit_payload("T", "body", false, "discovery", &labels, "orig");
        assert_eq!(p2["labels"].as_array().unwrap().len(), 2);
        let p3 = edit_payload(
            "T",
            "body",
            true,
            "discovery",
            &["discovery".to_string()],
            "orig",
        );
        assert_eq!(p3["labels"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn specced_verdict_parses_with_defaults() {
        let v: Verdict =
            serde_json::from_str(r#"{"verdict":"specced","title":"x","body":"y"}"#).unwrap();
        assert!(
            matches!(v, Verdict::Specced { discovery: false, ref questions, .. } if questions.is_empty())
        );
    }
}
