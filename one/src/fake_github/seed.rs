//! Seeding the fake: repos, issues and refs a test starts from. Split out of
//! `fake_github.rs`, which is held at its size baseline (T-30).

use super::FakeGitHub;

impl FakeGitHub {
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
        self.seed_issue_with_body(owner, repo, title, "", author, labels)
    }

    /// [`seed_issue`](Self::seed_issue) with a body: an issue a PM has
    /// already written its spec into (#713).
    pub fn seed_issue_with_body(
        &self,
        owner: &str,
        repo: &str,
        title: &str,
        body: &str,
        author: &str,
        labels: &[&str],
    ) -> u64 {
        self.lock()
            .create_issue(owner, repo, title, body, author, labels, None)
    }

    /// Set `refs/<name>` (e.g. `heads/main`) to `sha`, creating the repo.
    pub fn seed_ref(&self, owner: &str, repo: &str, name: &str, sha: &str) {
        self.lock()
            .repo_mut(owner, repo)
            .refs
            .insert(format!("refs/{name}"), sha.to_string());
    }
}
