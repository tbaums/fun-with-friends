//! T-20 — the check-run writer.
//!
//! A gate verdict becomes one GitHub check run on the sha it judged, under
//! the App the supervisor chose (never a seat). The mapping is total over
//! the terminal states and refuses everything else: `Green` → success,
//! `Red` → failure, `Killed` → cancelled (the venue killed it — not a
//! verdict on the code), and `Unknown` / non-terminal states are never
//! posted — a check run that lies about an unread gate is worse than none.

use crate::types::{GateState, Sha};
use serde_json::{json, Value};
use std::fmt;

/// Where to post and as whom. `base_url` is `https://api.github.com` in
/// production and the fake's `http://127.0.0.1:<port>` in tests.
#[derive(Clone, Debug)]
pub struct CheckClient {
    pub base_url: String,
    pub token: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CheckError {
    /// The gate state is `Unknown` (or not terminal): refused, nothing sent.
    Unknown,
    /// Transport failure — nothing is known about whether it landed.
    Http(String),
    /// GitHub answered with a non-2xx status.
    Refused { status: u16, body: String },
    /// A 2xx answer without a usable `id` / body.
    Malformed(String),
}

impl fmt::Display for CheckError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CheckError::Unknown => write!(
                f,
                "gate state is Unknown or not terminal; refusing to post a check run"
            ),
            CheckError::Http(e) => write!(f, "http: {e}"),
            CheckError::Refused { status, body } => {
                write!(
                    f,
                    "github refused ({status}): {}",
                    body.chars().take(200).collect::<String>()
                )
            }
            CheckError::Malformed(what) => write!(f, "malformed reply: {what}"),
        }
    }
}

/// One completed check run. Only terminal verdicts map.
struct Conclusion {
    conclusion: &'static str,
    title: String,
    summary: String,
}

fn conclude(state: &GateState) -> Result<Conclusion, CheckError> {
    Ok(match state {
        GateState::Green { suite, secs, .. } => Conclusion {
            conclusion: "success",
            title: format!("{suite}: green"),
            summary: format!("{suite} passed in {secs}s"),
        },
        GateState::Red { suite, failed, .. } => Conclusion {
            conclusion: "failure",
            title: format!("{suite}: red"),
            summary: format!("{suite}: {failed} failed"),
        },
        GateState::Killed { suite, reason, .. } => Conclusion {
            conclusion: "cancelled",
            title: format!("{suite}: killed"),
            summary: format!("{suite} was killed by the venue: {reason}"),
        },
        GateState::Queued { .. } | GateState::Running { .. } | GateState::Unknown => {
            return Err(CheckError::Unknown)
        }
    })
}

/// POST a completed check run named `name` on `sha`. Returns the check run id.
pub fn post_check_run(
    client: &CheckClient,
    repo: &str,
    sha: &Sha,
    name: &str,
    state: &GateState,
    details_url: Option<&str>,
) -> Result<u64, CheckError> {
    let c = conclude(state)?;
    let mut body = json!({
        "name": name,
        "head_sha": sha.as_str(),
        "status": "completed",
        "conclusion": c.conclusion,
        "output": { "title": c.title, "summary": c.summary },
    });
    if let Some(u) = details_url {
        body["details_url"] = json!(u);
    }
    let (status, text) = send(
        client,
        "POST",
        &format!("/repos/{repo}/check-runs"),
        Some(&body),
    )?;
    if !(200..300).contains(&status) {
        return Err(CheckError::Refused { status, body: text });
    }
    serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v["id"].as_u64())
        .ok_or_else(|| CheckError::Malformed(format!("no id in {text}")))
}

/// `(name, status, conclusion)` for every check run on `sha`. A run without
/// a conclusion (queued / in_progress) reports an empty conclusion.
pub fn list_check_runs(
    client: &CheckClient,
    repo: &str,
    sha: &Sha,
) -> Result<Vec<(String, String, String)>, CheckError> {
    let path = format!("/repos/{repo}/commits/{}/check-runs", sha.as_str());
    let (status, text) = send(client, "GET", &path, None)?;
    if !(200..300).contains(&status) {
        return Err(CheckError::Refused { status, body: text });
    }
    let v: Value =
        serde_json::from_str(&text).map_err(|e| CheckError::Malformed(format!("not json: {e}")))?;
    let runs = v["check_runs"]
        .as_array()
        .ok_or_else(|| CheckError::Malformed("no check_runs array".into()))?;
    Ok(runs
        .iter()
        .map(|r| {
            let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
            (s("name"), s("status"), s("conclusion"))
        })
        .collect())
}

fn send(
    client: &CheckClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<(u16, String), CheckError> {
    let url = format!("{}{path}", client.base_url.trim_end_matches('/'));
    let req = ureq::request(method, &url)
        .set("Authorization", &format!("Bearer {}", client.token))
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "fwfd/0.1")
        .set("X-GitHub-Api-Version", "2022-11-28");
    let resp = match body {
        Some(b) => req.send_string(&b.to_string()),
        None => req.call(),
    };
    match resp {
        Ok(r) => {
            let code = r.status();
            Ok((code, r.into_string().unwrap_or_default()))
        }
        Err(ureq::Error::Status(code, r)) => Ok((code, r.into_string().unwrap_or_default())),
        Err(e) => Err(CheckError::Http(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_github::FakeGitHub;

    const O: &str = "tbaums";
    const R: &str = "fun-with-friends";

    fn sha(c: char) -> Sha {
        Sha::parse(&std::iter::repeat_n(c, 40).collect::<String>()).unwrap()
    }

    fn client(fake: &FakeGitHub) -> CheckClient {
        fake.add_repo(O, R);
        CheckClient {
            base_url: fake.base_url().to_string(),
            token: fake.token("fwf-ops[bot]", &[("checks", "write"), ("metadata", "read")]),
        }
    }

    fn repo() -> String {
        format!("{O}/{R}")
    }

    #[test]
    fn green_posts_success() {
        let fake = FakeGitHub::start();
        let c = client(&fake);
        let s = sha('a');
        let st = GateState::Green {
            sha: s.clone(),
            suite: "fast".into(),
            secs: 42,
        };
        let id = post_check_run(&c, &repo(), &s, "gate/fast", &st, Some("http://dash/1")).unwrap();
        assert!(id >= 1000);
        let w = fake.writes();
        let post = w
            .iter()
            .find(|w| w.path.ends_with("/check-runs"))
            .expect("one POST");
        assert_eq!(post.body["status"], "completed");
        assert_eq!(post.body["conclusion"], "success");
        assert_eq!(post.body["head_sha"], s.as_str());
        assert_eq!(post.body["output"]["title"], "fast: green");
        assert_eq!(post.body["details_url"], "http://dash/1");
    }

    #[test]
    fn red_posts_failure_with_count() {
        let fake = FakeGitHub::start();
        let c = client(&fake);
        let s = sha('b');
        let st = GateState::Red {
            sha: s.clone(),
            suite: "fast".into(),
            failed: 3,
        };
        post_check_run(&c, &repo(), &s, "gate/fast", &st, None).unwrap();
        let w = fake.writes();
        assert_eq!(w[0].body["conclusion"], "failure");
        assert_eq!(w[0].body["output"]["summary"], "fast: 3 failed");
        assert!(w[0].body["details_url"].is_null());
    }

    #[test]
    fn killed_posts_cancelled() {
        let fake = FakeGitHub::start();
        let c = client(&fake);
        let s = sha('c');
        let st = GateState::Killed {
            sha: s.clone(),
            suite: "e2e".into(),
            reason: "oom or killed".into(),
        };
        post_check_run(&c, &repo(), &s, "gate/e2e", &st, None).unwrap();
        assert_eq!(fake.writes()[0].body["conclusion"], "cancelled");
    }

    #[test]
    fn unknown_and_non_terminal_are_refused_without_a_request() {
        let fake = FakeGitHub::start();
        let c = client(&fake);
        let s = sha('d');
        for st in [
            GateState::Unknown,
            GateState::Queued {
                sha: s.clone(),
                suite: "fast".into(),
            },
            GateState::Running {
                sha: s.clone(),
                suite: "fast".into(),
                started: 1,
            },
        ] {
            assert_eq!(
                post_check_run(&c, &repo(), &s, "gate/fast", &st, None),
                Err(CheckError::Unknown)
            );
        }
        assert!(fake.writes().is_empty(), "nothing was sent");
        assert!(list_check_runs(&c, &repo(), &s).unwrap().is_empty());
    }

    #[test]
    fn list_returns_what_was_posted_for_that_sha_only() {
        let fake = FakeGitHub::start();
        let c = client(&fake);
        let s = sha('e');
        let other = sha('f');
        post_check_run(
            &c,
            &repo(),
            &s,
            "gate/fast",
            &GateState::Green {
                sha: s.clone(),
                suite: "fast".into(),
                secs: 1,
            },
            None,
        )
        .unwrap();
        post_check_run(
            &c,
            &repo(),
            &s,
            "gate/e2e",
            &GateState::Killed {
                sha: s.clone(),
                suite: "e2e".into(),
                reason: "timeout".into(),
            },
            None,
        )
        .unwrap();
        post_check_run(
            &c,
            &repo(),
            &other,
            "gate/fast",
            &GateState::Red {
                sha: other.clone(),
                suite: "fast".into(),
                failed: 1,
            },
            None,
        )
        .unwrap();
        let runs = list_check_runs(&c, &repo(), &s).unwrap();
        assert_eq!(
            runs,
            vec![
                (
                    "gate/fast".to_string(),
                    "completed".to_string(),
                    "success".to_string()
                ),
                (
                    "gate/e2e".to_string(),
                    "completed".to_string(),
                    "cancelled".to_string()
                ),
            ]
        );
        assert_eq!(list_check_runs(&c, &repo(), &other).unwrap().len(), 1);
    }

    #[test]
    fn narrowed_token_without_checks_write_is_refused() {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let c = CheckClient {
            base_url: fake.base_url().to_string(),
            token: fake.token("fwf-impl[bot]", &[("contents", "read")]),
        };
        let s = sha('9');
        let st = GateState::Green {
            sha: s.clone(),
            suite: "fast".into(),
            secs: 1,
        };
        assert!(matches!(
            post_check_run(&c, &repo(), &s, "gate/fast", &st, None),
            Err(CheckError::Refused { status: 403, .. })
        ));
    }
}
