//! `fwf doctor` — what this floor can and cannot do right now. Split out of
//! `verbs.rs` to keep that file inside the 1,000-line rule (T-30) when #653
//! gave doctor the release line.

use super::{get, identity_report, scripts};
use crate::{default_log, github, manifest, prompts, upgrade};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// `fwf doctor [--manifest PATH] [--assets]`: what this floor can and cannot do right
/// now. Every App's token is minted narrow (metadata:read) to prove the keys
/// work, and every worktree the manifest names is asked what it commits as
/// (#590). Read-only: a wrong identity is fixed by `fwf seats --up`.
/// Non-zero when an App is unusable or a worktree commits as the wrong seat.
///
/// The release line (#653) is a report, never a verdict: a devbox restored
/// from a snapshot has to be told it is behind, and a devbox that cannot reach
/// GitHub has to be told that instead — neither moves the exit code.
pub fn doctor(args: &[String]) -> ExitCode {
    println!("fwf {}", env!("CARGO_PKG_VERSION"));
    if args.iter().any(|a| a == "--assets") {
        return assets();
    }
    println!("{}", upgrade::check_release().line());
    println!(
        "  event log  : append+fsync JSONL, read, `why <pr>` at {}",
        default_log().display()
    );
    // #674: a release binary carries the seat scripts, so an absent or stale
    // `one/scripts/` on this host says nothing about whether seats can come up.
    println!("{}", scripts::doctor_line());
    let mut bad = 0;
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    match manifest::Manifest::load(&path) {
        Ok(m) => {
            let floor = m.floor();
            println!("  floor      : {} ({})", floor.display(), m.repo);
            println!("seat identity");
            let (lines, wrong) = identity_report(&floor, &m.seats());
            for l in lines {
                println!("{l}");
            }
            bad += wrong;
        }
        // No manifest is not a failure here: the Apps are still worth checking.
        Err(e) => println!("  floor      : no manifest ({e}); skipping seat identity"),
    }
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            println!("  apps       : {e}");
            return ExitCode::from(1);
        }
    };
    println!("apps");
    for (name, entry) in &apps.0 {
        let narrow = std::collections::BTreeMap::from([("metadata", "read")]);
        match github::mint(entry, Some(&narrow)) {
            Ok(t) => println!(
                "  {name:<10} token minted (app {}, installation {}), expires {}, scopes {:?}",
                entry.app_id,
                entry.installation_id,
                t.expires_at,
                t.permissions.keys().collect::<Vec<_>>()
            ),
            Err(e) => {
                bad += 1;
                println!("  {name:<10} NOT USABLE — {e}");
            }
        }
        // A token minted for a permission the installation lacks is refused, so
        // this asks without writing (#602); a repo with no workflows can ignore it.
        if name == "impl" || name == "ops" {
            let wf = [("workflows", "write"), ("metadata", "read")];
            if let Err(e) = github::mint(entry, Some(&wf.into_iter().collect())) {
                println!(
                    "  {name:<10} WARNING no `workflows: write` — a branch touching .github/workflows/ cannot be pushed ({e}); add the permission in the App's settings and re-accept it on the installation"
                );
            }
        }
    }
    if bad == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

/// `fwf doctor --assets` (#719): what this binary carries, checked where the
/// seats will read it. No manifest, no Apps, no network. Each job is resolved
/// the way a seat's is — under `$HOME/.fwf/prompts`, with the `dev` fallback —
/// and read back from there, so a binary that still pointed at a build tree
/// fails here and not in a seat. Exit 0 only when every job and both seat
/// scripts are non-empty and use no unknown placeholder.
fn assets() -> ExitCode {
    let dir = match prompts::dir() {
        Ok(d) => d,
        Err(e) => {
            println!("  prompts    : {e}");
            return ExitCode::from(1);
        }
    };
    println!("  prompts    : embedded, written to {}", dir.display());
    let (lines, bad) = assets_report(dir);
    for l in lines {
        println!("{l}");
    }
    if bad == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

/// One line per (family, job) and per seat script, and how many are wrong.
fn assets_report(dir: &Path) -> (Vec<String>, usize) {
    let mut jobs: Vec<(String, PathBuf)> = Vec::new();
    for f in prompts::families() {
        for r in prompts::ROLES {
            jobs.push((format!("{f} {r}"), prompts::path(dir, f, r)));
        }
        jobs.push((format!("{f} rework"), prompts::rework_path(dir, f)));
    }
    let mut out = Vec::new();
    let mut bad = 0;
    let mut line = |what: &str, shown: String, body: Result<String, String>| {
        let verdict = match &body {
            Err(e) => format!("UNREADABLE — {e}"),
            Ok(t) if t.trim().is_empty() => "EMPTY".to_string(),
            Ok(t) => match prompts::unknown_placeholders(t) {
                u if u.is_empty() => "ok".to_string(),
                u => format!("UNKNOWN PLACEHOLDERS {u:?}"),
            },
        };
        if verdict != "ok" {
            bad += 1;
        }
        let n = body.map(|t| t.len()).unwrap_or(0);
        out.push(format!("  {what:<22} {shown:<30} {n:>6} B  {verdict}"));
    };
    for (what, p) in &jobs {
        let shown = p.strip_prefix(dir).unwrap_or(p).display().to_string();
        line(
            what,
            shown,
            std::fs::read_to_string(p).map_err(|e| e.to_string()),
        );
    }
    for (name, body) in [
        ("seat-up.sh", scripts::SEAT_UP),
        ("seat-push-guard.sh", scripts::SEAT_PUSH_GUARD),
    ] {
        line(
            "seat script",
            format!("{name} (embedded)"),
            Ok(body.to_string()),
        );
    }
    (out, bad)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #719: every family resolves every job from the written-out copy, and a
    /// job that is missing, emptied or carries a stray placeholder is counted.
    #[test]
    fn assets_lists_every_job_and_both_scripts_and_counts_the_wrong_ones() {
        let home = std::env::temp_dir().join(format!("fwfd-assets-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let dir = prompts::materialise(&home).unwrap();

        let (lines, bad) = assets_report(&dir);
        assert_eq!(bad, 0, "{lines:#?}");
        let n = prompts::families().len();
        assert_eq!(
            lines.len(),
            n * (prompts::ROLES.len() + 1) + 2,
            "{lines:#?}"
        );
        assert!(lines
            .iter()
            .any(|l| l.contains("refactor gv") && l.contains("dev/gv-job.md")));
        assert!(lines
            .iter()
            .any(|l| l.contains("dev rework") && l.contains("dev/impl-rework.md")));
        assert!(lines.iter().any(|l| l.contains("seat-up.sh (embedded)")));
        assert!(lines
            .iter()
            .any(|l| l.contains("seat-push-guard.sh (embedded)")));

        std::fs::write(dir.join("dev/pm-job.md"), "  \n").unwrap();
        std::fs::write(dir.join("dev/qa-job.md"), "{{NOPE}}").unwrap();
        std::fs::remove_file(dir.join("dev/gv-job.md")).unwrap();
        let (lines, bad) = assets_report(&dir);
        // pm and qa are read by every family that does not override them
        assert!(bad >= 3, "{lines:#?}");
        assert!(lines
            .iter()
            .any(|l| l.contains("dev pm") && l.ends_with("EMPTY")));
        assert!(lines
            .iter()
            .any(|l| l.contains("dev qa") && l.contains("{{NOPE}}")));
        assert!(lines
            .iter()
            .any(|l| l.contains("dev gv") && l.contains("UNREADABLE")));
        let _ = std::fs::remove_dir_all(&home);
    }
}
