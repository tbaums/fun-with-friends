//! The read side (T-09): one `Poller` reads a repo's open issues, open PRs,
//! their reviews and their `claims/<n>` refs through the REST API and returns
//! a [`Snapshot`]. Every GET is ETag-cached per URL (`If-None-Match`; a 304
//! re-uses the cached body) and single-flighted (two concurrent polls of one
//! URL make one request). A read that cannot complete is a typed
//! [`PollError`] and the caller holds an [`Snapshot::unknown`] — never a
//! partial, confident snapshot (#211).

use crate::types::Fence;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

/// The supervisor-owned label that marks a claimed issue. The fence for the
/// claim is the SHA of `refs/<CLAIM_REF_PREFIX>/<n>`; the label alone is
/// not a claim.
pub const CLAIM_LABEL: &str = "claimed";
/// Ref namespace of claim refs — `refs/claims/<n>`, as `mirror.rs` creates them.
pub const CLAIM_REF_PREFIX: &str = "claims";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IssueView {
    pub number: u64,
    pub title: String,
    /// GitHub's `author_association` (`OWNER`, `MEMBER`, `NONE`, …). When the
    /// API omits it (the fake does) it is derived: author == repo owner → OWNER.
    pub author_association: String,
    pub labels: Vec<String>,
    pub assignees: Vec<String>,
    pub state: String,
    pub updated_at: String,
    /// The live claim fence (`refs/claims/<n>` SHA), if the ref exists.
    pub claim: Option<Fence>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrView {
    pub number: u64,
    pub head_sha: String,
    pub head_ref: String,
    pub base_ref: String,
    pub draft: bool,
    pub state: String,
    /// `Closes #N` (or fixes/resolves) parsed from the body.
    pub closes_issue: Option<u64>,
    /// (login, state, commit_id)
    pub reviews: Vec<(String, String, String)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub issues: Vec<IssueView>,
    pub prs: Vec<PrView>,
    pub fetched_at: u64,
    /// False only for [`Snapshot::unknown`]: the tracker could not be read.
    pub known: bool,
}

impl Snapshot {
    pub fn unknown() -> Snapshot {
        Snapshot {
            issues: vec![],
            prs: vec![],
            fetched_at: 0,
            known: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PollError {
    /// Transport failure (connection refused, timeout, …).
    Transport(String),
    /// A non-2xx that is not a 304.
    Status { url: String, code: u16 },
    /// 2xx but the body was not the JSON shape we read.
    Malformed { url: String, why: String },
    /// A 304 arrived for a URL we hold no cached body for (server bug).
    NotModifiedUncached(String),
}

impl std::fmt::Display for PollError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PollError::Transport(e) => write!(f, "transport: {e}"),
            PollError::Status { url, code } => write!(f, "{code} from {url}"),
            PollError::Malformed { url, why } => write!(f, "malformed body from {url}: {why}"),
            PollError::NotModifiedUncached(u) => write!(f, "304 without a cached body for {u}"),
        }
    }
}

/// One raw GET result as the transport sees it.
#[derive(Clone, Debug)]
pub struct Raw {
    pub status: u16,
    pub etag: Option<String>,
    pub body: String,
}

/// `(url, if_none_match) -> Raw`. Injectable so tests can block or count.
pub type Transport = Arc<dyn Fn(&str, Option<&str>) -> Result<Raw, PollError> + Send + Sync>;

#[derive(Clone, Debug)]
struct Cached {
    etag: Option<String>,
    body: Value,
}

/// A single-flight slot: the leader fills `result`; followers wait on `cv`.
struct Flight {
    result: Mutex<Option<Result<Value, PollError>>>,
    cv: Condvar,
}

pub struct Poller {
    base: String,
    owner: String,
    repo: String,
    transport: Transport,
    cache: Mutex<HashMap<String, Cached>>,
    inflight: Mutex<HashMap<String, Arc<Flight>>>,
    requests: AtomicU64,
    not_modified: AtomicU64,
}

fn ureq_transport(token: String) -> Transport {
    Arc::new(move |url: &str, inm: Option<&str>| {
        let mut rq = ureq::get(url)
            .set("Authorization", &format!("Bearer {token}"))
            .set("Accept", "application/vnd.github+json")
            .set("User-Agent", "fwfd/0.1")
            .set("X-GitHub-Api-Version", "2022-11-28")
            .timeout(std::time::Duration::from_secs(30));
        if let Some(e) = inm {
            rq = rq.set("If-None-Match", e);
        }
        let r = match rq.call() {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => return Err(PollError::Transport(e.to_string())),
        };
        let status = r.status();
        let etag = r.header("ETag").map(str::to_string);
        let body = r
            .into_string()
            .map_err(|e| PollError::Transport(e.to_string()))?;
        Ok(Raw { status, etag, body })
    })
}

impl Poller {
    /// `base` is `https://api.github.com` or a fake's `base_url()`; `token`
    /// is sent as a bearer. `owner` doubles as the login whose issues count
    /// as OWNER-authored when the API omits `author_association`.
    pub fn new(base: &str, token: &str, owner: &str, repo: &str) -> Poller {
        Self::with_transport(base, owner, repo, ureq_transport(token.to_string()))
    }

    pub fn with_transport(base: &str, owner: &str, repo: &str, transport: Transport) -> Poller {
        Poller {
            base: base.trim_end_matches('/').to_string(),
            owner: owner.to_string(),
            repo: repo.to_string(),
            transport,
            cache: Mutex::new(HashMap::new()),
            inflight: Mutex::new(HashMap::new()),
            requests: AtomicU64::new(0),
            not_modified: AtomicU64::new(0),
        }
    }

    /// Requests actually sent to the transport (304s included).
    pub fn requests(&self) -> u64 {
        self.requests.load(Ordering::SeqCst)
    }

    /// How many of those came back 304 and were served from the cache.
    pub fn not_modified(&self) -> u64 {
        self.not_modified.load(Ordering::SeqCst)
    }

    fn url(&self, path: &str) -> String {
        format!("{}/repos/{}/{}/{path}", self.base, self.owner, self.repo)
    }

    /// GET one URL through the cache and the single-flight gate. `Ok(None)`
    /// is a 404 (a fact — "no such ref" — not a failure).
    pub fn get(&self, url: &str) -> Result<Option<Value>, PollError> {
        let flight = {
            let mut inflight = self.inflight.lock().expect("inflight");
            match inflight.get(url) {
                Some(f) => {
                    // Follower: wait for the leader's result.
                    let f = f.clone();
                    drop(inflight);
                    let mut slot = f.result.lock().expect("flight");
                    while slot.is_none() {
                        slot = f.cv.wait(slot).expect("flight");
                    }
                    return slot.clone().expect("filled").map(not_found_to_none);
                }
                None => {
                    let f = Arc::new(Flight {
                        result: Mutex::new(None),
                        cv: Condvar::new(),
                    });
                    inflight.insert(url.to_string(), f.clone());
                    f
                }
            }
        };
        let out = self.fetch(url);
        *flight.result.lock().expect("flight") = Some(out.clone());
        flight.cv.notify_all();
        self.inflight.lock().expect("inflight").remove(url);
        out.map(not_found_to_none)
    }

    fn fetch(&self, url: &str) -> Result<Value, PollError> {
        let cached = self.cache.lock().expect("cache").get(url).cloned();
        let inm = cached.as_ref().and_then(|c| c.etag.clone());
        self.requests.fetch_add(1, Ordering::SeqCst);
        let raw = (self.transport)(url, inm.as_deref())?;
        match raw.status {
            304 => {
                self.not_modified.fetch_add(1, Ordering::SeqCst);
                cached
                    .map(|c| c.body)
                    .ok_or_else(|| PollError::NotModifiedUncached(url.to_string()))
            }
            200..=299 => {
                let body: Value = if raw.body.trim().is_empty() {
                    Value::Null
                } else {
                    serde_json::from_str(&raw.body).map_err(|e| PollError::Malformed {
                        url: url.to_string(),
                        why: e.to_string(),
                    })?
                };
                self.cache.lock().expect("cache").insert(
                    url.to_string(),
                    Cached {
                        etag: raw.etag,
                        body: body.clone(),
                    },
                );
                Ok(body)
            }
            404 => Ok(NOT_FOUND.clone()),
            code => Err(PollError::Status {
                url: url.to_string(),
                code,
            }),
        }
    }

    /// Read everything the scheduler needs. Any failure is `Err`; the caller
    /// holds `Snapshot::unknown()` (`poll(..).unwrap_or_else(|_| Snapshot::unknown())`).
    pub fn poll(&self, now: u64) -> Result<Snapshot, PollError> {
        let list_url = self.url("issues?state=open");
        let list = self.get(&list_url)?.ok_or_else(|| PollError::Status {
            url: list_url.clone(),
            code: 404,
        })?;
        let items = list.as_array().ok_or_else(|| PollError::Malformed {
            url: list_url.clone(),
            why: "expected an array".into(),
        })?;
        let mut issues = Vec::new();
        let mut prs = Vec::new();
        for it in items {
            let number = it["number"].as_u64().ok_or_else(|| PollError::Malformed {
                url: list_url.clone(),
                why: "item without number".into(),
            })?;
            if it.get("pull_request").is_some_and(|p| !p.is_null()) {
                prs.push(self.pr_view(number)?);
                continue;
            }
            let login = it["user"]["login"].as_str().unwrap_or("");
            let author_association = it["author_association"]
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| {
                    if login == self.owner {
                        "OWNER".into()
                    } else {
                        "NONE".into()
                    }
                });
            let labels = names(&it["labels"], "name");
            let claim = if labels.iter().any(|l| l == CLAIM_LABEL) {
                self.get(&self.url(&format!("git/ref/{CLAIM_REF_PREFIX}/{number}")))?
                    .and_then(|r| r["object"]["sha"].as_str().map(|s| Fence(s.to_string())))
            } else {
                None
            };
            issues.push(IssueView {
                number,
                title: it["title"].as_str().unwrap_or("").to_string(),
                author_association,
                labels,
                assignees: names(&it["assignees"], "login"),
                state: it["state"].as_str().unwrap_or("").to_string(),
                updated_at: it["updated_at"].as_str().unwrap_or("").to_string(),
                claim,
            });
        }
        issues.sort_by_key(|i| i.number);
        prs.sort_by_key(|p| p.number);
        Ok(Snapshot {
            issues,
            prs,
            fetched_at: now,
            known: true,
        })
    }

    fn pr_view(&self, number: u64) -> Result<PrView, PollError> {
        let pr_url = self.url(&format!("pulls/{number}"));
        let pr = self.get(&pr_url)?.ok_or(PollError::Status {
            url: pr_url.clone(),
            code: 404,
        })?;
        let rv_url = self.url(&format!("pulls/{number}/reviews"));
        let reviews = self.get(&rv_url)?.ok_or(PollError::Status {
            url: rv_url.clone(),
            code: 404,
        })?;
        let reviews = reviews
            .as_array()
            .ok_or_else(|| PollError::Malformed {
                url: rv_url.clone(),
                why: "expected an array".into(),
            })?
            .iter()
            .map(|r| {
                (
                    r["user"]["login"].as_str().unwrap_or("").to_string(),
                    r["state"].as_str().unwrap_or("").to_string(),
                    r["commit_id"].as_str().unwrap_or("").to_string(),
                )
            })
            .collect();
        Ok(PrView {
            number,
            head_sha: pr["head"]["sha"].as_str().unwrap_or("").to_string(),
            head_ref: pr["head"]["ref"].as_str().unwrap_or("").to_string(),
            base_ref: pr["base"]["ref"].as_str().unwrap_or("").to_string(),
            draft: pr["draft"].as_bool().unwrap_or(false),
            state: pr["state"].as_str().unwrap_or("").to_string(),
            closes_issue: closes_issue(pr["body"].as_str().unwrap_or("")),
            reviews,
        })
    }
}

/// Sentinel body for a 404 inside the single-flight slot.
static NOT_FOUND: std::sync::LazyLock<Value> =
    std::sync::LazyLock::new(|| serde_json::json!({ "__fwfd_not_found": true }));

fn not_found_to_none(v: Value) -> Option<Value> {
    if v == *NOT_FOUND {
        None
    } else {
        Some(v)
    }
}

fn names(arr: &Value, key: &str) -> Vec<String> {
    arr.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v[key].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// The first `closes|fixes|resolves #N` (GitHub's keyword set, any case).
pub fn closes_issue(body: &str) -> Option<u64> {
    const KW: [&str; 9] = [
        "close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved",
    ];
    let words: Vec<&str> = body.split_whitespace().collect();
    for w in words.windows(2) {
        let kw = w[0]
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_ascii_lowercase();
        if !KW.contains(&kw.as_str()) {
            continue;
        }
        let digits: String = w[1]
            .trim_start_matches('#')
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if w[1].starts_with('#') && !digits.is_empty() {
            return digits.parse().ok();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_github::FakeGitHub;
    use serde_json::json;
    use std::sync::Barrier;

    const O: &str = "tbaums";
    const R: &str = "scratch";

    #[test]
    fn closes_issue_parses_github_keywords() {
        assert_eq!(closes_issue("Closes #12"), Some(12));
        assert_eq!(closes_issue("this PR\n\nfixes #7."), Some(7));
        assert_eq!(closes_issue("Resolves: #3"), Some(3));
        assert_eq!(closes_issue("see #9"), None);
        assert_eq!(closes_issue("closes 9"), None);
        assert_eq!(closes_issue(""), None);
    }

    #[test]
    fn etag_second_poll_is_all_304s_and_bodies_are_reused() {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let tok = fake.token("fwf-ops[bot]", &[]);
        fake.seed_issue(O, R, "a", O, &[]);
        let p = Poller::new(fake.base_url(), &tok, O, R);
        let s1 = p.poll(10).unwrap();
        assert_eq!(p.requests(), 1);
        let s2 = p.poll(11).unwrap();
        assert_eq!(p.requests(), 2);
        assert_eq!(p.not_modified(), 1);
        assert_eq!(s1.issues, s2.issues);
        assert_eq!(s2.fetched_at, 11);
        assert_eq!(s2.issues[0].author_association, "OWNER");
        assert_eq!(
            fake.request_count(&format!("/repos/{O}/{R}/issues?state=open")),
            2
        );
    }

    #[test]
    fn read_failure_is_typed_and_unknown_not_partial() {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        fake.seed_issue(O, R, "a", O, &[]);
        let p = Poller::new(fake.base_url(), "not-a-token", O, R);
        let err = p.poll(1).unwrap_err();
        assert!(matches!(err, PollError::Status { code: 401, .. }), "{err}");
        let s = p.poll(1).unwrap_or_else(|_| Snapshot::unknown());
        assert!(!s.known);
        assert!(s.issues.is_empty());
        // connection refused → Transport
        let dead = Poller::new("http://127.0.0.1:1", "t", O, R);
        assert!(matches!(dead.poll(1), Err(PollError::Transport(_))));
    }

    #[test]
    fn pr_view_reads_head_reviews_and_claim_fence() {
        let fake = FakeGitHub::start();
        let alice = fake.token("alice", &[]);
        let ops = fake.token("fwf-ops[bot]", &[]);
        fake.seed_ref(O, R, "heads/main", &FakeGitHub::sha("m"));
        fake.seed_ref(O, R, "heads/feat", &FakeGitHub::sha("f"));
        let n = fake.seed_issue(O, R, "claimed one", O, &[CLAIM_LABEL]);
        fake.seed_ref(
            O,
            R,
            &format!("{CLAIM_REF_PREFIX}/{n}"),
            &FakeGitHub::sha("claim"),
        );
        let r = ureq::post(&format!("{}/repos/{O}/{R}/pulls", fake.base_url()))
            .set("Authorization", &format!("Bearer {alice}"))
            .send_string(
                &json!({"title":"t","head":"feat","base":"main","body":format!("Closes #{n}")})
                    .to_string(),
            )
            .unwrap();
        let pr = r.into_json::<Value>().unwrap()["number"].as_u64().unwrap();
        ureq::post(&format!(
            "{}/repos/{O}/{R}/pulls/{pr}/reviews",
            fake.base_url()
        ))
        .set("Authorization", &format!("Bearer {ops}"))
        .send_string(&json!({"event":"APPROVE"}).to_string())
        .unwrap();
        let p = Poller::new(fake.base_url(), &ops, O, R);
        let s = p.poll(5).unwrap();
        assert_eq!(s.issues.len(), 1);
        assert_eq!(s.issues[0].claim, Some(Fence(FakeGitHub::sha("claim"))));
        assert_eq!(s.prs.len(), 1);
        let v = &s.prs[0];
        assert_eq!(v.number, pr);
        assert_eq!(v.head_sha, FakeGitHub::sha("f"));
        assert_eq!((v.head_ref.as_str(), v.base_ref.as_str()), ("feat", "main"));
        assert_eq!(v.closes_issue, Some(n));
        assert!(!v.draft);
        assert_eq!(
            v.reviews,
            vec![(
                "fwf-ops[bot]".to_string(),
                "APPROVED".to_string(),
                FakeGitHub::sha("f")
            )]
        );
        // list + pull + reviews + claim ref = 4 requests
        assert_eq!(p.requests(), 4);
    }

    #[test]
    fn single_flight_two_concurrent_gets_make_one_request() {
        let calls = Arc::new(AtomicU64::new(0));
        let gate = Arc::new(Barrier::new(2)); // transport waits for the follower to arrive
        let (c, g) = (calls.clone(), gate.clone());
        let transport: Transport = Arc::new(move |_url, _inm| {
            c.fetch_add(1, Ordering::SeqCst);
            g.wait();
            Ok(Raw {
                status: 200,
                etag: Some("\"e\"".into()),
                body: "[1]".into(),
            })
        });
        let p = Arc::new(Poller::with_transport("http://x", O, R, transport));
        let url = p.url("issues?state=open");
        let leader = {
            let (p, url) = (p.clone(), url.clone());
            std::thread::spawn(move || p.get(&url).unwrap())
        };
        // The follower: spin until the leader has registered its flight,
        // then join it; only then release the transport via the barrier.
        while p.inflight.lock().unwrap().is_empty() {
            std::thread::yield_now();
        }
        let follower = {
            let (p, url) = (p.clone(), url.clone());
            std::thread::spawn(move || p.get(&url).unwrap())
        };
        while Arc::strong_count(&p.inflight.lock().unwrap()[&url]) < 3 {
            std::thread::yield_now();
        }
        gate.wait();
        assert_eq!(leader.join().unwrap(), Some(json!([1])));
        assert_eq!(follower.join().unwrap(), Some(json!([1])));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(p.requests(), 1);
        assert!(p.inflight.lock().unwrap().is_empty());
    }
}
