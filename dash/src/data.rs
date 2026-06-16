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
}

#[derive(Debug, Clone, Deserialize)]
pub struct Role {
    pub role: String,
    /// "live" | "idle" | "down"
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
        "profile":"transom","template":"dev","parked":true,
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
        assert_eq!(d.profile, "transom");
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
}
