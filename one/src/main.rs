//! fwfd — the fwf 1.0 supervisor. M0 skeleton: the four state machines, the
//! event log, and `why`. No GitHub client, no seats, no gate runner yet.

// M0 only: the transitions and the appender have no caller until T-06/T-09
// land; they are exercised by the unit tests. Remove when the scheduler
// arrives so dead code becomes a build error again.
#![allow(dead_code)]

mod log;
mod types;

use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage:
  fwfd why <pr> [--log PATH]   timeline of one PR from the run record (default ~/.fwf/run.jsonl)
  fwfd doctor                  print what this build can and cannot do yet
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
            println!("fwfd {} (M0 skeleton)", env!("CARGO_PKG_VERSION"));
            println!("  types      : Issue / Pr / Seat / Gate state machines with typed refusals");
            println!("  event log  : append+fsync JSONL, read, `why <pr>`");
            println!("  not yet    : GitHub client, App tokens, seat waker, gate runner, promoter");
            println!("  run record : {}", default_log().display());
            ExitCode::SUCCESS
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
