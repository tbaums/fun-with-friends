//! T-14 — the manifest. One `fwf.toml` per customer repo is the ONLY launch
//! input: repo, branches, seats, suites, models. `fwf up` refuses without it
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
    /// How long an impl seat may be quiet on BOTH liveness signals — its
    /// worktree and its pane — before the loop calls it Stalled (#668).
    /// `job_timeout_secs` stays the absolute ceiling; this only ends the wait
    /// *early*, and only for a seat that has genuinely stopped moving. 0 turns
    /// the early stall off and leaves the ceiling alone.
    #[serde(default = "default_stall_quiet")]
    pub stall_quiet_secs: u64,
    #[serde(default = "default_poll")]
    pub poll_interval_secs: u64,
    /// Model per role, e.g. impl = "opus", pm = "haiku". Unset = the seat's default.
    #[serde(default)]
    pub models: BTreeMap<String, String>,
    /// Meter brake: park the floor at this weekly % and resume on reset.
    #[serde(default = "default_park")]
    pub park_at_weekly_pct: u8,
    /// How many times the loop re-wakes an impl seat on one PR after QA asked
    /// for changes (#576). Past it the PR waits for a human; nothing is closed.
    #[serde(default = "default_rework_cap")]
    pub rework_cap: u32,
    /// Prompt family under `prompts/` (dev, refactor, validate, ideation,
    /// consulting, defect-report, user-testing). Missing roles fall back to dev.
    #[serde(default = "default_template")]
    pub template: String,
    /// GV triage cycle inside `fwf run`: every tick, wake the GV seat once
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
    /// The spec cycle inside `fwf run` (#629): each tick, GV judges one gated
    /// issue it has never judged, and PM specs one gated issue GV called ready.
    /// On by default — a ticket filed with the gate label is meant to reach
    /// PM without an operator typing `fwf triage`/`fwf spec` by hand. Needs a
    /// `gv`/`pm` seat in `[models]`; a missing seat disables that half with a
    /// warning at startup.
    #[serde(default = "default_true")]
    pub auto_spec: bool,
    /// How far that spec cycle reaches (#652): `"all-gated"` (the default)
    /// reviews every open gated issue, `"allow-list"` narrows it to `issues`
    /// so a single-ticket floor spends no GV/PM cycles repo-wide. `skip_labels`
    /// parks an issue under either value.
    #[serde(default = "default_review_scope")]
    pub review_scope: String,
    /// Who un-gates on the floor's behalf once a spec lands *and GV has signed
    /// it off* (#655 — never on the spec alone). Unset (the default) leaves
    /// the un-gate to a human running `fwf ungate`; set to a name and `fwf
    /// run` removes the gate label itself and records that name as the actor,
    /// so the decision stays attributable either way.
    ///
    /// Attributable, and marked as delegated (#645): the issue comment and the
    /// run record both say the loop typed it, and `fwf up` names the delegate
    /// in its floor plan — a floor that approves its own specced tickets says
    /// so before it starts, not only afterwards in the record.
    ///
    /// The delegated un-gate never widens beyond the allow-list (#663): with
    /// `issues` set, a signed-off ticket outside it keeps its gate label and
    /// waits for a human `fwf ungate`, whatever `review_scope` says. Looking
    /// wide is GV and PM's business; making an issue claimable is the
    /// operator's rail.
    #[serde(default)]
    pub delegate_ungate: Option<String>,
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
/// 15 minutes of no worktree change and no pane output. Long enough for a
/// model's own thinking and a slow suite, short enough that a seat that has
/// really stopped is not held to the full `job_timeout_secs`.
pub const STALL_QUIET_DEFAULT: u64 = 900;
fn default_stall_quiet() -> u64 {
    STALL_QUIET_DEFAULT
}
fn default_poll() -> u64 {
    60
}
fn default_park() -> u8 {
    85
}
fn default_rework_cap() -> u32 {
    2
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
/// The two spellings `review_scope` accepts. `run` reads them back into its
/// own enum; the manifest is where an unknown one is refused.
pub const REVIEW_SCOPE_ALL_GATED: &str = "all-gated";
pub const REVIEW_SCOPE_ALLOW_LIST: &str = "allow-list";
fn default_review_scope() -> String {
    REVIEW_SCOPE_ALL_GATED.into()
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
                "no manifest at {} (fwf refuses to guess; write fwf.toml)",
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
        if ![REVIEW_SCOPE_ALL_GATED, REVIEW_SCOPE_ALLOW_LIST].contains(&self.review_scope.as_str())
        {
            return Err(ManifestError::Invalid(format!(
                "review_scope {:?} is not {REVIEW_SCOPE_ALL_GATED}|{REVIEW_SCOPE_ALLOW_LIST}",
                self.review_scope
            )));
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
    /// Every seat this manifest defines, as `(role, n)`: an impl/qa pair per
    /// `pairs`, then `gv`/`pm` when `[models]` names them. `fwf seats` brings
    /// up exactly these, so anything reporting on seats lists exactly these
    /// (#588 — `fwf status` was showing impl/qa only).
    pub fn seats(&self) -> Vec<(&'static str, u8)> {
        let mut v: Vec<(&'static str, u8)> = Vec::new();
        for n in 1..=self.pairs {
            v.push(("impl", n));
            v.push(("qa", n));
        }
        for r in ["gv", "pm"] {
            if self.models.contains_key(r) {
                v.push((r, 1));
            }
        }
        v
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
# An impl seat is called Stalled early only after this long with no worktree
# change AND no pane output; job_timeout_secs is still the ceiling.
stall_quiet_secs = 900
poll_interval_secs = 60
park_at_weekly_pct = 85
rework_cap = 2
template = "dev"
triage_new = false
# GV triage + PM spec of gated issues, inside the loop. Set delegate_ungate to
# a name to let the loop un-gate after a spec instead of waiting on a human.
auto_spec = true
# Which gated issues that cycle may spend a GV/PM wake on: every one
# ("all-gated"), or only the `issues` allow-list below ("allow-list").
review_scope = "all-gated"
skip_labels = ["idea", "release-hold", "tracking", "build-epic"]
# Only these issues may be worked while 1.0 is new. Remove to allow any eligible issue.
issues = [564]

[suites]
fast = "bash -n fwf-legacy bin/lib.sh bin/fwf-*.sh && echo SYNTAX-OK"
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

    /// #629: the spec cycle is on unless a manifest turns it off, and the
    /// un-gate stays a human's until one names a delegate.
    #[test]
    fn auto_spec_defaults_on_and_the_ungate_delegate_is_opt_in() {
        let bare = Manifest::parse("repo = \"a/b\"\n[suites]\nfast=\"x\"\n").unwrap();
        assert!(bare.auto_spec);
        assert_eq!(bare.delegate_ungate, None);
        let m = Manifest::parse(
            "repo = \"a/b\"\nauto_spec = false\ndelegate_ungate = \"tbaums\"\n[suites]\nfast=\"x\"\n",
        )
        .unwrap();
        assert!(!m.auto_spec);
        assert_eq!(m.delegate_ungate.as_deref(), Some("tbaums"));
        assert!(Manifest::parse(EXAMPLE).unwrap().auto_spec);
    }

    /// #652: the review cycle reviews every gated issue unless a manifest
    /// asks for the allow-list, and an unknown scope is refused at load —
    /// a typo must not silently widen what GV and PM are woken on.
    #[test]
    fn review_scope_defaults_to_all_gated_and_refuses_an_unknown_value() {
        let bare = Manifest::parse("repo = \"a/b\"\n[suites]\nfast=\"x\"\n").unwrap();
        assert_eq!(bare.review_scope, REVIEW_SCOPE_ALL_GATED);
        let m = Manifest::parse(
            "repo = \"a/b\"\nreview_scope = \"allow-list\"\n[suites]\nfast=\"x\"\n",
        )
        .unwrap();
        assert_eq!(m.review_scope, REVIEW_SCOPE_ALLOW_LIST);
        assert!(matches!(
            Manifest::parse("repo = \"a/b\"\nreview_scope = \"allowlist\"\n[suites]\nfast=\"x\"\n")
                .unwrap_err(),
            ManifestError::Invalid(_)
        ));
        assert_eq!(
            Manifest::parse(EXAMPLE).unwrap().review_scope,
            REVIEW_SCOPE_ALL_GATED
        );
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

    /// #668: the quiet limit is a manifest knob with a default, read exactly
    /// like `job_timeout_secs` beside it — a floor that says nothing gets 900s.
    #[test]
    fn stall_quiet_secs_parses_and_defaults_to_fifteen_minutes() {
        let bare = Manifest::parse("repo = \"a/b\"\n[suites]\nfast=\"x\"\n").unwrap();
        assert_eq!(bare.stall_quiet_secs, 900);
        assert_eq!(bare.job_timeout_secs, 1800);
        let m = Manifest::parse(
            "repo = \"a/b\"\nstall_quiet_secs = 1200\njob_timeout_secs = 2400\n[suites]\nfast=\"x\"\n",
        )
        .unwrap();
        assert_eq!(m.stall_quiet_secs, 1200);
        assert_eq!(m.job_timeout_secs, 2400);
        assert_eq!(Manifest::parse(EXAMPLE).unwrap().stall_quiet_secs, 900);
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
