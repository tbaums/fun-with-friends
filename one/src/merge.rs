//! T-13: the typed merge. The only path by which a PR reaches `staging`.
//!
//! `merge_pr` re-derives every precondition from GitHub's own objects at the
//! moment of the merge (never from a cached snapshot): the PR is open and not
//! a draft; the issue it closes carries a live `refs/claims/<n>` whose sha is
//! the caller's fence; an APPROVED review by someone other than the author is
//! anchored to the *current* head and no REQUEST_CHANGES at that head
//! outranks it; every check-run on the head (if any) is `completed/success`.
//! Each failed precondition is a `Refusal` value, appended to the run log as
//! `Kind::Refused`, and nothing is written. On success: one squash merge
//! (`PUT pulls/{n}/merge` with the `sha` precondition, so GitHub itself
//! refuses if the head moved in between), the claim ref is released, and
//! `Pr → Merged` / `Issue → Shipped` are recorded.
//!
//! [`Client`] is the base-URL-aware JSON transport every authority-bearing
//! write in fwf 1.0 goes through; tests point it at the fake.

use crate::log::{Event, Kind, Log};
use crate::poll::closes_issue;
use crate::review::Verdict;
use crate::types::{Fence, IssueState, PrState, Refusal, Sha};
use serde_json::{json, Value};
use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------- client

/// A GitHub REST client bound to one base URL and one installation token.
/// `base_url` is `https://api.github.com` in production and the fake's
/// address in tests. Every call has a hard timeout; a non-2xx status is a
/// value (`Reply.status`), never a panic.
#[derive(Clone, Debug)]
pub struct Client {
    pub base_url: String,
    pub token: String,
}

/// Status and parsed body of one call. An empty body (204) is `Value::Null`.
#[derive(Clone, Debug)]
pub struct Reply {
    pub status: u16,
    pub body: Value,
}

impl Reply {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
    /// The body, truncated, for error messages.
    pub fn excerpt(&self) -> String {
        self.body.to_string().chars().take(200).collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HttpError {
    Transport(String),
    UnsupportedMethod(String),
}

impl fmt::Display for HttpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HttpError::Transport(e) => write!(f, "http: {e}"),
            HttpError::UnsupportedMethod(m) => write!(f, "unsupported method {m}"),
        }
    }
}

const HTTP_TIMEOUT: Duration = Duration::from_secs(30);

impl Client {
    pub fn new(base_url: &str, token: &str) -> Client {
        Client {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
        }
    }

    /// The real API.
    pub fn github(token: &str) -> Client {
        Client::new("https://api.github.com", token)
    }

    pub fn get(&self, path: &str) -> Result<Reply, HttpError> {
        self.call("GET", path, None, &[])
    }

    /// POST / PUT / PATCH / DELETE with a JSON body and optional extra
    /// headers (the fake's `X-Fake-Expect-Sha` CAS header goes here).
    pub fn send(
        &self,
        method: &str,
        path: &str,
        body: &Value,
        extra: &[(&str, &str)],
    ) -> Result<Reply, HttpError> {
        self.call(method, path, Some(body), extra)
    }

    pub fn put(&self, path: &str, body: &Value) -> Result<Reply, HttpError> {
        self.send("PUT", path, body, &[])
    }
    pub fn post(&self, path: &str, body: &Value) -> Result<Reply, HttpError> {
        self.send("POST", path, body, &[])
    }
    pub fn patch(&self, path: &str, body: &Value) -> Result<Reply, HttpError> {
        self.send("PATCH", path, body, &[])
    }
    pub fn delete(&self, path: &str) -> Result<Reply, HttpError> {
        self.send("DELETE", path, &Value::Null, &[])
    }

    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        extra: &[(&str, &str)],
    ) -> Result<Reply, HttpError> {
        if !matches!(method, "GET" | "POST" | "PUT" | "PATCH" | "DELETE") {
            return Err(HttpError::UnsupportedMethod(method.to_string()));
        }
        let agent = ureq::AgentBuilder::new().timeout(HTTP_TIMEOUT).build();
        let mut rq = agent
            .request(method, &format!("{}{path}", self.base_url))
            .set("Authorization", &format!("Bearer {}", self.token))
            .set("Accept", "application/vnd.github+json")
            .set("User-Agent", "fwfd/0.1")
            .set("X-GitHub-Api-Version", "2022-11-28");
        for (k, v) in extra {
            rq = rq.set(k, v);
        }
        let res = match body {
            Some(b) if !b.is_null() => rq.send_string(&b.to_string()),
            _ if method == "GET" => rq.call(),
            _ => rq.send_string(""),
        };
        let r = match res {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => return Err(HttpError::Transport(e.to_string())),
        };
        let status = r.status();
        let text = r.into_string().unwrap_or_default();
        let body = if text.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::String(text))
        };
        Ok(Reply { status, body })
    }
}

// ---------------------------------------------------------------- errors

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MergeError {
    /// A precondition failed. Nothing was written.
    Refused(Refusal),
    /// The transport failed; the state of GitHub is Unknown to us.
    Http(HttpError),
    /// GitHub answered with a status we did not expect for `what`.
    Api {
        what: String,
        status: u16,
        body: String,
    },
    /// A response lacked a field we need; treated as Unknown, never guessed.
    Malformed { what: String, why: String },
}

impl From<Refusal> for MergeError {
    fn from(r: Refusal) -> MergeError {
        MergeError::Refused(r)
    }
}
impl From<HttpError> for MergeError {
    fn from(e: HttpError) -> MergeError {
        MergeError::Http(e)
    }
}

impl fmt::Display for MergeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MergeError::Refused(r) => write!(f, "refused: {r}"),
            MergeError::Http(e) => write!(f, "{e}"),
            MergeError::Api { what, status, body } => write!(f, "{what}: HTTP {status}: {body}"),
            MergeError::Malformed { what, why } => write!(f, "{what}: malformed response: {why}"),
        }
    }
}

// ---------------------------------------------------------------- helpers

pub(crate) fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub(crate) fn record(log: &mut Log, repo: &str, kind: Kind) {
    let ev = Event {
        ts: now_secs(),
        repo: repo.to_string(),
        kind,
    };
    // The log is the run record; a failed append is a real fault but must
    // not turn a completed GitHub write into a reported failure.
    if let Err(e) = log.append(&ev) {
        eprintln!("fwf: run log append failed: {e}");
    }
}

fn str_field<'a>(v: &'a Value, path: &[&str], what: &str) -> Result<&'a str, MergeError> {
    let mut cur = v;
    for p in path {
        cur = &cur[*p];
    }
    cur.as_str().ok_or_else(|| MergeError::Malformed {
        what: what.to_string(),
        why: format!("missing string field {}", path.join(".")),
    })
}

fn sha_field(v: &Value, path: &[&str], what: &str) -> Result<Sha, MergeError> {
    Sha::parse(str_field(v, path, what)?).map_err(|r| MergeError::Malformed {
        what: what.to_string(),
        why: r.to_string(),
    })
}

fn expect_ok(what: &str, r: Reply) -> Result<Value, MergeError> {
    if r.ok() {
        Ok(r.body)
    } else {
        Err(MergeError::Api {
            what: what.to_string(),
            status: r.status,
            body: r.excerpt(),
        })
    }
}

/// The review verdict for one head, from GitHub's raw reviews list.
///
/// The rule itself lives in [`crate::review`], shared with the planner since
/// #690 — the two used to disagree about what "approved" means, and a PR that
/// was approved and then refused at the same head deadlocked between them.
/// This is only the mapping into the `(login, state, commit)` triples that
/// function reads, which is the shape `poll::PrView.reviews` already has. A
/// review with no `user.login` is not a review anyone can be held to, so it is
/// dropped here exactly as it always was.
pub(crate) fn verdict_of(reviews: &[Value], head: &Sha, author: &str) -> Verdict {
    let triples: Vec<(&str, &str, &str)> = reviews
        .iter()
        .filter_map(|rv| {
            Some((
                rv["user"]["login"].as_str()?,
                rv["state"].as_str().unwrap_or(""),
                rv["commit_id"].as_str().unwrap_or(""),
            ))
        })
        .collect();
    crate::review::verdict(triples.iter().copied(), head.as_str(), author)
}

// ---------------------------------------------------------------- merge

/// Squash-merge `pr` into its base once every precondition holds, under the
/// caller's fence. Returns the merge commit sha. Every refusal is recorded.
pub fn merge_pr(
    client: &Client,
    repo: &str,
    pr: u64,
    fence: &Fence,
    log: &mut Log,
) -> Result<Sha, MergeError> {
    let what = format!("merge #{pr}");
    match merge_inner(client, repo, pr, fence, log) {
        Ok(sha) => Ok(sha),
        Err(e) => {
            record(
                log,
                repo,
                Kind::Refused {
                    what: what.clone(),
                    why: e.to_string(),
                },
            );
            Err(e)
        }
    }
}

fn merge_inner(
    client: &Client,
    repo: &str,
    pr: u64,
    fence: &Fence,
    log: &mut Log,
) -> Result<Sha, MergeError> {
    let base = format!("/repos/{repo}");

    // (1) open, not a draft
    let what = format!("GET pulls/{pr}");
    let p = expect_ok(&what, client.get(&format!("{base}/pulls/{pr}"))?)?;
    let head = sha_field(&p, &["head", "sha"], &what)?;
    let author = str_field(&p, &["user", "login"], &what)?.to_string();
    let title = p["title"].as_str().unwrap_or("").to_string();
    if p["merged"].as_bool() == Some(true) {
        return Err(Refusal::NotReady(format!("pr #{pr} is already merged")).into());
    }
    if p["state"].as_str() != Some("open") {
        return Err(Refusal::NotReady(format!(
            "pr #{pr} is {}",
            p["state"].as_str().unwrap_or("?")
        ))
        .into());
    }
    if p["draft"].as_bool() != Some(false) {
        return Err(Refusal::NotReady(format!("pr #{pr} is a draft")).into());
    }

    // (2) the closed issue's live claim ref equals the fence
    let body = p["body"].as_str().unwrap_or("");
    let Some(issue) = closes_issue(body) else {
        return Err(Refusal::NotReady(format!("pr #{pr} body names no `Closes #N`")).into());
    };
    let claim_path = format!("{base}/git/ref/claims/{issue}");
    let claim = client.get(&claim_path)?;
    if claim.status == 404 {
        return Err(Refusal::NotReady(format!(
            "issue #{issue} has no live claim ref refs/claims/{issue}"
        ))
        .into());
    }
    let claim = expect_ok(&format!("GET git/ref/claims/{issue}"), claim)?;
    let live = Fence(str_field(&claim, &["object", "sha"], "claim ref")?.to_string());
    if &live != fence {
        return Err(Refusal::FenceMismatch {
            expected: live,
            got: fence.clone(),
        }
        .into());
    }

    // (3) a non-author approval anchored to the current head
    let what = format!("GET pulls/{pr}/reviews");
    let reviews = expect_ok(&what, client.get(&format!("{base}/pulls/{pr}/reviews"))?)?;
    let reviews = reviews
        .as_array()
        .cloned()
        .ok_or_else(|| MergeError::Malformed {
            what: what.clone(),
            why: "not an array".into(),
        })?;
    let reviewer = match verdict_of(&reviews, &head, &author) {
        Verdict::Approved { by } => by,
        Verdict::ChangesRequested { .. } | Verdict::None => {
            return Err(Refusal::NotApproved { head }.into())
        }
        Verdict::Stale { approved_head } => {
            return Err(Refusal::ApprovalStale {
                head,
                approved_head,
            }
            .into())
        }
    };

    // (4) check-runs on the head: none is allowed (M1), any must be green
    let what = format!("GET commits/{}/check-runs", head.short());
    let runs = expect_ok(
        &what,
        client.get(&format!("{base}/commits/{head}/check-runs"))?,
    )?;
    let runs = runs["check_runs"].as_array().cloned().unwrap_or_default();
    if runs.is_empty() {
        record(
            log,
            repo,
            Kind::Note {
                text: format!(
                    "merge #{pr}: no check-runs on head {}; allowed in M1",
                    head.short()
                ),
            },
        );
    } else if let Some(bad) = runs
        .iter()
        .find(|c| !(c["status"] == "completed" && c["conclusion"] == "success"))
    {
        // One string, said twice: to the record as a Note, and — since #690 —
        // in the refusal itself. Before that the refusal read "no green gate
        // recorded for <sha>" and the operator had to go digging in the log
        // for the Note to learn which check-run to fix.
        let detail = format!(
            "check-run {:?} is {}/{}",
            bad["name"].as_str().unwrap_or("?"),
            bad["status"].as_str().unwrap_or("?"),
            bad["conclusion"].as_str().unwrap_or("null")
        );
        record(
            log,
            repo,
            Kind::Note {
                text: format!("merge #{pr}: {detail}"),
            },
        );
        return Err(Refusal::GateNotGreen {
            sha: head,
            detail: Some(detail),
        }
        .into());
    }

    // the merge itself: squash, with the head sha as GitHub's own precondition
    let card = format!(
        "Closes #{issue}\n\nfwf: seat={author} fence={} reviewer={reviewer} head={head}",
        fence.0
    );
    let merge_body = json!({
        "merge_method": "squash",
        "sha": head.as_str(),
        "commit_title": format!("{title} (#{pr})"),
        "commit_message": card,
    });
    let r = client.put(&format!("{base}/pulls/{pr}/merge"), &merge_body)?;
    let merged = expect_ok(&format!("PUT pulls/{pr}/merge"), r)?;
    let sha = sha_field(&merged, &["sha"], "merge result")?;

    // release the claim; the merge is done regardless, so a failure here is
    // recorded, not returned
    let del = client.delete(&format!("{base}/git/refs/claims/{issue}"));
    match del {
        Ok(r) if r.ok() => {}
        Ok(r) => record(
            log,
            repo,
            Kind::Note {
                text: format!(
                    "merge #{pr}: claim ref refs/claims/{issue} not released: HTTP {} {}",
                    r.status,
                    r.excerpt()
                ),
            },
        ),
        Err(e) => record(
            log,
            repo,
            Kind::Note {
                text: format!("merge #{pr}: claim ref refs/claims/{issue} not released: {e}"),
            },
        ),
    }
    record(
        log,
        repo,
        Kind::Pr {
            pr,
            issue: Some(issue),
            to: PrState::Merged { sha: sha.clone() },
        },
    );
    record(
        log,
        repo,
        Kind::Issue {
            issue,
            to: IssueState::Shipped {
                pr,
                sha: sha.clone(),
            },
        },
    );
    Ok(sha)
}

// ---------------------------------------------------------------- test shim

/// The fake (T-04) does not model `PUT pulls/{n}/merge`, `GET compare`, or
/// releases. This shim sits in front of a `FakeGitHub`, serves those three
/// routes with a tiny commit graph, and forwards everything else verbatim
/// (headers included, so the fake's auth/ETag/CAS semantics still apply).
/// Test-only; `promote.rs` uses it too.
#[cfg(test)]
pub(crate) mod shim {
    use super::*;
    use crate::fake_github::FakeGitHub;
    use std::collections::{HashMap, HashSet};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;

    #[derive(Default)]
    struct State {
        upstream: String,
        /// sha → parent shas. Unknown shas are roots.
        parents: HashMap<String, Vec<String>>,
        /// tag → asset names
        releases: HashMap<String, Vec<String>>,
        /// pr → extra reviews appended to `GET pulls/{n}/reviews`
        injected_reviews: HashMap<u64, Vec<Value>>,
        /// ref name → sha to move it to (through the fake, no CAS) right
        /// before the next PATCH of that ref is forwarded — "someone else
        /// pushed between our read and our push".
        move_before_patch: HashMap<String, String>,
        merges: Vec<(u64, Value)>,
    }

    pub struct Shim {
        state: Arc<Mutex<State>>,
        server: Arc<tiny_http::Server>,
        base: String,
        thread: Option<JoinHandle<()>>,
    }

    struct Fwd {
        status: u16,
        body: Value,
        etag: Option<String>,
    }

    fn forward(
        upstream: &str,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Fwd {
        let mut rq = ureq::request(method, &format!("{upstream}{url}"));
        for (k, v) in headers {
            let kl = k.to_ascii_lowercase();
            if kl == "host" || kl == "content-length" || kl == "transfer-encoding" {
                continue;
            }
            rq = rq.set(k, v);
        }
        let res = if method == "GET" {
            rq.call()
        } else {
            rq.send_bytes(body)
        };
        let r = match res {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => panic!("shim → fake transport: {e}"),
        };
        let status = r.status();
        let etag = r.header("ETag").map(str::to_string);
        let text = r.into_string().unwrap_or_default();
        let body = if text.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::Null)
        };
        Fwd { status, body, etag }
    }

    fn auth_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
        headers
            .iter()
            .filter(|(k, _)| k.eq_ignore_ascii_case("authorization"))
            .cloned()
            .collect()
    }

    fn is_sha(s: &str) -> bool {
        s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
    }

    fn ancestors(parents: &HashMap<String, Vec<String>>, start: &str) -> HashSet<String> {
        let mut seen = HashSet::new();
        let mut stack = vec![start.to_string()];
        while let Some(s) = stack.pop() {
            if !seen.insert(s.clone()) {
                continue;
            }
            if let Some(ps) = parents.get(&s) {
                stack.extend(ps.iter().cloned());
            }
        }
        seen
    }

    impl Shim {
        pub fn start(fake: &FakeGitHub) -> Shim {
            let server =
                Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind 127.0.0.1:0"));
            let addr = server.server_addr().to_ip().expect("tcp listener");
            let state = Arc::new(Mutex::new(State {
                upstream: fake.base_url().to_string(),
                ..State::default()
            }));
            let (srv, st) = (server.clone(), state.clone());
            let thread = std::thread::spawn(move || {
                for mut rq in srv.incoming_requests() {
                    let mut raw = Vec::new();
                    let _ = std::io::Read::read_to_end(rq.as_reader(), &mut raw);
                    let method = rq.method().to_string().to_ascii_uppercase();
                    let url = rq.url().to_string();
                    let headers: Vec<(String, String)> = rq
                        .headers()
                        .iter()
                        .map(|h| (h.field.to_string(), h.value.as_str().to_string()))
                        .collect();
                    let out = handle(&st, &method, &url, &headers, &raw);
                    let body = if out.body.is_null() {
                        Vec::new()
                    } else {
                        serde_json::to_vec(&out.body).expect("json")
                    };
                    let mut resp = tiny_http::Response::from_data(body)
                        .with_status_code(out.status)
                        .with_header(
                            tiny_http::Header::from_bytes("Content-Type", "application/json")
                                .expect("header"),
                        );
                    if let Some(e) = out.etag {
                        resp = resp.with_header(
                            tiny_http::Header::from_bytes("ETag", e.as_str()).expect("header"),
                        );
                    }
                    let _ = rq.respond(resp);
                }
            });
            Shim {
                state,
                server,
                base: format!("http://{addr}"),
                thread: Some(thread),
            }
        }

        pub fn base_url(&self) -> &str {
            &self.base
        }

        fn lock(&self) -> std::sync::MutexGuard<'_, State> {
            self.state.lock().expect("shim state")
        }

        /// Declare a commit and its parents (the fake has no commit graph).
        pub fn add_commit(&self, sha: &str, parents: &[&str]) {
            self.lock().parents.insert(
                sha.to_string(),
                parents.iter().map(|s| s.to_string()).collect(),
            );
        }

        pub fn add_release(&self, tag: &str, assets: &[&str]) {
            self.lock().releases.insert(
                tag.to_string(),
                assets.iter().map(|s| s.to_string()).collect(),
            );
        }

        /// Append a review the fake would refuse to create (e.g. an
        /// author's own APPROVED), so the client's distrust can be tested.
        pub fn inject_review(&self, pr: u64, login: &str, state: &str, commit_id: &str) {
            self.lock()
                .injected_reviews
                .entry(pr)
                .or_default()
                .push(json!({
                    "id": 999_000 + pr,
                    "user": { "login": login },
                    "state": state,
                    "commit_id": commit_id,
                    "body": "",
                    "submitted_at": "2026-01-01T00:00:00Z",
                }));
        }

        /// The next `PATCH git/refs/<name>` first moves the ref to `sha`
        /// (through the fake, as another actor would), then forwards.
        pub fn move_ref_before_patch(&self, name: &str, sha: &str) {
            self.lock()
                .move_before_patch
                .insert(format!("refs/{name}"), sha.to_string());
        }

        /// Every accepted `PUT pulls/{n}/merge`, with its body.
        pub fn merges(&self) -> Vec<(u64, Value)> {
            self.lock().merges.clone()
        }
    }

    impl Drop for Shim {
        fn drop(&mut self) {
            self.server.unblock();
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    fn handle(
        st: &Arc<Mutex<State>>,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        raw: &[u8],
    ) -> Fwd {
        let path = url.split_once('?').map(|(p, _)| p).unwrap_or(url);
        let segs: Vec<&str> = path.trim_start_matches('/').split('/').collect();
        let upstream = st.lock().unwrap().upstream.clone();
        let auth = auth_headers(headers);
        match (method, segs.as_slice()) {
            ("PUT", ["repos", o, r, "pulls", n, "merge"]) => {
                let n: u64 = n.parse().unwrap_or(0);
                let body: Value = serde_json::from_slice(raw).unwrap_or(Value::Null);
                let p = forward(
                    &upstream,
                    "GET",
                    &format!("/repos/{o}/{r}/pulls/{n}"),
                    &auth,
                    b"",
                );
                if p.status != 200 {
                    return Fwd {
                        status: p.status,
                        body: p.body,
                        etag: None,
                    };
                }
                if p.body["state"] != "open" {
                    return Fwd {
                        status: 405,
                        body: json!({ "message": "Pull Request is not mergeable" }),
                        etag: None,
                    };
                }
                let head = p.body["head"]["sha"].as_str().unwrap_or("").to_string();
                if let Some(want) = body["sha"].as_str() {
                    if want != head {
                        return Fwd {
                            status: 409,
                            body: json!({ "message": "Head branch was modified. Review and try the merge again." }),
                            etag: None,
                        };
                    }
                }
                let base_ref = p.body["base"]["ref"].as_str().unwrap_or("").to_string();
                let base_sha = forward(
                    &upstream,
                    "GET",
                    &format!("/repos/{o}/{r}/git/ref/heads/{base_ref}"),
                    &auth,
                    b"",
                )
                .body["object"]["sha"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                let merge_sha = FakeGitHub::sha(&format!("merge-{n}-{head}"));
                // close the PR and advance the base, as a squash does
                let closed = forward(
                    &upstream,
                    "PATCH",
                    &format!("/repos/{o}/{r}/pulls/{n}"),
                    &auth,
                    json!({ "state": "closed" }).to_string().as_bytes(),
                );
                assert_eq!(closed.status, 200, "shim: close pr: {}", closed.body);
                let moved = forward(
                    &upstream,
                    "PATCH",
                    &format!("/repos/{o}/{r}/git/refs/heads/{base_ref}"),
                    &auth,
                    json!({ "sha": merge_sha }).to_string().as_bytes(),
                );
                assert_eq!(moved.status, 200, "shim: move base: {}", moved.body);
                let mut s = st.lock().unwrap();
                s.parents.insert(merge_sha.clone(), vec![base_sha]);
                s.merges.push((n, body));
                Fwd {
                    status: 200,
                    body: json!({ "sha": merge_sha, "merged": true, "message": "Pull Request successfully merged" }),
                    etag: None,
                }
            }
            ("GET", ["repos", o, r, "compare", basehead]) => {
                let Some((a, b)) = basehead.split_once("...") else {
                    return Fwd {
                        status: 404,
                        body: json!({ "message": "Not Found" }),
                        etag: None,
                    };
                };
                let resolve = |name: &str| -> Option<String> {
                    if is_sha(name) {
                        return Some(name.to_string());
                    }
                    let f = forward(
                        &upstream,
                        "GET",
                        &format!("/repos/{o}/{r}/git/ref/heads/{name}"),
                        &auth,
                        b"",
                    );
                    f.body["object"]["sha"].as_str().map(str::to_string)
                };
                let (Some(base), Some(head)) = (resolve(a), resolve(b)) else {
                    return Fwd {
                        status: 404,
                        body: json!({ "message": "Not Found" }),
                        etag: None,
                    };
                };
                let s = st.lock().unwrap();
                let anc_head = ancestors(&s.parents, &head);
                let anc_base = ancestors(&s.parents, &base);
                let ahead_by = anc_head.difference(&anc_base).count();
                let behind_by = anc_base.difference(&anc_head).count();
                let status = match (ahead_by, behind_by) {
                    (0, 0) => "identical",
                    (_, 0) => "ahead",
                    (0, _) => "behind",
                    _ => "diverged",
                };
                Fwd {
                    status: 200,
                    body: json!({
                        "status": status,
                        "ahead_by": ahead_by,
                        "behind_by": behind_by,
                        "base_commit": { "sha": base },
                        "merge_base_commit": { "sha": base },
                        "commits": [],
                    }),
                    etag: None,
                }
            }
            ("GET", ["repos", _, _, "releases", "tags", tag]) => {
                let s = st.lock().unwrap();
                match s.releases.get(*tag) {
                    Some(assets) => Fwd {
                        status: 200,
                        body: json!({
                            "tag_name": tag,
                            "assets": assets.iter().map(|a| json!({ "name": a })).collect::<Vec<_>>(),
                        }),
                        etag: None,
                    },
                    None => Fwd {
                        status: 404,
                        body: json!({ "message": "Not Found" }),
                        etag: None,
                    },
                }
            }
            ("GET", ["repos", _, _, "pulls", n, "reviews"]) => {
                let n: u64 = n.parse().unwrap_or(0);
                let mut f = forward(&upstream, method, url, headers, raw);
                if f.status == 200 {
                    let extra = st
                        .lock()
                        .unwrap()
                        .injected_reviews
                        .get(&n)
                        .cloned()
                        .unwrap_or_default();
                    if !extra.is_empty() {
                        if let Some(arr) = f.body.as_array_mut() {
                            arr.extend(extra);
                        }
                        f.etag = None;
                    }
                }
                f
            }
            ("PATCH", ["repos", o, r, "git", "refs", rest @ ..]) => {
                let name = format!("refs/{}", rest.join("/"));
                let pre = st.lock().unwrap().move_before_patch.remove(&name);
                if let Some(sha) = pre {
                    let m = forward(
                        &upstream,
                        "PATCH",
                        &format!("/repos/{o}/{r}/git/refs/{}", rest.join("/")),
                        &auth,
                        json!({ "sha": sha }).to_string().as_bytes(),
                    );
                    assert_eq!(m.status, 200, "shim: pre-move: {}", m.body);
                }
                forward(&upstream, method, url, headers, raw)
            }
            _ => forward(&upstream, method, url, headers, raw),
        }
    }
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests;
