//! The local bare mirror (T-11).
//!
//! Seats never hold a GitHub write token. Their worktree's only remote is a
//! `file://` URL to `<dir>/mirror.git`; they push branches there. The
//! supervisor is the only party that pushes from the mirror to upstream, and
//! it does so with `--force-with-lease` against a SHA it read first (a true
//! compare-and-swap; expect-empty for new branches and for `refs/claims/<n>`).
//! Protected branches (`staging`, `main`) are refused here outright —
//! promotion is a different code path.
//!
//! Everything is driven through the `git` binary via `std::process::Command`.
//! The token is put into the push URL at call time and scrubbed from every
//! captured line before it can reach an error value or a log.

use crate::types::{Fence, Sha};
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Branches only the promoter may move upstream.
pub const PROTECTED: [&str; 2] = ["staging", "main"];

const REMOTE: &str = "upstream";
const GIT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorError {
    /// git failed for a reason we understood (spawn error, non-zero exit
    /// with a message, bad ref name, missing object).
    Git(String),
    /// A sync to a protected branch was asked for.
    Protected(String),
    /// The upstream ref moved between the read and the push. Nothing moved.
    LeaseLost {
        branch: String,
        expected: String,
        actual: String,
    },
    /// `refs/claims/<n>` already existed upstream.
    ClaimTaken(u64),
    /// git's result could not be parsed. Treated as failure, never success.
    Unknown(String),
}

impl fmt::Display for MirrorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MirrorError::Git(s) => write!(f, "git: {s}"),
            MirrorError::Protected(b) => {
                write!(f, "{b} is protected; promotion is a separate path")
            }
            MirrorError::LeaseLost {
                branch,
                expected,
                actual,
            } => write!(
                f,
                "lease lost on {branch}: expected {expected}, upstream is {actual}"
            ),
            MirrorError::ClaimTaken(n) => write!(f, "refs/claims/{n} already exists upstream"),
            MirrorError::Unknown(s) => write!(f, "unparseable git result (failing closed): {s}"),
        }
    }
}

impl std::error::Error for MirrorError {}

#[derive(Clone, Debug)]
pub struct Mirror {
    /// `<dir>/mirror.git`
    git_dir: PathBuf,
    upstream: String,
}

/// Output of one git invocation, with the secret already scrubbed.
struct Out {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Out {
    fn ok(&self) -> bool {
        self.code == Some(0)
    }
    fn summary(&self) -> String {
        let s = format!("{}{}", self.stdout, self.stderr);
        let s = s.trim();
        if s.is_empty() {
            format!("exit {:?}", self.code)
        } else {
            s.to_string()
        }
    }
}

fn scrub(s: &str, secret: &str) -> String {
    if secret.is_empty() {
        s.to_string()
    } else {
        s.replace(secret, "***")
    }
}

/// Run git with a hard timeout; capture both streams; scrub `secret`.
fn run_git(dir: &Path, args: &[&str], secret: &str) -> Result<Out, MirrorError> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| MirrorError::Git(format!("spawn git: {e}")))?;
    let mut so = child.stdout.take().unwrap();
    let mut se = child.stderr.take().unwrap();
    let t_out = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = so.read_to_end(&mut b);
        b
    });
    let t_err = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = se.read_to_end(&mut b);
        b
    });
    let start = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st.code(),
            Ok(None) if start.elapsed() > GIT_TIMEOUT => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(MirrorError::Unknown(format!(
                    "git {} timed out after {:?}",
                    args.first().unwrap_or(&""),
                    GIT_TIMEOUT
                )));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => return Err(MirrorError::Git(format!("wait git: {e}"))),
        }
    };
    let stdout = String::from_utf8_lossy(&t_out.join().unwrap_or_default()).into_owned();
    let stderr = String::from_utf8_lossy(&t_err.join().unwrap_or_default()).into_owned();
    Ok(Out {
        code,
        stdout: scrub(&stdout, secret),
        stderr: scrub(&stderr, secret),
    })
}

/// Outcome of one lease-guarded push, before it is mapped to a typed error.
enum PushFail {
    /// `[rejected] (stale info)`: the lease did not hold.
    Stale,
    /// Rejected for another stated reason.
    Rejected(String),
    /// No parseable porcelain line for our ref.
    Unparseable(String),
}

impl Mirror {
    /// Create or open `<dir>/mirror.git`, point its `upstream` remote at
    /// `upstream_url`, and fetch so `refs/remotes/upstream/*` exist. The
    /// protected branches are also mirrored into `refs/heads/*` so a seat
    /// clone has a base to branch from; HEAD is `staging`. Idempotent.
    pub fn init(dir: &Path, upstream_url: &str) -> Result<Mirror, MirrorError> {
        let git_dir = dir.join("mirror.git");
        if !git_dir.join("HEAD").exists() {
            std::fs::create_dir_all(&git_dir)
                .map_err(|e| MirrorError::Git(format!("mkdir {}: {e}", git_dir.display())))?;
            let out = run_git(&git_dir, &["init", "--bare", "--quiet"], "")?;
            if !out.ok() {
                return Err(MirrorError::Git(format!("init --bare: {}", out.summary())));
            }
        }
        let m = Mirror {
            git_dir,
            upstream: upstream_url.to_string(),
        };
        let have = m.git(&["remote", "get-url", REMOTE])?;
        let out = if have.ok() {
            m.git(&["remote", "set-url", REMOTE, upstream_url])?
        } else {
            m.git(&["remote", "add", REMOTE, upstream_url])?
        };
        if !out.ok() {
            return Err(MirrorError::Git(format!(
                "remote {REMOTE}: {}",
                out.summary()
            )));
        }
        let out = m.git(&["symbolic-ref", "HEAD", "refs/heads/staging"])?;
        if !out.ok() {
            return Err(MirrorError::Git(format!(
                "symbolic-ref HEAD: {}",
                out.summary()
            )));
        }
        m.fetch()?;
        Ok(m)
    }

    /// Refresh `refs/remotes/upstream/*` (pruned) and the protected branches.
    /// Read-only against upstream; uses the recorded URL without a token.
    pub fn fetch(&self) -> Result<(), MirrorError> {
        let mut args = vec![
            "fetch",
            "--quiet",
            "--prune",
            REMOTE,
            "+refs/heads/*:refs/remotes/upstream/*",
        ];
        let protected: Vec<String> = PROTECTED
            .iter()
            .map(|b| format!("+refs/heads/{b}:refs/heads/{b}"))
            .collect();
        args.extend(protected.iter().map(String::as_str));
        let out = self.git(&args)?;
        if out.ok() {
            Ok(())
        } else {
            Err(MirrorError::Git(format!("fetch: {}", out.summary())))
        }
    }

    /// The only remote a seat worktree gets. Never the GitHub URL.
    pub fn seat_remote_url(&self) -> String {
        let abs = std::fs::canonicalize(&self.git_dir).unwrap_or_else(|_| self.git_dir.clone());
        format!("file://{}", abs.display())
    }

    pub fn git_dir(&self) -> &Path {
        &self.git_dir
    }

    /// `refs/heads/<branch>` in the mirror (what a seat pushed).
    pub fn branch_head(&self, branch: &str) -> Result<Option<Sha>, MirrorError> {
        self.read_ref(&format!("refs/heads/{branch}"))
    }

    /// `refs/remotes/upstream/<branch>` as of the last `fetch`/`sync_branch`.
    pub fn upstream_head(&self, branch: &str) -> Result<Option<Sha>, MirrorError> {
        self.read_ref(&format!("refs/remotes/upstream/{branch}"))
    }

    /// Push the mirror's `refs/heads/<branch>` to upstream under a lease on
    /// `expected_upstream_old` (None = the branch must not exist upstream).
    /// Returns the SHA now at upstream. Protected branches are refused.
    pub fn sync_branch(
        &self,
        branch: &str,
        expected_upstream_old: Option<&Sha>,
        token: &str,
    ) -> Result<Sha, MirrorError> {
        if PROTECTED.contains(&branch) {
            return Err(MirrorError::Protected(branch.to_string()));
        }
        self.check_branch_name(branch)?;
        let sha = self
            .branch_head(branch)?
            .ok_or_else(|| MirrorError::Git(format!("refs/heads/{branch} is not in the mirror")))?;
        let dst = format!("refs/heads/{branch}");
        let expect = expected_upstream_old.map(|s| s.as_str().to_string());
        match self.push_leased(token, &dst, expect.as_deref(), Some(&sha)) {
            Ok(()) => {
                let out = self.git(&[
                    "update-ref",
                    &format!("refs/remotes/upstream/{branch}"),
                    sha.as_str(),
                ])?;
                if !out.ok() {
                    return Err(MirrorError::Git(format!(
                        "update-ref after push: {}",
                        out.summary()
                    )));
                }
                Ok(sha)
            }
            Err(PushFail::Stale) => Err(MirrorError::LeaseLost {
                branch: branch.to_string(),
                expected: expect.unwrap_or_else(|| "<absent>".into()),
                actual: self.remote_ref(token, &dst),
            }),
            Err(PushFail::Rejected(why)) => Err(MirrorError::Git(format!("push {dst}: {why}"))),
            Err(PushFail::Unparseable(raw)) => Err(MirrorError::Unknown(raw)),
        }
    }

    /// Create `refs/claims/<issue>` upstream at `sha`, expect-empty. The
    /// fence is the ref's SHA.
    pub fn create_claim_ref(
        &self,
        issue: u64,
        sha: &Sha,
        token: &str,
    ) -> Result<Fence, MirrorError> {
        let dst = format!("refs/claims/{issue}");
        let have = self.git(&["cat-file", "-e", &format!("{}^{{commit}}", sha.as_str())])?;
        if !have.ok() {
            return Err(MirrorError::Git(format!(
                "{} is not a commit in the mirror",
                sha.short()
            )));
        }
        match self.push_leased(token, &dst, None, Some(sha)) {
            Ok(()) => Ok(Fence(sha.as_str().to_string())),
            Err(PushFail::Stale) => Err(MirrorError::ClaimTaken(issue)),
            Err(PushFail::Rejected(why)) => Err(MirrorError::Git(format!("push {dst}: {why}"))),
            Err(PushFail::Unparseable(raw)) => Err(MirrorError::Unknown(raw)),
        }
    }

    /// Delete `refs/claims/<issue>` upstream only if it still equals `fence`.
    pub fn release_claim_ref(
        &self,
        issue: u64,
        fence: &Fence,
        token: &str,
    ) -> Result<(), MirrorError> {
        let dst = format!("refs/claims/{issue}");
        let expected = Sha::parse(&fence.0).map_err(|e| MirrorError::Git(format!("fence: {e}")))?;
        match self.push_leased(token, &dst, Some(expected.as_str()), None) {
            Ok(()) => Ok(()),
            Err(PushFail::Stale) => Err(MirrorError::LeaseLost {
                branch: dst.clone(),
                expected: expected.as_str().to_string(),
                actual: self.remote_ref(token, &dst),
            }),
            Err(PushFail::Rejected(why)) => Err(MirrorError::Git(format!("delete {dst}: {why}"))),
            Err(PushFail::Unparseable(raw)) => Err(MirrorError::Unknown(raw)),
        }
    }

    // ---- internals -------------------------------------------------------

    fn git(&self, args: &[&str]) -> Result<Out, MirrorError> {
        run_git(&self.git_dir, args, "")
    }

    fn check_branch_name(&self, branch: &str) -> Result<(), MirrorError> {
        let out = self.git(&["check-ref-format", "--branch", branch])?;
        if out.ok() {
            Ok(())
        } else {
            Err(MirrorError::Git(format!("bad branch name {branch:?}")))
        }
    }

    fn read_ref(&self, full: &str) -> Result<Option<Sha>, MirrorError> {
        let out = self.git(&["show-ref", "--verify", "--hash", full])?;
        if out.ok() {
            let s = out.stdout.trim();
            return Sha::parse(s)
                .map(Some)
                .map_err(|e| MirrorError::Unknown(format!("show-ref {full}: {e}")));
        }
        if out.stderr.contains("not a valid ref") {
            Ok(None)
        } else {
            Err(MirrorError::Unknown(format!(
                "show-ref {full}: {}",
                out.summary()
            )))
        }
    }

    /// The authenticated push URL, built at call time. An empty token is only
    /// allowed for a non-GitHub (file://, local path) upstream — tests.
    fn push_url(&self, token: &str) -> Result<String, MirrorError> {
        let path = github_path(&self.upstream);
        if token.is_empty() {
            return match path {
                Some(_) => Err(MirrorError::Git(
                    "a token is required to push to github.com".into(),
                )),
                None => Ok(self.upstream.clone()),
            };
        }
        match path {
            Some(p) => Ok(format!("https://x-access-token:{token}@github.com/{p}")),
            None => Err(MirrorError::Git(format!(
                "upstream {:?} is not a github.com URL; refusing to embed a token",
                self.upstream
            ))),
        }
    }

    /// One lease-guarded push of `src` (None = delete) to `dst`, with
    /// `--force-with-lease=<dst>:<expect>` (`expect` None = must not exist).
    fn push_leased(
        &self,
        token: &str,
        dst: &str,
        expect: Option<&str>,
        src: Option<&Sha>,
    ) -> Result<(), PushFail> {
        let url = match self.push_url(token) {
            Ok(u) => u,
            Err(e) => return Err(PushFail::Rejected(e.to_string())),
        };
        let lease = format!("--force-with-lease={dst}:{}", expect.unwrap_or(""));
        let refspec = format!("{}:{dst}", src.map(|s| s.as_str()).unwrap_or(""));
        let out = match run_git(
            &self.git_dir,
            &["push", "--porcelain", &lease, &url, &refspec],
            token,
        ) {
            Ok(o) => o,
            Err(e) => return Err(PushFail::Rejected(e.to_string())),
        };
        // porcelain: `<flag>\t<from>:<to>\t<summary>` per ref, then `Done`.
        let mut line_for_ref = None;
        for line in out.stdout.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() == 3 && parts[1].ends_with(&format!(":{dst}")) {
                line_for_ref = Some((parts[0], parts[2]));
            }
        }
        match line_for_ref {
            Some(("!", summary)) if summary.contains("stale info") => Err(PushFail::Stale),
            Some(("!", summary)) => Err(PushFail::Rejected(summary.to_string())),
            // `=` means the ref already sits at `src`; git skips the lease
            // then, so it only counts as success when that is what the
            // caller expected (a retry). Expect-empty on an existing ref is a
            // lost lease, not a silent no-op — a claim must not be "created"
            // twice.
            Some(("=", _)) if out.ok() => {
                if expect.is_some() && expect == src.map(|s| s.as_str()) {
                    Ok(())
                } else {
                    Err(PushFail::Stale)
                }
            }
            Some((" " | "+" | "-" | "*", _)) if out.ok() => Ok(()),
            Some((flag, summary)) => Err(PushFail::Unparseable(format!(
                "push {dst}: flag {flag:?} summary {summary:?} exit {:?}",
                out.code
            ))),
            None => Err(PushFail::Unparseable(format!(
                "push {dst}: {}",
                out.summary()
            ))),
        }
    }

    /// What upstream holds at `full` right now (for LeaseLost.actual).
    fn remote_ref(&self, token: &str, full: &str) -> String {
        let Ok(url) = self.push_url(token) else {
            return "<unknown>".into();
        };
        match run_git(
            &self.git_dir,
            &["ls-remote", "--exit-code", &url, full],
            token,
        ) {
            Ok(o) if o.ok() => o
                .stdout
                .split_whitespace()
                .next()
                .map(str::to_string)
                .unwrap_or_else(|| "<unknown>".into()),
            Ok(o) if o.code == Some(2) => "<absent>".into(),
            _ => "<unknown>".into(),
        }
    }
}

/// `owner/repo.git` if `url` names a github.com repository.
fn github_path(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("http://github.com/"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        .or_else(|| url.strip_prefix("git@github.com:"))?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    if rest.split('/').filter(|s| !s.is_empty()).count() != 2 {
        return None;
    }
    Some(format!("{rest}.git"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fwfd-mirror-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let o = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "git {args:?} in {}: {}{}",
            dir.display(),
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        String::from_utf8_lossy(&o.stdout).trim().to_string()
    }

    fn commit(dir: &Path, name: &str) -> Sha {
        std::fs::write(dir.join(name), name).unwrap();
        git(dir, &["add", "."]);
        git(dir, &["commit", "-q", "-m", name]);
        Sha::parse(&git(dir, &["rev-parse", "HEAD"])).unwrap()
    }

    /// A bare upstream with `main` and `staging` at one commit, plus a
    /// throwaway work clone that can push to it directly (the "someone else").
    fn upstream() -> (PathBuf, PathBuf, PathBuf, Sha) {
        let root = tmp();
        let up = root.join("upstream.git");
        git(&root, &["init", "-q", "--bare", "upstream.git"]);
        let work = root.join("work");
        git(&root, &["init", "-q", "work"]);
        let base = commit(&work, "README");
        let up_url = format!("file://{}", up.display());
        git(
            &work,
            &[
                "push",
                "-q",
                &up_url,
                "HEAD:refs/heads/main",
                "HEAD:refs/heads/staging",
            ],
        );
        (root, up, work, base)
    }

    fn up_ref(up: &Path, full: &str) -> Option<String> {
        let o = Command::new("git")
            .args([
                "-C",
                up.to_str().unwrap(),
                "show-ref",
                "--hash",
                "--verify",
                full,
            ])
            .output()
            .unwrap();
        o.status
            .success()
            .then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
    }

    #[test]
    fn init_is_idempotent_and_mirrors_upstream() {
        let (root, up, _work, base) = upstream();
        let url = format!("file://{}", up.display());
        let m = Mirror::init(&root, &url).unwrap();
        assert_eq!(m.upstream_head("main").unwrap(), Some(base.clone()));
        assert_eq!(m.upstream_head("staging").unwrap(), Some(base.clone()));
        assert_eq!(m.branch_head("staging").unwrap(), Some(base.clone()));
        assert_eq!(m.branch_head("nope").unwrap(), None);
        assert_eq!(m.upstream_head("nope").unwrap(), None);
        // second init: same repo, same refs, remote url re-recorded
        let m2 = Mirror::init(&root, &url).unwrap();
        assert_eq!(m2.git_dir(), root.join("mirror.git"));
        assert_eq!(m2.upstream_head("main").unwrap(), Some(base));
        assert_eq!(git(m2.git_dir(), &["remote", "get-url", "upstream"]), url);
        assert!(m2.seat_remote_url().starts_with("file://"));
        assert!(m2.seat_remote_url().ends_with("/mirror.git"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn seat_pushes_to_mirror_and_supervisor_syncs_upstream() {
        let (root, up, _work, base) = upstream();
        let url = format!("file://{}", up.display());
        let m = Mirror::init(&root, &url).unwrap();
        // the seat clones the mirror — its only remote is the file:// url
        let seat = root.join("seat");
        git(&root, &["clone", "-q", &m.seat_remote_url(), "seat"]);
        assert_eq!(
            git(&seat, &["remote", "get-url", "origin"]),
            m.seat_remote_url()
        );
        assert!(!git(&seat, &["remote", "-v"]).contains("upstream.git"));
        assert_eq!(
            git(&seat, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "staging"
        );
        git(&seat, &["checkout", "-q", "-b", "impl1/issue-41"]);
        let head = commit(&seat, "fix.txt");
        git(&seat, &["push", "-q", "origin", "impl1/issue-41"]);
        assert_eq!(m.branch_head("impl1/issue-41").unwrap(), Some(head.clone()));
        assert_eq!(up_ref(&up, "refs/heads/impl1/issue-41"), None);
        // supervisor: new branch upstream → expect-empty lease
        let pushed = m.sync_branch("impl1/issue-41", None, "").unwrap();
        assert_eq!(pushed, head);
        assert_eq!(
            up_ref(&up, "refs/heads/impl1/issue-41"),
            Some(head.as_str().to_string())
        );
        assert_eq!(
            m.upstream_head("impl1/issue-41").unwrap(),
            Some(head.clone())
        );
        // a second push with the right lease lands the next commit
        let head2 = commit(&seat, "more.txt");
        git(&seat, &["push", "-q", "origin", "impl1/issue-41"]);
        assert_eq!(
            m.sync_branch("impl1/issue-41", Some(&head), "").unwrap(),
            head2
        );
        assert_eq!(
            up_ref(&up, "refs/heads/impl1/issue-41"),
            Some(head2.as_str().to_string())
        );
        // expect-empty on an existing branch is a lease failure, not a force
        let e = m.sync_branch("impl1/issue-41", None, "").unwrap_err();
        assert!(matches!(e, MirrorError::LeaseLost { .. }), "{e}");
        assert_ne!(head2, base);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn lease_lost_when_upstream_moved_leaves_mirror_untouched() {
        let (root, up, work, base) = upstream();
        let url = format!("file://{}", up.display());
        let m = Mirror::init(&root, &url).unwrap();
        // someone lands the branch upstream directly at `base`
        git(
            &work,
            &["push", "-q", &url, "HEAD:refs/heads/impl1/issue-7"],
        );
        m.fetch().unwrap();
        assert_eq!(
            m.upstream_head("impl1/issue-7").unwrap(),
            Some(base.clone())
        );
        // the seat's work in the mirror
        let seat = root.join("seat");
        git(&root, &["clone", "-q", &m.seat_remote_url(), "seat"]);
        git(&seat, &["checkout", "-q", "-b", "impl1/issue-7"]);
        let mine = commit(&seat, "mine.txt");
        git(&seat, &["push", "-q", "origin", "impl1/issue-7"]);
        // upstream moves again behind our back
        let theirs = commit(&work, "theirs.txt");
        git(
            &work,
            &["push", "-q", &url, "HEAD:refs/heads/impl1/issue-7"],
        );
        let e = m.sync_branch("impl1/issue-7", Some(&base), "").unwrap_err();
        assert_eq!(
            e,
            MirrorError::LeaseLost {
                branch: "impl1/issue-7".into(),
                expected: base.as_str().into(),
                actual: theirs.as_str().into(),
            }
        );
        // upstream still theirs; mirror still ours; tracking ref not guessed
        assert_eq!(
            up_ref(&up, "refs/heads/impl1/issue-7"),
            Some(theirs.as_str().to_string())
        );
        assert_eq!(m.branch_head("impl1/issue-7").unwrap(), Some(mine));
        assert_eq!(m.upstream_head("impl1/issue-7").unwrap(), Some(base));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn protected_branches_are_refused_before_any_push() {
        let (root, up, _work, base) = upstream();
        let url = format!("file://{}", up.display());
        let m = Mirror::init(&root, &url).unwrap();
        for b in PROTECTED {
            assert_eq!(
                m.sync_branch(b, Some(&base), "").unwrap_err(),
                MirrorError::Protected(b.into())
            );
        }
        assert_eq!(
            up_ref(&up, "refs/heads/main"),
            Some(base.as_str().to_string())
        );
        // a missing branch and a malformed name are typed refusals too
        assert!(matches!(
            m.sync_branch("never-pushed", None, ""),
            Err(MirrorError::Git(_))
        ));
        assert!(matches!(
            m.sync_branch("bad..name", None, ""),
            Err(MirrorError::Git(_))
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn claim_ref_is_a_true_cas_and_release_checks_the_fence() {
        let (root, up, work, base) = upstream();
        let url = format!("file://{}", up.display());
        let m = Mirror::init(&root, &url).unwrap();
        let fence = m.create_claim_ref(41, &base, "").unwrap();
        assert_eq!(fence, Fence(base.as_str().to_string()));
        assert_eq!(
            up_ref(&up, "refs/claims/41"),
            Some(base.as_str().to_string())
        );
        // second claim of the same issue, even at the same sha, is taken
        assert_eq!(
            m.create_claim_ref(41, &base, "").unwrap_err(),
            MirrorError::ClaimTaken(41)
        );
        // a sha the mirror does not have cannot be claimed
        let other = commit(&work, "elsewhere.txt");
        assert!(matches!(
            m.create_claim_ref(42, &other, ""),
            Err(MirrorError::Git(_))
        ));
        // release with the wrong fence is refused and the ref stays
        let wrong = Fence("f".repeat(40));
        let e = m.release_claim_ref(41, &wrong, "").unwrap_err();
        assert!(
            matches!(e, MirrorError::LeaseLost { ref branch, .. } if branch == "refs/claims/41"),
            "{e}"
        );
        assert_eq!(
            up_ref(&up, "refs/claims/41"),
            Some(base.as_str().to_string())
        );
        assert!(matches!(
            m.release_claim_ref(41, &Fence("junk".into()), ""),
            Err(MirrorError::Git(_))
        ));
        // the right fence deletes it, and the issue is claimable again
        m.release_claim_ref(41, &fence, "").unwrap();
        assert_eq!(up_ref(&up, "refs/claims/41"), None);
        assert!(m.create_claim_ref(41, &base, "").is_ok());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn push_url_embeds_token_only_for_github_and_scrub_hides_it() {
        let m = Mirror {
            git_dir: PathBuf::from("/nonexistent/mirror.git"),
            upstream: "https://github.com/tbaums/fun-with-friends".into(),
        };
        let tok = "ghs_SECRET123";
        assert_eq!(
            m.push_url(tok).unwrap(),
            "https://x-access-token:ghs_SECRET123@github.com/tbaums/fun-with-friends.git"
        );
        assert!(matches!(m.push_url(""), Err(MirrorError::Git(_))));
        assert_eq!(
            github_path("git@github.com:o/r.git"),
            Some("o/r.git".into())
        );
        assert_eq!(
            github_path("https://github.com/o/r/"),
            Some("o/r.git".into())
        );
        assert_eq!(github_path("https://github.com/o"), None);
        assert_eq!(github_path("https://gitlab.com/o/r"), None);
        // a non-github upstream never gets a token embedded
        let f = Mirror {
            git_dir: m.git_dir.clone(),
            upstream: "file:///x/up.git".into(),
        };
        assert!(matches!(f.push_url(tok), Err(MirrorError::Git(_))));
        assert_eq!(f.push_url("").unwrap(), "file:///x/up.git");
        assert_eq!(
            scrub(
                "To https://x-access-token:ghs_SECRET123@github.com/o/r.git",
                tok
            ),
            "To https://x-access-token:***@github.com/o/r.git"
        );
        // an unreachable git_dir fails closed (Unknown / Git), never Ok(None)
        assert!(m.branch_head("main").is_err());
    }
}
