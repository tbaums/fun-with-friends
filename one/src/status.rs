//! T-24 — `fwfd status`: the captain's sweeps as one query, no model.
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

    out.push_str("issues\n");
    let mut elig: Vec<&crate::poll::IssueView> = s
        .issues
        .iter()
        .filter(|i| eligible(i, inp.gate_label, inp.owner_only))
        .collect();
    elig.sort_by_key(|i| i.number);
    let gated = s
        .issues
        .iter()
        .filter(|i| i.labels.iter().any(|l| l == inp.gate_label))
        .count();
    let claimed: Vec<&crate::poll::IssueView> =
        s.issues.iter().filter(|i| i.claim.is_some()).collect();
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
    for i in &claimed {
        out.push_str(&format!(
            "  claimed #{:<5} fence {}\n",
            i.number,
            i.claim
                .as_ref()
                .map(|f| f.0.chars().take(8).collect::<String>())
                .unwrap_or_default()
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
                "PR #{} is approved at head: `fwfd merge --pr {}`",
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

    out.push_str("recent\n");
    if let Ok(evs) = log::read_all(inp.run_log) {
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
mod tests {
    use super::*;
    use crate::poll::IssueView;

    #[test]
    fn unknown_snapshot_renders_a_warning_and_nothing_else() {
        let s = Snapshot::unknown();
        let inp = StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![],
            run_log: Path::new("/nonexistent"),
            now: 0,
            rework_cap: 2,
        };
        let r = render(&inp);
        assert!(r.starts_with("snapshot: UNKNOWN"));
        assert!(!r.contains("needs you"));
    }

    #[test]
    fn needs_you_lists_gone_seats_gated_issues_and_approved_prs() {
        let s = Snapshot {
            issues: vec![
                IssueView {
                    number: 1,
                    title: "gated".into(),
                    author_association: "OWNER".into(),
                    labels: vec!["product-wip".into()],
                    assignees: vec![],
                    state: "open".into(),
                    updated_at: String::new(),
                    claim: None,
                },
                IssueView {
                    number: 2,
                    title: "ready".into(),
                    author_association: "OWNER".into(),
                    labels: vec![],
                    assignees: vec![],
                    state: "open".into(),
                    updated_at: String::new(),
                    claim: None,
                },
            ],
            prs: vec![PrView {
                number: 9,
                head_sha: "a".repeat(40),
                head_ref: "impl1/x".into(),
                base_ref: "staging".into(),
                draft: false,
                state: "open".into(),
                closes_issue: Some(2),
                reviews: vec![("fwf-qa[bot]".into(), "APPROVED".into(), "a".repeat(40))],
            }],
            fetched_at: 1,
            known: true,
        };
        let inp = StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![("fwf-one:impl1".into(), "bash".into())],
            run_log: Path::new("/nonexistent"),
            now: 5,
            rework_cap: 2,
        };
        let r = render(&inp);
        assert!(!r.contains("rework cap"), "nothing is refused here");
        assert!(r.contains("GONE (bash)"));
        assert!(r.contains("ready #2"));
        assert!(r.contains("approved at head by fwf-qa[bot]"));
        assert!(r.contains("fwfd merge --pr 9"));
        assert!(r.contains("un-gate the ones worth building"));
    }

    /// #576: a refused PR is the loop's work (it re-wakes the seat) until the
    /// rounds in the record reach the cap; only then is it a human's problem.
    #[test]
    fn a_refused_pr_reaches_needs_you_only_at_the_rework_cap() {
        let head = "b".repeat(40);
        let s = Snapshot {
            issues: vec![],
            prs: vec![PrView {
                number: 1270,
                head_sha: head.clone(),
                head_ref: "impl1/issue-575-thin-slice".into(),
                base_ref: "staging".into(),
                draft: true,
                state: "open".into(),
                closes_issue: Some(575),
                reviews: vec![(
                    "fwf-qa[bot]".into(),
                    "CHANGES_REQUESTED".into(),
                    head.clone(),
                )],
            }],
            fetched_at: 1,
            known: true,
        };
        let dir = std::env::temp_dir().join(format!("fwfd-status-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let run_log = dir.join("run.jsonl");
        let mut l = log::Log::open(&run_log).unwrap();
        let inp = || StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![],
            run_log: &run_log,
            now: 5,
            rework_cap: 2,
        };
        let wake = |n: u64| log::Event {
            ts: n,
            repo: "o/r".into(),
            kind: Kind::Seat {
                seat: 1,
                role: crate::types::Role::Impl,
                to: crate::types::SeatState::Working {
                    job: crate::types::JobRef {
                        role: crate::types::Role::Impl,
                        issue: Some(575),
                        pr: Some(1270),
                    },
                    deadline: n + 10,
                },
                tokens_in: None,
                tokens_out: None,
            },
        };
        let r = render(&inp());
        assert!(r.contains("changes requested at head by fwf-qa[bot]"));
        assert!(!r.contains("rework cap"), "round 1 is the loop's to do");
        l.append(&wake(1)).unwrap();
        assert!(!render(&inp()).contains("rework cap"));
        l.append(&wake(2)).unwrap();
        let r = render(&inp());
        assert!(
            r.contains("PR #1270 hit the rework cap (2): close it or push a fix yourself"),
            "{r}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
