//! Verb bodies moved out of main.rs (the size ratchet): spec, triage,
//! release-check, dash. Each takes the raw argv and returns the exit code.

use crate::USAGE;
use crate::{
    dash, github, log, manifest, mirror, profile, prompts, run, seat, slice, spec, triage, upgrade,
};
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

mod doctor;
pub mod pidfile;
pub use pidfile::verb as stop;
pub mod scripts;
pub use doctor::*;

pub(crate) fn get(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1).cloned())
}

/// Where a seat's commits come from. Not a real mail domain on purpose: these
/// addresses say "a seat on this floor wrote this", nothing more.
pub const IDENTITY_DOMAIN: &str = "fwf.local";
/// The gate worktree commits nothing today; it still gets a name of its own.
pub const GATE_IDENTITY: &str = "fwf-gate";

/// Give a worktree its own commit identity: `<who>` / `<who>@fwf.local` (#590).
///
/// A seat worktree is an independent clone with its own config, and nothing was
/// writing one, so git fell back to whatever it could guess from the machine —
/// the same author for every seat, and indistinguishable from a human's local
/// commit. Repo config beats the global and system files, so this is the last
/// word short of `GIT_AUTHOR_*` in the environment. Written every time `seats
/// --up` runs, so an identity that drifted is corrected rather than kept.
pub fn set_seat_identity(wt: &Path, who: &str) -> Result<(), String> {
    for (key, value) in [
        ("user.name", who.to_string()),
        ("user.email", format!("{who}@{IDENTITY_DOMAIN}")),
    ] {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(wt)
            .args(["config", key, &value])
            .output()
            .map_err(|e| format!("git config {key}: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "git config {key} in {}: {}",
                wt.display(),
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
    }
    Ok(())
}

/// What a worktree says it commits as: `(user.name, user.email)` from its own
/// config. `None` when there is no worktree, or it has no identity of its own.
pub fn seat_identity(wt: &Path) -> Option<(String, String)> {
    let read = |key: &str| -> Option<String> {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(wt)
            .args(["config", "--local", "--get", key])
            .output()
            .ok()?;
        let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
        (out.status.success() && !v.is_empty()).then_some(v)
    };
    Some((read("user.name")?, read("user.email")?))
}

/// One line per worktree the manifest names, plus the gate's, and how many of
/// them commit as something other than themselves. Read-only: the fix for a
/// wrong identity is another `fwf seats --up`.
fn identity_report(floor: &Path, seats: &[(&str, u8)]) -> (Vec<String>, usize) {
    let mut lines = Vec::new();
    let mut wrong = 0;
    let mut expected: Vec<(String, String)> = seats
        .iter()
        .map(|(role, n)| (format!("wt-{role}{n}"), format!("{role}{n}")))
        .collect();
    expected.push(("gate-wt".to_string(), GATE_IDENTITY.to_string()));
    for (dir, who) in expected {
        let wt = floor.join(&dir);
        let want = format!("{who} <{who}@{IDENTITY_DOMAIN}>");
        let line = match seat_identity(&wt) {
            Some((name, email)) if name == who && email == format!("{who}@{IDENTITY_DOMAIN}") => {
                format!("  {dir:<12} {want}")
            }
            Some((name, email)) => {
                wrong += 1;
                format!("  {dir:<12} WRONG: {name} <{email}> — expected {want}")
            }
            // Not an identity problem: there is nothing there to commit with.
            None if !wt.join(".git").exists() => {
                format!("  {dir:<12} not provisioned (`fwf seats --up`)")
            }
            None => {
                wrong += 1;
                format!("  {dir:<12} no identity of its own — expected {want}")
            }
        };
        lines.push(line);
    }
    (lines, wrong)
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
        discovery_label: spec::DISCOVERY_LABEL.into(),
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
            eprintln!("fwf spec: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwf spec: no [ops] app");
        return ExitCode::from(2);
    };
    match spec::run(&cfg, ops) {
        Ok((title, questions)) => {
            println!("#{issue}: spec written — {title} ({} open question(s)); still gated, `fwf ungate {issue}` to approve", questions.len());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("fwf spec: {}", e.0);
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
            eprintln!("fwf triage: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwf triage: no [ops] app");
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
            eprintln!("fwf triage: {}", e.0);
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
            eprintln!("fwf release-check: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(ops) = apps.0.get("ops") else {
        eprintln!("fwf release-check: no [ops] app");
        return ExitCode::from(2);
    };
    let perms = std::collections::BTreeMap::from([("contents", "read"), ("metadata", "read")]);
    let tok = match github::mint(ops, Some(&perms)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("fwf release-check: {e}");
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
            eprintln!("fwf release-check: {e}");
            ExitCode::from(2)
        }
    }
}

/// The floor around the record: the manifest's facts plus what tmux says
/// right now. Read fresh every frame, because a pane can die between them.
/// No manifest is not an error — the dash must still open any copy of a
/// `run.jsonl` — the header simply says so.
fn dash_floor(m: Option<&manifest::Manifest>, repo_in_record: &str) -> dash::Floor {
    let meter = run::last_meter().map(|(weekly, session, when)| dash::Meter {
        age: run::meter_age_secs(&when, seat::now()),
        weekly,
        session,
        when,
    });
    let Some(m) = m else {
        return dash::Floor {
            repo: repo_in_record.to_string(),
            version: env!("CARGO_PKG_VERSION").into(),
            loop_state: dash::loop_state(None, meter.as_ref(), 100),
            meter,
            park_at: 0,
            ..Default::default()
        };
    };
    let mut roles: Vec<(&str, u8)> = Vec::new();
    for n in 1..=m.pairs {
        roles.push(("impl", n));
        roles.push(("qa", n));
    }
    for r in ["pm", "gv"] {
        if m.models.contains_key(r) {
            roles.push((r, 1));
        }
    }
    let slots = roles
        .into_iter()
        .map(|(role, n)| {
            let r = match role {
                "impl" => crate::types::Role::Impl,
                "qa" => crate::types::Role::Qa,
                "pm" => crate::types::Role::Pm,
                _ => crate::types::Role::Gv,
            };
            let target = m.seat_target(role, n);
            dash::Slot {
                role: r,
                seat: n,
                pane: dash::tty::pane_command(&target),
                target,
            }
        })
        .collect();
    // The loop is a pane too: `run` in the floor's session. A tmux that does
    // not answer is Unknown, never "not running".
    let window = dash::tty::window_exists(&m.session, "run");
    dash::Floor {
        repo: m.repo.clone(),
        base: m.base_branch.clone(),
        release: m.release_branch.clone(),
        session: m.session.clone(),
        version: env!("CARGO_PKG_VERSION").into(),
        slots,
        allow: m.issues.clone(),
        loop_state: dash::loop_state(window, meter.as_ref(), m.park_at_weekly_pct),
        meter,
        park_at: m.park_at_weekly_pct,
        rework_cap: m.rework_cap,
    }
}

pub fn dash(args: &[String]) -> ExitCode {
    // Answered before any manifest or record is touched: `--help` drew a
    // board for whatever floor `default_log()` pointed at, and so did a typo.
    match dash::args::parse(args) {
        dash::args::Dash::Help(usage) => {
            println!("{usage}");
            return ExitCode::SUCCESS;
        }
        dash::args::Dash::Unknown(flag) => {
            eprintln!("fwf dash: unknown flag {flag}");
            return ExitCode::from(2);
        }
        dash::args::Dash::BadTab(t) => {
            eprintln!("fwf dash: --tab {t:?} is not 1-5 or seats|issues|prs|decisions|usage");
            return ExitCode::from(2);
        }
        dash::args::Dash::Run => {}
    }
    let (m, path, note) = dash::args::sources(args);
    note.inspect(|n| eprintln!("{n}"));
    let mut events = match log::read_all(&path) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("fwf dash: cannot read {}: {e}", path.display());
            return ExitCode::from(2);
        }
    };
    let record_repo = events.first().map(|e| e.repo.clone()).unwrap_or_default();
    let (w, h) = dash::tty::size();
    let view = dash::view::View {
        tab: dash::args::tab(args),
        width: w,
        height: h,
        color: !args.iter().any(|a| a == "--no-color") && dash::tty::wants_color(),
        ..Default::default()
    };
    // Watch by default on a terminal; one labelled frame into a pipe (#626).
    match dash::tty::mode(args, dash::tty::is_tty()) {
        Some(secs) => {
            dash::tty::watch(secs, view, move || {
                // A record that cannot be re-read (mid-append, or gone) must
                // not blank the board: keep folding the last good events, and
                // let "last event N ago" age visibly.
                if let Ok(e) = log::read_all(&path) {
                    events = e;
                }
                (dash::fold(&events), dash_floor(m.as_ref(), &record_repo))
            });
            ExitCode::SUCCESS
        }
        None => {
            print!(
                "{}",
                dash::tty::once(
                    &dash::fold(&events),
                    &dash_floor(m.as_ref(), &record_repo),
                    &view
                )
            );
            ExitCode::SUCCESS
        }
    }
}

pub fn init_manifest(args: &[String]) -> ExitCode {
    let Some(path) = get(args, "--from-profile") else {
        print!("{}", manifest::EXAMPLE);
        return ExitCode::SUCCESS;
    };
    let Some(repo) = get(args, "--repo") else {
        eprintln!("fwf init-manifest: --from-profile needs --repo owner/name (a profile only knows a local path)");
        return ExitCode::from(2);
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("fwf init-manifest: cannot read {path}: {e}");
            return ExitCode::from(2);
        }
    };
    let name = repo.split_once('/').map(|(_, n)| n).unwrap_or("floor");
    let session = get(args, "--session").unwrap_or_else(|| format!("fwf-{name}"));
    let out = profile::to_manifest(&profile::parse(&text), &repo, &session);
    if let Err(e) = manifest::Manifest::parse(&out) {
        eprintln!("fwf init-manifest: converted manifest does not validate: {e}");
        return ExitCode::from(1);
    }
    print!("{out}");
    ExitCode::SUCCESS
}

fn seat_live(cmd: &str) -> bool {
    cmd == "claude" || cmd.chars().next().is_some_and(|c| c.is_ascii_digit())
}

/// `fwf seats [--up|--down] [--manifest PATH]`: bring every seat the
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
            eprintln!("fwf seats: {e}");
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
                "fwf seats --down: {stale} seat(s) are Working per the run record; wait for the verdict or pass --force"
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
    let read_tok = github::load_apps(&github::apps_path())
        .ok()
        .and_then(|apps| apps.0.get("ops").cloned())
        .and_then(|a| {
            github::mint(
                &a,
                Some(&std::collections::BTreeMap::from([
                    ("contents", "read"),
                    ("metadata", "read"),
                ])),
            )
            .ok()
        })
        .map(|t| t.token)
        .unwrap_or_default();
    let mr = match mirror::Mirror::init_with(
        &mirror_dir,
        &format!("https://github.com/{}.git", m.repo),
        &read_tok,
    ) {
        Ok(mr) => mr,
        Err(e) => {
            eprintln!("fwf seats: mirror: {e}");
            return ExitCode::from(1);
        }
    };
    let home = floor.join("home");
    // The scripts ride inside the binary and are laid down on the floor every
    // run (#674): the build-time manifest dir they used to be read from does
    // not exist on a host that installed a release.
    let script = match scripts::install(&home) {
        Ok(p) => p,
        Err(e) => {
            eprintln!(
                "fwf seats: seat scripts: {} ({e})",
                home.join(".fwf").display()
            );
            return ExitCode::from(1);
        }
    };
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
        // Every run, not only the clone: a seat that commits as the machine (or
        // as whoever hand-edited it) is put back to committing as itself (#590).
        if let Err(e) = set_seat_identity(&wt, &pane) {
            eprintln!("  {target:<18} identity: {e}");
            failures += 1;
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
        let st = std::process::Command::new(&script)
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
    // The gate worktree is cloned on demand by the loop, not here; stamp it
    // when it is already there so `fwf doctor` sees the whole floor.
    let gate_wt = floor.join("gate-wt");
    if gate_wt.join(".git").exists() {
        if let Err(e) = set_seat_identity(&gate_wt, GATE_IDENTITY) {
            eprintln!("  {:<18} identity: {e}", "gate-wt");
            failures += 1;
        }
    }
    if failures > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

pub fn run_loop(args: &[String]) -> ExitCode {
    // Before anything else has happened, so the loop the operator will have to
    // signal is called `fwf-run` and not `fwf` (#678).
    crate::proctitle::retitle("run");
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    let m = match manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwf run: {e}");
            return ExitCode::from(2);
        }
    };
    if m.issues.is_empty() {
        eprintln!("fwf run: the manifest has no `issues` allow-list; refusing to run against every eligible issue while 1.0 is new");
        return ExitCode::from(2);
    }
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwf run: {e}");
            return ExitCode::from(2);
        }
    };
    let floor = m.floor();
    // One loop per floor, and one the operator can name (#675): two would
    // both plan, both claim and both wake the same panes.
    match pidfile::claim(&floor, std::process::id()) {
        Ok(p) => println!("fwf run: pid {} ({})", std::process::id(), p.display()),
        Err(e) => {
            eprintln!("fwf run: {e}");
            return ExitCode::from(1);
        }
    }
    let (run_log, mirror_dir) = slice::defaults(&floor);
    let seats = |role: &str| -> Vec<(u8, String)> {
        (1..=m.pairs).map(|n| (n, m.seat_target(role, n))).collect()
    };
    let cfg = run::RunConfig {
        owner: m.owner().to_string(),
        repo: m.name().to_string(),
        base_branch: m.base_branch.clone(),
        gate_label: m.gate_label.clone(),
        floor_dir: floor.clone(),
        mirror_dir,
        run_log,
        impl_seats: seats("impl"),
        qa_seats: seats("qa"),
        seat_expect_cmd: "claude".into(),
        interval: Duration::from_secs(m.poll_interval_secs),
        job_timeout: Duration::from_secs(m.job_timeout_secs),
        stall_quiet: Duration::from_secs(m.stall_quiet_secs),
        once: args.iter().any(|a| a == "--once"),
        prompts_dir: PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/prompts")),
        template: m.template.clone(),
        allow_issues: m.issues.clone(),
        skip_labels: m.skip_labels.clone(),
        triage_new: m.triage_new,
        gv_seat: m.models.contains_key("gv").then(|| m.seat_target("gv", 1)),
        auto_spec: m.auto_spec,
        pm_seat: m.models.contains_key("pm").then(|| m.seat_target("pm", 1)),
        review_scope: run::ReviewScope::from_manifest(&m.review_scope),
        delegate_ungate: m.delegate_ungate.clone(),
        park_at_weekly_pct: m.park_at_weekly_pct,
        rework_cap: m.rework_cap,
        reviewers: m.review_logins(),
        gate_suite: m.fast_suite.clone(),
        gate_cmd: m.suites.get(&m.fast_suite).cloned().unwrap_or_default(),
        gate_venue: m.gate_venue.clone(),
        gate_memory_gb: m.gate_memory_gb,
        gate_timeout: Duration::from_secs(m.gate_timeout_secs),
    };
    match run::run(&cfg, &apps) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("fwf run: {e}");
            ExitCode::from(1)
        }
    }
}

pub fn up(args: &[String]) -> ExitCode {
    // A box restored from a hibernate snapshot runs whatever fwf it was
    // snapshotted with (#653). It does not get to start a floor on that
    // quietly — but an unreachable GitHub is a warning, never a refusal.
    match upgrade::up_gate(&upgrade::check_release(), upgrade::allow_stale()) {
        upgrade::UpGate::Go => {}
        upgrade::UpGate::Warn(m) => eprintln!("fwf up: {m}"),
        upgrade::UpGate::Refuse(m) => {
            eprintln!("fwf up: {m}");
            return ExitCode::from(1);
        }
    }
    let path = get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest::Manifest::default_path(Path::new(".")));
    let m = match manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwf up: {e}");
            return ExitCode::from(2);
        }
    };
    println!("manifest {} ok: repo {} · {} → {} · gate label {:?} · {} pair(s) · session {} · venue {} ({} GB, {} s) · suites {:?}{}",
        path.display(), m.repo, m.base_branch, m.release_branch, m.gate_label, m.pairs, m.session, m.gate_venue, m.gate_memory_gb, m.gate_timeout_secs, m.suites.keys().collect::<Vec<_>>(), m.delegate_ungate.as_deref().map(|d| format!(" · delegate_ungate {d}")).unwrap_or_default());
    println!("  floor: {}", m.floor().display());
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwf up: {e}");
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

/// `fwf ready --repo o/r --pr N`: mark a draft PR ready under the impl App
/// (the same call the loop makes), printing the exact refusal if any.
pub fn ready(args: &[String]) -> ExitCode {
    let (Some(repo), Some(pr)) = (
        get(args, "--repo"),
        get(args, "--pr").and_then(|s| s.parse::<u64>().ok()),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let apps = match github::load_apps(&github::apps_path()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("fwf ready: {e}");
            return ExitCode::from(2);
        }
    };
    let by = get(args, "--by").unwrap_or_else(|| "impl".into());
    let Some(app) = apps.0.get(by.as_str()) else {
        eprintln!("fwf ready: no [{by}] app");
        return ExitCode::from(2);
    };
    let rw = std::collections::BTreeMap::from([
        ("pull_requests", "write"),
        ("contents", if by == "ops" { "write" } else { "read" }),
        ("metadata", "read"),
    ]);
    let tok = match github::mint(app, Some(&rw)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("fwf ready: {e}");
            return ExitCode::from(2);
        }
    };
    let (code, body) = match github::get_status(&tok.token, &format!("/repos/{repo}/pulls/{pr}")) {
        Ok(x) => x,
        Err(e) => {
            eprintln!("fwf ready: {e}");
            return ExitCode::from(1);
        }
    };
    if code != 200 {
        eprintln!("fwf ready: cannot read PR ({code})");
        return ExitCode::from(1);
    }
    let v: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
    if v["draft"].as_bool() != Some(true) {
        println!("#{pr}: already ready");
        return ExitCode::SUCCESS;
    }
    match github::mark_ready(&tok.token, v["node_id"].as_str().unwrap_or("")) {
        Ok(true) => {
            println!("#{pr}: marked ready under the {by} App (id {})", app.app_id);
            ExitCode::SUCCESS
        }
        Ok(false) => {
            eprintln!("#{pr}: GitHub answered but the PR is still a draft");
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("#{pr}: {e}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fwfd-identity-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn repo(at: &Path) {
        std::fs::create_dir_all(at).unwrap();
        let ok = std::process::Command::new("git")
            .arg("-C")
            .arg(at)
            .args(["init", "-q"])
            .status()
            .unwrap()
            .success();
        assert!(ok, "git init in {}", at.display());
    }

    /// #590: a seat commits as itself, and keeps doing so after a hand-edit.
    #[test]
    fn a_seat_worktree_commits_as_itself_and_drift_is_corrected() {
        let floor = tmp();
        let wt = floor.join("wt-impl1");
        repo(&wt);
        // a fresh clone has no identity of its own: git would guess one
        assert_eq!(seat_identity(&wt), None);
        set_seat_identity(&wt, "impl1").unwrap();
        assert_eq!(
            seat_identity(&wt),
            Some(("impl1".into(), "impl1@fwf.local".into()))
        );
        // and it is the identity git actually uses, not merely a value on disk
        let ident = std::process::Command::new("git")
            .arg("-C")
            .arg(&wt)
            .args(["var", "GIT_AUTHOR_IDENT"])
            .output()
            .unwrap();
        let ident = String::from_utf8_lossy(&ident.stdout);
        assert!(ident.starts_with("impl1 <impl1@fwf.local>"), "{ident}");
        // and a commit made there carries it, author and committer both —
        // which is the whole point: `git log` can tell the seats apart
        std::fs::write(wt.join("fix.txt"), "a seat's work").unwrap();
        for args in [vec!["add", "."], vec!["commit", "-q", "-m", "from a seat"]] {
            assert!(std::process::Command::new("git")
                .arg("-C")
                .arg(&wt)
                .args(&args)
                .status()
                .unwrap()
                .success());
        }
        let who = std::process::Command::new("git")
            .arg("-C")
            .arg(&wt)
            .args(["log", "-1", "--format=%an <%ae> | %cn <%ce>"])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8_lossy(&who.stdout).trim(),
            "impl1 <impl1@fwf.local> | impl1 <impl1@fwf.local>"
        );
        // someone edits it to a person, or the operator's own name leaks in
        std::process::Command::new("git")
            .arg("-C")
            .arg(&wt)
            .args(["config", "user.email", "jamie@example.com"])
            .status()
            .unwrap();
        set_seat_identity(&wt, "impl1").unwrap();
        assert_eq!(
            seat_identity(&wt),
            Some(("impl1".into(), "impl1@fwf.local".into()))
        );
        // a path that is not a repo is a refusal, not a panic
        assert!(set_seat_identity(&floor.join("nope"), "impl1").is_err());
        let _ = std::fs::remove_dir_all(&floor);
    }

    /// #590: what `fwf doctor` prints, and what it counts as wrong.
    #[test]
    fn doctor_names_the_worktree_that_commits_as_someone_else() {
        let floor = tmp();
        let seats = [("impl", 1u8), ("qa", 1u8), ("gv", 1u8)];
        // impl1 correct, qa1 drifted, gv1 never provisioned, gate-wt correct
        repo(&floor.join("wt-impl1"));
        set_seat_identity(&floor.join("wt-impl1"), "impl1").unwrap();
        repo(&floor.join("wt-qa1"));
        set_seat_identity(&floor.join("wt-qa1"), "somebody-else").unwrap();
        repo(&floor.join("gate-wt"));
        set_seat_identity(&floor.join("gate-wt"), GATE_IDENTITY).unwrap();
        let (lines, wrong) = identity_report(&floor, &seats);
        assert_eq!(wrong, 1, "{lines:#?}");
        assert!(lines[0].contains("wt-impl1") && lines[0].contains("impl1 <impl1@fwf.local>"));
        assert!(
            lines[1].contains("WRONG: somebody-else <somebody-else@fwf.local>")
                && lines[1].contains("expected qa1 <qa1@fwf.local>"),
            "{}",
            lines[1]
        );
        assert!(lines[2].contains("wt-gv1") && lines[2].contains("not provisioned"));
        assert!(lines[3].contains("gate-wt") && lines[3].contains("fwf-gate@fwf.local"));
        // a provisioned worktree with no identity at all is wrong too
        repo(&floor.join("wt-gv1"));
        let (lines, wrong) = identity_report(&floor, &seats);
        assert_eq!(wrong, 2, "{lines:#?}");
        assert!(lines[2].contains("no identity of its own"), "{}", lines[2]);
        // every seat right: nothing for a human to do
        set_seat_identity(&floor.join("wt-qa1"), "qa1").unwrap();
        set_seat_identity(&floor.join("wt-gv1"), "gv1").unwrap();
        assert_eq!(identity_report(&floor, &seats).1, 0);
        let _ = std::fs::remove_dir_all(&floor);
    }
}
