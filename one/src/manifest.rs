//! T-14 — the manifest. One `fwf.toml` per customer repo is the ONLY launch
//! input: repo, branches, seats, suites, models. `fwfd up` refuses without it
//! and every verb reads its defaults from it, so nothing is ever inferred from
//! ambient environment (the 200-knob problem, closed by construction).
//!
//! Keys are counted: the manifest may not grow past `MAX_KEYS` without a
//! deliberate change here.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const MAX_KEYS: usize = 25;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    /// `owner/name` on GitHub.
    pub repo: String,
    /// Where PRs land. `main` only ever fast-forwards from it.
    #[serde(default = "default_staging")]
    pub base_branch: String,
    #[serde(default = "default_main")]
    pub release_branch: String,
    /// Issues carrying this label are not eligible.
    #[serde(default = "default_gate_label")]
    pub gate_label: String,
    /// Only owner-authored issues are eligible (never false on a public repo).
    #[serde(default = "default_true")]
    pub owner_only: bool,
    #[serde(default = "default_pairs")]
    pub pairs: u8,
    /// tmux session that holds the seat panes.
    #[serde(default = "default_session")]
    pub session: String,
    /// Where the floor's state, mirror and worktrees live.
    pub floor_dir: Option<PathBuf>,
    /// Suites: name → shell command run in a checkout of the sha under test.
    #[serde(default)]
    pub suites: BTreeMap<String, String>,
    /// The suite a PR must pass before merge, and the one promotion needs.
    #[serde(default = "default_fast")]
    pub fast_suite: String,
    #[serde(default = "default_fast")]
    pub promote_suite: String,
    /// Gate venue: "local" | "container" | "systemd".
    #[serde(default = "default_venue")]
    pub gate_venue: String,
    #[serde(default = "default_mem")]
    pub gate_memory_gb: u32,
    #[serde(default = "default_gate_timeout")]
    pub gate_timeout_secs: u64,
    #[serde(default = "default_job_timeout")]
    pub job_timeout_secs: u64,
    #[serde(default = "default_poll")]
    pub poll_interval_secs: u64,
    /// Model per role, e.g. impl = "opus", pm = "haiku". Unset = the seat's default.
    #[serde(default)]
    pub models: BTreeMap<String, String>,
    /// Meter brake: park the floor at this weekly % and resume on reset.
    #[serde(default = "default_park")]
    pub park_at_weekly_pct: u8,
    /// Prompt family under `prompts/` (dev, refactor, validate, ideation,
    /// consulting, defect-report, user-testing). Missing roles fall back to dev.
    #[serde(default = "default_template")]
    pub template: String,
    /// GV triage cycle inside `fwfd run`: every tick, wake the GV seat once
    /// per open, un-gated, never-triaged issue (allow-list does not apply:
    /// triage is how issues become worth allow-listing). Off by default
    /// because it labels and comments on real issues.
    #[serde(default)]
    pub triage_new: bool,
    /// Issues carrying any of these labels are never planned.
    #[serde(default = "default_skip_labels")]
    pub skip_labels: Vec<String>,
    /// Allow-list: if non-empty, the supervisor only ever works these issue
    /// numbers (the operator's safety rail while 1.0 is new). Empty = any
    /// eligible issue.
    #[serde(default)]
    pub issues: Vec<u64>,
}

fn default_staging() -> String {
    "staging".into()
}
fn default_main() -> String {
    "main".into()
}
fn default_gate_label() -> String {
    "product-wip".into()
}
fn default_true() -> bool {
    true
}
fn default_pairs() -> u8 {
    1
}
fn default_session() -> String {
    "fwf-one".into()
}
fn default_fast() -> String {
    "fast".into()
}
fn default_venue() -> String {
    "local".into()
}
fn default_mem() -> u32 {
    8
}
fn default_gate_timeout() -> u64 {
    1800
}
fn default_job_timeout() -> u64 {
    1800
}
fn default_poll() -> u64 {
    60
}
fn default_park() -> u8 {
    85
}
fn default_skip_labels() -> Vec<String> {
    ["idea", "release-hold", "tracking", "build-epic"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}
fn default_template() -> String {
    "dev".into()
}

#[derive(Debug, PartialEq)]
pub enum ManifestError {
    Missing(PathBuf),
    Unparseable(String),
    Invalid(String),
    TooManyKeys(usize),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManifestError::Missing(p) => write!(
                f,
                "no manifest at {} (fwfd refuses to guess; write fwf.toml)",
                p.display()
            ),
            ManifestError::Unparseable(e) => write!(f, "manifest unparseable: {e}"),
            ManifestError::Invalid(e) => write!(f, "manifest invalid: {e}"),
            ManifestError::TooManyKeys(n) => write!(
                f,
                "manifest has {n} top-level keys; the limit is {MAX_KEYS}"
            ),
        }
    }
}

impl Manifest {
    pub fn load(path: &Path) -> Result<Manifest, ManifestError> {
        let text = std::fs::read_to_string(path)
            .map_err(|_| ManifestError::Missing(path.to_path_buf()))?;
        Manifest::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Manifest, ManifestError> {
        let raw: toml::Value =
            toml::from_str(text).map_err(|e| ManifestError::Unparseable(e.to_string()))?;
        let n = raw.as_table().map(|t| t.len()).unwrap_or(0);
        if n > MAX_KEYS {
            return Err(ManifestError::TooManyKeys(n));
        }
        let m: Manifest =
            toml::from_str(text).map_err(|e| ManifestError::Unparseable(e.to_string()))?;
        m.validate()?;
        Ok(m)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        let (o, r) = self
            .repo
            .split_once('/')
            .ok_or_else(|| ManifestError::Invalid("repo must be owner/name".into()))?;
        if o.is_empty() || r.is_empty() || r.contains('/') {
            return Err(ManifestError::Invalid("repo must be owner/name".into()));
        }
        if self.base_branch == self.release_branch {
            return Err(ManifestError::Invalid(
                "base_branch and release_branch must differ".into(),
            ));
        }
        if self.pairs == 0 || self.pairs > 8 {
            return Err(ManifestError::Invalid("pairs must be 1..=8".into()));
        }
        if !["local", "container", "systemd"].contains(&self.gate_venue.as_str()) {
            return Err(ManifestError::Invalid(format!(
                "gate_venue {:?} is not local|container|systemd",
                self.gate_venue
            )));
        }
        for s in [&self.fast_suite, &self.promote_suite] {
            if !self.suites.contains_key(s) {
                return Err(ManifestError::Invalid(format!(
                    "suite {s:?} is named but not defined in [suites]"
                )));
            }
        }
        for (k, v) in &self.suites {
            if v.trim().is_empty() {
                return Err(ManifestError::Invalid(format!(
                    "suite {k:?} has an empty command"
                )));
            }
        }
        if self.park_at_weekly_pct > 98 {
            return Err(ManifestError::Invalid(
                "park_at_weekly_pct must be ≤ 98".into(),
            ));
        }
        Ok(())
    }

    pub fn owner(&self) -> &str {
        self.repo.split_once('/').map(|(o, _)| o).unwrap_or("")
    }
    pub fn name(&self) -> &str {
        self.repo.split_once('/').map(|(_, n)| n).unwrap_or("")
    }
    pub fn floor(&self) -> PathBuf {
        self.floor_dir.clone().unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".fwf/floors")
                .join(self.name())
        })
    }
    pub fn seat_target(&self, role: &str, n: u8) -> String {
        format!("{}:{role}{n}", self.session)
    }
    /// Where the manifest lives by default: in the customer repo.
    pub fn default_path(repo_dir: &Path) -> PathBuf {
        repo_dir.join(".fwf/fwf.toml")
    }
}

pub const EXAMPLE: &str = r#"# fwf 1.0 manifest — the only launch input. Keep it small.
# Scalars first; tables ([suites], [models]) last — TOML keys after a table
# header belong to that table.
repo = "tbaums/fun-with-friends"
base_branch = "staging"
release_branch = "main"
gate_label = "product-wip"
owner_only = true
pairs = 1
session = "fwf-one"
fast_suite = "fast"
promote_suite = "fast"
gate_venue = "local"
gate_memory_gb = 8
gate_timeout_secs = 1800
job_timeout_secs = 1800
poll_interval_secs = 60
park_at_weekly_pct = 85
template = "dev"
triage_new = false
skip_labels = ["idea", "release-hold", "tracking", "build-epic"]
# Only these issues may be worked while 1.0 is new. Remove to allow any eligible issue.
issues = [564]

[suites]
fast = "bash -n fwf lib.sh fwf-*.sh && echo SYNTAX-OK"
e2e = "cd one && cargo test --quiet"

[models]
impl = "opus"
qa = "opus"
pm = "sonnet"
gv = "haiku"
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn example_parses_and_stays_under_the_key_limit() {
        let m = Manifest::parse(EXAMPLE).unwrap();
        assert_eq!(m.owner(), "tbaums");
        assert_eq!(m.name(), "fun-with-friends");
        assert_eq!(m.seat_target("impl", 1), "fwf-one:impl1");
        let raw: toml::Value = toml::from_str(EXAMPLE).unwrap();
        assert!(raw.as_table().unwrap().len() <= MAX_KEYS);
    }

    #[test]
    fn missing_manifest_is_a_refusal_not_a_guess() {
        let e = Manifest::load(Path::new("/nonexistent/fwf.toml")).unwrap_err();
        assert!(matches!(e, ManifestError::Missing(_)));
    }

    #[test]
    fn invalid_shapes_are_named() {
        assert!(matches!(
            Manifest::parse("repo = \"nope\"\n[suites]\nfast=\"x\"\n").unwrap_err(),
            ManifestError::Invalid(_)
        ));
        let same = "repo = \"a/b\"\nbase_branch = \"main\"\nrelease_branch = \"main\"\n[suites]\nfast=\"x\"\n";
        assert!(matches!(
            Manifest::parse(same).unwrap_err(),
            ManifestError::Invalid(_)
        ));
        let nosuite = "repo = \"a/b\"\nfast_suite = \"missing\"\n[suites]\nfast=\"x\"\n";
        assert!(matches!(
            Manifest::parse(nosuite).unwrap_err(),
            ManifestError::Invalid(_)
        ));
        let venue = "repo = \"a/b\"\ngate_venue = \"cloud\"\n[suites]\nfast=\"x\"\n";
        assert!(matches!(
            Manifest::parse(venue).unwrap_err(),
            ManifestError::Invalid(_)
        ));
    }

    #[test]
    fn too_many_keys_is_refused() {
        // Extras must precede the [suites] table or they would land inside it.
        let mut s = String::from("repo = \"a/b\"\n");
        for i in 0..MAX_KEYS {
            s.push_str(&format!("extra{i} = 1\n"));
        }
        s.push_str("[suites]\nfast=\"x\"\n");
        assert!(matches!(
            Manifest::parse(&s).unwrap_err(),
            ManifestError::TooManyKeys(_)
        ));
    }
}
