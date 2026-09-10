//! Verb bodies moved out of main.rs (the size ratchet): spec, triage,
//! release-check, dash. Each takes the raw argv and returns the exit code.

use crate::{
    dash, github, log, manifest, mirror, profile, prompts, run, seat, slice, spec, triage,
};
use crate::{default_log, USAGE};
use std::path::Path;
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

pub fn init_manifest(args: &[String]) -> ExitCode {
    let Some(path) = get(args, "--from-profile") else {
        print!("{}", manifest::EXAMPLE);
        return ExitCode::SUCCESS;
    };
    let Some(repo) = get(args, "--repo") else {
        eprintln!("fwfd init-manifest: --from-profile needs --repo owner/name (a profile only knows a local path)");
        return ExitCode::from(2);
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("fwfd init-manifest: cannot read {path}: {e}");
            return ExitCode::from(2);
        }
    };
    let name = repo.split_once('/').map(|(_, n)| n).unwrap_or("floor");
    let session = get(args, "--session").unwrap_or_else(|| format!("fwf-{name}"));
    let out = profile::to_manifest(&profile::parse(&text), &repo, &session);
    if let Err(e) = manifest::Manifest::parse(&out) {
        eprintln!("fwfd init-manifest: converted manifest does not validate: {e}");
        return ExitCode::from(1);
    }
    print!("{out}");
    ExitCode::SUCCESS
}

fn seat_live(cmd: &str) -> bool {
    cmd == "claude" || cmd.chars().next().is_some_and(|c| c.is_ascii_digit())
}

/// `fwfd seats [--up|--down] [--manifest PATH]`: bring every seat the
/// manifest names up (mirror, worktree clone, warm pane) or take them down.
/// Up is idempotent: a live pane is left alone. Down refuses while the run
/// record says a seat is still Working, unless --force.
pub fn seats(args: &[String]) -> ExitCode {
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    let m = match manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwfd seats: {e}");
            return ExitCode::from(2);
        }
    };
    let floor = m.floor();
    let (run_log, mirror_dir) = slice::defaults(&floor);
    let mut roles: Vec<(String, u8)> = Vec::new();
    for n in 1..=m.pairs {
        roles.push(("impl".into(), n));
        roles.push(("qa".into(), n));
    }
    for r in ["gv", "pm"] {
        if m.models.contains_key(r) {
            roles.push((r.into(), 1));
        }
    }
    let down = args.iter().any(|a| a == "--down");
    if down {
        let stale = log::read_all(&run_log)
            .map(|evs| log::stale_working(&evs, u64::MAX).len())
            .unwrap_or(0);
        if stale > 0 && !args.iter().any(|a| a == "--force") {
            eprintln!(
                "fwfd seats --down: {stale} seat(s) are Working per the run record; wait for the verdict or pass --force"
            );
            return ExitCode::from(1);
        }
        let ok = std::process::Command::new("tmux")
            .args(["kill-session", "-t", &m.session])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        println!(
            "seats down: tmux session {} {}",
            m.session,
            if ok { "killed" } else { "was not running" }
        );
        return ExitCode::SUCCESS;
    }
    let mr = match mirror::Mirror::init(&mirror_dir, &format!("https://github.com/{}.git", m.repo))
        .and_then(|mr| mr.fetch().map(|_| mr))
    {
        Ok(mr) => mr,
        Err(e) => {
            eprintln!("fwfd seats: mirror: {e}");
            return ExitCode::from(1);
        }
    };
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/seat-up.sh");
    let home = floor.join("home");
    let mut failures = 0;
    for (role, n) in &roles {
        let target = m.seat_target(role, *n);
        let pane = format!("{role}{n}");
        let wt = floor.join(format!("wt-{pane}"));
        if !wt.join(".git").exists() {
            let st = std::process::Command::new("git")
                .args([
                    "clone",
                    "--quiet",
                    "--branch",
                    &m.base_branch,
                    &mr.seat_remote_url(),
                ])
                .arg(&wt)
                .status();
            match st {
                Ok(s) if s.success() => println!("  {target:<18} cloned {}", wt.display()),
                _ => {
                    eprintln!("  {target:<18} clone FAILED");
                    failures += 1;
                    continue;
                }
            }
        }
        let cmd = seat::pane_command(&target).unwrap_or_else(|_| "absent".into());
        if seat_live(&cmd) {
            println!("  {target:<18} already up ({cmd})");
            continue;
        }
        let model = m
            .models
            .get(role.as_str())
            .cloned()
            .unwrap_or_else(|| "opus".into());
        let st = std::process::Command::new(script)
            .arg(&home)
            .arg(&wt)
            .arg(&m.session)
            .arg(&pane)
            .arg(&model)
            .status();
        match st {
            Ok(s) if s.success() => println!("  {target:<18} up ({model})"),
            Ok(s) => {
                eprintln!("  {target:<18} seat-up exit {}", s.code().unwrap_or(-1));
                failures += 1;
            }
            Err(e) => {
                eprintln!("  {target:<18} seat-up: {e}");
                failures += 1;
            }
        }
    }
    if failures > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

pub fn run_loop(args: &[String]) -> ExitCode {
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    let m = match manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwfd run: {e}");
            return ExitCode::from(2);
        }
    };
    if m.issues.is_empty() {
        eprintln!("fwfd run: the manifest has no `issues` allow-list; refusing to run against every eligible issue while 1.0 is new");
        return ExitCode::from(2);
    }
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwfd run: {e}");
            return ExitCode::from(2);
        }
    };
    let floor = m.floor();
    let (run_log, mirror_dir) = slice::defaults(&floor);
    let mut impl_seats = Vec::new();
    let mut qa_seats = Vec::new();
    for n in 1..=m.pairs {
        impl_seats.push((n, m.seat_target("impl", n)));
        qa_seats.push((n, m.seat_target("qa", n)));
    }
    let cfg = run::RunConfig {
        owner: m.owner().to_string(),
        repo: m.name().to_string(),
        base_branch: m.base_branch.clone(),
        gate_label: m.gate_label.clone(),
        floor_dir: floor.clone(),
        mirror_dir,
        run_log,
        impl_seats,
        qa_seats,
        seat_expect_cmd: "claude".into(),
        interval: Duration::from_secs(m.poll_interval_secs),
        job_timeout: Duration::from_secs(m.job_timeout_secs),
        once: args.iter().any(|a| a == "--once"),
        prompts_dir: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/prompts")),
        template: m.template.clone(),
        allow_issues: m.issues.clone(),
        triage_new: m.triage_new,
        gv_seat: m.models.contains_key("gv").then(|| m.seat_target("gv", 1)),
        park_at_weekly_pct: m.park_at_weekly_pct,
        gate_suite: m.fast_suite.clone(),
        gate_cmd: m.suites.get(&m.fast_suite).cloned().unwrap_or_default(),
        gate_venue: m.gate_venue.clone(),
        gate_memory_gb: m.gate_memory_gb,
        gate_timeout: Duration::from_secs(m.gate_timeout_secs),
    };
    match run::run(&cfg, &apps) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("fwfd run: {e}");
            ExitCode::from(1)
        }
    }
}

pub fn up(args: &[String]) -> ExitCode {
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    let m = match manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwfd up: {e}");
            return ExitCode::from(2);
        }
    };
    println!("manifest {} ok: repo {} · {} → {} · gate label {:?} · {} pair(s) · session {} · venue {} ({} GB, {} s) · suites {:?}",
        path.display(), m.repo, m.base_branch, m.release_branch, m.gate_label, m.pairs, m.session, m.gate_venue, m.gate_memory_gb, m.gate_timeout_secs, m.suites.keys().collect::<Vec<_>>());
    println!("  floor: {}", m.floor().display());
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwfd up: {e}");
            return ExitCode::from(2);
        }
    };
    let mut bad = 0;
    for role in ["impl", "qa", "ops"] {
        match apps.0.get(role) {
            None => {
                bad += 1;
                println!("  app {role:<4}: MISSING from apps.toml");
            }
            Some(entry) => match github::mint(
                entry,
                Some(&std::collections::BTreeMap::from([("metadata", "read")])),
            ) {
                Ok(_) => println!("  app {role:<4}: ok"),
                Err(e) => {
                    bad += 1;
                    println!("  app {role:<4}: NOT USABLE — {e}");
                }
            },
        }
    }
    for n in 1..=m.pairs {
        for role in ["impl", "qa"] {
            let target = m.seat_target(role, n);
            let cmd = seat::pane_command(&target).unwrap_or_else(|_| "absent".into());
            println!("  seat {target}: {cmd}");
        }
    }
    if bad == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
