//! `fwf doctor` — what this floor can and cannot do right now. Split out of
//! `verbs.rs` to keep that file inside the 1,000-line rule (T-30) when #653
//! gave doctor the release line.

use super::{get, identity_report};
use crate::{default_log, github, manifest, upgrade};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// `fwf doctor [--manifest PATH]`: what this floor can and cannot do right
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
    println!("{}", upgrade::check_release().line());
    println!(
        "  event log  : append+fsync JSONL, read, `why <pr>` at {}",
        default_log().display()
    );
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
