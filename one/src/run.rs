//! `fwfd run` — the supervisor loop (M1 shape).
//!
//! poll → plan → act, forever (or `--once`). An idle floor costs GitHub reads
//! only (ETag-cached, mostly 304s) and zero model requests: seats are warm
//! panes that are only ever woken with a job. Cycles run one at a time per
//! seat; the loop is single-threaded on purpose so that every GitHub write is
//! serialised through this one process.

use crate::github::Apps;
use crate::poll::Poller;
use crate::qa::{self, QaConfig};
use crate::sched::{plan, Action, SeatSlot};
use crate::slice::{self, SliceConfig};
use crate::types::{Role, SeatState};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

pub struct RunConfig {
    pub owner: String,
    pub repo: String,
    pub base_branch: String,
    pub gate_label: String,
    pub floor_dir: PathBuf,
    pub mirror_dir: PathBuf,
    pub run_log: PathBuf,
    pub impl_seats: Vec<(u8, String)>, // (seat number, tmux target)
    pub qa_seats: Vec<(u8, String)>,
    pub seat_expect_cmd: String,
    pub interval: Duration,
    pub job_timeout: Duration,
    pub once: bool,
    pub prompts_dir: PathBuf,
    /// If non-empty, only these issues are ever planned.
    pub allow_issues: Vec<u64>,
    /// Conductor-as-code: after every merge, run this suite on the new base
    /// tip in the floor's gate worktree and post a check-run under ops.
    pub gate_suite: String,
    pub gate_cmd: String,
    pub gate_venue: String,
    pub gate_memory_gb: u32,
    pub gate_timeout: Duration,
}

pub fn run(cfg: &RunConfig, apps: &Apps) -> Result<(), String> {
    let impl_app = apps.0.get("impl").ok_or("no [impl] app")?;
    let qa_app = apps.0.get("qa").ok_or("no [qa] app")?;
    let ops_app = apps.0.get("ops");
    let read_perms = BTreeMap::from([
        ("issues", "read"),
        ("pull_requests", "read"),
        ("contents", "read"),
        ("metadata", "read"),
    ]);
    let mut cycles = 0u64;
    loop {
        let tok = crate::github::mint(impl_app, Some(&read_perms)).map_err(|e| e.to_string())?;
        let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
        let now = crate::seat::now();
        let mut snap = match poller.poll(now) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("fwfd run: poll failed ({e}); holding this tick");
                if cfg.once {
                    return Err(e.to_string());
                }
                std::thread::sleep(cfg.interval);
                continue;
            }
        };
        // Issues already shipped (their PR merged to the base branch) stay open
        // on GitHub until the release fast-forwards `main`; the run record is
        // the source of truth that they are done, so they are never re-planned.
        if let Ok(evs) = crate::log::read_all(&cfg.run_log) {
            let shipped: std::collections::BTreeSet<u64> = evs
                .iter()
                .filter_map(|e| match &e.kind {
                    crate::log::Kind::Issue {
                        issue,
                        to: crate::types::IssueState::Shipped { .. },
                    } => Some(*issue),
                    _ => None,
                })
                .collect();
            snap.issues.retain(|i| !shipped.contains(&i.number));
        }
        if !cfg.allow_issues.is_empty() {
            snap.issues.retain(|i| cfg.allow_issues.contains(&i.number));
            snap.prs.retain(|p| {
                p.closes_issue
                    .is_some_and(|n| cfg.allow_issues.contains(&n))
            });
        }
        // Every configured seat is presented as Idle: a pane whose foreground
        // command is not claude is refused by wake() and logged, which is the
        // liveness check — no tick files.
        let mut seats: Vec<SeatSlot> = Vec::new();
        for (n, _) in &cfg.impl_seats {
            seats.push(SeatSlot {
                seat: *n,
                role: Role::Impl,
                state: SeatState::Idle,
            });
        }
        for (n, _) in &cfg.qa_seats {
            seats.push(SeatSlot {
                seat: *n,
                role: Role::Qa,
                state: SeatState::Idle,
            });
        }
        let p = plan(&snap, &seats, &cfg.gate_label, true, now);
        let mut acted = 0;
        for a in &p.actions {
            match a {
                Action::WakeImpl { seat, issue } => {
                    let Some((_, target)) = cfg.impl_seats.iter().find(|(n, _)| n == seat) else {
                        continue;
                    };
                    let sc = SliceConfig {
                        owner: cfg.owner.clone(),
                        repo: cfg.repo.clone(),
                        issue: *issue,
                        base_branch: cfg.base_branch.clone(),
                        gate_label: cfg.gate_label.clone(),
                        seat_target: target.clone(),
                        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
                        floor_dir: cfg.floor_dir.clone(),
                        mirror_dir: cfg.mirror_dir.clone(),
                        job_template: cfg.prompts_dir.join("impl-job.md"),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                        dry_run: false,
                    };
                    match slice::run_with(&sc, impl_app, ops_app) {
                        Ok(url) => println!("fwfd run: impl seat {seat} → {url}"),
                        Err(e) => eprintln!("fwfd run: impl cycle for #{issue} failed: {}", e.0),
                    }
                    acted += 1;
                }
                Action::WakeQa { seat, pr } => {
                    let Some((_, target)) = cfg.qa_seats.iter().find(|(n, _)| n == seat) else {
                        continue;
                    };
                    let qc = QaConfig {
                        owner: cfg.owner.clone(),
                        repo: cfg.repo.clone(),
                        pr: *pr,
                        seat_target: target.clone(),
                        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
                        seat_no: *seat,
                        floor_dir: cfg.floor_dir.clone(),
                        mirror_dir: cfg.mirror_dir.clone(),
                        job_template: cfg.prompts_dir.join("qa-job.md"),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                    };
                    match qa::run(&qc, qa_app) {
                        Ok((id, state)) => {
                            println!("fwfd run: qa seat {seat} → review {id} {state} on #{pr}");
                            if state == "APPROVED" {
                                // The loop finishes the job: ready-for-review under the
                                // author App, then the typed merge under ops. Every
                                // precondition is re-checked inside merge_pr.
                                match finish_pr(cfg, apps, *pr) {
                                    Ok(sha) => {
                                        println!("fwfd run: merged #{pr} as {}", sha.short());
                                        match gate_after_merge(cfg, apps, &sha) {
                                            Ok(state) => println!(
                                                "fwfd run: gate {} {} → {state:?}",
                                                sha.short(),
                                                cfg.gate_suite
                                            ),
                                            Err(e) => eprintln!(
                                                "fwfd run: gate on {} not recorded: {e}",
                                                sha.short()
                                            ),
                                        }
                                    }
                                    Err(e) => {
                                        eprintln!("fwfd run: #{pr} approved but not merged: {e}")
                                    }
                                }
                            }
                        }
                        Err(e) => eprintln!("fwfd run: qa cycle for #{pr} failed: {}", e.0),
                    }
                    acted += 1;
                }
                Action::ReleaseClaim { issue, fence } => {
                    eprintln!("fwfd run: claim on #{issue} ({}) is stale; release is an operator decision in M1", fence.0);
                }
                Action::Nothing => {}
            }
        }
        cycles += 1;
        println!(
            "fwfd run: tick {cycles}: {} issues, {} prs, {} actions, {} requests ({} not-modified)",
            snap.issues.len(),
            snap.prs.len(),
            acted,
            poller.requests(),
            poller.not_modified()
        );
        if cfg.once {
            return Ok(());
        }
        std::thread::sleep(cfg.interval);
    }
}

/// Ready-for-review (author App) + typed merge (ops). Returns the merge sha.
fn finish_pr(cfg: &RunConfig, apps: &Apps, pr: u64) -> Result<crate::types::Sha, String> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let impl_app = apps.0.get("impl").ok_or("no [impl] app")?;
    let ops_app = apps.0.get("ops").ok_or("no [ops] app")?;
    let rw = BTreeMap::from([
        ("pull_requests", "write"),
        ("contents", "read"),
        ("metadata", "read"),
    ]);
    let itok = crate::github::mint(impl_app, Some(&rw)).map_err(|e| e.to_string())?;
    let (code, body) = crate::github::get_status(&itok.token, &format!("/repos/{repo}/pulls/{pr}"))
        .map_err(|e| e.to_string())?;
    if code != 200 {
        return Err(format!("cannot read PR ({code})"));
    }
    let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    if v["draft"].as_bool() == Some(true) {
        let node = v["node_id"].as_str().unwrap_or("");
        if !crate::github::mark_ready(&itok.token, node).map_err(|e| e.to_string())? {
            return Err("could not mark ready".into());
        }
    }
    let issue = v["body"]
        .as_str()
        .and_then(crate::poll::closes_issue)
        .ok_or("PR closes no issue")?;
    let ops_perms = BTreeMap::from([
        ("contents", "write"),
        ("pull_requests", "write"),
        ("issues", "read"),
        ("checks", "read"),
        ("metadata", "read"),
    ]);
    let otok = crate::github::mint(ops_app, Some(&ops_perms)).map_err(|e| e.to_string())?;
    let (code, body) = crate::github::get_status(
        &otok.token,
        &format!("/repos/{repo}/git/ref/claims/{issue}"),
    )
    .map_err(|e| e.to_string())?;
    if code != 200 {
        return Err(format!("no live claim ref for #{issue}"));
    }
    let fence = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| {
            v["object"]["sha"]
                .as_str()
                .map(|s| crate::types::Fence(s.to_string()))
        })
        .ok_or("bad claim ref")?;
    let client = crate::merge::Client {
        base_url: "https://api.github.com".into(),
        token: otok.token.clone(),
    };
    let mut log = crate::log::Log::open(&cfg.run_log).map_err(|e| e.to_string())?;
    crate::merge::merge_pr(&client, &repo, pr, &fence, &mut log).map_err(|e| e.to_string())
}

/// The conductor, as code: check out the merge sha in the floor's gate
/// worktree (from the mirror), run the manifest's suite in the configured
/// venue, record the verdict, post a check-run under ops. Never on a seat's
/// worktree; never on the floor's live tree.
fn gate_after_merge(
    cfg: &RunConfig,
    apps: &Apps,
    sha: &crate::types::Sha,
) -> Result<crate::types::GateState, String> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let mirror =
        crate::mirror::Mirror::init(&cfg.mirror_dir, &format!("https://github.com/{repo}.git"))
            .map_err(|e| e.to_string())?;
    mirror.fetch().map_err(|e| e.to_string())?;
    let wt = cfg.floor_dir.join("gate-wt");
    let sh = |args: &[&str], dir: &std::path::Path| -> Result<(), String> {
        let out = std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .output()
            .map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
        }
    };
    if !wt.join(".git").exists() {
        sh(
            &[
                "clone",
                "-q",
                &mirror.seat_remote_url(),
                wt.to_str().unwrap_or("."),
            ],
            &cfg.floor_dir,
        )?;
    }
    sh(&["fetch", "-q", "origin"], &wt)?;
    sh(&["checkout", "-q", "--detach", sha.as_str()], &wt)?;
    let venue = match cfg.gate_venue.as_str() {
        "container" => crate::gate::Venue::AppleContainer {
            image: "alpine:latest".into(),
        },
        "systemd" => crate::gate::Venue::SystemdRun,
        _ => crate::gate::Venue::Local,
    };
    let g = crate::gate::Gate {
        venue,
        memory_gb: cfg.gate_memory_gb,
        timeout: cfg.gate_timeout,
        workdir: wt.clone(),
    };
    let log_path = cfg
        .floor_dir
        .join(format!("gate-{}-{}.log", sha.short(), cfg.gate_suite));
    let state = g.run(sha, &cfg.gate_suite, &cfg.gate_cmd, &log_path);
    if let Ok(mut l) = crate::log::Log::open(&cfg.run_log) {
        let _ = l.append(&crate::log::Event {
            ts: crate::seat::now(),
            repo: repo.clone(),
            kind: crate::log::Kind::Gate { to: state.clone() },
        });
    }
    let ops = apps.0.get("ops").ok_or("no [ops] app")?;
    let perms = BTreeMap::from([("checks", "write"), ("metadata", "read")]);
    let tok = crate::github::mint(ops, Some(&perms)).map_err(|e| e.to_string())?;
    let client = crate::checks::CheckClient {
        base_url: "https://api.github.com".into(),
        token: tok.token,
    };
    crate::checks::post_check_run(
        &client,
        &repo,
        sha,
        &format!("fwfd/{}", cfg.gate_suite),
        &state,
        None,
    )
    .map_err(|e| format!("{e:?}"))?;
    Ok(state)
}
