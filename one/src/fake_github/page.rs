//! Paging, as GitHub pages its list endpoints (#723). `GET issues` and
//! `GET pulls/{n}/reviews` take `per_page` (default 30, max 100) and `page`
//! (default 1), and a response with more items after it carries
//! `Link: <…&page=N+1>; rel="next"`. Before this the fake returned every item
//! in one body, so no test could see a client that read only page 1. Split
//! out of `fake_github.rs`, which is held at its size baseline (T-30).

use super::{split_url, Req, Resp};
use serde_json::Value;
use std::collections::BTreeMap;

/// GitHub's `per_page` when the request names none.
pub(super) const DEFAULT_PER_PAGE: usize = 30;
/// GitHub's `per_page` ceiling; a larger value is served as this.
pub(super) const MAX_PER_PAGE: usize = 100;

/// One page of `items` (already in the order GitHub lists them), sized and
/// positioned by the request's `per_page` and `page`. A missing, zero or
/// unparseable value gets GitHub's default.
pub(super) fn page(req: &Req, items: Vec<Value>) -> Resp {
    let param = |k: &str, default: usize| {
        req.query
            .get(k)
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(default)
    };
    let per_page = param("per_page", DEFAULT_PER_PAGE).min(MAX_PER_PAGE);
    let page = param("page", 1);
    let start = (page - 1).saturating_mul(per_page);
    let more = items.len() > start.saturating_add(per_page);
    let body: Vec<Value> = items.into_iter().skip(start).take(per_page).collect();
    let mut resp = Resp::ok(Value::Array(body));
    if more {
        let mut q = req.query.clone();
        q.insert("page".into(), (page + 1).to_string());
        let host = req.header("Host").unwrap_or("127.0.0.1");
        let next = format!("http://{host}{}", count_key(&req.path, &q));
        resp.headers
            .push(("Link".into(), format!("<{next}>; rel=\"next\"")));
    }
    resp
}

/// The request counter's key: the path, then the query in sorted order. The
/// caller's `?state=open&per_page=100&page=1` and the server's parsed query
/// therefore count as one URL.
pub(super) fn count_key(path: &str, query: &BTreeMap<String, String>) -> String {
    if query.is_empty() {
        return path.to_string();
    }
    let q: Vec<String> = query.iter().map(|(k, v)| format!("{k}={v}")).collect();
    format!("{path}?{}", q.join("&"))
}

/// [`count_key`] for a `path?query` string as a test writes it.
pub(super) fn count_key_of(path_and_query: &str) -> String {
    let (path, query) = split_url(path_and_query);
    count_key(&path, &query)
}

#[cfg(test)]
mod tests {
    use super::super::FakeGitHub;
    use serde_json::{json, Value};

    const O: &str = "tbaums";
    const R: &str = "scratch";

    /// (status, body, Link header) for a GET with a bearer.
    fn get(fake: &FakeGitHub, tok: &str, path_and_query: &str) -> (u16, Value, Option<String>) {
        let mut r = crate::github::http_agent(None)
            .get(format!("{}{path_and_query}", fake.base_url()))
            .header("Authorization", format!("Bearer {tok}"))
            .call()
            .expect("transport");
        let link = crate::github::header(&r, "Link");
        let status = r.status().as_u16();
        let body = serde_json::from_str(&crate::github::body_text(&mut r)).unwrap_or(Value::Null);
        (status, body, link)
    }

    fn numbers(body: &Value) -> Vec<u64> {
        body.as_array()
            .expect("array")
            .iter()
            .map(|i| i["number"].as_u64().expect("number"))
            .collect()
    }

    /// AC2: no params is GitHub's default page — the 30 newest, newest first,
    /// with `rel="next"`; `per_page=100&page=2` is what remains after 100.
    #[test]
    fn issues_page_like_github() {
        let fake = FakeGitHub::start();
        let tok = fake.token("fwf-ops[bot]", &[]);
        for i in 0..135 {
            fake.seed_issue(O, R, &format!("i{i}"), O, &[]);
        }
        let list = format!("/repos/{O}/{R}/issues?state=open");
        let (status, body, link) = get(&fake, &tok, &list);
        assert_eq!(status, 200);
        assert_eq!(numbers(&body), (106..=135).rev().collect::<Vec<u64>>());
        let link = link.expect("a Link header while more remain");
        assert!(link.ends_with("; rel=\"next\""), "{link}");
        assert!(
            link.starts_with(&format!("<{}/repos/{O}/{R}/issues?", fake.base_url())),
            "{link}"
        );
        assert!(
            link.contains("page=2") && link.contains("state=open"),
            "{link}"
        );

        let (status, body, link) = get(&fake, &tok, &format!("{list}&per_page=100&page=2"));
        assert_eq!(status, 200);
        assert_eq!(numbers(&body), (1..=35).rev().collect::<Vec<u64>>());
        assert_eq!(link, None, "the last page has no rel=\"next\"");

        // per_page is capped at 100, and a page past the end is empty.
        let (_, body, _) = get(&fake, &tok, &format!("{list}&per_page=500"));
        assert_eq!(numbers(&body).len(), 100);
        let (_, body, link) = get(&fake, &tok, &format!("{list}&per_page=100&page=3"));
        assert_eq!((numbers(&body), link), (vec![], None));
    }

    #[test]
    fn reviews_page_oldest_first() {
        let fake = FakeGitHub::start();
        let alice = fake.token("alice", &[]);
        let ops = fake.token("fwf-ops[bot]", &[]);
        fake.seed_ref(O, R, "heads/main", &FakeGitHub::sha("m"));
        fake.seed_ref(O, R, "heads/feat", &FakeGitHub::sha("f"));
        let pr = crate::github::http_agent(None)
            .post(format!("{}/repos/{O}/{R}/pulls", fake.base_url()))
            .header("Authorization", format!("Bearer {alice}"))
            .send(json!({"title":"t","head":"feat","base":"main"}).to_string())
            .expect("open pr")
            .body_mut()
            .read_json::<Value>()
            .expect("json")["number"]
            .as_u64()
            .expect("number");
        let reviews = format!("/repos/{O}/{R}/pulls/{pr}/reviews");
        for i in 0..31 {
            crate::github::http_agent(None)
                .post(format!("{}{reviews}", fake.base_url()))
                .header("Authorization", format!("Bearer {ops}"))
                .send(json!({"event":"COMMENT","body":format!("r{i}")}).to_string())
                .expect("review");
        }
        let (_, body, link) = get(&fake, &ops, &reviews);
        assert_eq!(body.as_array().expect("array").len(), 30);
        assert_eq!(body[0]["body"], "r0");
        assert!(link.is_some_and(|l| l.contains("page=2")));
        let (_, body, link) = get(&fake, &ops, &format!("{reviews}?page=2"));
        assert_eq!(body.as_array().expect("array").len(), 1);
        assert_eq!(body[0]["body"], "r30");
        assert_eq!(link, None);
    }

    #[test]
    fn request_count_matches_whatever_order_the_query_is_written_in() {
        let fake = FakeGitHub::start();
        let tok = fake.token("fwf-ops[bot]", &[]);
        fake.seed_issue(O, R, "a", O, &[]);
        get(
            &fake,
            &tok,
            &format!("/repos/{O}/{R}/issues?state=open&per_page=100&page=1"),
        );
        for q in [
            "state=open&per_page=100&page=1",
            "page=1&per_page=100&state=open",
        ] {
            assert_eq!(fake.request_count(&format!("/repos/{O}/{R}/issues?{q}")), 1);
        }
        assert_eq!(
            fake.request_count(&format!("/repos/{O}/{R}/issues?state=open")),
            0
        );
    }
}
