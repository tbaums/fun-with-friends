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
mod tests {
    use super::*;
    use crate::poll::IssueView;
    use crate::types::{Fence, IssueState, Sha};

    fn open_issue(n: u64) -> IssueView {
        IssueView {
            number: n,
            title: format!("issue {n}"),
            author_association: "OWNER".into(),
            labels: vec![],
            assignees: vec![],
            state: "open".into(),
            updated_at: String::new(),
            claim: None,
        }
    }

    /// #588, transom 11:33 PDT: `refs/claims/1268` live and impl1 Working on it,
    /// yet the issue carried no `claimed` label — so the poller never filled
    /// `IssueView.claim`, and status called it `ready` with `claimed 0`.
    #[test]
    fn a_claim_in_the_record_is_claimed_even_when_the_snapshot_says_nothing() {
        let s = Snapshot {
            issues: vec![open_issue(1268), open_issue(1269)],
            prs: vec![],
            fetched_at: 1,
            known: true,
        };
        assert!(
            s.issues.iter().all(|i| i.claim.is_none()),
            "the snapshot is the broken half of this bug"
        );
        let dir = std::env::temp_dir().join(format!("fwfd-status-claim-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run_log = dir.join("run.jsonl");
        let mut l = log::Log::open(&run_log).unwrap();
        let render_now = |run_log: &Path| {
            render(&StatusInput {
                snapshot: &s,
                gate_label: "product-wip",
                owner_only: true,
                seats: vec![],
                run_log,
                now: 5,
                rework_cap: 2,
            })
        };
        // before any claim: both issues are the loop's to take
        let r = render_now(&run_log);
        assert!(r.contains("eligible 2 · gated 0 · claimed 0"), "{r}");
        assert!(r.contains("ready #1268"), "{r}");
        l.append(&issue_ev(
            2,
            1268,
            IssueState::Claimed {
                seat: 1,
                fence: Fence("7d39b3c4".to_string() + &"0".repeat(32)),
            },
        ))
        .unwrap();
        let r = render_now(&run_log);
        assert!(r.contains("eligible 1 · gated 0 · claimed 1"), "{r}");
        assert!(r.contains("claimed #1268 → impl1 (fence 7d39b3c4)"), "{r}");
        assert!(
            !r.contains("ready #1268"),
            "a claimed issue is not ready: {r}"
        );
        assert!(r.contains("ready #1269"), "{r}");
        // released again, it goes back on the queue
        l.append(&issue_ev(3, 1268, IssueState::Ready)).unwrap();
        let r = render_now(&run_log);
        assert!(r.contains("eligible 2 · gated 0 · claimed 0"), "{r}");
        assert!(r.contains("ready #1268"), "{r}");
        // an unreadable record degrades to "nothing claimed", never an error
        let r = render_now(Path::new("/nonexistent/run.jsonl"));
        assert!(r.contains("claimed 0"), "{r}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #588: every seat window the manifest defines is listed, gv and pm too.
    #[test]
    fn the_seat_list_is_whatever_the_manifest_defines() {
        let mut m = crate::manifest::Manifest::parse(crate::manifest::EXAMPLE).unwrap();
        assert_eq!(
            m.seats(),
            vec![("impl", 1), ("qa", 1), ("gv", 1), ("pm", 1)],
            "the example manifest names a gv and a pm model"
        );
        m.pairs = 2;
        m.models.remove("gv");
        assert_eq!(
            m.seats(),
            vec![("impl", 1), ("qa", 1), ("impl", 2), ("qa", 2), ("pm", 1)]
        );
        // …and they reach the screen as their own targets
        let targets: Vec<String> = m
            .seats()
            .iter()
            .map(|(r, n)| m.seat_target(r, *n))
            .collect();
        let s = Snapshot {
            issues: vec![],
            prs: vec![],
            fetched_at: 1,
            known: true,
        };
        let r = render(&StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: targets
                .iter()
                .map(|t| (t.clone(), "claude".into()))
                .collect(),
            run_log: Path::new("/nonexistent"),
            now: 5,
            rework_cap: 2,
        });
        for t in ["fwf-one:impl2", "fwf-one:qa2", "fwf-one:pm1"] {
            assert!(r.contains(t), "{t} missing from\n{r}");
        }
    }

    fn refused(ts: u64, what: &str, why: &str) -> log::Event {
        log::Event {
            ts,
            repo: "o/r".into(),
            kind: Kind::Refused {
                what: what.into(),
                why: why.into(),
            },
        }
    }

    fn issue_ev(ts: u64, issue: u64, to: IssueState) -> log::Event {
        log::Event {
            ts,
            repo: "o/r".into(),
            kind: Kind::Issue { issue, to },
        }
    }

    /// #579: a refusal the loop repeats every tick has to stay visible — it
    /// used to scroll out of "recent" and leave the floor looking busy.
    #[test]
    fn a_repeating_refusal_stays_in_needs_you_until_the_issue_moves() {
        let s = Snapshot {
            issues: vec![open_issue(574), open_issue(575)],
            prs: vec![],
            fetched_at: 1,
            known: true,
        };
        let why = "scheduler did not plan it: seat 1 cannot take #574";
        let mut evs = vec![refused(10, "#574", why)];
        let line = |evs: &[log::Event]| {
            stuck_refusals(&s, evs)
                .into_iter()
                .map(|(n, w, t)| format!("#{n} {t}× {w}"))
                .collect::<Vec<_>>()
        };
        assert_eq!(line(&evs), vec![format!("#574 1× {why}")]);
        // every tick refuses it again: still one line, with the count and the
        // newest reason
        evs.push(refused(70, "#574", why));
        evs.push(refused(130, "#574", "and again"));
        assert_eq!(line(&evs), vec!["#574 3× and again".to_string()]);
        // a claim after the refusal means the loop got past it
        let mut claimed = evs.clone();
        claimed.push(issue_ev(
            140,
            574,
            IssueState::Claimed {
                seat: 2,
                fence: Fence("f".repeat(40)),
            },
        ));
        assert!(line(&claimed).is_empty());
        // so does a ship, and a claim the snapshot still holds
        let mut shipped = evs.clone();
        shipped.push(issue_ev(
            140,
            574,
            IssueState::Shipped {
                pr: 581,
                sha: Sha::parse(&"b".repeat(40)).unwrap(),
            },
        ));
        assert!(line(&shipped).is_empty());
        let mut live_claim = s.clone();
        live_claim.issues[0].claim = Some(Fence("c".repeat(40)));
        assert!(stuck_refusals(&live_claim, &evs).is_empty());
        // a closed issue, and a refusal naming a PR rather than an issue, are
        // nobody's needs-you line
        let mut closed = s.clone();
        closed.issues[0].state = "closed".into();
        assert!(stuck_refusals(&closed, &evs).is_empty());
        assert!(stuck_refusals(&s, &[refused(10, "#1270", "QA seat stalled")]).is_empty());
        // the loop's own claim → refuse → release, all within one second, is
        // the shape this line is for: it does not count as having moved on
        let churn = vec![
            issue_ev(
                200,
                574,
                IssueState::Claimed {
                    seat: 1,
                    fence: Fence("f".repeat(40)),
                },
            ),
            refused(200, "#574", "seat worktree is dirty"),
            issue_ev(200, 574, IssueState::Ready),
        ];
        assert_eq!(
            line(&churn),
            vec!["#574 1× seat worktree is dirty".to_string()]
        );
        // an older claim does not clear a newer refusal
        let mut reclaimed = vec![issue_ev(
            5,
            574,
            IssueState::Claimed {
                seat: 1,
                fence: Fence("f".repeat(40)),
            },
        )];
        reclaimed.extend(evs.clone());
        assert_eq!(line(&reclaimed), vec!["#574 3× and again".to_string()]);
        // and it reaches the rendered page, once
        let dir = std::env::temp_dir().join(format!("fwfd-status-refused-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let run_log = dir.join("run.jsonl");
        let mut l = log::Log::open(&run_log).unwrap();
        for e in &evs {
            l.append(e).unwrap();
        }
        let r = render(&StatusInput {
            snapshot: &s,
            gate_label: "product-wip",
            owner_only: true,
            seats: vec![],
            run_log: &run_log,
            now: 200,
            rework_cap: 2,
        });
        let lines: Vec<&str> = r
            .lines()
            .filter(|l| l.contains("the loop refused it"))
            .collect();
        assert_eq!(lines.len(), 1, "{r}");
        assert!(
            lines[0].contains("#574 is still open but the loop refused it 3× in this record"),
            "{r}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

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
                author: "fwf-impl[bot]".into(),
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
                author: "fwf-impl[bot]".into(),
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
