//! T-26 — job prompts per (template family, role), one job per wake.
//!
//! `prompts/<family>/<role>-job.md`; a family that does not override a role
//! falls back to `dev`. Every file may use only the placeholders the
//! supervisor fills, checked by test so a typo never reaches a seat as
//! literal `{{FOO}}`.

use std::path::{Path, PathBuf};

pub const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/prompts");
pub const PLACEHOLDERS: &[&str] = &[
    "{{SEAT}}",
    "{{REPO}}",
    "{{ISSUE}}",
    "{{TITLE}}",
    "{{BODY}}",
    "{{BRANCH}}",
    "{{PR}}",
    "{{HEAD}}",
    "{{BASE}}",
    "{{CHECK}}",
];
pub const ROLES: &[&str] = &["impl", "qa", "gv", "pm"];

/// The prompt file for `role` under `family`, falling back to `dev`.
pub fn path(root: &Path, family: &str, role: &str) -> PathBuf {
    let p = root.join(family).join(format!("{role}-job.md"));
    if p.is_file() {
        p
    } else {
        root.join("dev").join(format!("{role}-job.md"))
    }
}

pub fn job_path(family: &str, role: &str) -> PathBuf {
    path(Path::new(ROOT), family, role)
}

/// Placeholders used by a prompt text that are not in `PLACEHOLDERS`.
pub fn unknown_placeholders(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(i) = rest.find("{{") {
        let after = &rest[i..];
        match after.find("}}") {
            Some(j) => {
                let tok = &after[..j + 2];
                if !PLACEHOLDERS.contains(&tok) && !out.contains(&tok.to_string()) {
                    out.push(tok.to_string());
                }
                rest = &after[j + 2..];
            }
            None => break,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_family_resolves_every_role_and_uses_only_known_placeholders() {
        let root = Path::new(ROOT);
        let mut families: Vec<String> = std::fs::read_dir(root)
            .unwrap()
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        families.sort();
        assert!(families.contains(&"dev".to_string()));
        assert!(families.len() >= 7, "{families:?}");
        for f in &families {
            for r in ROLES {
                let p = path(root, f, r);
                assert!(p.is_file(), "{f}/{r}: no file and no dev fallback");
                let text = std::fs::read_to_string(&p).unwrap();
                assert!(
                    text.contains("exactly ONE"),
                    "{}: not a one-job prompt",
                    p.display()
                );
                assert!(
                    !text.contains("gh issue") && !text.contains("gh pr"),
                    "{}: tells the seat to use gh",
                    p.display()
                );
                assert!(
                    text.contains("\"verdict\":\"blocked\""),
                    "{}: no blocked verdict",
                    p.display()
                );
                assert_eq!(
                    unknown_placeholders(&text),
                    Vec::<String>::new(),
                    "{}",
                    p.display()
                );
            }
        }
    }

    #[test]
    fn fallback_goes_to_dev_and_unknown_placeholders_are_named() {
        let p = path(Path::new(ROOT), "refactor", "gv");
        assert!(p.ends_with("dev/gv-job.md"));
        let p = path(Path::new(ROOT), "no-such-family", "impl");
        assert!(p.ends_with("dev/impl-job.md"));
        assert_eq!(
            unknown_placeholders("a {{SEAT}} b {{NOPE}} c {{NOPE}} {{BASE}}"),
            vec!["{{NOPE}}".to_string()]
        );
    }
}
