//! T-21: promotion by literal SHA. `staging → main` (or any `from → to`)
//! moves `to` to exactly the sha the gate went Green for, and only when
//! `to` is an ancestor of `from` — never a force, never a merge commit,
//! never "whatever the branch points at now".
//!
//! Order of checks, each a typed refusal recorded as `Kind::Refused`:
//! 1. both refs resolve (`GET git/ref/heads/{b}`);
//! 2. `GET compare/{to}...{from}` is `ahead` with `behind_by == 0`
//!    (`identical` is a no-op; `behind`/`diverged` refuse);
//! 3. `gate.promotable(&from_sha, suite)` — Green for exactly that sha+suite;
//! 4. `PATCH git/refs/heads/{to} {sha: from_sha, force: false}` under a CAS
//!    on the sha read in step 1.
//!
//! The CAS: against the fake the header `X-Fake-Expect-Sha` carries the
//! expected current sha (README "Ref CAS"). The real API has no such
//! header — `force: false` only guarantees fast-forward, not "nobody moved
//! it since I looked". Against real GitHub the supervisor promotes through
//! the mirror (`mirror::sync_branch`, `git push --force-with-lease=<to>:<sha>`)
//! or re-reads the ref after the PATCH and treats any sha other than
//! `from_sha` as `LeaseLost`. This function does the re-read on every path,
//! so the header is an optimisation for the fake, not the guarantee.

use crate::log::{Kind, Log};
use crate::merge::{record, Client, HttpError, MergeError, Reply};
use crate::types::{GateState, Refusal, Sha};
use serde_json::{json, Value};
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PromoteError {
    /// The gate is not Green for exactly this sha and suite (or Unknown).
    Refused(Refusal),
    /// `to` is not an ancestor of `from`. Nothing moved.
    NotFastForward {
        status: String,
        ahead_by: u64,
        behind_by: u64,
    },
    /// `to` moved between our read and our write. Nothing moved (by us).
    LeaseLost {
        branch: String,
        expected: Sha,
        actual: Option<Sha>,
    },
    /// A branch does not exist.
    RefMissing(String),
    Http(HttpError),
    Api {
        what: String,
        status: u16,
        body: String,
    },
    Malformed {
        what: String,
        why: String,
    },
}

impl From<Refusal> for PromoteError {
    fn from(r: Refusal) -> PromoteError {
        PromoteError::Refused(r)
    }
}
impl From<HttpError> for PromoteError {
    fn from(e: HttpError) -> PromoteError {
        PromoteError::Http(e)
    }
}
impl From<MergeError> for PromoteError {
    fn from(e: MergeError) -> PromoteError {
        match e {
            MergeError::Refused(r) => PromoteError::Refused(r),
            MergeError::Http(h) => PromoteError::Http(h),
            MergeError::Api { what, status, body } => PromoteError::Api { what, status, body },
            MergeError::Malformed { what, why } => PromoteError::Malformed { what, why },
        }
    }
}

impl fmt::Display for PromoteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PromoteError::Refused(r) => write!(f, "refused: {r}"),
            PromoteError::NotFastForward {
                status,
                ahead_by,
                behind_by,
            } => write!(
                f,
                "not a fast-forward: compare is {status} (ahead {ahead_by}, behind {behind_by}); never forced"
            ),
            PromoteError::LeaseLost {
                branch,
                expected,
                actual,
            } => write!(
                f,
                "lease lost on {branch}: expected {} but it is now {}",
                expected.short(),
                actual.as_ref().map(|s| s.short().to_string()).unwrap_or("gone".into())
            ),
            PromoteError::RefMissing(b) => write!(f, "branch {b} does not exist"),
            PromoteError::Http(e) => write!(f, "{e}"),
            PromoteError::Api { what, status, body } => {
                write!(f, "{what}: HTTP {status}: {body}")
            }
            PromoteError::Malformed { what, why } => {
                write!(f, "{what}: malformed response: {why}")
            }
        }
    }
}

fn ok(what: &str, r: Reply) -> Result<Value, PromoteError> {
    if r.ok() {
        Ok(r.body)
    } else {
        Err(PromoteError::Api {
            what: what.to_string(),
            status: r.status,
            body: r.excerpt(),
        })
    }
}

/// `GET git/ref/heads/{branch}` → sha; 404 → `RefMissing`.
fn branch_sha(client: &Client, repo: &str, branch: &str) -> Result<Sha, PromoteError> {
    let what = format!("GET git/ref/heads/{branch}");
    let r = client.get(&format!("/repos/{repo}/git/ref/heads/{branch}"))?;
    if r.status == 404 {
        return Err(PromoteError::RefMissing(branch.to_string()));
    }
    let v = ok(&what, r)?;
    let s = v["object"]["sha"]
        .as_str()
        .ok_or_else(|| PromoteError::Malformed {
            what: what.clone(),
            why: "missing object.sha".into(),
        })?;
    Sha::parse(s).map_err(|e| PromoteError::Malformed {
        what,
        why: e.to_string(),
    })
}

/// Move `to_branch` to the sha `from_branch` points at, iff `to` is an
/// ancestor of `from` and the gate is Green for that sha under `suite`.
/// Returns the sha `to` now points at.
pub fn promote(
    client: &Client,
    repo: &str,
    from_branch: &str,
    to_branch: &str,
    gate: &GateState,
    suite: &str,
    log: &mut Log,
) -> Result<Sha, PromoteError> {
    let what = format!("promote {to_branch} ← {from_branch}");
    match promote_inner(client, repo, from_branch, to_branch, gate, suite, log) {
        Ok(sha) => Ok(sha),
        Err(e) => {
            record(
                log,
                repo,
                Kind::Refused {
                    what,
                    why: e.to_string(),
                },
            );
            Err(e)
        }
    }
}

fn promote_inner(
    client: &Client,
    repo: &str,
    from_branch: &str,
    to_branch: &str,
    gate: &GateState,
    suite: &str,
    log: &mut Log,
) -> Result<Sha, PromoteError> {
    // 1. both refs
    let from_sha = branch_sha(client, repo, from_branch)?;
    let to_sha = branch_sha(client, repo, to_branch)?;

    // 2. fast-forward only
    let what = format!("GET compare/{}...{}", to_sha.short(), from_sha.short());
    let cmp = ok(
        &what,
        client.get(&format!("/repos/{repo}/compare/{to_sha}...{from_sha}"))?,
    )?;
    let status = cmp["status"].as_str().unwrap_or("").to_string();
    let ahead_by = cmp["ahead_by"].as_u64().unwrap_or(0);
    let behind_by = cmp["behind_by"].as_u64().unwrap_or(u64::MAX);
    if status.is_empty() {
        return Err(PromoteError::Malformed {
            what,
            why: "missing status".into(),
        });
    }
    // 3. the gate — checked even for a no-op, so a Red sha is never "fine"
    gate.promotable(&from_sha, suite)?;
    if status == "identical" && from_sha == to_sha {
        record(
            log,
            repo,
            Kind::Note {
                text: format!(
                    "promote {to_branch}: already at {} ({from_branch}); nothing to move",
                    from_sha.short()
                ),
            },
        );
        return Ok(from_sha);
    }
    if status != "ahead" || behind_by != 0 {
        return Err(PromoteError::NotFastForward {
            status,
            ahead_by,
            behind_by,
        });
    }

    // 4. the write, under CAS on the sha we read
    let r = client.send(
        "PATCH",
        &format!("/repos/{repo}/git/refs/heads/{to_branch}"),
        &json!({ "sha": from_sha.as_str(), "force": false }),
        &[("X-Fake-Expect-Sha", to_sha.as_str())],
    )?;
    let lost = |actual: Option<Sha>| PromoteError::LeaseLost {
        branch: to_branch.to_string(),
        expected: to_sha.clone(),
        actual,
    };
    if r.status == 422 || r.status == 409 {
        let actual = branch_sha(client, repo, to_branch).ok();
        return Err(lost(actual));
    }
    ok(&format!("PATCH git/refs/heads/{to_branch}"), r)?;
    // Re-read: the real API has no CAS header, so the write is only proven
    // by the ref now being exactly from_sha.
    let now = branch_sha(client, repo, to_branch)?;
    if now != from_sha {
        return Err(lost(Some(now)));
    }
    record(
        log,
        repo,
        Kind::Promote {
            branch: to_branch.to_string(),
            from: to_sha.to_string(),
            to: from_sha.to_string(),
        },
    );
    Ok(from_sha)
}

/// Does a release object for `tag` exist with at least one asset? Used by
/// T-22 to decide whether a cut actually published (a tag is not a release;
/// a release with no assets is not shipped). Any failure to read is `false`.
pub fn release_check(client: &Client, repo: &str, tag: &str) -> bool {
    let Ok(r) = client.get(&format!("/repos/{repo}/releases/tags/{tag}")) else {
        return false;
    };
    if !r.ok() {
        return false;
    }
    r.body["assets"]
        .as_array()
        .map(|a| !a.is_empty())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_github::FakeGitHub;
    use crate::log::{read_all, Event};
    use crate::merge::shim::Shim;
    use std::path::PathBuf;

    const O: &str = "tbaums";
    const R: &str = "scratch";
    const REPO: &str = "tbaums/scratch";

    /// Graph: A ← B ← C (staging), D ← A (a diverged main when asked).
    struct Rig {
        fake: FakeGitHub,
        shim: Shim,
        client: Client,
        a: String,
        c: String,
        d: String,
        log: Log,
        log_path: PathBuf,
    }

    fn rig(name: &str) -> Rig {
        let fake = FakeGitHub::start();
        fake.add_repo(O, R);
        let shim = Shim::start(&fake);
        let tok = fake.token("fwf-ops[bot]", &[]);
        let (a, b, c, d) = (
            FakeGitHub::sha("A"),
            FakeGitHub::sha("B"),
            FakeGitHub::sha("C"),
            FakeGitHub::sha("D"),
        );
        shim.add_commit(&a, &[]);
        shim.add_commit(&b, &[&a]);
        shim.add_commit(&c, &[&b]);
        shim.add_commit(&d, &[&a]);
        fake.seed_ref(O, R, "heads/staging", &c);
        fake.seed_ref(O, R, "heads/main", &a);
        let dir = std::env::temp_dir().join(format!("fwfd-promote-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let log_path = dir.join("run.jsonl");
        let log = Log::open(&log_path).unwrap();
        Rig {
            client: Client::new(shim.base_url(), &tok),
            fake,
            shim,
            a,
            c,
            d,
            log,
            log_path,
        }
    }

    impl Rig {
        fn green(&self) -> GateState {
            GateState::Green {
                sha: Sha::parse(&self.c).unwrap(),
                suite: "e2e".into(),
                secs: 42,
            }
        }
        fn go(&mut self, gate: &GateState, suite: &str) -> Result<Sha, PromoteError> {
            promote(
                &self.client,
                REPO,
                "staging",
                "main",
                gate,
                suite,
                &mut self.log,
            )
        }
        fn main_sha(&self) -> String {
            self.fake.ref_sha(O, R, "heads/main").unwrap()
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
        fn patches(&self) -> usize {
            self.fake
                .writes()
                .iter()
                .filter(|w| w.method == "PATCH" && w.path.ends_with("/git/refs/heads/main"))
                .count()
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
    fn fast_forward_moves_main_to_the_literal_green_sha_and_records() {
        let mut g = rig("ff");
        let sha = g.go(&g.green(), "e2e").unwrap();
        assert_eq!(sha.as_str(), g.c);
        assert_eq!(g.main_sha(), g.c);
        assert_eq!(g.patches(), 1);
        let w = g
            .fake
            .writes()
            .into_iter()
            .find(|w| w.method == "PATCH")
            .unwrap();
        assert_eq!(w.actor, "fwf-ops[bot]");
        assert_eq!(w.body["sha"], g.c.as_str());
        assert_eq!(w.body["force"], false);
        let evs = g.events();
        assert!(evs.iter().any(|e| matches!(&e.kind,
            Kind::Promote { branch, from, to } if branch == "main" && *from == g.a && *to == g.c)));
        assert!(g.refusals().is_empty());
        // idempotent: a second promote is a recorded no-op, not a write
        let again = g.go(&g.green(), "e2e").unwrap();
        assert_eq!(again.as_str(), g.c);
        assert_eq!(g.patches(), 1);
        assert!(g
            .events()
            .iter()
            .any(|e| matches!(&e.kind, Kind::Note { text } if text.contains("already at"))));
    }

    #[test]
    fn diverged_is_refused_and_never_forced() {
        let mut g = rig("diverged");
        g.fake.seed_ref(O, R, "heads/main", &g.d);
        let e = g.go(&g.green(), "e2e").unwrap_err();
        assert!(
            matches!(e, PromoteError::NotFastForward { ref status, behind_by: 1, .. } if status == "diverged"),
            "{e}"
        );
        assert_eq!(g.main_sha(), g.d);
        assert_eq!(g.patches(), 0);
        assert!(g.refusals()[0].starts_with("promote main ← staging: not a fast-forward"));
    }

    #[test]
    fn behind_is_refused() {
        // main is ahead of staging: promoting would rewind it
        let mut g = rig("behind");
        g.fake.seed_ref(O, R, "heads/main", &g.c);
        g.fake.seed_ref(O, R, "heads/staging", &g.a);
        let gate = GateState::Green {
            sha: Sha::parse(&g.a).unwrap(),
            suite: "e2e".into(),
            secs: 1,
        };
        let e = g.go(&gate, "e2e").unwrap_err();
        assert!(
            matches!(e, PromoteError::NotFastForward { ref status, .. } if status == "behind"),
            "{e}"
        );
        assert_eq!(g.main_sha(), g.c);
        assert_eq!(g.patches(), 0);
    }

    #[test]
    fn gate_red_killed_unknown_and_wrong_sha_are_refused() {
        let mut g = rig("gate");
        let c = Sha::parse(&g.c).unwrap();
        let red = GateState::Red {
            sha: c.clone(),
            suite: "e2e".into(),
            failed: 3,
        };
        let killed = GateState::Killed {
            sha: c.clone(),
            suite: "e2e".into(),
            reason: "oom".into(),
        };
        let other = GateState::Green {
            sha: Sha::parse(&g.a).unwrap(),
            suite: "e2e".into(),
            secs: 1,
        };
        for gate in [&red, &killed, &other] {
            let e = g.go(gate, "e2e").unwrap_err();
            assert!(
                matches!(e, PromoteError::Refused(Refusal::GateNotGreen { ref sha }) if *sha == c),
                "{e}"
            );
        }
        let e = g.go(&GateState::Unknown, "e2e").unwrap_err();
        assert!(
            matches!(e, PromoteError::Refused(Refusal::UnknownState("gate"))),
            "{e}"
        );
        assert_eq!(g.main_sha(), g.a);
        assert_eq!(g.patches(), 0);
        assert_eq!(g.refusals().len(), 4);
    }

    #[test]
    fn wrong_suite_is_refused() {
        let mut g = rig("suite");
        let e = g.go(&g.green(), "fast").unwrap_err();
        assert!(
            matches!(e, PromoteError::Refused(Refusal::GateNotGreen { .. })),
            "{e}"
        );
        assert_eq!(g.main_sha(), g.a);
        assert_eq!(g.patches(), 0);
    }

    #[test]
    fn cas_lost_when_someone_moves_main_between_read_and_write() {
        let mut g = rig("cas");
        // another actor advances main to B (still an ancestor of C, so the
        // compare passes) after we read it and before our PATCH lands
        let b = FakeGitHub::sha("B");
        g.shim.move_ref_before_patch("heads/main", &b);
        let e = g.go(&g.green(), "e2e").unwrap_err();
        match e {
            PromoteError::LeaseLost {
                branch,
                expected,
                actual,
            } => {
                assert_eq!(branch, "main");
                assert_eq!(expected.as_str(), g.a);
                assert_eq!(actual.unwrap().as_str(), b);
            }
            other => panic!("{other}"),
        }
        // main is where the other actor left it; our sha never landed
        assert_eq!(g.main_sha(), b);
        assert!(g.refusals()[0].contains("lease lost on main"));
        assert!(!g
            .events()
            .iter()
            .any(|e| matches!(e.kind, Kind::Promote { .. })));
    }

    #[test]
    fn missing_branch_is_a_typed_error() {
        let mut g = rig("missing");
        let e = promote(
            &g.client,
            REPO,
            "nope",
            "main",
            &g.green(),
            "e2e",
            &mut g.log,
        )
        .unwrap_err();
        assert!(
            matches!(e, PromoteError::RefMissing(ref b) if b == "nope"),
            "{e}"
        );
        assert_eq!(g.patches(), 0);
    }

    #[test]
    fn release_check_needs_a_release_with_an_asset() {
        let g = rig("release");
        assert!(!release_check(&g.client, REPO, "v1.0.0"), "404 is false");
        g.shim.add_release("v1.0.0", &[]);
        assert!(
            !release_check(&g.client, REPO, "v1.0.0"),
            "no assets is false"
        );
        g.shim.add_release("v1.0.1", &["fwf-darwin-arm64.tar.gz"]);
        assert!(release_check(&g.client, REPO, "v1.0.1"));
        let dead = Client::new("http://127.0.0.1:9", "x");
        assert!(
            !release_check(&dead, REPO, "v1.0.1"),
            "transport failure is false"
        );
    }
}
