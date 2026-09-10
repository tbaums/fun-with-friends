//! fwfd — the fwf 1.0 supervisor. M0 skeleton: the four state machines, the
//! event log, and `why`. No GitHub client, no seats, no gate runner yet.

// M0 only: the transitions and the appender have no caller until T-06/T-09
// land; they are exercised by the unit tests. Remove when the scheduler
// arrives so dead code becomes a build error again.
#![allow(dead_code)]

mod checks;
mod cost;
#[cfg(test)]
mod fake_github;
mod gate;
mod github;
mod log;
mod manifest;
mod merge;
mod mirror;
mod poll;
mod promote;
mod qa;
mod run;
mod sched;
mod seat;
mod slice;
mod status;
mod triage;
mod types;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

const USAGE: &str = "usage:
  fwfd why <pr> [--log PATH]   timeline of one PR from the run record (default ~/.fwf/run.jsonl)
  fwfd up [--manifest PATH]   validate the manifest (default ./.fwf/fwf.toml or --manifest), mint every App, print the floor plan; refuses without a manifest
  fwfd init-manifest         print an example fwf.toml
  fwfd cost --floor DIR --seat impl1 [--since EPOCH]   measured tokens for a seat since a time, from its own transcript
  fwfd status [--manifest PATH]   one screen: seats, eligible/claimed issues, PRs with review state, recent events, needs-you
  fwfd run [--manifest PATH] [--once]   the supervisor loop: poll → plan → act; only issues in the manifest's allow-list
  fwfd triage --repo o/r --issue N --seat tmux-target [--timeout SECS]   wake the GV pane; a not-ready verdict gates the issue under ops
  fwfd ungate --repo o/r --issue N --by NAME   the human un-gate: remove the gate label under ops, record who
  fwfd doctor                  mint a narrowed installation token per App in ~/.fwf/apps.toml
  fwfd probe <role> <api-path> GET an API path with that App's token; prints the status
  fwfd mirror-init --repo o/r [--floor DIR]   create/refresh the local bare mirror and print the seat remote URL
  fwfd review --repo o/r --pr N --by qa|impl|ops [--changes] [--body TEXT]   PR review anchored to the current head, under that App
  fwfd qa --repo o/r --pr N --seat tmux-target [--seat-no 1] [--timeout SECS]   wake a QA pane, post its verdict as a review under fwf-qa
  fwfd merge --repo o/r --pr N   typed squash-merge under fwf-ops (approval at head by a non-author, fence, checks)
  fwfd gate --repo o/r --sha SHA --suite NAME --cmd 'shell' --workdir DIR [--venue local|container] [--memory GB] [--timeout SECS]   run a gate, record the verdict, post a check-run under fwf-ops
  fwfd promote --repo o/r --from BRANCH --to BRANCH --suite NAME   fast-forward `to` to `from` if a Green verdict for (from-sha, suite) is recorded
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
        Some("cost") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(floor), Some(seat)) = (get("--floor").map(PathBuf::from), get("--seat"))
            else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let since = get("--since")
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            match cost::cycle_usage(
                &floor.join("home"),
                &floor.join(format!("wt-{seat}")),
                since,
            ) {
                Some(u) => {
                    println!("{seat} since {since}: {} messages, in {} (input {} + cache-read {} + cache-create {}), out {}", u.messages, u.tokens_in(), u.input, u.cache_read, u.cache_create, u.output);
                    ExitCode::SUCCESS
                }
                None => {
                    eprintln!(
                        "fwfd cost: no transcript for {seat} under {}",
                        floor.display()
                    );
                    ExitCode::from(1)
                }
            }
        }
        Some("status") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let path = get("--manifest")
                .map(PathBuf::from)
                .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
            let m = match manifest::Manifest::load(&path) {
                Ok(m) => m,
                Err(e) => {
                    eprintln!("fwfd status: {e}");
                    return ExitCode::from(2);
                }
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd status: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("impl") else {
                eprintln!("fwfd status: no [impl] app");
                return ExitCode::from(2);
            };
            let perms = std::collections::BTreeMap::from([
                ("issues", "read"),
                ("pull_requests", "read"),
                ("contents", "read"),
                ("metadata", "read"),
            ]);
            let tok = match github::mint(app, Some(&perms)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd status: {e}");
                    return ExitCode::from(2);
                }
            };
            let poller =
                poll::Poller::new("https://api.github.com", &tok.token, m.owner(), m.name());
            let now = seat::now();
            let snap = poller
                .poll(now)
                .unwrap_or_else(|_| poll::Snapshot::unknown());
            let mut targets = Vec::new();
            for n in 1..=m.pairs {
                targets.push(m.seat_target("impl", n));
                targets.push(m.seat_target("qa", n));
            }
            let (run_log, _) = slice::defaults(&m.floor());
            let inp = status::StatusInput {
                snapshot: &snap,
                gate_label: &m.gate_label,
                owner_only: m.owner_only,
                seats: status::seat_commands(&targets),
                run_log: &run_log,
                now,
            };
            print!("{}", status::render(&inp));
            ExitCode::SUCCESS
        }
        Some("run") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let path = get("--manifest")
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
                allow_issues: m.issues.clone(),
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
        Some("triage") => {
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
                seat_expect_cmd: get("--expect").unwrap_or_else(|| "claude".into()),
                floor_dir: floor,
                job_template: PathBuf::from(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/prompts/gv-job.md"
                )),
                run_log,
                timeout: Duration::from_secs(
                    get("--timeout").and_then(|s| s.parse().ok()).unwrap_or(600),
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
        Some("ungate") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(issue)) = (
                get("--repo"),
                get("--issue").and_then(|s| s.parse::<u64>().ok()),
            ) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let by = get("--by")
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
                    eprintln!("fwfd ungate: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(ops) = apps.0.get("ops") else {
                eprintln!("fwfd ungate: no [ops] app");
                return ExitCode::from(2);
            };
            match triage::ungate(owner, name, issue, "product-wip", &by, &run_log, ops) {
                Ok(()) => {
                    println!("#{issue} un-gated by {by}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd ungate: {}", e.0);
                    ExitCode::from(1)
                }
            }
        }
        Some("init-manifest") => {
            print!("{}", manifest::EXAMPLE);
            ExitCode::SUCCESS
        }
        Some("up") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let path = get("--manifest")
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
        Some("review") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(pr), Some(by)) = (
                get("--repo"),
                get("--pr").and_then(|s| s.parse::<u64>().ok()),
                get("--by"),
            ) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd review: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get(&by) else {
                eprintln!("fwfd review: no app {by}");
                return ExitCode::from(2);
            };
            let perms = std::collections::BTreeMap::from([
                ("pull_requests", "write"),
                ("contents", "read"),
                ("metadata", "read"),
            ]);
            let tok = match github::mint(app, Some(&perms)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd review: {e}");
                    return ExitCode::from(2);
                }
            };
            let (code, body) =
                match github::get_status(&tok.token, &format!("/repos/{repo}/pulls/{pr}")) {
                    Ok(x) => x,
                    Err(e) => {
                        eprintln!("fwfd review: {e}");
                        return ExitCode::from(2);
                    }
                };
            if code != 200 {
                eprintln!("fwfd review: cannot read PR ({code})");
                return ExitCode::from(1);
            }
            let head = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v["head"]["sha"].as_str().map(String::from))
                .unwrap_or_default();
            let head = match types::Sha::parse(&head) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("fwfd review: {e}");
                    return ExitCode::from(1);
                }
            };
            let event = if args.iter().any(|a| a == "--changes") {
                "REQUEST_CHANGES"
            } else {
                "APPROVE"
            };
            let text = get("--body")
                .unwrap_or_else(|| format!("fwfd review by {by}: {event} at {}", head.as_str()));
            let payload =
                serde_json::json!({ "commit_id": head.as_str(), "event": event, "body": text });
            match github::send_json(
                "POST",
                &tok.token,
                &format!("/repos/{repo}/pulls/{pr}/reviews"),
                &payload,
            ) {
                Ok((200, b)) | Ok((201, b)) => {
                    let v: serde_json::Value = serde_json::from_str(&b).unwrap_or_default();
                    println!(
                        "review {} by {} state={} commit_id={}",
                        v["id"],
                        v["user"]["login"],
                        v["state"],
                        head.short()
                    );
                    ExitCode::SUCCESS
                }
                Ok((code, b)) => {
                    eprintln!(
                        "fwfd review: refused ({code}): {}",
                        b.chars().take(200).collect::<String>()
                    );
                    ExitCode::from(1)
                }
                Err(e) => {
                    eprintln!("fwfd review: {e}");
                    ExitCode::from(2)
                }
            }
        }
        Some("qa") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(pr), Some(seat)) = (
                get("--repo"),
                get("--pr").and_then(|s| s.parse::<u64>().ok()),
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
            let cfg = qa::QaConfig {
                owner: owner.to_string(),
                repo: name.to_string(),
                pr,
                seat_target: seat,
                seat_expect_cmd: get("--expect").unwrap_or_else(|| "claude".into()),
                seat_no: get("--seat-no").and_then(|s| s.parse().ok()).unwrap_or(1),
                floor_dir: floor.clone(),
                mirror_dir,
                job_template: PathBuf::from(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/prompts/qa-job.md"
                )),
                run_log,
                timeout: Duration::from_secs(
                    get("--timeout")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(1200),
                ),
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd qa: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("qa") else {
                eprintln!("fwfd qa: no [qa] app");
                return ExitCode::from(2);
            };
            match qa::run(&cfg, app) {
                Ok((id, state)) => {
                    println!("review {id} {state} on #{pr}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd qa: {}", e.0);
                    ExitCode::from(1)
                }
            }
        }
        Some("merge") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(pr)) = (
                get("--repo"),
                get("--pr").and_then(|s| s.parse::<u64>().ok()),
            ) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd merge: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("ops") else {
                eprintln!("fwfd merge: no [ops] app");
                return ExitCode::from(2);
            };
            let perms = std::collections::BTreeMap::from([
                ("contents", "write"),
                ("pull_requests", "write"),
                ("issues", "read"),
                ("checks", "read"),
                ("metadata", "read"),
            ]);
            let tok = match github::mint(app, Some(&perms)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd merge: {e}");
                    return ExitCode::from(2);
                }
            };
            let floor = std::env::var_os("HOME")
                .map(|h| {
                    PathBuf::from(h)
                        .join(".fwf/floors")
                        .join(repo.rsplit('/').next().unwrap_or("repo"))
                })
                .unwrap_or_else(|| PathBuf::from("floor"));
            let (run_log, _) = slice::defaults(&floor);
            let mut log = match log::Log::open(&run_log) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("fwfd merge: {e}");
                    return ExitCode::from(2);
                }
            };
            let client = merge::Client {
                base_url: "https://api.github.com".into(),
                token: tok.token.clone(),
            };
            // The fence is the live claim ref for the PR's issue; merge.rs verifies it.
            let (code, body) =
                match github::get_status(&tok.token, &format!("/repos/{repo}/pulls/{pr}")) {
                    Ok(x) => x,
                    Err(e) => {
                        eprintln!("fwfd merge: {e}");
                        return ExitCode::from(2);
                    }
                };
            if code != 200 {
                eprintln!("fwfd merge: cannot read PR ({code})");
                return ExitCode::from(1);
            }
            let issue = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v["body"].as_str().and_then(poll::closes_issue))
                .unwrap_or(0);
            let (code, body) = match github::get_status(
                &tok.token,
                &format!("/repos/{repo}/git/ref/claims/{issue}"),
            ) {
                Ok(x) => x,
                Err(e) => {
                    eprintln!("fwfd merge: {e}");
                    return ExitCode::from(2);
                }
            };
            let fence = if code == 200 {
                serde_json::from_str::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|v| {
                        v["object"]["sha"]
                            .as_str()
                            .map(|s| types::Fence(s.to_string()))
                    })
            } else {
                None
            };
            let Some(fence) = fence else {
                eprintln!("fwfd merge: no live claim ref for issue #{issue}; refusing");
                return ExitCode::from(1);
            };
            match merge::merge_pr(&client, &repo, pr, &fence, &mut log) {
                Ok(sha) => {
                    println!("merged #{pr} as {}", sha.as_str());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd merge: refused: {e}");
                    ExitCode::from(1)
                }
            }
        }
        Some("gate") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(sha), Some(suite), Some(cmd), Some(workdir)) = (
                get("--repo"),
                get("--sha"),
                get("--suite"),
                get("--cmd"),
                get("--workdir"),
            ) else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let sha = match types::Sha::parse(&sha) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("fwfd gate: {e}");
                    return ExitCode::from(2);
                }
            };
            let venue = match get("--venue").as_deref() {
                Some("container") => gate::Venue::AppleContainer {
                    image: get("--image").unwrap_or_else(|| "alpine:latest".into()),
                },
                _ => gate::Venue::Local,
            };
            let g = gate::Gate {
                venue,
                memory_gb: get("--memory").and_then(|s| s.parse().ok()).unwrap_or(8),
                timeout: Duration::from_secs(
                    get("--timeout")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(1800),
                ),
                workdir: PathBuf::from(&workdir),
            };
            let floor = std::env::var_os("HOME")
                .map(|h| {
                    PathBuf::from(h)
                        .join(".fwf/floors")
                        .join(repo.rsplit('/').next().unwrap_or("repo"))
                })
                .unwrap_or_else(|| PathBuf::from("floor"));
            let (run_log, _) = slice::defaults(&floor);
            let log_path = floor.join(format!("gate-{}-{suite}.log", sha.short()));
            let state = g.run(&sha, &suite, &cmd, &log_path);
            println!("gate {} {suite}: {state:?}", sha.short());
            if let Ok(mut l) = log::Log::open(&run_log) {
                let _ = l.append(&log::Event {
                    ts: seat::now(),
                    repo: repo.clone(),
                    kind: log::Kind::Gate { to: state.clone() },
                });
            }
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd gate: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("ops") else {
                eprintln!("fwfd gate: no [ops] app");
                return ExitCode::from(2);
            };
            let perms =
                std::collections::BTreeMap::from([("checks", "write"), ("metadata", "read")]);
            let tok = match github::mint(app, Some(&perms)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd gate: {e}");
                    return ExitCode::from(2);
                }
            };
            let client = checks::CheckClient {
                base_url: "https://api.github.com".into(),
                token: tok.token,
            };
            match checks::post_check_run(
                &client,
                &repo,
                &sha,
                &format!("fwfd/{suite}"),
                &state,
                None,
            ) {
                Ok(id) => {
                    println!("check-run {id} posted");
                    if matches!(state, types::GateState::Green { .. }) {
                        ExitCode::SUCCESS
                    } else {
                        ExitCode::from(1)
                    }
                }
                Err(e) => {
                    eprintln!("fwfd gate: check-run not posted: {e:?}");
                    ExitCode::from(1)
                }
            }
        }
        Some("promote") => {
            let get = |flag: &str| {
                args.iter()
                    .position(|a| a == flag)
                    .and_then(|i| args.get(i + 1).cloned())
            };
            let (Some(repo), Some(from), Some(to), Some(suite)) =
                (get("--repo"), get("--from"), get("--to"), get("--suite"))
            else {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            };
            let apps = match github::load_apps(&github::apps_path()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("fwfd promote: {e}");
                    return ExitCode::from(2);
                }
            };
            let Some(app) = apps.0.get("ops") else {
                eprintln!("fwfd promote: no [ops] app");
                return ExitCode::from(2);
            };
            let perms = std::collections::BTreeMap::from([
                ("contents", "write"),
                ("checks", "read"),
                ("metadata", "read"),
            ]);
            let tok = match github::mint(app, Some(&perms)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("fwfd promote: {e}");
                    return ExitCode::from(2);
                }
            };
            let (code, body) = match github::get_status(
                &tok.token,
                &format!("/repos/{repo}/git/ref/heads/{from}"),
            ) {
                Ok(x) => x,
                Err(e) => {
                    eprintln!("fwfd promote: {e}");
                    return ExitCode::from(2);
                }
            };
            if code != 200 {
                eprintln!("fwfd promote: cannot read {from} ({code})");
                return ExitCode::from(1);
            }
            let from_sha = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| {
                    v["object"]["sha"]
                        .as_str()
                        .and_then(|s| types::Sha::parse(s).ok())
                });
            let Some(from_sha) = from_sha else {
                eprintln!("fwfd promote: bad ref");
                return ExitCode::from(1);
            };
            let floor = std::env::var_os("HOME")
                .map(|h| {
                    PathBuf::from(h)
                        .join(".fwf/floors")
                        .join(repo.rsplit('/').next().unwrap_or("repo"))
                })
                .unwrap_or_else(|| PathBuf::from("floor"));
            let (run_log, _) = slice::defaults(&floor);
            let g = gate::Gate {
                venue: gate::Venue::Local,
                memory_gb: 0,
                timeout: Duration::from_secs(1),
                workdir: get("--workdir")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| floor.join("gate-wt")),
            };
            let state = g
                .recorded(&from_sha, &suite)
                .unwrap_or(types::GateState::Unknown);
            let mut log = match log::Log::open(&run_log) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("fwfd promote: {e}");
                    return ExitCode::from(2);
                }
            };
            let client = merge::Client {
                base_url: "https://api.github.com".into(),
                token: tok.token,
            };
            match promote::promote(&client, &repo, &from, &to, &state, &suite, &mut log) {
                Ok(sha) => {
                    println!("promoted {to} → {}", sha.as_str());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("fwfd promote: refused: {e}");
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
