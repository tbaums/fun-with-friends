//! fwfd — the fwf 1.0 supervisor. M0 skeleton: the four state machines, the
//! event log, and `why`. No GitHub client, no seats, no gate runner yet.

// M0 only: the transitions and the appender have no caller until T-06/T-09
// land; they are exercised by the unit tests. Remove when the scheduler
// arrives so dead code becomes a build error again.
#![allow(dead_code)]

mod github;
mod log;
mod types;

use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage:
  fwfd why <pr> [--log PATH]   timeline of one PR from the run record (default ~/.fwf/run.jsonl)
  fwfd doctor                  mint a narrowed installation token per App in ~/.fwf/apps.toml
  fwfd probe <role> <api-path> GET an API path with that App's token; prints the status
  fwfd version";

fn default_log() -> PathBuf {
    std::env::var_os("FWF_RUN_LOG")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".fwf/run.jsonl")))
        .unwrap_or_else(|| PathBuf::from("run.jsonl"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version") => {
            println!("fwfd {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("doctor") => {
            println!("fwfd {} (M0)", env!("CARGO_PKG_VERSION"));
            println!("  types      : Issue / Pr / Seat / Gate state machines with typed refusals");
            println!(
                "  event log  : append+fsync JSONL, read, `why <pr>` at {}",
                default_log().display()
            );
            println!("  not yet    : ETag client, seat waker, gate runner, promoter");
            let path = github::apps_path();
            let apps = match github::load_apps(&path) {
                Ok(a) => a,
                Err(e) => {
                    println!("  apps       : {e}");
                    return ExitCode::from(1);
                }
            };
            let mut bad = 0;
            for (name, entry) in &apps.0 {
                let narrow = std::collections::BTreeMap::from([("metadata", "read")]);
                match github::mint(entry, Some(&narrow)) {
                    Ok(t) => println!(
                        "  app {name:<5}: token minted (app {}, installation {}), expires {}, scopes {:?}",
                        entry.app_id,
                        entry.installation_id,
                        t.expires_at,
                        t.permissions.keys().collect::<Vec<_>>()
                    ),
                    Err(e) => {
                        bad += 1;
                        println!("  app {name:<5}: NOT USABLE — {e}");
                    }
                }
            }
            if bad == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(1)
            }
        }
        Some("probe") => {
            let (Some(role), Some(api_path)) = (args.get(1), args.get(2)) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd probe: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(entry) = apps.0.get(role) else {
                eprintln!("fwfd probe: no app named {role}");
                return ExitCode::from(2);
            };
            let tok = match github::mint(entry, None) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd probe: {e}");
                    return ExitCode::from(2);
                }
            };
            match github::get_status(&tok.token, api_path) {
                Ok((code, body)) => {
                    println!(
                        "{code} {}",
                        body.chars()
                            .take(200)
                            .collect::<String>()
                            .replace('\n', " ")
                    );
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd probe: {e}");
                    ExitCode::from(2)
                }
            }
        }
        Some("why") => {
            let Some(pr) = args
                .get(1)
                .and_then(|s| s.trim_start_matches('#').parse::<u64>().ok())
            else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let path = match args.iter().position(|a| a == "--log") {
                Some(i) => args
                    .get(i + 1)
                    .map(PathBuf::from)
                    .unwrap_or_else(default_log),
                None => default_log(),
            };
            let events = match log::read_all(&path) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("fwfd why: cannot read {}: {e}", path.display());
                    return ExitCode::from(2);
                }
            };
            let tl = log::why(&events, pr);
            if tl.is_empty() {
                println!("no events mention pr #{pr} in {}", path.display());
                return ExitCode::from(1);
            }
            print!("{}", log::render(&tl));
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}
