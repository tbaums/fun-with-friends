//! T-24 — `fwf status`: the captain's sweeps as one query, no model.
//!
//! What a human needs to see in one screen: eligible issues waiting, open
//! PRs with their review/check state, live claims, seat liveness, and the
//! "needs you" list (things only a human can do). Everything comes from the
//! poll snapshot and the run record; nothing is inferred from pane text.

use crate::log::{self, Kind};
use crate::poll::{PrView, Snapshot};
use crate::seat;
use crate::types::PrState;
use std::path::Path;

pub struct StatusInput<'a> {
    pub snapshot: &'a Snapshot,
    pub gate_label: &'a str,
    pub owner_only: bool,
    pub seats: Vec<(String, String)>, // (target, foreground command)
    pub run_log: &'a Path,
    /// The floor's `run.pid`, so the screen can say whether a loop is running
    /// it at all (#675).
    pub pidfile: &'a Path,
    pub now: u64,
    /// Manifest `rework_cap`: how many rounds the loop gives a refused PR
    /// before it becomes a human's decision (#576).
    pub rework_cap: u32,
}

fn eligible(i: &crate::poll::IssueView, gate: &str, owner_only: bool) -> bool {
    i.state == "open"
        && !i.labels.iter().any(|l| l == gate)
        && (!owner_only || i.author_association == "OWNER")
        && i.assignees.is_empty()
        && i.claim.is_none()
}

fn pr_line(p: &PrView) -> String {
    let approved_by: Vec<&str> = p
        .reviews
        .iter()
        .filter(|(_, state, commit)| state == "APPROVED" && *commit == p.head_sha)
        .map(|(login, _, _)| login.as_str())
        .collect();
    let changes: Vec<&str> = p
        .reviews
        .iter()
        .filter(|(_, state, commit)| state == "CHANGES_REQUESTED" && *commit == p.head_sha)
        .map(|(login, _, _)| login.as_str())
        .collect();
    let review = if !changes.is_empty() {
        format!("changes requested at head by {}", changes.join(","))
    } else if !approved_by.is_empty() {
        format!("approved at head by {}", approved_by.join(","))
    } else {
        "no review at head".to_string()
    };
    format!(
        "  PR #{:<5} {:<9} {} → {}  head {}  closes {}  {}",
        p.number,
        if p.draft { "draft" } else { &p.state },
        p.head_ref,
        p.base_ref,
        &p.head_sha[..8.min(p.head_sha.len())],
        p.closes_issue
            .map(|n| format!("#{n}"))
            .unwrap_or_else(|| "-".into()),
        review
    )
}

/// How long ago the run record last moved. A floor whose loop is working is
/// never silent here for long: every wake, verdict, claim and refusal lands
/// in it. `no events` is a record that has never been written, not a stall.
fn record_age_line(evs: &[log::Event], now: u64) -> String {
    match evs.iter().map(|e| e.ts).max() {
        Some(ts) => format!("record age {}s", now.saturating_sub(ts)),
        None => "record age: no events".to_string(),
    }
}

/// The newest merge refusal recorded against a PR, and how many times it was
/// refused (#677). `merge_pr` records every refusal as `Kind::Refused` with
/// `what == "merge #<PR>"`; before this the operator had to read the run
/// record to find out why an approved PR never landed.
fn merge_refusal(evs: &[log::Event], pr: u64) -> Option<(String, usize)> {
    let mine = format!("merge #{pr}");
    let why = evs.iter().rev().find_map(|e| match &e.kind {
        Kind::Refused { what, why } if *what == mine => Some(why.clone()),
        _ => None,
    })?;
    let times = evs
        .iter()
        .filter(|e| matches!(&e.kind, Kind::Refused { what, .. } if *what == mine))
        .count();
    Some((why, times))
}

/// Refusals a human still has to look at: per issue that is *still* open and
/// unclaimed in the snapshot, the newest `Kind::Refused` naming it that no
/// later claim or ship has overtaken, with how many times it was refused.
///
/// Keyed by issue, so the loop refusing the same issue on every tick is one
/// line, not one per tick; a `#N` that is not an open issue in the snapshot
/// (a PR number, a closed issue) is not one of these.
fn stuck_refusals(s: &Snapshot, evs: &[log::Event]) -> Vec<(u64, String, usize)> {
    let mut out = Vec::new();
    for i in &s.issues {
        if i.state != "open" || i.claim.is_some() {
            continue;
        }
        let mine = format!("#{}", i.number);
        let last_refusal = evs
            .iter()
            .rfind(|e| matches!(&e.kind, Kind::Refused { what, .. } if *what == mine));
        let Some(e) = last_refusal else { continue };
        let Kind::Refused { why, .. } = &e.kind else {
            continue;
        };
        // A claim or a ship *after* the refusal means the loop got past it.
        // Strictly after: the claim/refuse/release loop this line exists for
        // records all three inside one second, and must stay visible.
        let moved_on = evs.iter().any(|x| {
            x.ts > e.ts
                && matches!(
                    &x.kind,
                    Kind::Issue {
                        issue,
                        to: crate::types::IssueState::Claimed { .. }
                            | crate::types::IssueState::Shipped { .. },
                    } if *issue == i.number
                )
        });
        if moved_on {
            continue;
        }
        let times = evs
            .iter()
            .filter(|x| matches!(&x.kind, Kind::Refused { what, .. } if *what == mine))
            .count();
        out.push((i.number, why.clone(), times));
    }
    out
}

pub fn render(inp: &StatusInput) -> String {
    let s = inp.snapshot;
    let mut out = String::new();
    if !s.known {
        out.push_str(
            "snapshot: UNKNOWN (the tracker could not be read; nothing below is trustworthy)\n",
        );
        return out;
    }
    let mut needs_you: Vec<String> = Vec::new();
    let evs = log::read_all(inp.run_log).unwrap_or_default();

    // The two lines an operator over ssh needs first (#675). Stdout going
    // quiet is not a stalled floor — a seat wait is routinely 30+ minutes —
    // so the record's own age is the liveness signal, and the pidfile says
    // whether there is a loop behind it at all. Restarting a loop that was
    // merely mid-wait cost a day's work once; these two lines are the answer
    // to "is it alive?" that `pkill` used to be.
    out.push_str(&format!("{}\n", record_age_line(&evs, inp.now)));
    out.push_str(&format!(
        "{}\n",
        crate::verbs::pidfile::status_line_at(inp.pidfile)
    ));

    out.push_str("seats\n");
    for (target, cmd) in &inp.seats {
        let live = cmd == "claude" || cmd.chars().next().is_some_and(|c| c.is_ascii_digit());
        out.push_str(&format!(
            "  {target:<20} {}\n",
            if live {
                format!("live ({cmd})")
            } else {
                format!("GONE ({cmd})")
            }
        ));
        if !live {
            needs_you.push(format!("seat {target} is gone: `one/scripts/seat-up.sh …`"));
        }
    }
    // Capacity the replay just handed back (#676): a seat left Stalled or
    // Working on an issue that has since shipped, closed or been re-claimed
    // is idle, and nothing ever wrote that down. Informational — the leak was
    // invisible, which is why two of three pairs sat out a whole afternoon.
    for g in log::ghost_seats(&evs) {
        out.push_str(&format!("  {}\n", g.line()));
    }

    out.push_str("issues\n");
    // Who holds what comes from the record, not from the snapshot (#588): the
    // poller fills `IssueView.claim` only for issues carrying the `claimed`
    // label, and nothing applies that label, so a fenced claim being actively
    // worked read as `ready` here. Only open issues count — a claim whose issue
    // has left the open set is not the operator's business on this screen.
    let held = log::claimed_issues(&evs);
    let claimed: Vec<(u64, u8, String)> = s
        .issues
        .iter()
        .filter_map(|i| {
            held.get(&i.number)
                .map(|(seat, fence)| (i.number, *seat, fence.0.chars().take(8).collect()))
        })
        .collect();
    let mut elig: Vec<&crate::poll::IssueView> = s
        .issues
        .iter()
        .filter(|i| eligible(i, inp.gate_label, inp.owner_only))
        .filter(|i| !held.contains_key(&i.number))
        .collect();
    elig.sort_by_key(|i| i.number);
    let gated = s
        .issues
        .iter()
        .filter(|i| i.labels.iter().any(|l| l == inp.gate_label))
        .count();
    out.push_str(&format!(
        "  open {} · eligible {} · gated {} · claimed {}\n",
        s.issues.len(),
        elig.len(),
        gated,
        claimed.len()
    ));
    for i in elig.iter().take(8) {
        out.push_str(&format!(
            "  ready #{:<5} {}\n",
            i.number,
            i.title.chars().take(70).collect::<String>()
        ));
    }
    for (number, seat, fence) in &claimed {
        out.push_str(&format!(
            "  claimed #{number} → impl{seat} (fence {fence})\n"
        ));
    }
    if gated > 0 {
        needs_you.push(format!(
            "{gated} issue(s) carry {:?}: un-gate the ones worth building",
            inp.gate_label
        ));
    }

    out.push_str("pull requests\n");
    for p in &s.prs {
        out.push_str(&pr_line(p));
        out.push('\n');
        // Why an approved PR is still sitting there, without reading the run
        // record (#677). The loop answers a "not mergeable" with a rebase
        // round now, so a line that keeps coming back is one to look at.
        if let Some((why, times)) = merge_refusal(&evs, p.number) {
            out.push_str(&format!(
                "    merge refused ×{times} ({} rework round(s)): {why}\n",
                crate::rework::rounds_in(inp.run_log, p.number)
            ));
        }
        let approved = p
            .reviews
            .iter()
            .any(|(_, st, c)| st == "APPROVED" && *c == p.head_sha);
        if p.draft && approved {
            needs_you.push(format!(
                "PR #{} is approved but still a draft: mark ready (the impl App can)",
                p.number
            ));
        }
        if !p.draft && approved {
            needs_you.push(format!(
                "PR #{} is approved at head: `fwf merge --pr {}`",
                p.number, p.number
            ));
        }
        // Changes requested is the loop's work now (#576) — it re-wakes the
        // seat. Only a PR that used up its rounds needs a human.
        let refused = p
            .reviews
            .iter()
            .any(|(_, st, c)| st == "CHANGES_REQUESTED" && *c == p.head_sha);
        if refused && !approved {
            let rounds = crate::rework::rounds_in(inp.run_log, p.number);
            if rounds >= inp.rework_cap {
                needs_you.push(format!(
                    "PR #{} hit the rework cap ({}): close it or push a fix yourself",
                    p.number, inp.rework_cap
                ));
            }
        }
    }

    // Work that is finished and unpushed (#602): the loop retries the write
    // every tick, but a push GitHub refuses on principle — an App without
    // `workflows: write` and a branch that touches `.github/workflows/` —
    // only a human can clear.
    for (issue, p) in log::pending_pushes(&evs) {
        let fix = if crate::mirror::is_workflows_permission_refusal(&p.why) {
            "grant the impl App `workflows: write` and re-accept the installation, or push it by hand"
        } else {
            "push it by hand or fix the App"
        };
        needs_you.push(format!(
            "#{issue} is implemented on {} but the push was refused: {} — {fix}",
            p.branch,
            p.why.chars().take(120).collect::<String>()
        ));
    }

    // A refusal the loop repeats every tick used to scroll out of "recent" and
    // leave nothing behind (#579): the floor looked busy while an issue was
    // claimed, refused and released forever. Surface the live ones.
    for (issue, why, times) in stuck_refusals(s, &evs) {
        needs_you.push(format!(
            "#{issue} is still open but the loop refused it{}: {}",
            if times > 1 {
                format!(" {times}× in this record")
            } else {
                String::new()
            },
            why.chars().take(100).collect::<String>()
        ));
    }

    out.push_str("recent\n");
    for e in evs
        .iter()
        .rev()
        .take(8)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        let age = inp.now.saturating_sub(e.ts);
        let what = match &e.kind {
            Kind::Issue { issue, to } => format!("issue #{issue} → {to:?}"),
            Kind::Pr { pr, to, .. } => format!(
                "pr #{pr} → {}",
                match to {
                    PrState::Merged { .. } => "merged".to_string(),
                    other => format!("{other:?}"),
                }
            ),
            Kind::Seat {
                seat,
                role,
                to,
                tokens_in,
                tokens_out,
            } => format!(
                "seat {seat} {role:?} → {to:?} {}",
                match (tokens_in, tokens_out) {
                    (Some(i), Some(o)) => format!("[{i} in/{o} out]"),
                    _ => String::new(),
                }
            ),
            Kind::Gate { to } => format!("gate → {to:?}"),
            Kind::Promote { branch, to, .. } => {
                format!("promote {branch} → {}", &to[..8.min(to.len())])
            }
            Kind::Human {
                actor,
                action,
                target,
            } => format!("human {actor} {action} {target}"),
            Kind::Refused { what, why } => format!("REFUSED {what}: {why}"),
            Kind::Note { text } => format!("note {text}"),
        };
        let what: String = what.chars().take(110).collect();
        out.push_str(&format!("  {:>6}s ago  {what}\n", age));
    }

    out.push_str("needs you\n");
    if needs_you.is_empty() {
        out.push_str("  nothing\n");
    }
    for n in needs_you {
        out.push_str(&format!("  - {n}\n"));
    }
    out
}

pub fn seat_commands(targets: &[String]) -> Vec<(String, String)> {
    targets
        .iter()
        .map(|t| {
            (
                t.clone(),
                seat::pane_command(t).unwrap_or_else(|_| "absent".into()),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests;
