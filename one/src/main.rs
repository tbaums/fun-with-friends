//! fwfd — the fwf 1.0 supervisor. M0 skeleton: the four state machines, the
//! event log, and `why`. No GitHub client, no seats, no gate runner yet.

// M0 only: the transitions and the appender have no caller until T-06/T-09
// land; they are exercised by the unit tests. Remove when the scheduler
// arrives so dead code becomes a build error again.
#![allow(dead_code)]

#[cfg(test)]
mod fake_github;
mod github;
mod log;
mod mirror;
mod poll;
mod sched;
mod seat;
mod slice;
mod types;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

const USAGE: &str = "usage:
  fwfd why <pr> [--log PATH]   timeline of one PR from the run record (default ~/.fwf/run.jsonl)
  fwfd doctor                  mint a narrowed installation token per App in ~/.fwf/apps.toml
  fwfd probe <role> <api-path> GET an API path with that App's token; prints the status
  fwfd mirror-init --repo o/r [--floor DIR]   create/refresh the local bare mirror and print the seat remote URL
  fwfd slice --repo o/r --issue N --seat tmux-target [--expect claude|bash] [--floor DIR] [--base staging] [--timeout SECS] [--dry-run]
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
        Some("mirror-init") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let Some(repo) = get("--repo") else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let name = repo.rsplit('/').next().unwrap_or("repo").to_string();
            let floor = get("--floor").map(PathBuf::from).unwrap_or_else(|| {
                std::env::var_os("HOME")
                    .map(|h| PathBuf::from(h).join(".fwf/floors").join(&name))
                    .unwrap_or_else(|| PathBuf::from("floor"))
            });
            let (_, mirror_dir) = slice::defaults(&floor);
            match mirror::Mirror::init(&mirror_dir, &format!("https://github.com/{repo}.git"))
                .and_then(|m| m.fetch().map(|_| m))
            {
                Ok(m) => {
                    println!("{}", m.seat_remote_url());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd mirror-init: {e}");
                    ExitCode::from(1)
                }
            }
        }
        Some("slice") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(issue), Some(seat)) = (
                get("--repo"),
                get("--issue").and_then(|s| s.parse::<u64>().ok()),
                get("--seat"),
            ) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let Some((owner, name)) = repo.split_once('/') else {
                eprintln!("--repo must be owner/name");
                return ExitCode::from(2);
            };
            let floor = get("--floor").map(PathBuf::from).unwrap_or_else(|| {
                std::env::var_os("HOME")
                    .map(|h| PathBuf::from(h).join(".fwf/floors").join(name))
                    .unwrap_or_else(|| PathBuf::from("floor"))
            });
            let (run_log, mirror_dir) = slice::defaults(&floor);
            let cfg = slice::SliceConfig {
                owner: owner.to_string(),
                repo: name.to_string(),
                issue,
                base_branch: get("--base").unwrap_or_else(|| "staging".into()),
                gate_label: "product-wip".into(),
                seat_target: seat,
                seat_expect_cmd: get("--expect").unwrap_or_else(|| "claude".into()),
                floor_dir: floor.clone(),
                mirror_dir,
                job_template: PathBuf::from(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/prompts/impl-job.md"
                )),
                run_log,
                timeout: Duration::from_secs(
                    get("--timeout")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(1800),
                ),
                dry_run: args.iter().any(|a| a == "--dry-run"),
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd slice: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("impl") else {
                eprintln!("fwfd slice: no [impl] app in apps.toml");
                return ExitCode::from(2);
            };
            match slice::run(&cfg, app) {
                Ok(msg) => {
                    println!("{msg}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd slice: {}", e.0);
                    ExitCode::from(1)
                }
            }
        }
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}
