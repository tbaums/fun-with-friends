//! T-29 — convert a v0.42 profile (`profiles/<name>.sh`, a bash file of
//! `VAR="${FWF_VAR:-default}"` lines) into a 1.0 manifest. No bash is run:
//! the file is parsed as text, `${FWF_X:-default}` yields `default`, and
//! anything the parser cannot read is left out with a comment, never guessed.
//!
//! What changes shape on the way over:
//! - three branches (staging → integration → main) become two: the base is
//!   `STAGING_BRANCH`, the release branch is `DEFAULT_BRANCH`, integration is
//!   dropped (1.0 promotes after a gate, so the middle branch has no job).
//! - `GATE_CMD` → `[suites] fast`, `E2E_CMD` → `[suites] e2e`; `BUILD_CMD`,
//!   `DEV_UI_HINT`, UT_* and WT_* have no 1.0 equivalent.
//! - `FWF_MODEL*` → `[models]` with the short names the CLI accepts.

use std::collections::BTreeMap;

#[derive(Debug, Default, PartialEq)]
pub struct Profile {
    pub vars: BTreeMap<String, String>,
    pub unparsed: Vec<String>,
}

/// Unwrap `"${FWF_X:-default}"` → `default`, strip one layer of quotes, and
/// drop a trailing `# comment` outside quotes.
fn value(raw: &str) -> Option<(String, bool)> {
    let s = raw.trim();
    let (quote, inner) = match s.chars().next()? {
        '"' => ('"', &s[1..]),
        '\'' => ('\'', &s[1..]),
        _ => ('\0', s),
    };
    let body = if quote == '\0' {
        inner.split('#').next()?.trim().to_string()
    } else {
        let end = inner.find(quote)?;
        inner[..end].to_string()
    };
    if let Some(rest) = body.strip_prefix("${") {
        let rest = rest.strip_suffix('}')?;
        return rest.split_once(":-").map(|(_, d)| (d.to_string(), false));
    }
    // Single quotes are literal shell text: a `$` inside them is the gate
    // command's own, expanded later by the gate's bash, so it is kept.
    Some((body, quote == '\''))
}

pub fn parse(text: &str) -> Profile {
    let mut p = Profile::default();
    for line in text.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        let l = l.strip_prefix("export ").unwrap_or(l);
        let Some((k, v)) = l.split_once('=') else {
            continue;
        };
        let k = k.trim();
        if k.is_empty()
            || !k
                .chars()
                .all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit())
        {
            continue;
        }
        match value(v) {
            Some((val, literal)) if literal || !val.contains('$') => {
                p.vars.insert(k.to_string(), val);
            }
            _ => p.unparsed.push(k.to_string()),
        }
    }
    p
}

fn short_model(m: &str) -> String {
    let m = m.trim();
    for s in ["opus", "sonnet", "haiku"] {
        if m.contains(s) {
            return s.to_string();
        }
    }
    m.to_string()
}

fn toml_str(s: &str) -> String {
    if s.contains('\'') {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        format!("'{s}'")
    }
}

/// Render the manifest. `repo` is `owner/name` (a profile only knows a local
/// path, so the caller passes it). Missing pieces become commented lines.
pub fn to_manifest(p: &Profile, repo: &str, session: &str) -> String {
    let g = |k: &str| p.vars.get(k).map(String::as_str);
    let mut out = String::new();
    out.push_str("# fwf 1.0 manifest converted from a v0.42 profile by `fwfd init-manifest --from-profile`.\n");
    out.push_str("# Scalars first; tables ([suites], [models]) last.\n");
    out.push_str(&format!("repo = \"{repo}\"\n"));
    out.push_str(&format!(
        "base_branch = \"{}\"\n",
        g("STAGING_BRANCH").unwrap_or("staging")
    ));
    out.push_str(&format!(
        "release_branch = \"{}\"\n",
        g("DEFAULT_BRANCH").unwrap_or("main")
    ));
    if let Some(i) = g("INTEGRATION_BRANCH") {
        out.push_str(&format!(
            "# integration branch {i:?} dropped: 1.0 promotes base → release after a gate\n"
        ));
    }
    out.push_str("gate_label = \"product-wip\"\nowner_only = true\n");
    let pairs = g("FWF_PAIRS")
        .and_then(|s| s.parse::<u8>().ok())
        .unwrap_or(1)
        .clamp(1, 8);
    out.push_str(&format!("pairs = {pairs}\n"));
    out.push_str(&format!("session = \"{session}\"\n"));
    let has_e2e = g("E2E_CMD").is_some_and(|c| c != "true" && !c.is_empty());
    out.push_str("fast_suite = \"fast\"\n");
    out.push_str(&format!(
        "promote_suite = \"{}\"\n",
        if has_e2e { "e2e" } else { "fast" }
    ));
    out.push_str("gate_venue = \"local\"\ngate_memory_gb = 8\ngate_timeout_secs = 1800\njob_timeout_secs = 1800\npoll_interval_secs = 60\npark_at_weekly_pct = 85\ntemplate = \"dev\"\n");
    out.push_str(
        "issues = []  # fill in before the first run: fwfd run refuses an empty allow-list\n",
    );
    for k in [
        "BUILD_CMD",
        "DEV_UI_HINT",
        "E2E_SETUP_CMD",
        "UT_APP_URL",
        "UT_BROWSER",
        "WT_PREFIX",
        "WT_BASE",
        "FWF_MIN_FREE_GB",
    ] {
        if p.vars.contains_key(k) {
            out.push_str(&format!("# {k} has no 1.0 equivalent (dropped)\n"));
        }
    }
    for k in &p.unparsed {
        out.push_str(&format!(
            "# {k}: could not be read without running bash (left out, not guessed)\n"
        ));
    }
    out.push_str("\n[suites]\n");
    match g("GATE_CMD") {
        Some(c) if !c.is_empty() => out.push_str(&format!("fast = {}\n", toml_str(c))),
        _ => out.push_str("fast = \"true\"  # GATE_CMD missing: replace before the first run\n"),
    }
    if has_e2e {
        out.push_str(&format!("e2e = {}\n", toml_str(g("E2E_CMD").unwrap_or(""))));
    }
    out.push_str("\n[models]\n");
    let base = g("FWF_MODEL")
        .map(short_model)
        .unwrap_or_else(|| "opus".into());
    out.push_str(&format!("impl = \"{base}\"\nqa = \"{base}\"\n"));
    out.push_str(&format!(
        "pm = \"{}\"\n",
        g("FWF_MODEL_PM")
            .map(short_model)
            .unwrap_or_else(|| "sonnet".into())
    ));
    out.push_str(&format!(
        "gv = \"{}\"\n",
        g("FWF_MODEL_GV")
            .map(short_model)
            .unwrap_or_else(|| "haiku".into())
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    const FWF: &str = r#"
FWF_REPO="${FWF_REPO:-$HOME/fwf-factory}"   # isolated dev clone
WT_PREFIX="${FWF_WT_PREFIX:-fwf}"
STAGING_BRANCH="${FWF_STAGING_BRANCH:-staging}"
INTEGRATION_BRANCH="${FWF_INTEGRATION_BRANCH:-integration}"
DEFAULT_BRANCH="${FWF_DEFAULT_BRANCH:-main}"   # released by a SEPARATE session
FWF_MODEL="${FWF_MODEL:-claude-sonnet-5}"
FWF_MODEL_PM="${FWF_MODEL_PM:-claude-opus-5}"
FWF_PAIRS="${FWF_PAIRS:-2}"
export FWF_MIN_FREE_GB=25
GATE_CMD='shellcheck -s bash -S warning fwf *.sh && bash test/run.sh'
E2E_CMD='mkdir -p "${TMPDIR:-/tmp}/x" && bash test/run.sh'
SOMETHING="$(uname)"
"#;

    #[test]
    fn parses_defaults_and_leaves_bash_alone() {
        let p = parse(FWF);
        assert_eq!(p.vars["STAGING_BRANCH"], "staging");
        assert_eq!(p.vars["FWF_PAIRS"], "2");
        assert_eq!(p.vars["FWF_MIN_FREE_GB"], "25");
        assert!(p.vars["GATE_CMD"].starts_with("shellcheck"));
        assert!(
            !p.vars.contains_key("FWF_REPO"),
            "a $HOME default is not a value"
        );
        assert!(p.unparsed.contains(&"FWF_REPO".to_string()));
        assert!(p.unparsed.contains(&"SOMETHING".to_string()));
    }

    #[test]
    fn converted_manifest_validates_and_maps_the_shape() {
        let p = parse(FWF);
        let text = to_manifest(&p, "tbaums/fun-with-friends", "fwf-one");
        let m = Manifest::parse(&text).unwrap_or_else(|e| panic!("{e}\n{text}"));
        assert_eq!(m.base_branch, "staging");
        assert_eq!(m.release_branch, "main");
        assert_eq!(m.pairs, 2);
        assert_eq!(m.promote_suite, "e2e");
        assert!(m.suites["fast"].starts_with("shellcheck"));
        assert!(
            m.suites["e2e"].contains("${TMPDIR:-/tmp}/x"),
            "shell text survives verbatim"
        );
        assert_eq!(m.models["impl"], "sonnet");
        assert_eq!(m.models["pm"], "opus");
        assert_eq!(m.models["gv"], "haiku");
        assert!(text.contains("integration branch \"integration\" dropped"));
        assert!(text.contains("FWF_REPO: could not be read"));
        assert!(m.issues.is_empty());
    }

    #[test]
    fn empty_profile_still_yields_a_valid_manifest_with_placeholders() {
        let text = to_manifest(&parse(""), "o/r", "s");
        let m = Manifest::parse(&text).unwrap();
        assert_eq!(m.suites["fast"], "true");
        assert_eq!(m.promote_suite, "fast");
    }
}
