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
}

pub fn run(cfg: &RunConfig, apps: &Apps) -> Result<(), String> {
    let impl_app = apps.0.get("impl").ok_or("no [impl] app")?;
    let qa_app = apps.0.get("qa").ok_or("no [qa] app")?;
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
        let snap = match poller.poll(now) {
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
                    match slice::run(&sc, impl_app) {
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
                            println!("fwfd run: qa seat {seat} → review {id} {state} on #{pr}")
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
