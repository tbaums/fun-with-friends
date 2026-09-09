//! Fake GitHub (T-04): an in-process HTTP stand-in for the dozen REST
//! endpoints `fwfd` uses, with the semantics the real API has and the old
//! harness got wrong. Tests construct a [`FakeGitHub`], seed it, point the
//! client at [`FakeGitHub::base_url`], and assert on [`FakeGitHub::writes`].
//!
//! What it models (see README "Fake GitHub" for the full list):
//! - `ETag` on every GET, `If-None-Match` → 304.
//! - Bearer tokens minted per installation; a token narrowed to `read`
//!   is refused on writes (403), a missing/unknown token is 401.
//! - A reviewer cannot APPROVE / REQUEST_CHANGES their own PR (422).
//! - Moving a PR head (fake `head_sha` PATCH, or a ref update to the head
//!   branch) dismisses prior approvals, as dismiss-stale-reviews does.
//! - Ref update is compare-and-set: `X-Fake-Expect-Sha` must equal the
//!   current sha or the update is 422 — the stand-in for
//!   `git push --force-with-lease=<ref>:<expected>`.
//! - Ref create is 422 when the ref exists — the expect-empty CAS used
//!   for `claim/<n>` refs.
//!
//! Ids are sequential; timestamps come from an injectable clock; every
//! request bumps a per-path counter; every accepted write is logged.

use serde_json::{json, Value};
use std::collections::hash_map::DefaultHasher;
use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

/// Seconds since the Unix epoch, produced on demand by the injected clock.
pub type Clock = Box<dyn FnMut() -> u64 + Send>;

/// 2026-01-01T00:00:00Z; the default clock starts here and ticks one
/// second per read, so timestamps are deterministic and strictly ordered.
const EPOCH_2026: u64 = 1_767_225_600;

/// One accepted write, in arrival order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Write {
    pub actor: String,
    pub method: String,
    pub path: String,
    pub body: Value,
}

#[derive(Debug, Clone)]
struct Token {
    login: String,
    /// Empty = unnarrowed (everything at `write`).
    permissions: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
struct Issue {
    number: u64,
    id: u64,
    title: String,
    body: String,
    state: String,
    author: String,
    labels: Vec<String>,
    created_at: String,
    updated_at: String,
    pull: Option<Pull>,
    events: Vec<Value>,
    comments: Vec<Value>,
}

#[derive(Debug, Clone)]
struct Pull {
    draft: bool,
    head_ref: String,
    head_sha: String,
    base_ref: String,
    base_sha: String,
    reviews: Vec<Value>,
}

#[derive(Debug, Default)]
struct Repo {
    issues: BTreeMap<u64, Issue>,
    refs: BTreeMap<String, String>,
    check_runs: Vec<Value>,
    next_number: u64,
}

struct State {
    clock: Clock,
    next_id: u64,
    repos: BTreeMap<String, Repo>,
    installations: BTreeMap<u64, String>,
    tokens: BTreeMap<String, Token>,
    writes: Vec<Write>,
    counts: BTreeMap<String, u64>,
}

struct Resp {
    status: u16,
    body: Value,
    headers: Vec<(String, String)>,
}

impl Resp {
    fn ok(body: Value) -> Resp {
        Resp {
            status: 200,
            body,
            headers: vec![],
        }
    }
    fn created(body: Value) -> Resp {
        Resp {
            status: 201,
            body,
            headers: vec![],
        }
    }
    fn err(status: u16, message: &str) -> Resp {
        Resp {
            status,
            body: json!({ "message": message, "documentation_url": "https://docs.github.com/rest" }),
            headers: vec![],
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Perm {
    Issues,
    PullRequests,
    Contents,
    Checks,
}

impl Perm {
    fn key(self) -> &'static str {
        match self {
            Perm::Issues => "issues",
            Perm::PullRequests => "pull_requests",
            Perm::Contents => "contents",
            Perm::Checks => "checks",
        }
    }
}

struct Req {
    method: String,
    path: String,
    query: BTreeMap<String, String>,
    headers: Vec<(String, String)>,
    body: Value,
}

impl Req {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

// ---------------------------------------------------------------- helpers

fn iso8601(secs: u64) -> String {
    // Howard Hinnant's civil_from_days.
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn etag_of(body: &[u8]) -> String {
    let mut h = DefaultHasher::new();
    body.hash(&mut h);
    format!("\"{:016x}\"", h.finish())
}

fn etag_matches(if_none_match: &str, etag: &str) -> bool {
    if_none_match.split(',').any(|c| {
        let c = c.trim();
        c == "*" || c == etag || c.strip_prefix("W/") == Some(etag)
    })
}

fn synthetic_sha(seed: &str) -> String {
    let mut h = DefaultHasher::new();
    seed.hash(&mut h);
    let a = h.finish();
    format!("{a:016x}{a:016x}{:08x}", (a >> 32) as u32)
}

// ---------------------------------------------------------------- state

impl State {
    fn now(&mut self) -> String {
        iso8601((self.clock)())
    }

    fn next_id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    fn repo_mut(&mut self, owner: &str, repo: &str) -> &mut Repo {
        self.repos.entry(format!("{owner}/{repo}")).or_default()
    }

    fn mint(&mut self, login: &str, perms: &[(&str, &str)]) -> String {
        let id = self.next_id();
        let permissions: BTreeMap<String, String> = perms
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let encoded = if permissions.is_empty() {
            "all".to_string()
        } else {
            permissions
                .iter()
                .map(|(k, v)| format!("{k}.{v}"))
                .collect::<Vec<_>>()
                .join("+")
        };
        let token = format!("ghs_fake_{id}_{}_{encoded}", login.replace(['[', ']'], ""));
        self.tokens.insert(
            token.clone(),
            Token {
                login: login.to_string(),
                permissions,
            },
        );
        token
    }

    fn issue_json(&self, owner: &str, repo: &str, i: &Issue) -> Value {
        let base = format!("/repos/{owner}/{repo}");
        let mut v = json!({
            "id": i.id,
            "number": i.number,
            "title": i.title,
            "body": i.body,
            "state": i.state,
            "user": { "login": i.author },
            "labels": i.labels.iter().map(|l| json!({ "name": l })).collect::<Vec<_>>(),
            "created_at": i.created_at,
            "updated_at": i.updated_at,
            "url": format!("{base}/issues/{}", i.number),
            "comments": i.comments.len(),
        });
        if i.pull.is_some() {
            v["pull_request"] = json!({ "url": format!("{base}/pulls/{}", i.number) });
        }
        v
    }

    fn pull_json(&self, owner: &str, repo: &str, i: &Issue, p: &Pull) -> Value {
        let base = format!("/repos/{owner}/{repo}");
        json!({
            "id": i.id,
            "number": i.number,
            "title": i.title,
            "body": i.body,
            "state": i.state,
            "draft": p.draft,
            "merged": false,
            "user": { "login": i.author },
            "labels": i.labels.iter().map(|l| json!({ "name": l })).collect::<Vec<_>>(),
            "head": { "ref": p.head_ref, "sha": p.head_sha },
            "base": { "ref": p.base_ref, "sha": p.base_sha },
            "created_at": i.created_at,
            "updated_at": i.updated_at,
            "url": format!("{base}/pulls/{}", i.number),
        })
    }

    fn event(&mut self, actor: &str, kind: &str, extra: Value) -> Value {
        let id = self.next_id();
        let at = self.now();
        let mut e = json!({
            "id": id,
            "event": kind,
            "actor": { "login": actor },
            "created_at": at,
        });
        if let Value::Object(m) = extra {
            for (k, v) in m {
                e[k] = v;
            }
        }
        e
    }

    /// Move a PR's head to `sha`: stale approvals become DISMISSED.
    fn move_head(&mut self, owner: &str, repo: &str, number: u64, sha: &str, actor: &str) {
        let forced = self.event(actor, "head_ref_force_pushed", json!({ "commit_id": sha }));
        let mut dismissals = vec![];
        {
            let key = format!("{owner}/{repo}");
            let r = self.repos.get_mut(&key).expect("repo");
            let i = r.issues.get_mut(&number).expect("pr");
            let p = i.pull.as_mut().expect("pull");
            p.head_sha = sha.to_string();
            r.refs
                .insert(format!("refs/heads/{}", p.head_ref), sha.to_string());
            i.events.push(forced);
            for rv in &mut p.reviews {
                if rv["state"] == "APPROVED" {
                    rv["state"] = json!("DISMISSED");
                    dismissals.push(rv["id"].clone());
                }
            }
        }
        for rid in dismissals {
            let e = self.event(
                actor,
                "review_dismissed",
                json!({ "dismissed_review": { "review_id": rid, "state": "approved",
                        "dismissal_message": "stale: head moved" } }),
            );
            let r = self
                .repos
                .get_mut(&format!("{owner}/{repo}"))
                .expect("repo");
            let i = r.issues.get_mut(&number).expect("pr");
            i.events.push(e);
        }
        self.touch(owner, repo, number);
    }

    fn touch(&mut self, owner: &str, repo: &str, number: u64) {
        let at = self.now();
        if let Some(i) = self
            .repos
            .get_mut(&format!("{owner}/{repo}"))
            .and_then(|r| r.issues.get_mut(&number))
        {
            i.updated_at = at;
        }
    }

    // ------------------------------------------------------------ dispatch

    fn handle(&mut self, req: &Req) -> Resp {
        let key = if req.query.is_empty() {
            req.path.clone()
        } else {
            let q: Vec<String> = req.query.iter().map(|(k, v)| format!("{k}={v}")).collect();
            format!("{}?{}", req.path, q.join("&"))
        };
        *self.counts.entry(key).or_insert(0) += 1;

        let segs: Vec<String> = req
            .path
            .split('/')
            .filter(|s| !s.is_empty())
            .map(percent_decode)
            .collect();
        let s: Vec<&str> = segs.iter().map(String::as_str).collect();

        // Token mint: authenticated by an App JWT we do not verify.
        if let ["app", "installations", id, "access_tokens"] = s.as_slice() {
            if req.method != "POST" {
                return Resp::err(404, "Not Found");
            }
            if req.header("Authorization").is_none() {
                return Resp::err(401, "A JSON web token could not be decoded");
            }
            let Ok(id) = id.parse::<u64>() else {
                return Resp::err(404, "Not Found");
            };
            let Some(login) = self.installations.get(&id).cloned() else {
                return Resp::err(404, "Not Found");
            };
            let perms: Vec<(String, String)> = req.body["permissions"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                        .collect()
                })
                .unwrap_or_default();
            let borrowed: Vec<(&str, &str)> = perms
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            let token = self.mint(&login, &borrowed);
            let expires = iso8601((self.clock)() + 3600);
            let permissions: BTreeMap<_, _> = perms.iter().cloned().collect();
            self.writes.push(Write {
                actor: login.clone(),
                method: "POST".into(),
                path: req.path.clone(),
                body: req.body.clone(),
            });
            return Resp::created(json!({
                "token": token,
                "expires_at": expires,
                "permissions": permissions,
                "repository_selection": "selected",
            }));
        }

        let Some(("repos", rest)) = s.split_first().map(|(a, b)| (*a, b)) else {
            return Resp::err(404, "Not Found");
        };
        let [owner, repo, rest @ ..] = rest else {
            return Resp::err(404, "Not Found");
        };
        let (owner, repo) = (owner.to_string(), repo.to_string());

        // Every /repos route requires a token; the required permission and
        // whether the verb writes are decided by the route.
        let is_write = matches!(req.method.as_str(), "POST" | "PATCH" | "PUT" | "DELETE");
        let perm = match rest.first().copied() {
            Some("issues") => Perm::Issues,
            Some("pulls") => Perm::PullRequests,
            Some("git") => Perm::Contents,
            Some("check-runs") | Some("commits") => Perm::Checks,
            _ => return Resp::err(404, "Not Found"),
        };
        let actor = match self.authorize(req, perm, is_write) {
            Ok(a) => a,
            Err(r) => return r,
        };
        if !self.repos.contains_key(&format!("{owner}/{repo}")) {
            return Resp::err(404, "Not Found");
        }

        let resp = self.route(req, &owner, &repo, rest, &actor);
        if is_write && resp.status < 300 {
            self.writes.push(Write {
                actor,
                method: req.method.clone(),
                path: req.path.clone(),
                body: req.body.clone(),
            });
        }
        resp
    }

    fn authorize(&self, req: &Req, perm: Perm, is_write: bool) -> Result<String, Resp> {
        let Some(auth) = req.header("Authorization") else {
            return Err(Resp::err(401, "Requires authentication"));
        };
        let raw = auth
            .strip_prefix("Bearer ")
            .or_else(|| auth.strip_prefix("token "))
            .unwrap_or(auth);
        let Some(t) = self.tokens.get(raw) else {
            return Err(Resp::err(401, "Bad credentials"));
        };
        if !t.permissions.is_empty() {
            let level = t.permissions.get(perm.key()).map(String::as_str);
            let allowed = matches!(
                (level, is_write),
                (Some("write"), _) | (Some("read"), false)
            );
            if !allowed {
                return Err(Resp::err(403, "Resource not accessible by integration"));
            }
        }
        Ok(t.login.clone())
    }

    fn route(&mut self, req: &Req, owner: &str, repo: &str, rest: &[&str], actor: &str) -> Resp {
        let m = req.method.as_str();
        let num = |s: &str| s.parse::<u64>().ok();
        match (m, rest) {
            // ---------------------------------------------------- issues
            ("GET", ["issues"]) => {
                let want = req.query.get("state").map(String::as_str).unwrap_or("open");
                let r = &self.repos[&format!("{owner}/{repo}")];
                let list: Vec<Value> = r
                    .issues
                    .values()
                    .filter(|i| want == "all" || i.state == want)
                    .map(|i| self.issue_json(owner, repo, i))
                    .collect();
                Resp::ok(Value::Array(list))
            }
            ("GET", ["issues", n]) => match num(n).and_then(|n| self.issue(owner, repo, n)) {
                Some(i) => Resp::ok(self.issue_json(owner, repo, &i)),
                None => Resp::err(404, "Not Found"),
            },
            ("POST", ["issues", n, "labels"]) => {
                let Some(n) = num(n).filter(|n| self.issue(owner, repo, *n).is_some()) else {
                    return Resp::err(404, "Not Found");
                };
                let Some(names) = req.body["labels"].as_array() else {
                    return Resp::err(422, "Invalid request.\n\n\"labels\" wasn't supplied.");
                };
                let names: Vec<String> = names
                    .iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect();
                for name in names {
                    let already = self.issue(owner, repo, n).map(|i| i.labels.contains(&name));
                    if already == Some(true) {
                        continue;
                    }
                    let e = self.event(actor, "labeled", json!({ "label": { "name": name } }));
                    let i = self.issue_mut(owner, repo, n);
                    i.labels.push(name);
                    i.events.push(e);
                }
                self.touch(owner, repo, n);
                Resp::ok(self.labels_json(owner, repo, n))
            }
            ("DELETE", ["issues", n, "labels", name]) => {
                let Some(n) = num(n).filter(|n| self.issue(owner, repo, *n).is_some()) else {
                    return Resp::err(404, "Not Found");
                };
                let name = name.to_string();
                if !self.issue_mut(owner, repo, n).labels.contains(&name) {
                    return Resp::err(404, "Label does not exist");
                }
                let e = self.event(actor, "unlabeled", json!({ "label": { "name": name } }));
                let i = self.issue_mut(owner, repo, n);
                i.labels.retain(|l| *l != name);
                i.events.push(e);
                self.touch(owner, repo, n);
                Resp::ok(self.labels_json(owner, repo, n))
            }
            ("GET", ["issues", n, "events"]) => {
                match num(n).and_then(|n| self.issue(owner, repo, n)) {
                    Some(i) => Resp::ok(Value::Array(i.events)),
                    None => Resp::err(404, "Not Found"),
                }
            }
            ("GET", ["issues", n, "comments"]) => {
                match num(n).and_then(|n| self.issue(owner, repo, n)) {
                    Some(i) => Resp::ok(Value::Array(i.comments)),
                    None => Resp::err(404, "Not Found"),
                }
            }
            ("POST", ["issues", n, "comments"]) => {
                let Some(n) = num(n).filter(|n| self.issue(owner, repo, *n).is_some()) else {
                    return Resp::err(404, "Not Found");
                };
                let Some(body) = req.body["body"].as_str() else {
                    return Resp::err(422, "Invalid request.\n\n\"body\" wasn't supplied.");
                };
                let id = self.next_id();
                let at = self.now();
                let c = json!({
                    "id": id,
                    "body": body,
                    "user": { "login": actor },
                    "created_at": at,
                    "updated_at": at,
                    "issue_url": format!("/repos/{owner}/{repo}/issues/{n}"),
                });
                self.issue_mut(owner, repo, n).comments.push(c.clone());
                self.touch(owner, repo, n);
                Resp::created(c)
            }

            // ---------------------------------------------------- pulls
            ("POST", ["pulls"]) => {
                let (Some(title), Some(head), Some(base)) = (
                    req.body["title"].as_str(),
                    req.body["head"].as_str(),
                    req.body["base"].as_str(),
                ) else {
                    return Resp::err(422, "Validation Failed: title, head and base are required");
                };
                let r = self.repo_mut(owner, repo);
                let Some(head_sha) = r.refs.get(&format!("refs/heads/{head}")).cloned() else {
                    return Resp::err(422, "Validation Failed: head branch does not exist");
                };
                let Some(base_sha) = r.refs.get(&format!("refs/heads/{base}")).cloned() else {
                    return Resp::err(422, "Validation Failed: base branch does not exist");
                };
                if r.issues.values().any(|i| {
                    i.state == "open" && i.pull.as_ref().is_some_and(|p| p.head_ref == head)
                }) {
                    return Resp::err(422, "A pull request already exists for this head");
                }
                let n = self.create_issue(
                    owner,
                    repo,
                    title,
                    req.body["body"].as_str().unwrap_or(""),
                    actor,
                    &[],
                    Some(Pull {
                        draft: req.body["draft"].as_bool().unwrap_or(false),
                        head_ref: head.to_string(),
                        head_sha,
                        base_ref: base.to_string(),
                        base_sha,
                        reviews: vec![],
                    }),
                );
                let i = self.issue(owner, repo, n).expect("just created");
                let p = i.pull.clone().expect("pull");
                Resp::created(self.pull_json(owner, repo, &i, &p))
            }
            ("GET", ["pulls", n]) => match num(n).and_then(|n| self.issue(owner, repo, n)) {
                Some(i) => match &i.pull {
                    Some(p) => Resp::ok(self.pull_json(owner, repo, &i, p)),
                    None => Resp::err(404, "Not Found"),
                },
                None => Resp::err(404, "Not Found"),
            },
            ("PATCH", ["pulls", n]) => {
                let Some(n) = num(n).filter(|n| self.pull_exists(owner, repo, *n)) else {
                    return Resp::err(404, "Not Found");
                };
                if let Some(t) = req.body["title"].as_str() {
                    self.issue_mut(owner, repo, n).title = t.to_string();
                }
                if let Some(b) = req.body["body"].as_str() {
                    self.issue_mut(owner, repo, n).body = b.to_string();
                }
                if let Some(st) = req.body["state"].as_str() {
                    if st != "open" && st != "closed" {
                        return Resp::err(422, "Validation Failed: state");
                    }
                    self.issue_mut(owner, repo, n).state = st.to_string();
                }
                // GitHub only flips draft via GraphQL; the fake accepts
                // either spelling so the client can be tested over REST.
                if req.body["ready_for_review"].as_bool() == Some(true)
                    || req.body["draft"].as_bool() == Some(false)
                {
                    let e = self.event(actor, "ready_for_review", json!({}));
                    let i = self.issue_mut(owner, repo, n);
                    i.pull.as_mut().expect("pull").draft = false;
                    i.events.push(e);
                }
                // Fake-only: simulate a push to the head branch.
                if let Some(sha) = req.body["head_sha"].as_str() {
                    self.move_head(owner, repo, n, sha, actor);
                }
                self.touch(owner, repo, n);
                let i = self.issue(owner, repo, n).expect("pr");
                let p = i.pull.clone().expect("pull");
                Resp::ok(self.pull_json(owner, repo, &i, &p))
            }
            ("GET", ["pulls", n, "reviews"]) => {
                match num(n).and_then(|n| self.issue(owner, repo, n)) {
                    Some(Issue { pull: Some(p), .. }) => Resp::ok(Value::Array(p.reviews)),
                    _ => Resp::err(404, "Not Found"),
                }
            }
            ("POST", ["pulls", n, "reviews"]) => {
                let Some(n) = num(n).filter(|n| self.pull_exists(owner, repo, *n)) else {
                    return Resp::err(404, "Not Found");
                };
                let event = req.body["event"].as_str().unwrap_or("COMMENT");
                let state = match event {
                    "APPROVE" => "APPROVED",
                    "REQUEST_CHANGES" => "CHANGES_REQUESTED",
                    "COMMENT" => "COMMENTED",
                    _ => return Resp::err(422, "Validation Failed: event"),
                };
                let i = self.issue(owner, repo, n).expect("pr");
                let p = i.pull.as_ref().expect("pull");
                if i.author == actor && event == "APPROVE" {
                    return Resp::err(422, "Can not approve your own pull request");
                }
                if i.author == actor && event == "REQUEST_CHANGES" {
                    return Resp::err(422, "Can not request changes on your own pull request");
                }
                let commit_id = req.body["commit_id"]
                    .as_str()
                    .unwrap_or(&p.head_sha)
                    .to_string();
                if commit_id != p.head_sha {
                    // The fake knows only the current head; the real API
                    // accepts any commit in the PR and marks it stale.
                    return Resp::err(422, "Validation Failed: commit_id is not the PR head");
                }
                let id = self.next_id();
                let at = self.now();
                let rv = json!({
                    "id": id,
                    "user": { "login": actor },
                    "state": state,
                    "commit_id": commit_id,
                    "body": req.body["body"].as_str().unwrap_or(""),
                    "submitted_at": at,
                });
                self.issue_mut(owner, repo, n)
                    .pull
                    .as_mut()
                    .expect("pull")
                    .reviews
                    .push(rv.clone());
                self.touch(owner, repo, n);
                Resp::ok(rv)
            }

            // ---------------------------------------------------- refs
            ("GET", ["git", "ref", parts @ ..]) => {
                let name = format!("refs/{}", parts.join("/"));
                match self.repo_mut(owner, repo).refs.get(&name) {
                    Some(sha) => Resp::ok(ref_json(owner, repo, &name, sha)),
                    None => Resp::err(404, "Not Found"),
                }
            }
            ("POST", ["git", "refs"]) => {
                let (Some(name), Some(sha)) = (req.body["ref"].as_str(), req.body["sha"].as_str())
                else {
                    return Resp::err(422, "Validation Failed: ref and sha are required");
                };
                if !name.starts_with("refs/") {
                    return Resp::err(422, "Reference name must start with refs/");
                }
                let r = self.repo_mut(owner, repo);
                if r.refs.contains_key(name) {
                    return Resp::err(422, "Reference already exists");
                }
                r.refs.insert(name.to_string(), sha.to_string());
                Resp::created(ref_json(owner, repo, name, sha))
            }
            ("PATCH", ["git", "refs", parts @ ..]) => {
                let name = format!("refs/{}", parts.join("/"));
                let Some(sha) = req.body["sha"].as_str().map(str::to_string) else {
                    return Resp::err(422, "Validation Failed: sha is required");
                };
                let Some(current) = self.repo_mut(owner, repo).refs.get(&name).cloned() else {
                    return Resp::err(404, "Not Found");
                };
                if let Some(expect) = req.header("X-Fake-Expect-Sha") {
                    if expect != current {
                        return Resp::err(
                            422,
                            "Update is not a fast forward (stale expected sha; force-with-lease refused)",
                        );
                    }
                }
                self.repo_mut(owner, repo)
                    .refs
                    .insert(name.clone(), sha.clone());
                // A push to a branch that is an open PR's head moves that PR.
                let moved: Vec<u64> = self
                    .repo_mut(owner, repo)
                    .issues
                    .values()
                    .filter(|i| {
                        i.state == "open"
                            && i.pull.as_ref().is_some_and(|p| {
                                format!("refs/heads/{}", p.head_ref) == name && p.head_sha != sha
                            })
                    })
                    .map(|i| i.number)
                    .collect();
                for n in moved {
                    self.move_head(owner, repo, n, &sha, actor);
                }
                Resp::ok(ref_json(owner, repo, &name, &sha))
            }
            ("DELETE", ["git", "refs", parts @ ..]) => {
                let name = format!("refs/{}", parts.join("/"));
                match self.repo_mut(owner, repo).refs.remove(&name) {
                    Some(_) => Resp {
                        status: 204,
                        body: Value::Null,
                        headers: vec![],
                    },
                    None => Resp::err(422, "Reference does not exist"),
                }
            }

            // ---------------------------------------------------- checks
            ("POST", ["check-runs"]) => {
                let (Some(name), Some(head_sha)) =
                    (req.body["name"].as_str(), req.body["head_sha"].as_str())
                else {
                    return Resp::err(422, "Validation Failed: name and head_sha are required");
                };
                let id = self.next_id();
                let at = self.now();
                let cr = json!({
                    "id": id,
                    "name": name,
                    "head_sha": head_sha,
                    "status": req.body["status"].as_str().unwrap_or("queued"),
                    "conclusion": req.body["conclusion"].clone(),
                    "details_url": req.body["details_url"].clone(),
                    "output": req.body["output"].clone(),
                    "app": { "slug": actor.trim_end_matches("[bot]") },
                    "started_at": at,
                });
                self.repo_mut(owner, repo).check_runs.push(cr.clone());
                Resp::created(cr)
            }
            ("PATCH", ["check-runs", id]) => {
                let Some(id) = num(id) else {
                    return Resp::err(404, "Not Found");
                };
                let at = self.now();
                let r = self.repo_mut(owner, repo);
                let Some(cr) = r.check_runs.iter_mut().find(|c| c["id"] == id) else {
                    return Resp::err(404, "Not Found");
                };
                for k in ["status", "conclusion", "output", "details_url"] {
                    if !req.body[k].is_null() {
                        cr[k] = req.body[k].clone();
                    }
                }
                if cr["status"] == "completed" {
                    cr["completed_at"] = json!(at);
                }
                Resp::ok(cr.clone())
            }
            ("GET", ["commits", sha, "check-runs"]) => {
                let r = self.repo_mut(owner, repo);
                let runs: Vec<Value> = r
                    .check_runs
                    .iter()
                    .filter(|c| c["head_sha"] == *sha)
                    .cloned()
                    .collect();
                Resp::ok(json!({ "total_count": runs.len(), "check_runs": runs }))
            }
            _ => Resp::err(404, "Not Found"),
        }
    }

    fn issue(&self, owner: &str, repo: &str, n: u64) -> Option<Issue> {
        self.repos
            .get(&format!("{owner}/{repo}"))
            .and_then(|r| r.issues.get(&n))
            .cloned()
    }

    fn issue_mut(&mut self, owner: &str, repo: &str, n: u64) -> &mut Issue {
        self.repo_mut(owner, repo)
            .issues
            .get_mut(&n)
            .expect("issue existence checked by caller")
    }

    fn pull_exists(&self, owner: &str, repo: &str, n: u64) -> bool {
        self.issue(owner, repo, n).is_some_and(|i| i.pull.is_some())
    }

    fn labels_json(&self, owner: &str, repo: &str, n: u64) -> Value {
        let i = self.issue(owner, repo, n).expect("issue");
        Value::Array(i.labels.iter().map(|l| json!({ "name": l })).collect())
    }

    #[allow(clippy::too_many_arguments)]
    fn create_issue(
        &mut self,
        owner: &str,
        repo: &str,
        title: &str,
        body: &str,
        author: &str,
        labels: &[&str],
        pull: Option<Pull>,
    ) -> u64 {
        let id = self.next_id();
        let at = self.now();
        let r = self.repo_mut(owner, repo);
        r.next_number += 1;
        let number = r.next_number;
        r.issues.insert(
            number,
            Issue {
                number,
                id,
                title: title.to_string(),
                body: body.to_string(),
                state: "open".into(),
                author: author.to_string(),
                labels: labels.iter().map(|s| s.to_string()).collect(),
                created_at: at.clone(),
                updated_at: at,
                pull,
                events: vec![],
                comments: vec![],
            },
        );
        number
    }
}

fn ref_json(owner: &str, repo: &str, name: &str, sha: &str) -> Value {
    json!({
        "ref": name,
        "url": format!("/repos/{owner}/{repo}/git/{name}"),
        "object": { "type": "commit", "sha": sha },
    })
}

// ---------------------------------------------------------------- server

/// An in-process fake of api.github.com. Construct, seed, point the client
/// at [`base_url`](Self::base_url), assert on [`writes`](Self::writes).
/// Shuts down on drop.
pub struct FakeGitHub {
    state: Arc<Mutex<State>>,
    server: Arc<tiny_http::Server>,
    base: String,
    thread: Option<JoinHandle<()>>,
}

impl FakeGitHub {
    /// Start on 127.0.0.1:0 with the default deterministic clock.
    pub fn start() -> FakeGitHub {
        let mut t = EPOCH_2026;
        Self::start_with_clock(Box::new(move || {
            t += 1;
            t
        }))
    }

    pub fn start_with_clock(clock: Clock) -> FakeGitHub {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind 127.0.0.1:0"));
        let addr = server.server_addr().to_ip().expect("tcp listener");
        let state = Arc::new(Mutex::new(State {
            clock,
            next_id: 1000,
            repos: BTreeMap::new(),
            installations: BTreeMap::new(),
            tokens: BTreeMap::new(),
            writes: vec![],
            counts: BTreeMap::new(),
        }));
        let (srv, st) = (server.clone(), state.clone());
        let thread = std::thread::spawn(move || {
            for mut rq in srv.incoming_requests() {
                let mut raw = String::new();
                let _ = std::io::Read::read_to_string(rq.as_reader(), &mut raw);
                let body = if raw.trim().is_empty() {
                    Value::Null
                } else {
                    serde_json::from_str(&raw).unwrap_or(Value::Null)
                };
                let (path, query) = split_url(rq.url());
                let req = Req {
                    method: rq.method().to_string().to_ascii_uppercase(),
                    path,
                    query,
                    headers: rq
                        .headers()
                        .iter()
                        .map(|h| (h.field.to_string(), h.value.as_str().to_string()))
                        .collect(),
                    body,
                };
                let resp = st.lock().expect("fake state").handle(&req);
                let _ = rq.respond(to_http(&req, resp));
            }
        });
        FakeGitHub {
            state,
            server,
            base: format!("http://{addr}"),
            thread: Some(thread),
        }
    }

    /// `http://127.0.0.1:<port>` — no trailing slash.
    pub fn base_url(&self) -> &str {
        &self.base
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().expect("fake state")
    }

    // ------------------------------------------------------------ seeding

    /// Register an App installation; `POST /app/installations/{id}/access_tokens`
    /// mints tokens acting as `login` (e.g. `fwf-impl[bot]`).
    pub fn add_installation(&self, id: u64, login: &str) {
        self.lock().installations.insert(id, login.to_string());
    }

    /// Mint a token directly. Empty `perms` = unnarrowed (all writes);
    /// otherwise e.g. `&[("contents", "read"), ("issues", "write")]`.
    pub fn token(&self, login: &str, perms: &[(&str, &str)]) -> String {
        self.lock().mint(login, perms)
    }

    /// Create (or no-op) a repo.
    pub fn add_repo(&self, owner: &str, repo: &str) {
        self.lock().repo_mut(owner, repo);
    }

    pub fn seed_issue(
        &self,
        owner: &str,
        repo: &str,
        title: &str,
        author: &str,
        labels: &[&str],
    ) -> u64 {
        self.lock()
            .create_issue(owner, repo, title, "", author, labels, None)
    }

    /// Set `refs/<name>` (e.g. `heads/main`) to `sha`, creating the repo.
    pub fn seed_ref(&self, owner: &str, repo: &str, name: &str, sha: &str) {
        self.lock()
            .repo_mut(owner, repo)
            .refs
            .insert(format!("refs/{name}"), sha.to_string());
    }

    /// A deterministic 40-hex "sha" for a label, for tests that need one.
    pub fn sha(label: &str) -> String {
        synthetic_sha(label)
    }

    // ------------------------------------------------------------ queries

    /// Every accepted write, in order.
    pub fn writes(&self) -> Vec<Write> {
        self.lock().writes.clone()
    }

    /// Requests seen for exactly this path (+ query, if any), any method,
    /// 304s included.
    pub fn request_count(&self, path_and_query: &str) -> u64 {
        self.lock().counts.get(path_and_query).copied().unwrap_or(0)
    }

    pub fn ref_sha(&self, owner: &str, repo: &str, name: &str) -> Option<String> {
        self.lock()
            .repos
            .get(&format!("{owner}/{repo}"))
            .and_then(|r| r.refs.get(&format!("refs/{name}")).cloned())
    }

    pub fn issue_json(&self, owner: &str, repo: &str, n: u64) -> Option<Value> {
        let s = self.lock();
        s.issue(owner, repo, n)
            .map(|i| s.issue_json(owner, repo, &i))
    }

    pub fn events(&self, owner: &str, repo: &str, n: u64) -> Vec<Value> {
        self.lock()
            .issue(owner, repo, n)
            .map(|i| i.events)
            .unwrap_or_default()
    }

    pub fn reviews(&self, owner: &str, repo: &str, n: u64) -> Vec<Value> {
        self.lock()
            .issue(owner, repo, n)
            .and_then(|i| i.pull.map(|p| p.reviews))
            .unwrap_or_default()
    }
}

impl Drop for FakeGitHub {
    fn drop(&mut self) {
        self.server.unblock();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn split_url(url: &str) -> (String, BTreeMap<String, String>) {
    let (path, q) = url.split_once('?').unwrap_or((url, ""));
    let query = q
        .split('&')
        .filter(|s| !s.is_empty())
        .map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            (percent_decode(k), percent_decode(v))
        })
        .collect();
    (path.to_string(), query)
}

fn to_http(req: &Req, resp: Resp) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    use std::io::Cursor;
    let header = |k: &str, v: &str| tiny_http::Header::from_bytes(k, v).expect("ascii header");
    let body = if resp.body.is_null() {
        Vec::new()
    } else {
        serde_json::to_vec(&resp.body).expect("json")
    };
    let mut out = tiny_http::Response::from_data(Vec::new())
        .with_header(header("Content-Type", "application/json; charset=utf-8"))
        .with_header(header("X-GitHub-Media-Type", "github.v3; format=json"))
        .with_header(header("X-RateLimit-Limit", "5000"));
    for (k, v) in &resp.headers {
        out = out.with_header(header(k, v));
    }
    if req.method == "GET" && resp.status == 200 {
        let etag = etag_of(&body);
        out = out.with_header(header("ETag", &etag));
        if req
            .header("If-None-Match")
            .is_some_and(|inm| etag_matches(inm, &etag))
        {
            return out.with_status_code(304);
        }
    }
    let len = body.len();
    out.with_status_code(resp.status)
        .with_data(Cursor::new(body), Some(len))
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    const O: &str = "tbaums";
    const R: &str = "scratch";

    struct Reply {
        status: u16,
        body: Value,
        etag: Option<String>,
    }

    fn call(
        method: &str,
        url: &str,
        token: Option<&str>,
        body: Option<Value>,
        extra: &[(&str, &str)],
    ) -> Reply {
        let mut rq = ureq::request(method, url).set("Accept", "application/vnd.github+json");
        if let Some(t) = token {
            rq = rq.set("Authorization", &format!("Bearer {t}"));
        }
        for (k, v) in extra {
            rq = rq.set(k, v);
        }
        let res = match body {
            Some(b) => rq.send_string(&b.to_string()),
            None => rq.call(),
        };
        let r = match res {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => panic!("transport: {e}"),
        };
        let status = r.status();
        let etag = r.header("ETag").map(str::to_string);
        let text = r.into_string().unwrap_or_default();
        let body = if text.is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::Null)
        };
        Reply { status, body, etag }
    }

    fn get(fake: &FakeGitHub, tok: &str, path: &str, extra: &[(&str, &str)]) -> Reply {
        call(
            "GET",
            &format!("{}{path}", fake.base_url()),
            Some(tok),
            None,
            extra,
        )
    }

    fn send(
        fake: &FakeGitHub,
        method: &str,
        tok: &str,
        path: &str,
        body: Value,
        extra: &[(&str, &str)],
    ) -> Reply {
        call(
            method,
            &format!("{}{path}", fake.base_url()),
            Some(tok),
            Some(body),
            extra,
        )
    }

    /// A repo with main + feat branches and an open PR #2 by alice.
    fn with_pr(fake: &FakeGitHub) -> (String, u64) {
        let alice = fake.token("alice", &[]);
        fake.seed_ref(O, R, "heads/main", &FakeGitHub::sha("main-1"));
        fake.seed_ref(O, R, "heads/feat", &FakeGitHub::sha("feat-1"));
        fake.seed_issue(O, R, "the issue", "jamie", &["ready"]);
        let r = send(
            fake,
            "POST",
            &alice,
            &format!("/repos/{O}/{R}/pulls"),
            json!({ "title": "impl", "head": "feat", "base": "main", "draft": true }),
            &[],
        );
        assert_eq!(r.status, 201, "{}", r.body);
        assert_eq!(r.body["draft"], true);
        assert_eq!(r.body["head"]["sha"], FakeGitHub::sha("feat-1"));
        (alice, r.body["number"].as_u64().unwrap())
    }

    #[test]
    fn etag_304_round_trip_and_request_counter() {
        let fake = FakeGitHub::start();
        let tok = fake.token("fwf-ops[bot]", &[]);
        fake.seed_issue(O, R, "one", "jamie", &["ready"]);
        let path = format!("/repos/{O}/{R}/issues?state=open");
        let first = get(&fake, &tok, &path, &[]);
        assert_eq!(first.status, 200);
        assert_eq!(first.body.as_array().unwrap().len(), 1);
        assert_eq!(first.body[0]["created_at"], "2026-01-01T00:00:01Z");
        let etag = first.etag.clone().expect("ETag on GET");

        let again = get(&fake, &tok, &path, &[("If-None-Match", &etag)]);
        assert_eq!(again.status, 304);
        assert!(again.body.is_null());
        assert_eq!(again.etag.as_deref(), Some(etag.as_str()));
        assert_eq!(fake.request_count(&path), 2, "304s still count as requests");
        assert_eq!(fake.request_count(&format!("/repos/{O}/{R}/issues")), 0);

        send(
            &fake,
            "POST",
            &tok,
            &format!("/repos/{O}/{R}/issues/1/labels"),
            json!({ "labels": ["claimed"] }),
            &[],
        );
        let changed = get(&fake, &tok, &path, &[("If-None-Match", &etag)]);
        assert_eq!(changed.status, 200);
        assert_ne!(changed.etag, Some(etag));
        assert_eq!(fake.request_count(&path), 3);
    }

    #[test]
    fn author_cannot_approve_own_pr() {
        let fake = FakeGitHub::start();
        let (alice, n) = with_pr(&fake);
        let path = format!("/repos/{O}/{R}/pulls/{n}/reviews");
        let own = send(
            &fake,
            "POST",
            &alice,
            &path,
            json!({ "event": "APPROVE" }),
            &[],
        );
        assert_eq!(own.status, 422);
        assert!(own.body["message"]
            .as_str()
            .unwrap()
            .contains("own pull request"));
        let own = send(
            &fake,
            "POST",
            &alice,
            &path,
            json!({ "event": "REQUEST_CHANGES" }),
            &[],
        );
        assert_eq!(own.status, 422);
        assert!(fake.reviews(O, R, n).is_empty());

        let qa = fake.token("fwf-qa[bot]", &[("pull_requests", "write")]);
        let ok = send(
            &fake,
            "POST",
            &qa,
            &path,
            json!({ "event": "APPROVE", "commit_id": FakeGitHub::sha("feat-1") }),
            &[],
        );
        assert_eq!(ok.status, 200, "{}", ok.body);
        assert_eq!(ok.body["state"], "APPROVED");
        assert_eq!(ok.body["user"]["login"], "fwf-qa[bot]");
        let stale = send(
            &fake,
            "POST",
            &qa,
            &path,
            json!({ "event": "APPROVE", "commit_id": FakeGitHub::sha("nope") }),
            &[],
        );
        assert_eq!(stale.status, 422);
        let w = fake.writes();
        assert_eq!(
            w.len(),
            2,
            "pr create + one review; refusals are not writes"
        );
        assert_eq!(w[1].actor, "fwf-qa[bot]");
        assert_eq!(w[1].path, path);
    }

    #[test]
    fn approval_dismissed_on_head_move() {
        let fake = FakeGitHub::start();
        let (alice, n) = with_pr(&fake);
        let qa = fake.token("fwf-qa[bot]", &[]);
        let reviews = format!("/repos/{O}/{R}/pulls/{n}/reviews");
        send(
            &fake,
            "POST",
            &qa,
            &reviews,
            json!({ "event": "APPROVE" }),
            &[],
        );
        assert_eq!(fake.reviews(O, R, n)[0]["state"], "APPROVED");

        let moved = send(
            &fake,
            "PATCH",
            &alice,
            &format!("/repos/{O}/{R}/pulls/{n}"),
            json!({ "head_sha": FakeGitHub::sha("feat-2"), "ready_for_review": true }),
            &[],
        );
        assert_eq!(moved.status, 200);
        assert_eq!(moved.body["head"]["sha"], FakeGitHub::sha("feat-2"));
        assert_eq!(moved.body["draft"], false);
        assert_eq!(
            fake.ref_sha(O, R, "heads/feat").unwrap(),
            FakeGitHub::sha("feat-2")
        );
        let rv = get(&fake, &qa, &reviews, &[]);
        assert_eq!(rv.body[0]["state"], "DISMISSED");
        let kinds: Vec<String> = fake
            .events(O, R, n)
            .iter()
            .map(|e| e["event"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            kinds,
            [
                "ready_for_review",
                "head_ref_force_pushed",
                "review_dismissed"
            ]
        );

        // The same happens when the head branch ref is pushed directly.
        send(
            &fake,
            "POST",
            &qa,
            &reviews,
            json!({ "event": "APPROVE" }),
            &[],
        );
        assert_eq!(fake.reviews(O, R, n)[1]["state"], "APPROVED");
        let pushed = send(
            &fake,
            "PATCH",
            &alice,
            &format!("/repos/{O}/{R}/git/refs/heads/feat"),
            json!({ "sha": FakeGitHub::sha("feat-3"), "force": true }),
            &[],
        );
        assert_eq!(pushed.status, 200);
        assert_eq!(fake.reviews(O, R, n)[1]["state"], "DISMISSED");
        let pr = get(&fake, &qa, &format!("/repos/{O}/{R}/pulls/{n}"), &[]);
        assert_eq!(pr.body["head"]["sha"], FakeGitHub::sha("feat-3"));
    }

    #[test]
    fn ref_cas_success_then_422_on_stale_expect() {
        let fake = FakeGitHub::start();
        let tok = fake.token("fwf-ops[bot]", &[("contents", "write")]);
        let (a, b, c) = (
            FakeGitHub::sha("a"),
            FakeGitHub::sha("b"),
            FakeGitHub::sha("c"),
        );
        fake.seed_ref(O, R, "heads/main", &a);
        let path = format!("/repos/{O}/{R}/git/refs/heads/main");

        let ok = send(
            &fake,
            "PATCH",
            &tok,
            &path,
            json!({ "sha": b, "force": false }),
            &[("X-Fake-Expect-Sha", &a)],
        );
        assert_eq!(ok.status, 200, "{}", ok.body);
        assert_eq!(ok.body["object"]["sha"], b);

        let stale = send(
            &fake,
            "PATCH",
            &tok,
            &path,
            json!({ "sha": c, "force": true }),
            &[("X-Fake-Expect-Sha", &a)],
        );
        assert_eq!(stale.status, 422);
        assert_eq!(
            fake.ref_sha(O, R, "heads/main").unwrap(),
            b,
            "stale CAS must not move the ref"
        );

        let got = get(
            &fake,
            &tok,
            &format!("/repos/{O}/{R}/git/ref/heads/main"),
            &[],
        );
        assert_eq!(got.status, 200);
        assert_eq!(got.body["ref"], "refs/heads/main");
        assert_eq!(got.body["object"]["sha"], b);
        assert_eq!(
            get(
                &fake,
                &tok,
                &format!("/repos/{O}/{R}/git/ref/heads/nope"),
                &[]
            )
            .status,
            404
        );

        let w = fake.writes();
        assert_eq!(w.len(), 1);
        assert_eq!(
            w[0],
            Write {
                actor: "fwf-ops[bot]".into(),
                method: "PATCH".into(),
                path,
                body: json!({ "sha": b, "force": false })
            }
        );
    }

    #[test]
    fn create_ref_is_422_when_it_exists() {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let tok = fake.token("fwf-ops[bot]", &[]);
        let path = format!("/repos/{O}/{R}/git/refs");
        let body = json!({ "ref": "refs/heads/claim/5", "sha": FakeGitHub::sha("x") });
        let first = send(&fake, "POST", &tok, &path, body.clone(), &[]);
        assert_eq!(first.status, 201);
        assert_eq!(first.body["ref"], "refs/heads/claim/5");
        let second = send(&fake, "POST", &tok, &path, body, &[]);
        assert_eq!(second.status, 422);
        assert_eq!(second.body["message"], "Reference already exists");
        assert_eq!(fake.writes().len(), 1);

        let del = send(
            &fake,
            "DELETE",
            &tok,
            &format!("{path}/heads/claim/5"),
            Value::Null,
            &[],
        );
        assert_eq!(del.status, 204);
        assert!(fake.ref_sha(O, R, "heads/claim/5").is_none());
        assert_eq!(
            send(
                &fake,
                "DELETE",
                &tok,
                &format!("{path}/heads/claim/5"),
                Value::Null,
                &[]
            )
            .status,
            422
        );
    }

    #[test]
    fn read_only_token_is_refused_on_write() {
        let fake = FakeGitHub::start();
        fake.add_installation(42, "fwf-impl[bot]");
        fake.seed_ref(O, R, "heads/main", &FakeGitHub::sha("m"));
        let mint = call(
            "POST",
            &format!("{}/app/installations/42/access_tokens", fake.base_url()),
            Some("fake.app.jwt"),
            Some(json!({ "permissions": { "contents": "read", "metadata": "read" } })),
            &[],
        );
        assert_eq!(mint.status, 201, "{}", mint.body);
        let tok = mint.body["token"].as_str().unwrap().to_string();
        assert!(
            tok.contains("contents.read"),
            "token encodes its permissions: {tok}"
        );
        assert_eq!(mint.body["permissions"]["contents"], "read");

        let read = get(
            &fake,
            &tok,
            &format!("/repos/{O}/{R}/git/ref/heads/main"),
            &[],
        );
        assert_eq!(read.status, 200);
        let write = send(
            &fake,
            "PATCH",
            &tok,
            &format!("/repos/{O}/{R}/git/refs/heads/main"),
            json!({ "sha": FakeGitHub::sha("n"), "force": true }),
            &[],
        );
        assert_eq!(write.status, 403);
        assert_eq!(
            write.body["message"],
            "Resource not accessible by integration"
        );
        assert_eq!(
            fake.ref_sha(O, R, "heads/main").unwrap(),
            FakeGitHub::sha("m")
        );
        // A permission the token lacks entirely is refused even for reads.
        assert_eq!(
            get(&fake, &tok, &format!("/repos/{O}/{R}/issues"), &[]).status,
            403
        );
        // No token / unknown token.
        assert_eq!(
            call(
                "GET",
                &format!("{}/repos/{O}/{R}/issues", fake.base_url()),
                None,
                None,
                &[]
            )
            .status,
            401
        );
        assert_eq!(
            get(&fake, "ghs_bogus", &format!("/repos/{O}/{R}/issues"), &[]).status,
            401
        );
        assert_eq!(
            call(
                "POST",
                &format!("{}/app/installations/7/access_tokens", fake.base_url()),
                Some("jwt"),
                Some(json!({})),
                &[]
            )
            .status,
            404
        );

        let w = fake.writes();
        assert_eq!(w.len(), 1, "only the mint is a write");
        assert_eq!(w[0].actor, "fwf-impl[bot]");
        assert_eq!(w[0].path, "/app/installations/42/access_tokens");
    }

    #[test]
    fn label_events_carry_the_actor() {
        let fake = FakeGitHub::start();
        let ops = fake.token("fwf-ops[bot]", &[("issues", "write")]);
        let n = fake.seed_issue(O, R, "one", "jamie", &["ready"]);
        let labels = format!("/repos/{O}/{R}/issues/{n}/labels");
        let added = send(
            &fake,
            "POST",
            &ops,
            &labels,
            json!({ "labels": ["claimed", "ready"] }),
            &[],
        );
        assert_eq!(added.status, 200);
        assert_eq!(
            added.body,
            json!([{ "name": "ready" }, { "name": "claimed" }])
        );
        let removed = send(
            &fake,
            "DELETE",
            &ops,
            &format!("{labels}/ready"),
            Value::Null,
            &[],
        );
        assert_eq!(removed.status, 200);
        assert_eq!(removed.body, json!([{ "name": "claimed" }]));
        assert_eq!(
            send(
                &fake,
                "DELETE",
                &ops,
                &format!("{labels}/ready"),
                Value::Null,
                &[]
            )
            .status,
            404
        );

        let ev = get(
            &fake,
            &ops,
            &format!("/repos/{O}/{R}/issues/{n}/events"),
            &[],
        );
        let ev = ev.body.as_array().unwrap().clone();
        assert_eq!(
            ev.len(),
            2,
            "re-adding an existing label emits no event: {ev:?}"
        );
        assert_eq!(ev[0]["event"], "labeled");
        assert_eq!(ev[0]["label"]["name"], "claimed");
        assert_eq!(ev[0]["actor"]["login"], "fwf-ops[bot]");
        assert_eq!(ev[1]["event"], "unlabeled");
        assert_eq!(ev[1]["label"]["name"], "ready");
        assert_eq!(ev[1]["actor"]["login"], "fwf-ops[bot]");
        assert_eq!(ev[0]["created_at"], "2026-01-01T00:00:02Z");
        assert!(
            ev[1]["id"].as_u64() > ev[0]["id"].as_u64(),
            "ids are sequential"
        );

        let one = get(&fake, &ops, &format!("/repos/{O}/{R}/issues/{n}"), &[]);
        assert_eq!(one.body["labels"], json!([{ "name": "claimed" }]));
        assert!(one.body.get("pull_request").is_none());
        let w = fake.writes();
        assert_eq!(
            w.iter().map(|w| w.method.as_str()).collect::<Vec<_>>(),
            ["POST", "DELETE"]
        );
        assert!(w.iter().all(|w| w.actor == "fwf-ops[bot]"));
    }

    #[test]
    fn comments_check_runs_and_pull_as_issue() {
        let fake = FakeGitHub::start();
        let (alice, n) = with_pr(&fake);
        let c = send(
            &fake,
            "POST",
            &alice,
            &format!("/repos/{O}/{R}/issues/{n}/comments"),
            json!({ "body": "CLAIM seat-1" }),
            &[],
        );
        assert_eq!(c.status, 201);
        assert_eq!(c.body["user"]["login"], "alice");
        let list = get(
            &fake,
            &alice,
            &format!("/repos/{O}/{R}/issues/{n}/comments"),
            &[],
        );
        assert_eq!(list.body.as_array().unwrap().len(), 1);
        // A PR shows up in the issues list with a pull_request key.
        let issues = get(
            &fake,
            &alice,
            &format!("/repos/{O}/{R}/issues?state=all"),
            &[],
        );
        assert_eq!(issues.body.as_array().unwrap().len(), 2);
        assert!(issues.body[1]["pull_request"].is_object());
        assert!(issues.body[0]["pull_request"].is_null());
        assert_eq!(
            get(&fake, &alice, &format!("/repos/{O}/{R}/pulls/1"), &[]).status,
            404,
            "issue #1 is not a PR"
        );

        let sha = FakeGitHub::sha("feat-1");
        let cr = send(
            &fake,
            "POST",
            &alice,
            &format!("/repos/{O}/{R}/check-runs"),
            json!({ "name": "gate", "head_sha": sha, "status": "in_progress" }),
            &[],
        );
        assert_eq!(cr.status, 201);
        let id = cr.body["id"].as_u64().unwrap();
        let done = send(
            &fake,
            "PATCH",
            &alice,
            &format!("/repos/{O}/{R}/check-runs/{id}"),
            json!({ "status": "completed", "conclusion": "success" }),
            &[],
        );
        assert_eq!(done.status, 200);
        let runs = get(
            &fake,
            &alice,
            &format!("/repos/{O}/{R}/commits/{sha}/check-runs"),
            &[],
        );
        assert_eq!(runs.body["total_count"], 1);
        assert_eq!(runs.body["check_runs"][0]["conclusion"], "success");
        assert_eq!(
            get(
                &fake,
                &alice,
                &format!("/repos/{O}/{R}/commits/deadbeef/check-runs"),
                &[]
            )
            .body["total_count"],
            0
        );
        assert_eq!(
            get(&fake, &alice, "/repos/nobody/nothing/issues", &[]).status,
            404
        );
    }

    #[test]
    fn clock_is_injectable_and_iso8601_is_right() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(EPOCH_2026), "2026-01-01T00:00:00Z");
        assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
        let fake = FakeGitHub::start_with_clock(Box::new(|| 1_772_150_400));
        let n = fake.seed_issue(O, R, "t", "jamie", &[]);
        assert_eq!(
            fake.issue_json(O, R, n).unwrap()["created_at"],
            "2026-02-27T00:00:00Z"
        );
        assert_eq!(percent_decode("needs%20review"), "needs review");
    }
}
