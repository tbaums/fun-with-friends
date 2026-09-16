//! T-23 — the cheap coordination cycle and the human un-gate.
//!
//! GV triage: a woken GV pane (Haiku/Sonnet per the manifest) judges one
//! issue and returns `Triaged { ready, reason }`. If not ready, the supervisor
//! applies the gate label and posts the reason under the ops App. "Ready" is
//! never granted by a model: the only way an issue becomes eligible is the
//! human un-gate, `fwf ungate <n>`, which removes the label under ops and
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

/// Every "GV judged this ready" note starts with this; the run loop reads the
/// issue number back out of it.
pub const READY_NOTE_PREFIX: &str = "GV triage: #";

/// The record's note for a ready verdict. One spelling, written here and read
/// by `run`'s spec cycle, so the two cannot drift apart.
pub fn ready_note(issue: u64) -> String {
    format!("{READY_NOTE_PREFIX}{issue} judged ready — awaiting the human un-gate")
}

/// Wake the GV seat on one issue; apply the gate label with the reason if the
/// verdict is not-ready. Returns (ready, reason).
///
/// A gated issue is judged the same way an un-gated one is (#629): the not-ready
/// path re-asserts the label it already carries, which GitHub accepts, so the
/// loop's spec cycle can offer newly filed `product-wip` tickets here.
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
            &serde_json::json!({ "body": format!("**fwf GV triage: not ready.** {reason}\n\nGated with `{}` under the ops identity. A human un-gate (`fwf ungate {}`) makes it eligible.\n\nfwf-Provenance: fwf triage cycle", cfg.gate_label, cfg.issue) }),
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
                text: ready_note(cfg.issue),
            },
        )?;
    }
    Ok((ready, reason))
}

/// Who un-gated (#645). The mechanics are identical either way — the label
/// comes off under ops, the record names the human — but a standing manifest
/// delegation must never read as a keystroke somebody made. Attribution is the
/// whole reason the delegate exists, so the two say which they are, in the
/// comment on GitHub and in the run record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ungate<'a> {
    /// A human ran `fwf ungate --by <name>`.
    Manual(&'a str),
    /// The loop stood in for the name the manifest's `delegate_ungate` gave it.
    Delegated(&'a str),
}

impl<'a> Ungate<'a> {
    /// Whose decision it is, either way.
    pub fn actor(self) -> &'a str {
        match self {
            Ungate::Manual(who) | Ungate::Delegated(who) => who,
        }
    }

    /// What the run record's `Human.action` says. Rendered verbatim by the
    /// dash and by `fwf status` — nothing branches on it.
    pub fn action(self) -> &'static str {
        match self {
            Ungate::Manual(_) => "ungate",
            Ungate::Delegated(_) => "ungate (delegated)",
        }
    }

    /// The clause the issue comment carries. Empty for a manual un-gate, so
    /// what a human's `fwf ungate` posts is byte-identical to before #645.
    fn marker(self) -> &'static str {
        match self {
            Ungate::Manual(_) => "",
            Ungate::Delegated(_) => " (delegated via manifest `delegate_ungate`)",
        }
    }
}

/// The comment an un-gate posts on the issue. The `**OPERATOR-UNGATE #N**`
/// opening is the sentinel other tools scan for, so the marker goes after it,
/// never in front of it.
pub fn ungate_comment(issue: u64, by: Ungate) -> String {
    format!(
        "**OPERATOR-UNGATE #{issue}** by {} via `fwf ungate`{} — eligible for the factory.\n\nfwf-Provenance: fwf ungate",
        by.actor(),
        by.marker()
    )
}

/// The human un-gate: remove the gate label under ops and record who did it.
/// The label event on GitHub carries the ops App as actor; the run record
/// carries the human's name — from the command line, or from the manifest that
/// delegated the decision to a name.
pub fn ungate(
    owner: &str,
    repo: &str,
    issue: u64,
    gate_label: &str,
    by: Ungate,
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
        &serde_json::json!({ "body": ungate_comment(issue, by) }),
    )?;
    if c2 != 201 && c2 != 200 {
        return Err(TriageError(format!("un-gate comment refused ({c2})")));
    }
    let mut log = Log::open(run_log)?;
    for ev in ungate_events(&full, issue, by, seat::now()) {
        log.append(&ev)?;
    }
    Ok(())
}

/// What an un-gate leaves in the record: who did it, how, and that the issue is
/// now eligible. `fwf run`'s spec cycle reads both back (a delegated un-gate is
/// still an attributable human act), so the shape lives in one place.
pub fn ungate_events(repo: &str, issue: u64, by: Ungate, ts: u64) -> [Event; 2] {
    [
        Event {
            ts,
            repo: repo.to_string(),
            kind: Kind::Human {
                actor: by.actor().to_string(),
                action: by.action().into(),
                target: format!("#{issue}"),
            },
        },
        Event {
            ts,
            repo: repo.to_string(),
            kind: Kind::Issue {
                issue,
                to: IssueState::Ready,
            },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #645: the un-gate a manifest delegates and the un-gate a human types
    /// are the same act with the same authority, and they must not read the
    /// same. Everything else about them — who, which issue, the `Ready` that
    /// follows — stays identical, so this diffs the two.
    #[test]
    fn a_delegated_ungate_says_so_and_a_manual_one_is_word_for_word_what_it_was() {
        const WHO: &str = "jamie-proxy";
        let (manual, delegated) = (
            ungate_comment(1381, Ungate::Manual(WHO)),
            ungate_comment(1381, Ungate::Delegated(WHO)),
        );
        // the manual comment is byte-identical to the pre-#645 text
        assert_eq!(
            manual,
            "**OPERATOR-UNGATE #1381** by jamie-proxy via `fwf ungate` — eligible for the factory.\n\nfwf-Provenance: fwf ungate"
        );
        // and the delegated one is that text plus the marker, nothing else
        assert_eq!(
            delegated,
            manual.replace(
                "via `fwf ungate` —",
                "via `fwf ungate` (delegated via manifest `delegate_ungate`) —"
            )
        );
        assert!(!manual.contains("(delegated"), "{manual}");

        let (m, d) = (
            ungate_events("o/r", 1381, Ungate::Manual(WHO), 7),
            ungate_events("o/r", 1381, Ungate::Delegated(WHO), 7),
        );
        let human = |evs: &[Event; 2]| match &evs[0].kind {
            Kind::Human {
                actor,
                action,
                target,
            } => (actor.clone(), action.clone(), target.clone()),
            other => panic!("the first event names the human, not {other:?}"),
        };
        assert_eq!(
            human(&m),
            ("jamie-proxy".into(), "ungate".into(), "#1381".into())
        );
        assert_eq!(
            human(&d),
            (
                "jamie-proxy".into(),
                "ungate (delegated)".into(),
                "#1381".into()
            )
        );
        // the second event is what makes the issue claimable, and the marker
        // has no business changing it
        assert_eq!(m[1], d[1]);
        assert!(matches!(
            m[1].kind,
            Kind::Issue {
                issue: 1381,
                to: IssueState::Ready
            }
        ));
    }
}
