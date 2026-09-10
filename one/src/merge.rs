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
        eprintln!("fwfd: run log append failed: {e}");
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

/// The review verdict for one head, from the raw reviews list. The latest
/// review per login wins; the author's reviews never count; only reviews
/// anchored to `head` decide.
#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    Approved { by: String },
    ChangesRequested { by: String },
    Stale { approved_head: Sha },
    None,
}

fn verdict(reviews: &[Value], head: &Sha, author: &str) -> Verdict {
    // Latest per login, in list order (GitHub returns submission order).
    let mut latest: Vec<(&str, &Value)> = Vec::new();
    for rv in reviews {
        let Some(login) = rv["user"]["login"].as_str() else {
            continue;
        };
        if login == author {
            continue;
        }
        if let Some(slot) = latest.iter_mut().find(|(l, _)| *l == login) {
            slot.1 = rv;
        } else {
            latest.push((login, rv));
        }
    }
    let at_head = |rv: &Value| rv["commit_id"].as_str() == Some(head.as_str());
    if let Some((by, _)) = latest
        .iter()
        .find(|(_, rv)| rv["state"] == "CHANGES_REQUESTED" && at_head(rv))
    {
        return Verdict::ChangesRequested { by: by.to_string() };
    }
    if let Some((by, _)) = latest
        .iter()
        .find(|(_, rv)| rv["state"] == "APPROVED" && at_head(rv))
    {
        return Verdict::Approved { by: by.to_string() };
    }
    // An approval (live or dismissed by the head move) for another commit.
    let stale = reviews.iter().rev().find_map(|rv| {
        let login = rv["user"]["login"].as_str()?;
        let approved = rv["state"] == "APPROVED" || rv["state"] == "DISMISSED";
        if login != author && approved && !at_head(rv) {
            Sha::parse(rv["commit_id"].as_str()?).ok()
        } else {
            None
        }
    });
    match stale {
        Some(approved_head) => Verdict::Stale { approved_head },
        None => Verdict::None,
    }
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
    let reviewer = match verdict(&reviews, &head, &author) {
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
        record(
            log,
            repo,
            Kind::Note {
                text: format!(
                    "merge #{pr}: check-run {:?} is {}/{}",
                    bad["name"].as_str().unwrap_or("?"),
                    bad["status"].as_str().unwrap_or("?"),
                    bad["conclusion"].as_str().unwrap_or("null")
                ),
            },
        );
        return Err(Refusal::GateNotGreen { sha: head }.into());
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
mod tests {
    use super::shim::Shim;
    use super::*;
    use crate::fake_github::FakeGitHub;
    use crate::log::read_all;
    use std::path::PathBuf;

    const O: &str = "tbaums";
    const R: &str = "scratch";
    const REPO: &str = "tbaums/scratch";
    const IMPL: &str = "fwf-impl[bot]";
    const QA: &str = "fwf-qa[bot]";
    const OPS: &str = "fwf-ops[bot]";

    /// One PR closing one claimed issue, ready for review, plus a log.
    struct Rig {
        fake: FakeGitHub,
        shim: Shim,
        client: Client,
        impl_tok: String,
        qa_tok: String,
        pr: u64,
        issue: u64,
        head: String,
        fence: Fence,
        log: Log,
        log_path: PathBuf,
    }

    fn rig(name: &str, draft: bool) -> Rig {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let shim = Shim::start(&fake);
        let impl_tok = fake.token(IMPL, &[]);
        let qa_tok = fake.token(QA, &[]);
        let ops_tok = fake.token(OPS, &[]);
        let a = FakeGitHub::sha("A");
        let b = FakeGitHub::sha("B");
        shim.add_commit(&a, &[]);
        shim.add_commit(&b, &[&a]);
        fake.seed_ref(O, R, "heads/staging", &a);
        fake.seed_ref(O, R, "heads/feat", &b);
        let issue = fake.seed_issue(O, R, "the work", "tbaums", &["claimed"]);
        let fence_sha = FakeGitHub::sha("claim");
        fake.seed_ref(O, R, &format!("claims/{issue}"), &fence_sha);
        let client = Client::new(shim.base_url(), &ops_tok);
        let seat = Client::new(shim.base_url(), &impl_tok);
        let r = seat
            .post(
                &format!("/repos/{REPO}/pulls"),
                &json!({
                    "title": "do the work",
                    "head": "feat",
                    "base": "staging",
                    "body": format!("Closes #{issue}"),
                    "draft": draft,
                }),
            )
            .unwrap();
        assert_eq!(r.status, 201, "{}", r.body);
        let pr = r.body["number"].as_u64().unwrap();
        let dir = std::env::temp_dir().join(format!("fwfd-merge-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let log_path = dir.join("run.jsonl");
        let log = Log::open(&log_path).unwrap();
        Rig {
            fake,
            shim,
            client,
            impl_tok,
            qa_tok,
            pr,
            issue,
            head: b,
            fence: Fence(fence_sha),
            log,
            log_path,
        }
    }

    impl Rig {
        fn approve(&self, by: &str) {
            let tok = if by == QA {
                &self.qa_tok
            } else {
                &self.impl_tok
            };
            let c = Client::new(self.shim.base_url(), tok);
            let r = c
                .post(
                    &format!("/repos/{REPO}/pulls/{}/reviews", self.pr),
                    &json!({ "event": "APPROVE" }),
                )
                .unwrap();
            assert_eq!(r.status, 200, "{}", r.body);
        }
        fn events(&self) -> Vec<Event> {
            read_all(&self.log_path).unwrap()
        }
        fn refusals(&self) -> Vec<String> {
            self.events()
                .into_iter()
                .filter_map(|e| match e.kind {
                    Kind::Refused { what, why } => Some(format!("{what}: {why}")),
                    _ => None,
                })
                .collect()
        }
        fn merge(&mut self) -> Result<Sha, MergeError> {
            let fence = self.fence.clone();
            merge_pr(&self.client, REPO, self.pr, &fence, &mut self.log)
        }
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            if let Some(d) = self.log_path.parent() {
                let _ = std::fs::remove_dir_all(d);
            }
        }
    }

    #[test]
    fn happy_path_squash_merges_releases_claim_and_records() {
        let mut g = rig("happy", false);
        g.approve(QA);
        let sha = g.merge().unwrap();
        assert_eq!(
            sha.as_str(),
            FakeGitHub::sha(&format!("merge-{}-{}", g.pr, g.head))
        );

        // exactly one merge call, squash, anchored to the head, with the card
        let merges = g.shim.merges();
        assert_eq!(merges.len(), 1);
        let (n, body) = &merges[0];
        assert_eq!(*n, g.pr);
        assert_eq!(body["merge_method"], "squash");
        assert_eq!(body["sha"], g.head.as_str());
        let msg = body["commit_message"].as_str().unwrap();
        assert!(msg.contains(&format!("Closes #{}", g.issue)), "{msg}");
        assert!(msg.contains(&format!("fence={}", g.fence.0)), "{msg}");
        assert!(msg.contains(&format!("reviewer={QA}")), "{msg}");
        assert!(msg.contains(&format!("head={}", g.head)), "{msg}");

        // the claim ref is gone, released by exactly one DELETE under ops
        assert_eq!(g.fake.ref_sha(O, R, &format!("claims/{}", g.issue)), None);
        let deletes: Vec<_> = g
            .fake
            .writes()
            .into_iter()
            .filter(|w| w.method == "DELETE")
            .collect();
        assert_eq!(deletes.len(), 1, "{deletes:?}");
        assert_eq!(deletes[0].actor, OPS);
        assert!(deletes[0]
            .path
            .ends_with(&format!("/git/refs/claims/{}", g.issue)));

        // staging advanced to the merge sha; the PR is closed
        assert_eq!(g.fake.ref_sha(O, R, "heads/staging").unwrap(), sha.as_str());
        assert_eq!(g.fake.issue_json(O, R, g.pr).unwrap()["state"], "closed");

        // the record: a Note for the missing check-runs, then Merged, Shipped
        let evs = g.events();
        assert!(evs
            .iter()
            .any(|e| matches!(&e.kind, Kind::Note { text } if text.contains("no check-runs"))));
        assert!(evs.iter().any(|e| matches!(&e.kind,
            Kind::Pr { pr, issue, to: PrState::Merged { sha: s } } if *pr == g.pr && *issue == Some(g.issue) && *s == sha)));
        assert!(evs.iter().any(|e| matches!(&e.kind,
            Kind::Issue { issue, to: IssueState::Shipped { pr, sha: s } } if *issue == g.issue && *pr == g.pr && *s == sha)));
        assert!(g.refusals().is_empty());

        // a second merge of the same PR is refused: it is closed now
        assert!(matches!(
            g.merge(),
            Err(MergeError::Refused(Refusal::NotReady(_)))
        ));
        assert_eq!(g.shim.merges().len(), 1);
    }

    #[test]
    fn draft_is_refused_before_anything_is_read_or_written() {
        let mut g = rig("draft", true);
        g.approve(QA);
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::NotReady(ref w)) if w.contains("draft")),
            "{e}"
        );
        assert!(g.shim.merges().is_empty());
        assert!(g
            .fake
            .ref_sha(O, R, &format!("claims/{}", g.issue))
            .is_some());
        let r = g.refusals();
        assert_eq!(r.len(), 1);
        assert!(r[0].starts_with(&format!("merge #{}", g.pr)), "{}", r[0]);
        assert!(r[0].contains("draft"));
    }

    #[test]
    fn fence_mismatch_is_refused() {
        let mut g = rig("fence", false);
        g.approve(QA);
        g.fence = Fence(FakeGitHub::sha("someone-elses-claim"));
        let e = g.merge().unwrap_err();
        match e {
            MergeError::Refused(Refusal::FenceMismatch { expected, got }) => {
                assert_eq!(expected.0, FakeGitHub::sha("claim"));
                assert_eq!(got, g.fence);
            }
            other => panic!("{other}"),
        }
        assert!(g.shim.merges().is_empty());
        assert!(g.refusals()[0].contains("fence mismatch"));
    }

    #[test]
    fn missing_claim_ref_is_refused() {
        let mut g = rig("noclaim", false);
        g.approve(QA);
        let r = g
            .client
            .delete(&format!("/repos/{REPO}/git/refs/claims/{}", g.issue))
            .unwrap();
        assert_eq!(r.status, 204);
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::NotReady(ref w)) if w.contains("no live claim")),
            "{e}"
        );
        assert!(g.shim.merges().is_empty());
    }

    #[test]
    fn self_approval_never_counts() {
        let mut g = rig("selfapprove", false);
        // the fake refuses an author's APPROVE (422) — so inject one, as a
        // compromised or lying API would return it
        g.shim.inject_review(g.pr, IMPL, "APPROVED", &g.head);
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::NotApproved { ref head }) if head.as_str() == g.head),
            "{e}"
        );
        assert!(g.shim.merges().is_empty());
        assert!(g.refusals()[0].contains("no approval anchored"));
    }

    #[test]
    fn no_review_at_all_is_not_approved() {
        let mut g = rig("noreview", false);
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::NotApproved { .. })),
            "{e}"
        );
    }

    #[test]
    fn changes_requested_at_head_outranks_an_approval() {
        let mut g = rig("changes", false);
        g.approve(QA);
        // a second reviewer requests changes at the same head
        let tok = g.fake.token("fwf-pm[bot]", &[]);
        let c = Client::new(g.shim.base_url(), &tok);
        let r = c
            .post(
                &format!("/repos/{REPO}/pulls/{}/reviews", g.pr),
                &json!({ "event": "REQUEST_CHANGES", "body": "no" }),
            )
            .unwrap();
        assert_eq!(r.status, 200, "{}", r.body);
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::NotApproved { .. })),
            "{e}"
        );
        assert!(g.shim.merges().is_empty());
    }

    #[test]
    fn approval_goes_stale_when_the_head_moves() {
        let mut g = rig("stale", false);
        g.approve(QA);
        let c = FakeGitHub::sha("C");
        g.shim.add_commit(&c, &[&g.head]);
        let seat = Client::new(g.shim.base_url(), &g.impl_tok);
        let r = seat
            .patch(
                &format!("/repos/{REPO}/pulls/{}", g.pr),
                &json!({ "head_sha": c }),
            )
            .unwrap();
        assert_eq!(r.status, 200, "{}", r.body);
        let e = g.merge().unwrap_err();
        match e {
            MergeError::Refused(Refusal::ApprovalStale {
                head,
                approved_head,
            }) => {
                assert_eq!(head.as_str(), c);
                assert_eq!(approved_head.as_str(), g.head);
            }
            other => panic!("{other}"),
        }
        assert!(g.shim.merges().is_empty());
        assert!(g.refusals()[0].contains("approval is for"));

        // re-approval at the new head restores mergeability
        g.approve(QA);
        let sha = g.merge().unwrap();
        assert_eq!(
            sha.as_str(),
            FakeGitHub::sha(&format!("merge-{}-{c}", g.pr))
        );
    }

    fn check_run(g: &Rig, status: &str, conclusion: Option<&str>) {
        let r = g
            .client
            .post(
                &format!("/repos/{REPO}/check-runs"),
                &json!({
                    "name": "gate/fast",
                    "head_sha": g.head,
                    "status": status,
                    "conclusion": conclusion,
                }),
            )
            .unwrap();
        assert_eq!(r.status, 201, "{}", r.body);
    }

    #[test]
    fn failing_or_unfinished_check_run_is_refused() {
        let mut g = rig("checkfail", false);
        g.approve(QA);
        check_run(&g, "completed", Some("failure"));
        let e = g.merge().unwrap_err();
        assert!(
            matches!(e, MergeError::Refused(Refusal::GateNotGreen { ref sha }) if sha.as_str() == g.head),
            "{e}"
        );
        assert!(g.shim.merges().is_empty());
        assert!(g
            .fake
            .ref_sha(O, R, &format!("claims/{}", g.issue))
            .is_some());

        let mut g = rig("checkpending", false);
        g.approve(QA);
        check_run(&g, "in_progress", None);
        assert!(matches!(
            g.merge(),
            Err(MergeError::Refused(Refusal::GateNotGreen { .. }))
        ));
    }

    #[test]
    fn green_check_run_merges_without_the_m1_note() {
        let mut g = rig("checkgreen", false);
        g.approve(QA);
        check_run(&g, "completed", Some("success"));
        g.merge().unwrap();
        assert_eq!(g.shim.merges().len(), 1);
        assert!(!g
            .events()
            .iter()
            .any(|e| matches!(&e.kind, Kind::Note { text } if text.contains("no check-runs"))));
    }

    #[test]
    fn a_head_that_moves_under_the_merge_is_a_409_not_a_merge() {
        // The read→PUT window: the client sends `sha: <head it verified>`,
        // GitHub's own precondition. Simulate the race by moving the head
        // through the shim's pre-PATCH hook on the head branch is not
        // possible (the PUT is not a ref PATCH), so drive the shim's merge
        // route directly with a stale sha and assert the 409 is surfaced as
        // an Api error, never as success.
        let mut g = rig("race", false);
        g.approve(QA);
        let stale = FakeGitHub::sha("stale");
        let r = g
            .client
            .put(
                &format!("/repos/{REPO}/pulls/{}/merge", g.pr),
                &json!({ "merge_method": "squash", "sha": stale }),
            )
            .unwrap();
        assert_eq!(r.status, 409);
        assert!(g.shim.merges().is_empty());
        assert_eq!(g.fake.issue_json(O, R, g.pr).unwrap()["state"], "open");
        // and the real path still merges with the live head
        g.merge().unwrap();
        assert_eq!(g.shim.merges()[0].1["sha"], g.head.as_str());
    }

    #[test]
    fn verdict_is_latest_per_login_and_ignores_the_author() {
        let h = Sha::parse(&FakeGitHub::sha("h")).unwrap();
        let old = FakeGitHub::sha("old");
        let rv = |login: &str, state: &str, commit: &str| json!({ "user": { "login": login }, "state": state, "commit_id": commit });
        // approve then request changes by the same login: latest wins
        assert_eq!(
            verdict(
                &[
                    rv(QA, "APPROVED", h.as_str()),
                    rv(QA, "CHANGES_REQUESTED", h.as_str())
                ],
                &h,
                IMPL
            ),
            Verdict::ChangesRequested { by: QA.into() }
        );
        // request changes then approve: latest wins
        assert_eq!(
            verdict(
                &[
                    rv(QA, "CHANGES_REQUESTED", h.as_str()),
                    rv(QA, "APPROVED", h.as_str())
                ],
                &h,
                IMPL
            ),
            Verdict::Approved { by: QA.into() }
        );
        // an author approval at head plus a dismissed qa approval at old head
        assert_eq!(
            verdict(
                &[rv(QA, "DISMISSED", &old), rv(IMPL, "APPROVED", h.as_str())],
                &h,
                IMPL
            ),
            Verdict::Stale {
                approved_head: Sha::parse(&old).unwrap()
            }
        );
        // a COMMENTED review is nothing
        assert_eq!(
            verdict(&[rv(QA, "COMMENTED", h.as_str())], &h, IMPL),
            Verdict::None
        );
    }

    #[test]
    fn client_reports_status_as_a_value_and_transport_as_an_error() {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let c = Client::new(fake.base_url(), "not-a-token");
        let r = c.get(&format!("/repos/{REPO}/pulls/1")).unwrap();
        assert_eq!(r.status, 401);
        let dead = Client::new("http://127.0.0.1:9", "x");
        assert!(matches!(dead.get("/x"), Err(HttpError::Transport(_))));
        assert!(matches!(
            c.send("HEAD", "/x", &Value::Null, &[]),
            Err(HttpError::UnsupportedMethod(_))
        ));
    }
}
