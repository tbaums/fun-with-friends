//! T-26 — job prompts per (template family, role), one job per wake.
//!
//! Repo-root `prompts/<family>/<role>-job.md`; a family that does not override a role
//! falls back to `dev`. Every file may use only the placeholders the
//! supervisor fills, checked by test so a typo never reaches a seat as
//! literal `{{FOO}}`.

use std::path::{Path, PathBuf};

/// Repo-root `prompts/`: the job prompts are the product's content, not a
/// crate detail (#605). Read from disk at runtime, not embedded at build time.
/// `one/prompts` stays as a symlink here for one release; this points past it
/// at the real directory so the two can never be read as different trees.
pub const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../prompts");
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
    "{{REVIEW}}",
    // Local HH:MM when this cycle's deadline falls, so a seat can cut a long
    // proof short instead of parking on it (#589).
    "{{DEADLINE}}",
];
pub const ROLES: &[&str] = &["impl", "qa", "gv", "pm"];

/// The impl seat's second pass over a PR QA refused (#576). Not a `<role>-job`
/// file: one role can be woken for more than one shape of job.
pub const REWORK: &str = "impl-rework.md";

/// The prompt file `name` under `family`, falling back to `dev`.
fn named(root: &Path, family: &str, name: &str) -> PathBuf {
    let p = root.join(family).join(name);
    if p.is_file() {
        p
    } else {
        root.join("dev").join(name)
    }
}

/// The prompt file for `role` under `family`, falling back to `dev`.
pub fn path(root: &Path, family: &str, role: &str) -> PathBuf {
    named(root, family, &format!("{role}-job.md"))
}

/// The rework job under `family`, falling back to `dev`.
pub fn rework_path(root: &Path, family: &str) -> PathBuf {
    named(root, family, REWORK)
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
            let jobs = ROLES
                .iter()
                .map(|r| path(root, f, r))
                .chain(std::iter::once(rework_path(root, f)));
            for p in jobs {
                assert!(
                    p.is_file(),
                    "{f}: {} has no file and no dev fallback",
                    p.display()
                );
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
                // #589: a seat that does not know when its cycle ends parks on
                // a long proof instead of cutting it short. Every job says so,
                // in the same words.
                assert!(
                    text.contains(
                        "Your job deadline is {{DEADLINE}}; push before it — a partial result beats a stall."
                    ),
                    "{}: no deadline line",
                    p.display()
                );
                // #590: the worktree's commit identity is the supervisor's to
                // set, so no job may tell a seat to set its own.
                assert!(
                    text.contains(
                        "Your worktree already commits as this seat (`git config user.*` is set for you; do not change it)."
                    ),
                    "{}: no commit-identity line",
                    p.display()
                );
                assert!(
                    !text.contains("git config user.name")
                        && !text.contains("git config user.email"),
                    "{}: tells the seat to set its own identity",
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

    /// #612: the guide beside the prompts documents every role and every
    /// placeholder, and nothing that does not exist. The old README listed 9
    /// placeholders while the code had 12, and a GV pass caught it describing a
    /// role and a `{{FENCE}}` token that were never real — a guide drifts
    /// silently because nothing reads it. This reads it.
    #[test]
    fn guide_covers_every_role_and_placeholder() {
        let p = Path::new(ROOT).join("README.md");
        let text = std::fs::read_to_string(&p).unwrap();
        for r in ROLES {
            assert!(
                text.contains(&format!("### {r}")),
                "{}: no section for the `{r}` role",
                p.display()
            );
        }
        for ph in PLACEHOLDERS {
            assert!(
                text.contains(ph),
                "{}: placeholder {ph} is not documented",
                p.display()
            );
        }
        // The other direction: a token the supervisor does not fill must not be
        // described as one it does.
        assert_eq!(
            unknown_placeholders(&text),
            Vec::<String>::new(),
            "{}: documents a placeholder that does not exist",
            p.display()
        );
        // The rework job is impl's second job shape (#576), not a fifth role.
        assert!(
            text.contains(REWORK),
            "{}: the rework job is not documented",
            p.display()
        );
    }

    /// #589: every module that renders a job template substitutes the deadline.
    /// Those renders sit inside GitHub-dependent cycles, so the guard is on the
    /// source itself: a caller that forgot it would paste the literal
    /// placeholder into a seat, which is what this placeholder must never be.
    #[test]
    fn every_job_renderer_fills_the_deadline() {
        for m in ["slice", "qa", "spec", "triage", "rework"] {
            let src = std::fs::read_to_string(format!("{}/src/{m}.rs", env!("CARGO_MANIFEST_DIR")))
                .unwrap();
            assert!(
                src.contains("\"{{DEADLINE}}\""),
                "{m}.rs renders a job without filling the deadline placeholder"
            );
        }
    }

    #[test]
    fn fallback_goes_to_dev_and_unknown_placeholders_are_named() {
        let p = path(Path::new(ROOT), "refactor", "gv");
        assert!(p.ends_with("dev/gv-job.md"));
        let p = path(Path::new(ROOT), "no-such-family", "impl");
        assert!(p.ends_with("dev/impl-job.md"));
        // no family overrides the rework job yet; every one resolves to dev's
        let p = rework_path(Path::new(ROOT), "refactor");
        assert!(p.ends_with("dev/impl-rework.md"), "{}", p.display());
        assert!(std::fs::read_to_string(&p).unwrap().contains("{{REVIEW}}"));
        assert_eq!(
            unknown_placeholders("a {{SEAT}} b {{NOPE}} c {{NOPE}} {{BASE}}"),
            vec!["{{NOPE}}".to_string()]
        );
    }
}
