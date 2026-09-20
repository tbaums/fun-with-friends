//! `fwf ungate --repo o/r --issue N --by NAME`: the human sign-off the planner
//! waits for (#630) — the gate label comes off under the ops App, and the
//! record gets the `Ready` event plus the `Human` line saying whose call it
//! was.
//!
//! Lifted out of `main.rs` verbatim by the size ratchet (T-30), which is what
//! `verbs.rs` exists for: `main.rs` is grandfathered at 920 lines and may only
//! shrink, and #688 added a verb to it. Behaviour is unchanged — the same
//! flags, the same refusals, the same exit codes. It sits beside
//! [`release`](super::release) because the two are the same shape: an
//! attributed human decision the loop cannot make for itself.

use crate::{github, slice, triage, USAGE};
use std::path::PathBuf;
use std::process::ExitCode;

pub fn verb(args: &[String]) -> ExitCode {
    let (Some(repo), Some(issue)) = (
        super::get(args, "--repo"),
        super::get(args, "--issue").and_then(|s| s.parse::<u64>().ok()),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let by = super::get(args, "--by")
        .unwrap_or_else(|| std::env::var("USER").unwrap_or_else(|_| "operator".into()));
    let Some((owner, name)) = repo.split_once('/') else {
        eprintln!("--repo must be owner/name");
        return ExitCode::from(2);
    };
    let floor = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".fwf/floors").join(name))
        .unwrap_or_else(|| PathBuf::from("floor"));
    let (run_log, _) = slice::defaults(&floor);
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwf ungate: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwf ungate: no [ops] app");
        return ExitCode::from(2);
    };
    match triage::ungate(
        owner,
        name,
        issue,
        "product-wip",
        triage::Ungate::Manual(&by),
        &run_log,
        ops,
    ) {
        Ok(()) => {
            println!("#{issue} un-gated by {by}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("fwf ungate: {}", e.0);
            ExitCode::from(1)
        }
    }
}
