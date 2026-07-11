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
    /// `fwf-down.sh --floor-only`, issue #85 — never a real crash)
    pub state: String,
    #[serde(default)]
    pub detail: String,
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
}
