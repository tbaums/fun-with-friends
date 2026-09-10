//! Verb bodies moved out of main.rs (the size ratchet): spec, triage,
//! release-check, dash. Each takes the raw argv and returns the exit code.

use crate::{dash, github, log, prompts, seat, slice, spec, triage};
use crate::{default_log, USAGE};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

fn get(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1).cloned())
}

pub fn spec(args: &[String]) -> ExitCode {
    let (Some(repo), Some(issue), Some(seat)) = (
        get(args, "--repo"),
        get(args, "--issue").and_then(|s| s.parse::<u64>().ok()),
        get(args, "--seat"),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let Some((owner, name)) = repo.split_once('/') else {
        eprintln!("--repo must be owner/name");
        return ExitCode::from(2);
    };
    let floor = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".fwf/floors").join(name))
        .unwrap_or_else(|| PathBuf::from("floor"));
    let (run_log, _) = slice::defaults(&floor);
    let cfg = spec::SpecConfig {
        owner: owner.into(),
        repo: name.into(),
        issue,
        gate_label: "product-wip".into(),
        discovery_label: "discovery".into(),
        seat_target: seat,
        seat_expect_cmd: get(args, "--expect").unwrap_or_else(|| "claude".into()),
        floor_dir: floor,
        job_template: spec::default_template(
            &get(args, "--template").unwrap_or_else(|| "dev".into()),
        ),
        run_log,
        timeout: Duration::from_secs(
            get(args, "--timeout")
                .and_then(|s| s.parse().ok())
                .unwrap_or(900),
        ),
    };
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwfd spec: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwfd spec: no [ops] app");
        return ExitCode::from(2);
    };
    match spec::run(&cfg, ops) {
        Ok((title, questions)) => {
            println!("#{issue}: spec written — {title} ({} open question(s)); still gated, `fwfd ungate {issue}` to approve", questions.len());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("fwfd spec: {}", e.0);
            ExitCode::from(1)
        }
    }
}

pub fn triage(args: &[String]) -> ExitCode {
    let (Some(repo), Some(issue), Some(seat)) = (
        get(args, "--repo"),
        get(args, "--issue").and_then(|s| s.parse::<u64>().ok()),
        get(args, "--seat"),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let Some((owner, name)) = repo.split_once('/') else {
        eprintln!("--repo must be owner/name");
        return ExitCode::from(2);
    };
    let floor = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".fwf/floors").join(name))
        .unwrap_or_else(|| PathBuf::from("floor"));
    let (run_log, _) = slice::defaults(&floor);
    let cfg = triage::TriageConfig {
        owner: owner.into(),
        repo: name.into(),
        issue,
        gate_label: "product-wip".into(),
        seat_target: seat,
        seat_expect_cmd: get(args, "--expect").unwrap_or_else(|| "claude".into()),
        floor_dir: floor,
        job_template: prompts::job_path(
            &get(args, "--template").unwrap_or_else(|| "dev".into()),
            "gv",
        ),
        run_log,
        timeout: Duration::from_secs(
            get(args, "--timeout")
                .and_then(|s| s.parse().ok())
                .unwrap_or(600),
        ),
    };
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwfd triage: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwfd triage: no [ops] app");
        return ExitCode::from(2);
    };
    match triage::run(&cfg, ops) {
        Ok((ready, reason)) => {
            println!(
                "#{issue}: {} — {reason}",
                if ready {
                    "READY (awaiting human un-gate)"
                } else {
                    "NOT READY (gated)"
                }
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("fwfd triage: {}", e.0);
            ExitCode::from(1)
        }
    }
}

pub fn release_check(args: &[String]) -> ExitCode {
    let (Some(repo), Some(tag)) = (get(args, "--repo"), get(args, "--tag")) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let expect: usize = get(args, "--expect")
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwfd release-check: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwfd release-check: no [ops] app");
        return ExitCode::from(2);
    };
    let perms = std::collections::BTreeMap::from([("contents", "read"), ("metadata", "read")]);
    let tok = match github::mint(ops, Some(&perms)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("fwfd release-check: {e}");
            return ExitCode::from(2);
        }
    };
    match github::get_status(&tok.token, &format!("/repos/{repo}/releases/tags/{tag}")) {
        Ok((200, body)) => {
            let v: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            let assets: Vec<String> = v["assets"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x["name"].as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            if assets.len() >= expect {
                println!(
                    "{tag}: release ok, {} assets: {}",
                    assets.len(),
                    assets.join(" ")
                );
                ExitCode::SUCCESS
            } else {
                eprintln!(
                    "{tag}: release exists but has {} assets (expected ≥ {expect}): {}",
                    assets.len(),
                    assets.join(" ")
                );
                ExitCode::from(1)
            }
        }
        Ok((404, _)) => {
            eprintln!("{tag}: NO release object (a tag is not a release)");
            ExitCode::from(1)
        }
        Ok((code, _)) => {
            eprintln!("{tag}: unexpected {code}");
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("fwfd release-check: {e}");
            ExitCode::from(2)
        }
    }
}

pub fn dash(args: &[String]) -> ExitCode {
    let path = get(args, "--log")
        .map(PathBuf::from)
        .unwrap_or_else(default_log);
    let watch: Option<u64> = get(args, "--watch").and_then(|s| s.parse().ok());
    loop {
        let events = match log::read_all(&path) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("fwfd dash: cannot read {}: {e}", path.display());
                return ExitCode::from(2);
            }
        };
        let board = dash::fold(&events);
        let text = dash::render(&board, seat::now());
        match watch {
            Some(secs) => {
                print!("\x1b[2J\x1b[H{text}");
                use std::io::Write;
                let _ = std::io::stdout().flush();
                std::thread::sleep(std::time::Duration::from_secs(secs.max(1)));
            }
            None => {
                print!("{text}");
                return ExitCode::SUCCESS;
            }
        }
    }
}
