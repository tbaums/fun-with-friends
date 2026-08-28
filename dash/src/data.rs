//! Data layer: shells out to the bash provider (`fwf-dash-data.sh`) and parses its
//! JSON. Keeping derivation in bash means the gh/local backend abstraction and
//! profile resolution stay in one tested place (the gh-dash model); this binary is
//! purely the renderer. Read-only — nothing here mutates the tracker.

use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Dashboard {
    pub profile: String,
    pub template: String,
    #[serde(default)]
    pub parked: bool,
    pub prod: String,
    pub pipeline: String,
    /// "status.json" | "stale" | "derived" — provenance of prod/pipeline.
    pub stamp: String,
    pub generated_at: String,
    #[serde(default)]
    pub roles: Vec<Role>,
    #[serde(default)]
    pub decisions: Vec<Decision>,
    #[serde(default)]
    pub issues: Vec<Issue>,
    #[serde(default)]
    pub activity: Activity,
    #[serde(default)]
    pub needs_you: NeedsYou,
    #[serde(default)]
    pub floor_idle: FloorIdle,
    #[serde(default)]
    pub upgrade: UpgradeAvailable,
    #[serde(default)]
    pub installed: InstalledVersion,
    #[serde(default)]
    pub visibility: Visibility,
    #[serde(default)]
    pub api_budget: ApiBudget,
}

/// Set when the captain is blocked on a human decision (an in-pane "NEEDS YOU"
/// state or interactive menu) that the gh label protocol doesn't capture — so the
/// dash can show an unmissable banner instead of looking calm.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct NeedsYou {
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub summary: String,
}

/// Issue #85: the last floor-lifecycle event (`fwf-down.sh --floor-only` /
/// `fwf-up.sh --floor-only` / a floor-role respawn), so a deliberate idle can be
/// told apart from a crash. `active` is true only when the last logged event is
/// `floor-down` with no later `floor-up` — see `roles_json()` in
/// fwf-dash-data.sh for how this combines with live-pane precedence.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct FloorIdle {
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub since: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub actor: String,
}

/// Set when a newer fwf release exists (issue #94, from the #79 discovery
/// proposal) — cache-only, read from lib/version_check.sh's shared cache by
/// `upgrade_json()` in fwf-dash-data.sh. Never triggers a network call itself;
/// freshness comes from that cache's own detached background refresh.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct UpgradeAvailable {
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub current: String,
    #[serde(default)]
    pub latest: String,
}

/// The INSTALLED version on disk (issue #153), re-read fresh on EVERY tick by
/// `installed_version_json()` in fwf-dash-data.sh — a cheap `cat`, never a
/// `fwf --version` subprocess, and never cached at launch (caching it would
/// make the drift this exists to catch invisible for the process's whole
/// life). Deliberately separate from `UpgradeAvailable`: that field is EMPTY
/// whenever the install is already current with the latest GitHub release
/// (`fwf_version_skew_check` returns nothing in that case) — exactly the
/// state right after a fresh `fwf upgrade`, which is precisely when a
/// long-lived dash is most likely to have just gone stale.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct InstalledVersion {
    #[serde(default)]
    pub version: String,
}

/// GitHub API budget headroom (issue #239). A correlated failure — one
/// shared account, one budget — takes every role's read layer out AT ONCE,
/// which is exactly when a false-confident "nothing in flight" is most
/// damaging. `status` is `"EXHAUSTED"` both when a genuine 0-remaining
/// reading comes back AND when the headroom read itself could not
/// complete (network/auth/rate-limited) — from the operator's chair, "we
/// cannot tell how much budget is left" and "budget is gone" both mean
/// "do not trust the read layer right now", and both get the same visible
/// alarm. `#[serde(default)]` on every field means a `fwf-dash-data.sh`
/// too old to emit this key at all renders as `status: ""`, never as a
/// fabricated "EXHAUSTED" or "OK" — `default()` below is deliberately
/// empty/false, not "OK", so an absent field can never read as reassuring.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ApiBudget {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub remaining: Option<i64>,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub reset: Option<i64>,
}

/// This RUNNING process's own version + build date, embedded at compile time
/// by `build.rs` from the top-level `VERSION` file (issue #153) — fixed for
/// the life of the process, unlike `InstalledVersion.version` above (which is
/// re-read from disk every refresh and reflects whatever `fwf upgrade` may
/// have installed SINCE this process started).
pub const RUNNING_VERSION: &str = env!("FWF_DASH_VERSION");
pub const RUNNING_BUILD_DATE: &str = env!("FWF_DASH_BUILD_DATE");

/// rc true if semver `a` < semver `b` ("vX.Y.Z" or "X.Y.Z"; missing/non-numeric
/// segments treat as 0) — a numeric field-by-field compare, NOT a string
/// inequality, mirroring `lib/version_check.sh`'s `_fwf_semver_lt` exactly so
/// the two never disagree about what counts as "behind".
pub fn semver_lt(a: &str, b: &str) -> bool {
    fn parts(v: &str) -> (u64, u64, u64) {
        let v = v.strip_prefix('v').unwrap_or(v);
        let mut it = v.split('.');
        let seg = |s: Option<&str>| -> u64 {
            s.unwrap_or("0")
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>()
                .parse()
                .unwrap_or(0)
        };
        (seg(it.next()), seg(it.next()), seg(it.next()))
    }
    parts(a) < parts(b)
}

/// True when this RUNNING dash is older than the version currently
/// INSTALLED on disk — this process needs a restart to pick up what `fwf
/// upgrade` already installed. `installed_current` empty (no successful read
/// yet, e.g. `$FWF_HOME/VERSION` unreadable) means UNKNOWN, never drift —
/// only ever compare two values that were both actually read.
pub fn running_binary_stale(installed_current: &str) -> bool {
    !installed_current.is_empty() && semver_lt(RUNNING_VERSION, installed_current)
}

#[cfg(test)]
mod running_stale_tests {
    use super::*;

    #[test]
    fn semver_lt_basic_ordering() {
        assert!(semver_lt("0.30.0", "0.31.0"));
        assert!(semver_lt("0.31.0", "0.31.1"));
        assert!(semver_lt("0.9.9", "0.10.0"));
        assert!(!semver_lt("0.31.0", "0.31.0"));
        assert!(!semver_lt("0.32.0", "0.31.0"));
    }

    #[test]
    fn semver_lt_v_prefix_and_missing_segments_are_tolerated() {
        assert!(semver_lt("v0.30.0", "v0.31.0"));
        assert!(semver_lt("0.30", "0.30.1")); // missing patch treated as 0
        assert!(!semver_lt("garbage", "also-garbage")); // both parse as 0.0.0
    }

    #[test]
    fn running_binary_stale_empty_installed_is_unknown_not_drift() {
        assert!(!running_binary_stale(""));
    }
}

/// Factory motion, derived from PRs against the integration targets: drafts are
/// being built, ready PRs are in test/review, recent merges are promotions.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Activity {
    #[serde(default)]
    pub building: Vec<ActivityItem>,
    #[serde(default)]
    pub in_test: Vec<ActivityItem>,
    #[serde(default)]
    pub merged: Vec<ActivityItem>,
    /// Open PRs straight to the default branch (e.g. `main`) — outside the
    /// staging/integration factory pipeline. Surfaced as a "review" hint so
    /// direct PRs (often human-authored, no linked issue) are still findable.
    #[serde(default)]
    pub to_main: Vec<ActivityItem>,
}

impl Activity {
    /// building → in_test → merged → to_main: display and cursor-selection order.
    pub fn flat(&self) -> Vec<&ActivityItem> {
        self.building
            .iter()
            .chain(&self.in_test)
            .chain(&self.merged)
            .chain(&self.to_main)
            .collect()
    }

    pub fn len(&self) -> usize {
        self.building.len() + self.in_test.len() + self.merged.len() + self.to_main.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ActivityItem {
    pub pr: i64,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub issue: String,
    #[serde(default)]
    pub base: String,
    /// "pass" | "run" | "fail" | "none" — on building / in_test rows.
    #[serde(default)]
    pub checks: String,
    /// "MM-DD HH:MM" — on merged rows.
    #[serde(default)]
    pub when: String,
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Role {
    pub role: String,
    /// "live" | "idle" | "down" | "floor_idle" (deliberately parked by
    /// `fwf-down.sh --floor-only`, issue #85 — never a real crash) | "unknown"
    /// (session not visible from this host/socket — issue #193, never a
    /// fabricated "down") | "busy" (no pane, but holding its own gate lock —
    /// #193 AC i) | "stale" (session visible, a heartbeat exists but is aging)
    pub state: String,
    #[serde(default)]
    pub detail: String,
    /// Seconds since this role's heartbeat last touched (issue #193 AC a/i0)
    /// — populated alongside `state`, never a substitute for it. `null`/absent
    /// (older `fwf-dash-data.sh`, or a role with no heartbeat trace at all)
    /// means "not available", not "zero".
    #[serde(default)]
    pub heartbeat_age: Option<i64>,
}

/// Whole-factory read visibility (issue #193 AC b/e) — always emitted by
/// `fwf-dash-data.sh`, never only during a failure, so the header's
/// newest-heartbeat age is something an operator has actually calibrated
/// before the one incident where it matters. `#[serde(default)]` on the
/// `Dashboard` field below means an older provider JSON (no `visibility` key
/// at all) degrades to `factory_visible: false` — the fail-safe direction,
/// same as every other read in this ticket — never a false "all clear".
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Visibility {
    #[serde(default)]
    pub factory_visible: bool,
    #[serde(default)]
    pub newest_heartbeat_age: Option<i64>,
    #[serde(default)]
    pub state_dir: String,
    #[serde(default)]
    pub profile: String,
    #[serde(default)]
    pub host: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Decision {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub flags: String,
    #[serde(default)]
    pub body: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Issue {
    pub number: i64,
    pub title: String,
    #[serde(default)]
    pub gated: bool,
    #[serde(default)]
    pub body: String,
}

/// Run the bash provider and parse one dashboard snapshot. The provider path comes
/// from `$FWF_DASH_DATA` (set by the `fwf dash` wrapper); we inherit the rest of the
/// environment (FWF_PROFILE etc.) so the provider resolves the same factory we do.
pub fn fetch() -> Result<Dashboard, String> {
    let script = std::env::var("FWF_DASH_DATA")
        .map_err(|_| "FWF_DASH_DATA is not set (run via `fwf dash`)".to_string())?;
    let out = Command::new("bash")
        .arg(&script)
        .output()
        .map_err(|e| format!("could not run the data provider: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "data provider exited {}: {}",
            out.status.code().unwrap_or(-1),
            err.trim()
        ));
    }
    parse(&out.stdout)
}

/// Per-role token/$ usage (issue #95, Ticket A of #70), from the sibling
/// provider `fwf-usage-data.sh` — a separate script (and a separate refresh
/// cadence in main.rs) because summing every role's Claude Code transcripts
/// is a heavier read than the gh/tmux-derived Dashboard above.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct UsageData {
    // `generated_at` is in the provider's JSON but unused here — per-role
    // `age_secs` is what the UI actually shows; serde ignores the extra field.
    #[serde(default)]
    pub caveat: String,
    #[serde(default)]
    pub roles: Vec<UsageRole>,
    #[serde(default)]
    pub total: UsageTotals,
    /// Hard token-budget enforcement status (issue #96, Ticket B of #70) —
    /// NOT part of the bash provider's JSON (fwf-usage-data.sh stays
    /// read-only/#95-only). Populated separately by `fetch_usage()` reading
    /// env vars + the writer's own sentinel files directly, so `#[serde]`
    /// must skip it (there is nothing to deserialize).
    #[serde(skip)]
    pub budget: BudgetStatus,
}

/// The GV-signoff residual-risk fix for #96: a budget configured mid-run
/// without a re-`fwf up` (which is when `fwf_budget_writer_start` in lib.sh
/// actually arms the enforcement loop) must be VISIBLY off, not silently off.
/// Mirrors `_fwf_usage_budget_line` in fwf-usage.sh exactly (same wording),
/// so the CLI and the dash Usage tab read as one system to an operator
/// comparing them.
#[derive(Debug, Clone, Default)]
pub struct BudgetStatus {
    /// `$FWF_TOKEN_BUDGET` — None when unset/empty (unlimited, not armed).
    pub token_budget: Option<u64>,
    /// True only when a budget is configured AND the writer loop is alive
    /// for this profile (a real `kill -0` on the PID in
    /// `$FWF_STATE_DIR/budget-writer.pid` — see `resolve_budget_status()` /
    /// `pid_alive()` in this module).
    pub armed: bool,
    /// First line of `$BUDGET_HOLD_FILE`, if that sentinel exists. Its
    /// exact text (HOLD / WARN / UNKNOWN — FAIL-CLOSED) is written only by
    /// the bash WRITER (fwf-budget-check.sh) and passed through verbatim —
    /// this must never be reworded, since the HOLD/FAIL-CLOSED distinction
    /// is load-bearing for the incident protocol (an operator must never
    /// confuse "reader broke" with "I blew my budget").
    pub hold_line: Option<String>,
}

impl BudgetStatus {
    /// Mirrors `_fwf_usage_budget_line`'s "budget enforcement: …" line in
    /// fwf-usage.sh verbatim (down to the wording of each of the three
    /// cases), so the CLI and the dash tab are textually consistent.
    pub fn enforcement_line(&self) -> String {
        match self.token_budget {
            None => {
                "budget enforcement: NOT ARMED (no FWF_TOKEN_BUDGET configured — unlimited)"
                    .to_string()
            }
            Some(n) if self.armed => format!("budget enforcement: ARMED (ceiling {n} tokens)"),
            Some(n) => format!(
                "budget enforcement: NOT ARMED — FWF_TOKEN_BUDGET={n} is set, but the writer is not running for this profile (re-run 'fwf up' to arm it)"
            ),
        }
    }

    /// Mirrors `_fwf_usage_budget_line`'s "hold state: …" line verbatim.
    pub fn hold_status_line(&self) -> String {
        match &self.hold_line {
            Some(l) => format!("hold state: {l}"),
            None => "hold state: none".to_string(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct UsageRole {
    pub role: String,
    /// "fresh" | "stale" | "unknown" — see fwf-usage-data.sh for the exact
    /// semantics (unknown = never successfully read; stale = a prior good
    /// read exists but this poll couldn't refresh it).
    pub state: String,
    #[serde(default)]
    pub age_secs: Option<i64>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub tokens: UsageTokens,
    #[serde(default)]
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Copy, Deserialize, Default)]
pub struct UsageTokens {
    #[serde(default)]
    pub input: i64,
    #[serde(default)]
    pub cache_creation: i64,
    #[serde(default)]
    pub cache_read: i64,
    #[serde(default)]
    pub output: i64,
}

#[derive(Debug, Clone, Copy, Deserialize, Default)]
pub struct UsageTotals {
    #[serde(default)]
    pub tokens: UsageTokens,
    #[serde(default)]
    pub cost_usd: f64,
}

/// Run the usage provider and parse one snapshot. `$FWF_USAGE_DATA` is set by
/// the `fwf dash` wrapper alongside `$FWF_DASH_DATA`.
pub fn fetch_usage() -> Result<UsageData, String> {
    let script = std::env::var("FWF_USAGE_DATA")
        .map_err(|_| "FWF_USAGE_DATA is not set (run via `fwf dash`)".to_string())?;
    let out = Command::new("bash")
        .arg(&script)
        .output()
        .map_err(|e| format!("could not run the usage provider: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "usage provider exited {}: {}",
            out.status.code().unwrap_or(-1),
            err.trim()
        ));
    }
    let mut data = parse_usage(&out.stdout)?;
    data.budget = resolve_budget_status();
    Ok(data)
}

pub fn parse_usage(bytes: &[u8]) -> Result<UsageData, String> {
    serde_json::from_slice::<UsageData>(bytes)
        .map_err(|e| format!("could not parse usage JSON: {e}"))
}

/// Resolve the #96 budget-enforcement status by reading env vars + the
/// WRITER's own sentinel files directly — read-only; dash must never write
/// `$BUDGET_HOLD_FILE` or the PID file, only the bash WRITER
/// (fwf-budget-check.sh) does.
///
/// `$FWF_TOKEN_BUDGET` is read from dash's own process env, exactly like
/// `_fwf_usage_budget_line` in fwf-usage.sh reads it from its own invocation
/// — both surfaces share the same known limitation (a budget exported in one
/// shell is invisible to a `fwf dash` started from a different shell/tab
/// that never re-exported it); that is the accepted #96 design already
/// shipped on the bash side, not something to paper over here.
///
/// `$FWF_RUN`/`$FWF_STATE_DIR`/`$BUDGET_HOLD_FILE` are plain shell variables
/// in lib.sh/config.sh, never `export`ed — so they are not in dash's env
/// either. Recomputed here with the exact same fallback formula config.sh
/// uses (`$FWF_RUN_DIR` env var, else `$HOME/.fun-with-friends`) plus
/// `$FWF_PROFILE`, which IS inherited (the `fwf` dispatcher exports it, then
/// `exec`s all the way down to this binary without ever unsetting it).
fn resolve_budget_status() -> BudgetStatus {
    let token_budget = std::env::var("FWF_TOKEN_BUDGET")
        .ok()
        .filter(|s| !s.is_empty())
        .and_then(|s| s.parse::<u64>().ok());

    let fwf_run = std::env::var("FWF_RUN_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_default();
            format!("{home}/.fun-with-friends")
        });
    let profile = std::env::var("FWF_PROFILE").unwrap_or_default();

    let armed = token_budget.is_some()
        && !profile.is_empty()
        && pid_alive(&format!("{fwf_run}/state/{profile}/budget-writer.pid"));

    let hold_line = std::fs::read_to_string(format!("{fwf_run}/BUDGET_HOLD"))
        .ok()
        .and_then(|s| s.lines().next().map(str::to_string));

    BudgetStatus {
        token_budget,
        armed,
        hold_line,
    }
}

/// True iff `pid_file` holds a PID whose process is currently alive, checked
/// via `kill -0` — the exact same liveness check `fwf_budget_writer_running`
/// in lib.sh uses. A plain shell-out to the ubiquitous `kill` utility (dash
/// already shells out to bash for its data providers) rather than a new
/// `libc`/`nix` crate dependency, since this is the only caller that would
/// need one.
fn pid_alive(pid_file: &str) -> bool {
    let pid = match std::fs::read_to_string(pid_file) {
        Ok(s) => s.trim().to_string(),
        Err(_) => return false,
    };
    if pid.is_empty() || pid.parse::<i64>().is_err() {
        return false;
    }
    std::process::Command::new("kill")
        .arg("-0")
        .arg(&pid)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Fetch ONE issue/decision's full thread (body + comments) as plain text for the
/// detail pane. Lazy: called only for the selected row, off the per-tick board
/// fetch, so a freshly-posted comment appears the moment the dash re-requests it.
pub fn fetch_detail(id: &str) -> Result<String, String> {
    let script = std::env::var("FWF_DASH_DATA")
        .map_err(|_| "FWF_DASH_DATA is not set (run via `fwf dash`)".to_string())?;
    let out = Command::new("bash")
        .arg(&script)
        .arg("detail")
        .arg(id)
        .output()
        .map_err(|e| format!("could not run the detail provider: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "detail provider exited {}",
            out.status.code().unwrap_or(-1)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Parse a dashboard snapshot from provider stdout (split out so it is unit-testable
/// without spawning bash).
pub fn parse(bytes: &[u8]) -> Result<Dashboard, String> {
    serde_json::from_slice::<Dashboard>(bytes)
        .map_err(|e| format!("could not parse dashboard JSON: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r##"{
        "profile":"myapp","template":"dev","parked":true,
        "prod":"v0.16.0 ✓","pipeline":"staging +3 ahead","stamp":"status.json",
        "generated_at":"12:04:31",
        "roles":[{"role":"impl1","state":"live","detail":"#441 auth"},
                 {"role":"qa1","state":"down","detail":""}],
        "decisions":[{"id":"384","title":"un-gate: KB","flags":"GV ✓✓ · captain: ship","body":"Merge."}],
        "issues":[{"number":40,"title":"fwf dash","gated":false,"body":"Why\nShape"}]
    }"##;

    #[test]
    fn parses_a_full_snapshot() {
        let d = parse(SAMPLE.as_bytes()).expect("parse");
        assert_eq!(d.profile, "myapp");
        assert!(d.parked);
        assert_eq!(d.stamp, "status.json");
        assert_eq!(d.roles.len(), 2);
        assert_eq!(d.roles[0].state, "live");
        assert_eq!(d.decisions.len(), 1);
        assert_eq!(d.decisions[0].id, "384");
        assert_eq!(d.issues[0].number, 40);
    }

    #[test]
    fn tolerates_missing_optional_fields() {
        let d = parse(br#"{"profile":"p","template":"dev","prod":"-","pipeline":"-","stamp":"derived","generated_at":"00:00:00"}"#)
            .expect("parse");
        assert!(d.roles.is_empty());
        assert!(d.decisions.is_empty());
        assert!(!d.parked);
    }

    #[test]
    fn reports_bad_json() {
        assert!(parse(b"not json").is_err());
    }

    #[test]
    fn parses_floor_idle() {
        let d = parse(br#"{"profile":"p","template":"dev","prod":"-","pipeline":"-","stamp":"derived","generated_at":"00:00:00",
            "floor_idle":{"active":true,"since":"2026-01-01T00:00:00Z","reason":"queue empty; nothing in flight","actor":"captain"}}"#)
            .expect("parse");
        assert!(d.floor_idle.active);
        assert_eq!(d.floor_idle.actor, "captain");
        assert_eq!(d.floor_idle.reason, "queue empty; nothing in flight");
    }

    #[test]
    fn activity_flat_orders_building_intest_merged_tomain() {
        let mk = |pr: i64| ActivityItem {
            pr,
            role: String::new(),
            issue: String::new(),
            base: String::new(),
            checks: String::new(),
            when: String::new(),
            title: String::new(),
        };
        let a = Activity {
            building: vec![mk(1)],
            in_test: vec![mk(2)],
            merged: vec![mk(3)],
            to_main: vec![mk(4)],
        };
        assert_eq!(a.len(), 4);
        assert!(!a.is_empty());
        let order: Vec<i64> = a.flat().iter().map(|x| x.pr).collect();
        assert_eq!(order, vec![1, 2, 3, 4]);
    }

    const USAGE_SAMPLE: &str = r##"{
        "generated_at":"2026-07-11T01:00:00Z",
        "caveat":"estimated $ equivalent — not your account's actual rolling-window usage",
        "roles":[
            {"role":"impl1","state":"fresh","age_secs":0,"model":"claude-sonnet-5",
             "tokens":{"input":310,"cache_creation":50,"cache_read":40,"output":65},"cost_usd":0.001403},
            {"role":"qa1","state":"stale","age_secs":240,"model":"claude-sonnet-5",
             "tokens":{"input":100,"cache_creation":0,"cache_read":0,"output":10},"cost_usd":0.0002},
            {"role":"pm","state":"unknown","age_secs":null,"model":null,
             "tokens":{"input":0,"cache_creation":0,"cache_read":0,"output":0},"cost_usd":null}
        ],
        "total":{"tokens":{"input":410,"cache_creation":50,"cache_read":40,"output":75},"cost_usd":0.001603}
    }"##;

    #[test]
    fn parses_usage_snapshot_all_three_states() {
        let u = parse_usage(USAGE_SAMPLE.as_bytes()).expect("parse");
        assert_eq!(u.roles.len(), 3);
        assert_eq!(u.roles[0].state, "fresh");
        assert_eq!(u.roles[0].tokens.input, 310);
        assert_eq!(u.roles[0].cost_usd, Some(0.001403));
        assert_eq!(u.roles[1].state, "stale");
        assert_eq!(u.roles[1].age_secs, Some(240));
        assert_eq!(u.roles[2].state, "unknown");
        assert_eq!(u.roles[2].model, None);
        assert_eq!(u.roles[2].cost_usd, None); // never a false $0
        assert_eq!(u.total.tokens.input, 410);
        assert!(u
            .caveat
            .contains("not your account's actual rolling-window usage"));
    }

    #[test]
    fn usage_reports_bad_json() {
        assert!(parse_usage(b"not json").is_err());
    }

    #[test]
    fn usage_tolerates_missing_optional_fields() {
        let u = parse_usage(br#"{"generated_at":"x","caveat":"c"}"#).expect("parse");
        assert!(u.roles.is_empty());
        assert_eq!(u.total.cost_usd, 0.0);
    }

    #[test]
    fn parsed_usage_json_never_carries_a_budget_status() {
        // BudgetStatus is deliberately NOT part of the bash provider's JSON
        // (fwf-usage-data.sh stays #95-only/read-only) — it must come back
        // at its Default (not armed, no hold) from parse_usage alone; only
        // fetch_usage() (untested here — it shells out + touches the real
        // filesystem, same as fetch()) fills it in via resolve_budget_status.
        let u = parse_usage(USAGE_SAMPLE.as_bytes()).expect("parse");
        assert_eq!(u.budget.token_budget, None);
        assert!(!u.budget.armed);
        assert_eq!(u.budget.hold_line, None);
    }

    // --- BudgetStatus text (issue #96, Ticket B — the GV-signoff residual-risk
    // fix): these three cases must mirror `_fwf_usage_budget_line` in
    // fwf-usage.sh verbatim, and a HOLD/WARN/FAIL-CLOSED hold_line must never
    // get reworded or collapsed into another case — that distinction is
    // load-bearing for the incident protocol.

    #[test]
    fn budget_status_no_budget_configured_is_not_armed() {
        let b = BudgetStatus::default();
        assert_eq!(
            b.enforcement_line(),
            "budget enforcement: NOT ARMED (no FWF_TOKEN_BUDGET configured — unlimited)"
        );
        assert_eq!(b.hold_status_line(), "hold state: none");
    }

    #[test]
    fn budget_status_configured_and_writer_alive_is_armed_with_ceiling() {
        let b = BudgetStatus {
            token_budget: Some(500_000),
            armed: true,
            hold_line: None,
        };
        assert_eq!(
            b.enforcement_line(),
            "budget enforcement: ARMED (ceiling 500000 tokens)"
        );
    }

    #[test]
    fn budget_status_configured_but_writer_not_running_is_not_armed() {
        let b = BudgetStatus {
            token_budget: Some(500_000),
            armed: false,
            hold_line: None,
        };
        assert_eq!(
            b.enforcement_line(),
            "budget enforcement: NOT ARMED — FWF_TOKEN_BUDGET=500000 is set, but the writer is not running for this profile (re-run 'fwf up' to arm it)"
        );
    }

    #[test]
    fn budget_status_hold_warn_and_failclosed_render_distinct_never_confused() {
        let hold = BudgetStatus {
            token_budget: Some(100),
            armed: true,
            hold_line: Some(
                "HOLD — 120 tokens spent, budget is 100 — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold"
                    .to_string(),
            ),
        };
        let warn = BudgetStatus {
            token_budget: Some(100),
            armed: true,
            hold_line: Some(
                "WARN — 85 tokens spent, budget is 100 (80% warn threshold) — not paused"
                    .to_string(),
            ),
        };
        let fail_closed = BudgetStatus {
            token_budget: Some(100),
            armed: true,
            hold_line: Some(
                "UNKNOWN — FAIL-CLOSED: could not read usage ... NOT over budget — lift: fwf usage --clear-hold"
                    .to_string(),
            ),
        };

        assert!(hold.hold_status_line().starts_with("hold state: HOLD —"));
        assert!(warn.hold_status_line().starts_with("hold state: WARN —"));
        assert!(fail_closed
            .hold_status_line()
            .starts_with("hold state: UNKNOWN — FAIL-CLOSED"));

        // The three must never collapse into each other's wording.
        let lines = [
            hold.hold_status_line(),
            warn.hold_status_line(),
            fail_closed.hold_status_line(),
        ];
        assert!(!lines[0].contains("WARN") && !lines[0].contains("FAIL-CLOSED"));
        assert!(!lines[1].contains("HOLD —") && !lines[1].contains("FAIL-CLOSED"));
        assert!(!lines[2].contains("HOLD —") && !lines[2].contains("WARN —"));
    }
}
