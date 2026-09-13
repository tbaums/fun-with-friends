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
    /// Prompt family under prompts_dir (manifest `template`).
    pub template: String,
    /// If non-empty, only these issues are ever planned.
    pub allow_issues: Vec<u64>,
    /// Issues carrying any of these labels are never planned (0.x holds:
    /// idea, release-hold, tracking epics).
    pub skip_labels: Vec<String>,
    /// GV triage of new issues each tick (manifest `triage_new`); needs a GV seat.
    pub triage_new: bool,
    pub gv_seat: Option<String>,
    /// Park the floor while the last logged weekly meter % is at or above this.
    pub park_at_weekly_pct: u8,
    /// How many rework rounds one PR may have before it becomes a human's
    /// decision (manifest `rework_cap`).
    pub rework_cap: u32,
    /// Conductor-as-code: after every merge, run this suite on the new base
    /// tip in the floor's gate worktree and post a check-run under ops.
    pub gate_suite: String,
    pub gate_cmd: String,
    pub gate_venue: String,
    pub gate_memory_gb: u32,
    pub gate_timeout: Duration,
}

/// Issues the record already judged: a Gated event, a "judged ready" note,
/// or a human un-gate. Triage never runs twice on the same issue.
pub fn triaged_issues(events: &[crate::log::Event]) -> std::collections::BTreeSet<u64> {
    use crate::log::Kind;
    use crate::types::IssueState;
    let mut out = std::collections::BTreeSet::new();
    for e in events {
        match &e.kind {
            Kind::Issue {
                issue,
                to: IssueState::Gated | IssueState::Ready,
            } => {
                out.insert(*issue);
            }
            Kind::Note { text } if text.starts_with("GV triage: #") => {
                if let Some(n) = text["GV triage: #".len()..]
                    .split(|c: char| !c.is_ascii_digit())
                    .next()
                    .and_then(|s| s.parse().ok())
                {
                    out.insert(n);
                }
            }
            _ => {}
        }
    }
    out
}

/// Open, un-gated, not parked by a `skip_labels` tag, never-triaged, and not
/// already carrying work (a claim or an assignee means a human or a seat is
/// past the question). Oldest first.
///
/// The skip labels matter here as much as they do to the scheduler: an `idea`
/// or `tracking` ticket is parked on purpose, and GV labels and comments on
/// whatever it is offered (#585 — transom's #374, an `idea`).
pub fn triage_candidates(
    snap: &crate::poll::Snapshot,
    gate_label: &str,
    skip_labels: &[String],
    seen: &std::collections::BTreeSet<u64>,
) -> Vec<u64> {
    let mut v: Vec<u64> = snap
        .issues
        .iter()
        .filter(|i| {
            i.state == "open"
                && !i.labels.iter().any(|l| l == gate_label)
                && !i.labels.iter().any(|l| skip_labels.contains(l))
                && i.assignees.is_empty()
                && i.claim.is_none()
                && !seen.contains(&i.number)
        })
        .map(|i| i.number)
        .collect();
    v.sort_unstable();
    v
}

fn ready_or_gated_in_record(run_log: &std::path::Path, issue: u64) -> bool {
    crate::log::read_all(run_log)
        .map(|evs| triaged_issues(&evs).contains(&issue))
        .unwrap_or(false)
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
    // A previous supervisor interrupted mid-wait leaves a seat Working in the
    // record with no terminal event; say so before planning anything.
    match crate::log::reconcile_stale_working(
        &cfg.run_log,
        &format!("{}/{}", cfg.owner, cfg.repo),
        crate::seat::now(),
    ) {
        Ok(0) | Err(_) => {}
        Ok(n) => eprintln!("run: {n} stale Working seat(s) from an interrupted run marked Stalled"),
    }
    loop {
        // Meter brake (T-28): the operator's meter log is the only source of
        // subscription usage; park while the last logged weekly % is at or
        // above the manifest threshold, re-reading every interval.
        if let Some((weekly, when)) = last_meter_reading() {
            // A reading older than METER_MAX_AGE is not a reading: the
            // operator's meter helper (or its session) is gone, and a loop
            // that cannot see the meter must not spend.
            let age = meter_age_secs(&when, crate::seat::now());
            if age.is_none_or(|a| a > METER_MAX_AGE) {
                println!(
                    "fwfd run: PARKED — last meter reading is {} (logged {when}); no seats woken until a fresh reading lands in ~/.fwf-meter-log",
                    age.map(|a| format!("{}m old", a / 60)).unwrap_or_else(|| "unparseable".into())
                );
                if cfg.once {
                    return Ok(());
                }
                std::thread::sleep(cfg.interval);
                continue;
            }
            if weekly >= cfg.park_at_weekly_pct {
                println!("fwfd run: PARKED — weekly meter {weekly}% ≥ {}% (logged {when}); no seats woken", cfg.park_at_weekly_pct);
                if cfg.once {
                    return Ok(());
                }
                std::thread::sleep(cfg.interval);
                continue;
            }
        }
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
        // GitHub's list endpoints lag a few seconds behind a just-opened PR;
        // if the run record shows a recent draft the snapshot lacks, re-poll
        // once so the QA cycle is not delayed by a whole tick.
        if let Ok(evs) = crate::log::read_all(&cfg.run_log) {
            let merged: std::collections::BTreeSet<u64> = evs
                .iter()
                .filter_map(|e| match &e.kind {
                    crate::log::Kind::Pr {
                        pr,
                        to: crate::types::PrState::Merged { .. },
                        ..
                    } => Some(*pr),
                    _ => None,
                })
                .collect();
            let recent_prs: Vec<u64> = evs
                .iter()
                .filter(|e| now.saturating_sub(e.ts) < 600)
                .filter_map(|e| match &e.kind {
                    crate::log::Kind::Pr {
                        pr,
                        to: crate::types::PrState::Draft { .. },
                        ..
                    } if !merged.contains(pr) => Some(*pr),
                    _ => None,
                })
                .collect();
            let missing = recent_prs
                .iter()
                .any(|n| !snap.prs.iter().any(|p| p.number == *n));
            if missing {
                std::thread::sleep(Duration::from_secs(3));
                if let Ok(s2) = poller.poll(now) {
                    snap = s2;
                }
            }
        }
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
        // GV triage (T-23 inside the loop): before the allow-list narrows the
        // snapshot, judge every open un-gated issue the record has never seen.
        // The skip labels apply here too — this runs before the retain below.
        if cfg.triage_new {
            if let Some(gv) = &cfg.gv_seat {
                let seen = triaged_issues(&crate::log::read_all(&cfg.run_log).unwrap_or_default());
                for n in triage_candidates(&snap, &cfg.gate_label, &cfg.skip_labels, &seen) {
                    let Some(ops) = ops_app else { break };
                    let tcfg = crate::triage::TriageConfig {
                        owner: cfg.owner.clone(),
                        repo: cfg.repo.clone(),
                        issue: n,
                        gate_label: cfg.gate_label.clone(),
                        seat_target: gv.clone(),
                        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
                        floor_dir: cfg.floor_dir.clone(),
                        job_template: crate::prompts::path(&cfg.prompts_dir, &cfg.template, "gv"),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                    };
                    match crate::triage::run(&tcfg, ops) {
                        Ok((ready, reason)) => eprintln!(
                            "run: triage #{n}: {} — {reason}",
                            if ready {
                                "ready (awaiting un-gate)"
                            } else {
                                "gated"
                            }
                        ),
                        Err(e) => {
                            eprintln!("run: triage #{n} failed: {}", e.0);
                            break;
                        }
                    }
                    if !ready_or_gated_in_record(&cfg.run_log, n) {
                        break;
                    }
                }
            }
        }
        snap.issues
            .retain(|i| !i.labels.iter().any(|l| cfg.skip_labels.contains(l)));
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
                        // The seat this plan picked, so the slice's own recheck
                        // asks about the same seat the loop dispatched (#579).
                        seat: *seat,
                        seat_target: target.clone(),
                        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
                        floor_dir: cfg.floor_dir.clone(),
                        mirror_dir: cfg.mirror_dir.clone(),
                        job_template: crate::prompts::path(&cfg.prompts_dir, &cfg.template, "impl"),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                        dry_run: false,
                        check_cmd: cfg.gate_cmd.clone(),
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
                        job_template: crate::prompts::path(&cfg.prompts_dir, &cfg.template, "qa"),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                        check_cmd: cfg.gate_cmd.clone(),
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
                Action::FinishPr { pr } => {
                    match finish_pr(cfg, apps, *pr) {
                        Ok(sha) => {
                            println!(
                                "fwfd run: merged #{pr} as {} (approval was already at head)",
                                sha.short()
                            );
                            match gate_after_merge(cfg, apps, &sha) {
                                Ok(state) => println!(
                                    "fwfd run: gate {} {} → {state:?}",
                                    sha.short(),
                                    cfg.gate_suite
                                ),
                                Err(e) => {
                                    eprintln!("fwfd run: gate on {} not recorded: {e}", sha.short())
                                }
                            }
                        }
                        Err(e) => eprintln!("fwfd run: #{pr} approved but not merged: {e}"),
                    }
                    acted += 1;
                }
                Action::Rework { seat, pr, issue } => {
                    let Some((_, target)) = cfg.impl_seats.iter().find(|(n, _)| n == seat) else {
                        continue;
                    };
                    let rc = crate::rework::ReworkConfig {
                        owner: cfg.owner.clone(),
                        repo: cfg.repo.clone(),
                        pr: *pr,
                        seat_no: *seat,
                        seat_target: target.clone(),
                        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
                        base_branch: cfg.base_branch.clone(),
                        floor_dir: cfg.floor_dir.clone(),
                        mirror_dir: cfg.mirror_dir.clone(),
                        job_template: crate::prompts::rework_path(&cfg.prompts_dir, &cfg.template),
                        run_log: cfg.run_log.clone(),
                        timeout: cfg.job_timeout,
                        check_cmd: cfg.gate_cmd.clone(),
                        cap: cfg.rework_cap,
                    };
                    match crate::rework::run(&rc, impl_app, ops_app) {
                        Ok(crate::rework::Outcome::Pushed { head, round }) => println!(
                            "fwfd run: impl seat {seat} reworked #{pr} (round {round}) → {}",
                            head.short()
                        ),
                        // Past the cap nothing is closed and no issue released:
                        // two passes that did not convince QA are a human's call.
                        Ok(crate::rework::Outcome::AtCap { rounds }) => eprintln!(
                            "fwfd run: #{pr} has had {rounds} rework round(s) (cap {}); close it or push it yourself — the loop will not wake the seat again",
                            cfg.rework_cap
                        ),
                        Ok(crate::rework::Outcome::Gone) => {
                            println!("fwfd run: #{pr} is no longer open; nothing to rework")
                        }
                        Err(e) => eprintln!(
                            "fwfd run: rework of #{pr}{} failed: {}",
                            issue.map(|i| format!(" (#{i})")).unwrap_or_default(),
                            e.0
                        ),
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
        // Undrafting needs contents:write on a private repo ("Resource not
        // accessible by integration" for the impl App, proven on diaspective
        // #11), so the ops identity does it; the PR's author stays impl.
        let undraft = BTreeMap::from([
            ("pull_requests", "write"),
            ("contents", "write"),
            ("metadata", "read"),
        ]);
        let otok = crate::github::mint(ops_app, Some(&undraft)).map_err(|e| e.to_string())?;
        let node = v["node_id"].as_str().unwrap_or("");
        match crate::github::mark_ready(&otok.token, node) {
            Ok(true) => {}
            Ok(false) => {
                return Err("could not mark ready: still a draft after the mutation".into())
            }
            Err(e) => return Err(format!("could not mark ready: {e}")),
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
    let read_tok = apps
        .0
        .get("ops")
        .map(|a| {
            crate::github::mint(
                a,
                Some(&BTreeMap::from([
                    ("contents", "read"),
                    ("metadata", "read"),
                ])),
            )
            .map(|t| t.token)
        })
        .transpose()
        .map_err(|e| e.to_string())?
        .unwrap_or_default();
    let mirror = crate::mirror::Mirror::init_with(
        &cfg.mirror_dir,
        &format!("https://github.com/{repo}.git"),
        &read_tok,
    )
    .map_err(|e| e.to_string())?;
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

/// Last `weekly=NN` from ~/.fwf-meter-log (written by the operator's meter
/// tick). Returns (percent, the line's timestamp). None if unreadable.
/// The last reading the operator's meter helper logged: (weekly %, session %,
/// "date time"). Only lines carrying `weekly=` count; nothing is inferred.
pub fn last_meter() -> Option<(u8, Option<u8>, String)> {
    let home = std::env::var_os("HOME")?;
    let text = std::fs::read_to_string(PathBuf::from(home).join(".fwf-meter-log")).ok()?;
    let pct = |line: &str, key: &str| -> Option<u8> {
        let i = line.find(key)?;
        line[i + key.len()..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .ok()
    };
    for line in text.lines().rev() {
        if let Some(w) = pct(line, "weekly=") {
            let when = line
                .split_whitespace()
                .take(2)
                .collect::<Vec<_>>()
                .join(" ");
            return Some((w, pct(line, "session="), when));
        }
    }
    None
}

/// How old a meter reading may be before the loop treats it as absent.
pub const METER_MAX_AGE: u64 = 45 * 60;

/// Age of a "YYYY-MM-DD HH:MM:SS" local-time stamp, in seconds. The meter
/// log is written by `date` on this machine, so local time is compared with
/// local time via `date -j` — no timezone arithmetic in Rust.
pub fn meter_age_secs(when: &str, now: u64) -> Option<u64> {
    let ts = local_stamp_to_epoch(when)?;
    Some(now.saturating_sub(ts))
}

/// `YYYY-MM-DD HH:MM:SS` in the local zone → epoch seconds, via the system
/// `date`: BSD (`-j -f`, macOS) first, then GNU (`-d`, Linux). `None` when
/// neither accepts the stamp — a stale-or-garbage meter must park, never guess.
fn local_stamp_to_epoch(when: &str) -> Option<u64> {
    let bsd = ["-j", "-f", "%Y-%m-%d %H:%M:%S", when, "+%s"];
    let gnu = ["-d", when, "+%s"];
    for args in [&bsd[..], &gnu[..]] {
        if let Ok(out) = std::process::Command::new("date").args(args).output() {
            if out.status.success() {
                if let Ok(ts) = String::from_utf8_lossy(&out.stdout).trim().parse::<u64>() {
                    return Some(ts);
                }
            }
        }
    }
    None
}

fn last_meter_reading() -> Option<(u8, String)> {
    last_meter().map(|(w, _, when)| (w, when))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::{Event, Kind};
    use crate::poll::{IssueView, Snapshot};
    use crate::types::IssueState;

    fn issue(n: u64, labels: &[&str], claimed: bool) -> IssueView {
        IssueView {
            number: n,
            title: format!("issue {n}"),
            author_association: "OWNER".into(),
            labels: labels.iter().map(|s| s.to_string()).collect(),
            assignees: vec![],
            state: "open".into(),
            updated_at: String::new(),
            claim: if claimed {
                Some(crate::types::Fence("f".repeat(40)))
            } else {
                None
            },
        }
    }

    #[test]
    fn meter_age_parses_a_local_stamp_and_rejects_garbage() {
        let now = crate::seat::now();
        // Render `now - 600` as a local stamp with whichever `date` this is
        // (BSD `-r`, GNU `-d @`), so the test exercises the same fallback path
        // the brake uses on Linux runners.
        let then = (now - 600).to_string();
        let attempts: [Vec<String>; 2] = [
            vec!["-r".into(), then.clone()],
            vec!["-d".into(), format!("@{then}")],
        ];
        let stamp = attempts
            .iter()
            .find_map(|a| {
                let out = std::process::Command::new("date")
                    .args(a)
                    .arg("+%Y-%m-%d %H:%M:%S")
                    .output()
                    .ok()?;
                out.status
                    .success()
                    .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
            })
            .expect("a date that renders epoch seconds as a local stamp");
        let age = meter_age_secs(&stamp, now).unwrap();
        assert!((595..=605).contains(&age), "{age}");
        assert_eq!(meter_age_secs("not a date", now), None);
    }

    #[test]
    fn triage_candidates_skip_gated_claimed_parked_and_already_judged() {
        // #374 is the shape that started #585: parked as an `idea`, and offered
        // to GV anyway because this filter never read the skip labels.
        let snap = Snapshot {
            issues: vec![
                issue(5, &[], false),
                issue(3, &["product-wip"], false),
                issue(4, &[], true),
                issue(2, &[], false),
                issue(9, &[], false),
                issue(374, &["idea"], false),
                issue(375, &["tracking", "product-wip"], false),
                issue(376, &["needs-human"], false),
            ],
            prs: vec![],
            fetched_at: 0,
            known: true,
        };
        let skip: Vec<String> = ["idea", "release-hold", "tracking", "needs-human"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let evs = vec![
            Event {
                ts: 1,
                repo: "o/r".into(),
                kind: Kind::Issue {
                    issue: 9,
                    to: IssueState::Gated,
                },
            },
            Event {
                ts: 2,
                repo: "o/r".into(),
                kind: Kind::Note {
                    text: "GV triage: #2 judged ready — awaiting the human un-gate".into(),
                },
            },
        ];
        let seen = triaged_issues(&evs);
        assert_eq!(seen.into_iter().collect::<Vec<_>>(), vec![2, 9]);
        let seen = triaged_issues(&evs);
        assert_eq!(
            triage_candidates(&snap, "product-wip", &skip, &seen),
            vec![5],
            "a parked ticket is not GV's to judge"
        );
        // #5 is only in because it carries no skip label: take the list away
        // and the parked ones come back (the default-off behaviour, unchanged).
        assert_eq!(
            triage_candidates(&snap, "product-wip", &[], &seen),
            vec![5, 374, 376]
        );
        // a skip label alone is enough, with or without the gate label
        assert_eq!(
            triage_candidates(&snap, "no-such-gate", &skip, &seen),
            vec![3, 5]
        );
    }
}
