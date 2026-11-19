//! T-26 — job prompts per (template family, role), one job per wake.
//!
//! Repo-root `prompts/<family>/<role>-job.md`; a family that does not override a role
//! falls back to `dev`. Every file may use only the placeholders the
//! supervisor fills, checked by test so a typo never reaches a seat as
//! literal `{{FOO}}`.
//!
//! #719: the prompts ride inside the binary, as the seat scripts do (#674).
//! They used to be read from `CARGO_MANIFEST_DIR/../prompts`, a path `env!`
//! fixes when the binary is *built*, so a release asset looked for them under
//! `/home/runner/work/…` and every seat job on any other host failed with `No
//! such file or directory`. Now every file under `prompts/` is compiled in and,
//! once per process, written to `$HOME/.fwf/prompts/<family>/<file>`; the
//! readers keep taking a path, so tests that inject their own template still do.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The source tree's `prompts/`, for tests only: they check the files the table
/// is built from. Nothing at run time may read it (#719).
#[cfg(test)]
pub const SOURCE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../prompts");

/// `(path under prompts/, contents)` for every prompt file, as of the build.
/// A test fails when this and the files under `prompts/` differ in names or
/// bytes, so a new prompt cannot be added without a line here.
macro_rules! embed {
    ($($name:literal),* $(,)?) => {
        &[$(($name, include_str!(concat!("../../prompts/", $name)))),*]
    };
}
pub const EMBEDDED: &[(&str, &str)] = embed![
    "README.md",
    "stop.txt",
    "consulting/gv-job.md",
    "consulting/impl-job.md",
    "consulting/qa-job.md",
    "defect-report/impl-job.md",
    "defect-report/qa-job.md",
    "dev/gv-job.md",
    "dev/impl-job.md",
    "dev/impl-rework.md",
    "dev/pm-job.md",
    "dev/qa-job.md",
    "ideation/gv-job.md",
    "ideation/impl-job.md",
    "ideation/qa-job.md",
    "refactor/impl-job.md",
    "refactor/qa-job.md",
    "user-testing/impl-job.md",
    "user-testing/qa-job.md",
    "validate/gv-job.md",
    "validate/impl-job.md",
    "validate/qa-job.md",
];

/// The template families the binary carries: every directory in the table.
pub fn families() -> Vec<&'static str> {
    let mut f: Vec<&str> = EMBEDDED
        .iter()
        .filter_map(|(name, _)| name.split_once('/').map(|(fam, _)| fam))
        .collect();
    f.sort_unstable();
    f.dedup();
    f
}

/// Write every embedded prompt to `<home>/.fwf/prompts/`, each through a temp
/// file and a rename, so a reader never sees half a prompt and two processes
/// writing at once both leave the same bytes. A copy an older binary left, or
/// one edited by hand, is overwritten; a file the table does not name is
/// removed, because the `dev` fallback reads what is on disk and a stale
/// family override would otherwise still win.
pub fn materialise(home: &Path) -> io::Result<PathBuf> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let root = home.join(".fwf").join("prompts");
    for (name, body) in EMBEDDED {
        let dest = root.join(name);
        let dir = dest.parent().unwrap_or(&root);
        std::fs::create_dir_all(dir)?;
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = dir.join(format!(".fwf-{}-{n}.tmp", std::process::id()));
        std::fs::write(&tmp, body)?;
        std::fs::rename(&tmp, &dest)?;
    }
    prune(&root, &root)?;
    Ok(root)
}

/// Remove every file under `dir` the table does not name, one level of family
/// directories deep. Another writer's temp file is in flight, not stale.
fn prune(root: &Path, dir: &Path) -> io::Result<()> {
    for e in std::fs::read_dir(dir)?.flatten() {
        let p = e.path();
        if p.is_dir() {
            if dir == root {
                prune(root, &p)?;
            }
            continue;
        }
        let file = e.file_name().to_string_lossy().into_owned();
        let in_flight = file.starts_with(".fwf-") && file.ends_with(".tmp");
        let rel = p.strip_prefix(root).unwrap_or(&p);
        if !in_flight && !EMBEDDED.iter().any(|(name, _)| Path::new(name) == rel) {
            std::fs::remove_file(&p)?;
        }
    }
    Ok(())
}

/// `$HOME/.fwf/prompts`, written on first use and then reused for the life of
/// the process. With `HOME` unset this is an error naming `HOME`; there is no
/// fallback to a build path.
pub fn dir() -> Result<&'static Path, String> {
    static DIR: OnceLock<Result<PathBuf, String>> = OnceLock::new();
    DIR.get_or_init(|| {
        let home = std::env::var_os("HOME")
            .filter(|h| !h.is_empty())
            .ok_or_else(|| {
                "HOME is not set; fwf writes its job prompts under $HOME/.fwf/prompts".to_string()
            })?;
        materialise(Path::new(&home))
            .map_err(|e| format!("cannot write the job prompts under $HOME/.fwf/prompts: {e}"))
    })
    .as_deref()
    .map_err(Clone::clone)
}

/// [`dir`] for a verb that cannot start without its prompts: it says why on
/// stderr and exits 2 rather than wake a seat with a path that does not exist.
pub fn dir_or_exit() -> PathBuf {
    match dir() {
        Ok(d) => d.to_path_buf(),
        Err(e) => {
            eprintln!("fwf: {e}");
            std::process::exit(2);
        }
    }
}

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
    // GV's reason for refusing the previous spec at sign-off (#697); PM only.
    "{{GV_REFUSAL_REASON}}",
    // The issue's spec, read by the supervisor at QA dispatch (#713); QA only.
    "{{SPEC}}",
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
    path(&dir_or_exit(), family, role)
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
        let root = Path::new(SOURCE);
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
        let p = Path::new(SOURCE).join("README.md");
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

    /// #713: every family's QA job is given the spec and asks for the
    /// per-criterion list `qa::check_verdict` requires on an approval — a
    /// family whose prompt did not would have every approval refused.
    #[test]
    fn every_qa_job_carries_the_spec_and_asks_for_the_criteria() {
        for e in std::fs::read_dir(SOURCE).unwrap().flatten() {
            if !e.path().is_dir() {
                continue;
            }
            let f = e.file_name().to_string_lossy().into_owned();
            let p = path(Path::new(SOURCE), &f, "qa");
            let text = std::fs::read_to_string(&p).unwrap();
            for needle in [
                "{{SPEC}}",
                "EACH acceptance criterion",
                "\"criteria\":[{\"criterion\"",
                "met`, `not_met` or `not_verifiable`",
            ] {
                assert!(text.contains(needle), "{}: no {needle}", p.display());
            }
        }
    }

    #[test]
    fn fallback_goes_to_dev_and_unknown_placeholders_are_named() {
        let p = path(Path::new(SOURCE), "refactor", "gv");
        assert!(p.ends_with("dev/gv-job.md"));
        let p = path(Path::new(SOURCE), "no-such-family", "impl");
        assert!(p.ends_with("dev/impl-job.md"));
        // no family overrides the rework job yet; every one resolves to dev's
        let p = rework_path(Path::new(SOURCE), "refactor");
        assert!(p.ends_with("dev/impl-rework.md"), "{}", p.display());
        assert!(std::fs::read_to_string(&p).unwrap().contains("{{REVIEW}}"));
        assert_eq!(
            unknown_placeholders("a {{SEAT}} b {{NOPE}} c {{NOPE}} {{BASE}}"),
            vec!["{{NOPE}}".to_string()]
        );
    }
    /// #719: the table the binary carries is exactly the files under
    /// `prompts/` — same names, same bytes. A prompt added on disk but not to
    /// [`EMBEDDED`] would never reach a seat; one edited on disk would reach
    /// it only after a rebuild, which this makes the same thing.
    #[test]
    fn the_embedded_table_is_the_prompts_directory_byte_for_byte() {
        fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>) {
            for e in std::fs::read_dir(dir).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(root, &p, out);
                } else {
                    let rel = p.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                    out.push((rel, std::fs::read(&p).unwrap()));
                }
            }
        }
        let mut on_disk = Vec::new();
        walk(Path::new(SOURCE), Path::new(SOURCE), &mut on_disk);
        on_disk.sort();
        let mut embedded: Vec<(String, Vec<u8>)> = EMBEDDED
            .iter()
            .map(|(n, b)| (n.to_string(), b.as_bytes().to_vec()))
            .collect();
        embedded.sort();
        let names = |v: &[(String, Vec<u8>)]| v.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>();
        assert_eq!(names(&embedded), names(&on_disk), "names differ");
        for ((n, a), (_, b)) in embedded.iter().zip(&on_disk) {
            assert!(a == b, "{n}: embedded bytes differ from prompts/{n}");
        }
    }

    /// #719: written out under `<home>/.fwf/prompts`, read back byte for byte,
    /// with the `dev` fallback working there as it does in the source tree. A
    /// copy edited by hand is put back; a file the table does not name (a
    /// stale family override) is removed, or it would shadow `dev`.
    #[test]
    fn materialise_writes_every_prompt_under_home_and_heals_what_it_finds() {
        let home = std::env::temp_dir().join(format!("fwfd-prompts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let root = materialise(&home).unwrap();
        assert_eq!(root, home.join(".fwf/prompts"));
        for (name, body) in EMBEDDED {
            assert_eq!(
                std::fs::read_to_string(root.join(name)).unwrap(),
                *body,
                "{name}"
            );
        }
        assert!(path(&root, "refactor", "gv").ends_with("dev/gv-job.md"));
        assert!(rework_path(&root, "validate").ends_with("dev/impl-rework.md"));

        std::fs::write(root.join("dev/impl-job.md"), "edited by hand").unwrap();
        std::fs::write(root.join("refactor/gv-job.md"), "left by an older binary").unwrap();
        let in_flight = root.join("dev/.fwf-1-0.tmp");
        std::fs::write(&in_flight, "another writer").unwrap();
        materialise(&home).unwrap();
        let dev_impl = EMBEDDED
            .iter()
            .find(|(n, _)| *n == "dev/impl-job.md")
            .unwrap()
            .1;
        assert_eq!(
            std::fs::read_to_string(root.join("dev/impl-job.md")).unwrap(),
            dev_impl
        );
        assert!(!root.join("refactor/gv-job.md").exists());
        assert!(path(&root, "refactor", "gv").ends_with("dev/gv-job.md"));
        assert!(
            in_flight.exists(),
            "another process's temp file is not ours to remove"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn families_are_the_table_s_directories() {
        let f = families();
        assert!(f.contains(&"dev") && f.contains(&"refactor"), "{f:?}");
        assert!(f.len() >= 7, "{f:?}");
        assert!(!f.contains(&"README.md"), "{f:?}");
    }
}
