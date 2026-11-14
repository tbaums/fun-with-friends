//! T-12 — the QA cycle: a woken QA pane reviews one PR and returns a verdict;
//! the supervisor turns it into a GitHub review under the QA App, anchored to
//! the head it reviewed. The seat never touches GitHub.

use crate::github::{self, AppEntry};
use crate::log::{Event, Kind, Log};
use crate::mirror::Mirror;
use crate::seat::{self, Pane, Verdict};
use crate::types::{JobRef, PrState, Role, SeatState, Sha};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(test)]
mod tests;

/// Where `run` reads the issue from; the fake GitHub in tests.
const API: &str = "https://api.github.com";

/// The most spec text one QA job carries (#713). A PM spec is a few thousand
/// characters; GitHub caps an issue body at 65,536. The bound keeps one
/// oversized issue from turning a wake into a paste the pane chokes on.
pub const SPEC_MAX_CHARS: usize = 20_000;

/// The statuses a criterion may carry, exactly as the prompt spells them.
pub const STATUSES: &[&str] = &["met", "not_met", "not_verifiable"];

/// One line of QA's per-acceptance-criterion review (#713). Every field
/// defaults, so a seat that leaves one out gets a named refusal from
/// [`check_verdict`] instead of a verdict that never parses and a stall.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Criterion {
    #[serde(default)]
    pub criterion: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub evidence: String,
}

/// Where the spec QA is held to came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpecSource {
    /// The issue body as GitHub serves it at dispatch: the PM spec as it
    /// stands now, including any later edit.
    Issue,
    /// The PM seat's own `verdict-spec-N.json` on this floor, used only when
    /// GitHub yields nothing.
    LocalVerdict,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Spec {
    pub text: String,
    pub source: SpecSource,
}

/// The body of issue `n`, read with `token` from `api`. `Err` names why there
/// is none (an HTTP status, a transport error).
pub fn issue_body(api: &str, token: &str, repo: &str, n: u64) -> Result<String, String> {
    let url = format!("{api}/repos/{repo}/issues/{n}");
    let mut r = github::http_agent(Some(Duration::from_secs(30)))
        .get(&url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "fwfd/0.1")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .call()
        .map_err(|e| format!("GET issue #{n}: {e}"))?;
    let code = r.status().as_u16();
    let text = github::body_text(&mut r);
    if code != 200 {
        return Err(format!("GET issue #{n}: HTTP {code}"));
    }
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("GET issue #{n}: {e}"))?;
    Ok(v["body"].as_str().unwrap_or("").to_string())
}

/// The spec body from the PM seat's verdict file on this floor, if one is there.
pub fn local_spec(floor_dir: &Path, n: u64) -> Option<String> {
    let p = floor_dir.join(format!("verdict-spec-{n}.json"));
    match seat::read_verdict(&p) {
        Ok(Some(Verdict::Specced { body, .. })) if !body.trim().is_empty() => Some(body),
        _ => None,
    }
}

/// The spec QA is held to, or a refusal (#713). Fail closed: with no issue,
/// or no non-empty body on GitHub and no local spec verdict, the seat is never
/// woken. A woken seat with no spec can only guess, and a forced
/// request-changes would send impl to rework a PR nothing is known to be
/// wrong with; refusing costs no tokens, and the loop re-reads next tick.
pub fn resolve_spec(
    issue: u64,
    fetched: Result<String, String>,
    floor_dir: &Path,
) -> Result<Spec, QaError> {
    if issue == 0 {
        return Err(QaError(
            "spec unavailable: the PR closes no issue, so there is no spec to review against; QA seat not woken".into(),
        ));
    }
    let why = match fetched {
        Ok(body) if !body.trim().is_empty() => {
            return Ok(Spec {
                text: body,
                source: SpecSource::Issue,
            })
        }
        Ok(_) => format!("issue #{issue} has an empty body"),
        Err(e) => e,
    };
    match local_spec(floor_dir, issue) {
        Some(text) => Ok(Spec {
            text,
            source: SpecSource::LocalVerdict,
        }),
        None => Err(QaError(format!(
            "spec unavailable for #{issue}: {why}, and no verdict-spec-{issue}.json on this floor; QA seat not woken (fail closed; the loop retries next tick)"
        ))),
    }
}

/// What `{{SPEC}}` becomes: a source line, then the spec, cut at
/// [`SPEC_MAX_CHARS`] with a note saying so.
pub fn spec_block(issue: u64, spec: &Spec) -> String {
    let source = match spec.source {
        SpecSource::Issue => format!("Source: issue #{issue} as it reads on GitHub at dispatch."),
        SpecSource::LocalVerdict => format!(
            "Source: the PM seat's local spec verdict for #{issue}. GitHub's copy could not be read, so a later edit to the issue may be missing."
        ),
    };
    let total = spec.text.chars().count();
    let body: String = spec.text.chars().take(SPEC_MAX_CHARS).collect();
    let cut = if total > SPEC_MAX_CHARS {
        format!("\n\n[fwf: spec truncated at {SPEC_MAX_CHARS} of {total} characters. A criterion you cannot read in full is not_verifiable.]")
    } else {
        String::new()
    };
    format!("{source}\n\n{}{cut}", body.trim_end())
}

/// Everything a QA job template is filled with.
pub struct Job<'a> {
    pub seat_no: u8,
    pub pr: u64,
    pub repo: &'a str,
    pub branch: &'a str,
    pub head: &'a str,
    pub issue: u64,
    pub title: &'a str,
    pub body: &'a str,
    pub base: &'a str,
    pub check: &'a str,
    pub deadline: &'a str,
    pub spec: &'a str,
}

/// Fill a QA job template. `{{SPEC}}` goes last so a placeholder written
/// inside an issue is never itself substituted.
pub fn render(template: &str, j: &Job) -> String {
    template
        .replace("{{SEAT}}", &j.seat_no.to_string())
        .replace("{{PR}}", &j.pr.to_string())
        .replace("{{REPO}}", j.repo)
        .replace("{{BRANCH}}", j.branch)
        .replace("{{HEAD}}", j.head)
        .replace("{{ISSUE}}", &j.issue.to_string())
        .replace("{{TITLE}}", j.title)
        .replace("{{BODY}}", j.body)
        .replace("{{BASE}}", j.base)
        .replace("{{CHECK}}", j.check)
        // When this cycle ends, so a long proof can be cut short (#589).
        .replace("{{DEADLINE}}", j.deadline)
        .replace("{{SPEC}}", j.spec)
}

/// An approval must carry the per-criterion review (#713): a non-empty
/// `criteria` list, each entry with text, a known status and evidence, and
/// none `not_met`. A request for changes passes as it is.
pub fn check_verdict(approve: bool, criteria: &[Criterion]) -> Result<(), String> {
    if !approve {
        return Ok(());
    }
    if criteria.is_empty() {
        return Err("an approval needs a `criteria` list: one entry per acceptance criterion of the spec, each {criterion, status: met|not_met|not_verifiable, evidence}".into());
    }
    for (i, c) in criteria.iter().enumerate() {
        let name = c.criterion.trim();
        if name.is_empty() {
            return Err(format!("criteria[{i}] has no `criterion` text"));
        }
        if !STATUSES.contains(&c.status.trim()) {
            return Err(format!(
                "criteria[{i}] (`{name}`) has status `{}`; it must be one of met, not_met, not_verifiable",
                c.status
            ));
        }
        if c.evidence.trim().is_empty() {
            return Err(format!(
                "criteria[{i}] (`{name}`) has no `evidence` (the test run or code path)"
            ));
        }
        if c.status.trim() == "not_met" {
            return Err(format!(
                "criteria[{i}] (`{name}`) is not_met; an unmet criterion is a request for changes, not an approval"
            ));
        }
    }
    Ok(())
}

/// The checklist as it appears in the posted review; empty when there is none.
pub fn checklist(criteria: &[Criterion]) -> String {
    if criteria.is_empty() {
        return String::new();
    }
    let mut out = String::from("**Acceptance criteria**\n\n");
    for c in criteria {
        let (mark, said) = match c.status.trim() {
            "met" => ("x", "met"),
            "not_met" => (" ", "not met"),
            "not_verifiable" => (" ", "not verifiable"),
            other => (" ", other),
        };
        out.push_str(&format!(
            "- [{mark}] {} — **{said}**: {}\n",
            c.criterion.trim(),
            c.evidence.trim()
        ));
    }
    out.push('\n');
    out
}

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

    // The spec QA is held to (#713): the issue body as it stands now, read
    // here because the seat has no token. Its own narrow token, so a refused
    // mint lands on the local fallback rather than failing the whole read.
    let fetched = if issue == 0 {
        Err("no issue".to_string())
    } else {
        let issue_perms = BTreeMap::from([("issues", "read"), ("metadata", "read")]);
        github::mint(qa_app, Some(&issue_perms))
            .map_err(|e| format!("issue token: {e}"))
            .and_then(|t| issue_body(API, &t.token, &repo, issue))
    };
    let spec = match resolve_spec(issue, fetched, &cfg.floor_dir) {
        Ok(s) => s,
        Err(e) => {
            record(
                &mut log,
                &repo,
                Kind::Refused {
                    what: format!("#{}", cfg.pr),
                    why: e.0.clone(),
                },
            )?;
            return Err(e);
        }
    };

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
    // `"{{DEADLINE}}"` is filled inside `render` (#589).
    let job_text = render(
        &std::fs::read_to_string(&cfg.job_template)?,
        &Job {
            seat_no: cfg.seat_no,
            pr: cfg.pr,
            repo: &repo,
            branch: &branch,
            head: head.as_str(),
            issue,
            title: &title,
            body: &pr_body,
            base: &base,
            check: &cfg.check_cmd,
            deadline: &seat::local_hhmm(now() + cfg.timeout.as_secs()),
            spec: &spec_block(issue, &spec),
        },
    );
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
    let (st, verdict) = seat::wait_verdict(
        &job,
        cfg.seat_no,
        &verdict_path,
        deadline,
        Duration::from_secs(2),
    )?;
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
    let (v_head, approve, notes, criteria) = match verdict {
        Some(Verdict::Reviewed {
            head,
            approve,
            notes,
            criteria,
        }) => (head, approve, notes, criteria),
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
    // An approval that skipped the per-criterion review posts nothing (#713).
    // The PR stays un-reviewed, so the loop wakes QA on it again.
    if let Err(why) = check_verdict(approve, &criteria) {
        let why = format!("QA approval rejected: {why}; no review posted");
        record(
            &mut log,
            &repo,
            Kind::Refused {
                what: format!("#{}", cfg.pr),
                why: why.clone(),
            },
        )?;
        return Err(QaError(why));
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
    let text = format!("fwf QA seat {} reviewed {} — {}\n\n{notes}\n\n{}fwf-Provenance: fwf qa cycle · author {author}", cfg.seat_no, head.short(), if approve { "approved" } else { "changes requested" }, checklist(&criteria));
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
