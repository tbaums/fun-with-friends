//! #574 — the four tab bodies and the cost ledger.
//!
//! Each `*_tab` returns (list title, list rows, (detail title, detail
//! lines)); `view` puts them in the two panes and draws the borders.
//! Pure, like the frame: everything time-dependent takes `now`.

use super::view::{paint, span_hours, View};
use crate::dash::{
    fmt_secs, gate_line, hhmm, issue_rows, job_name, k, needs_you, pr_rows, role_name, seat_phrase,
    seat_rows, Board, Floor, PrLive, Stage,
};
use crate::log;
use crate::types::{IssueState, SeatState};

type TabBody = (String, Vec<String>, (String, Vec<String>));

fn trail_lines(trail: &[(u64, String)], now: u64) -> Vec<String> {
    let mut v = vec![String::new(), "recent, newest last".to_string()];
    if trail.is_empty() {
        v.push("  (this entity has no events in the record)".into());
    }
    for (ts, what) in trail {
        v.push(format!(
            "  {:>8} ago  {what}",
            fmt_secs(now.saturating_sub(*ts))
        ));
    }
    v
}

pub(super) fn seats_tab(b: &Board, f: &Floor, v: &View, now: u64) -> TabBody {
    let rows = seat_rows(b, f);
    let list: Vec<String> = rows
        .iter()
        .map(|r| {
            let (word, what) = seat_phrase(r, now);
            let dot = match r.live {
                Some(true) => "●",
                Some(false) => "○",
                None => "?",
            };
            format!(
                "{dot} {:<7} {} {what}",
                r.label,
                paint(&format!("{word:<9}"), state_code(word), v.color),
            )
        })
        .collect();
    let sel = v.selected().min(rows.len().saturating_sub(1));
    let detail = match rows.get(sel) {
        None => ("Detail".to_string(), vec!["no seats".into()]),
        Some(r) => {
            let (word, what) = seat_phrase(r, now);
            let mut d = vec![
                format!(
                    "seat {}   role {}   #{}",
                    r.label,
                    role_name(r.role),
                    r.seat
                ),
                format!("pane {}", r.target),
                format!("tmux {}", r.pane_word()),
                String::new(),
                format!("state {} — {what}", paint(word, state_code(word), v.color)),
            ];
            if let SeatState::Working { deadline, job } = &r.state {
                d.push(format!(
                    "job   {}   deadline {} ({} from now)",
                    job_name(job),
                    hhmm(*deadline),
                    fmt_secs(deadline.saturating_sub(now.min(*deadline)))
                ));
            }
            d.push(String::new());
            d.push(format!(
                "cycles {}   stalls {}   tokens {} in / {} out",
                r.cycles,
                r.stalls,
                k(r.tokens_in),
                k(r.tokens_out)
            ));
            if r.cycles > 0 {
                // An upper bound, not a per-task price: see the Usage tab.
                d.push(format!(
                    "per cycle {} in — upper bound (see Usage)",
                    k(r.tokens_in / r.cycles as u64)
                ));
            }
            d.extend(trail_lines(r.trail, now));
            (format!("Detail · seat {}", r.label), d)
        }
    };
    ("Seats — who is working".to_string(), list, detail)
}

fn state_code(word: &str) -> &'static str {
    match word {
        "WORKING" => "36",
        "REPORTED" => "32",
        "STALLED" => "1;31",
        "GONE" => "31",
        "IDLE" => "2",
        _ => "35",
    }
}

fn issue_word(s: &IssueState) -> (&'static str, &'static str) {
    match s {
        IssueState::Gated => ("gated", "33"),
        IssueState::Ready => ("ready", "36"),
        IssueState::Claimed { .. } => ("claimed", "1;36"),
        IssueState::Shipped { .. } => ("shipped", "32"),
        IssueState::Closed => ("closed", "2"),
        IssueState::Unknown => ("not started", "2"),
    }
}

pub(super) fn issues_tab(b: &Board, f: &Floor, v: &View, now: u64) -> TabBody {
    let rows = issue_rows(b, f);
    let list: Vec<String> = rows
        .iter()
        .map(|r| {
            let (word, code) = issue_word(&r.state);
            format!(
                "#{:<6} {} {}{}{}",
                r.issue,
                paint(&format!("{word:<12}"), code, v.color),
                r.seat.map(|s| format!("seat {s} ")).unwrap_or_default(),
                r.pr.map(|p| format!("PR #{p} ")).unwrap_or_default(),
                if r.allowed { "" } else { "(not allow-listed)" }
            )
        })
        .collect();
    let sel = v.selected().min(rows.len().saturating_sub(1));
    let detail = match rows.get(sel) {
        None => ("Detail".to_string(), vec!["no issues in the record".into()]),
        Some(r) => {
            let (word, code) = issue_word(&r.state);
            let mut d = vec![
                format!("issue #{}", r.issue),
                format!("state {}", paint(word, code, v.color)),
            ];
            if r.since > 0 {
                d.push(format!(
                    "since {} ({} ago)",
                    hhmm(r.since),
                    fmt_secs(now.saturating_sub(r.since))
                ));
            }
            match &r.state {
                IssueState::Claimed { seat, fence } => d.push(format!(
                    "claim  seat {seat}, fence {}",
                    fence.0.chars().take(12).collect::<String>()
                )),
                IssueState::Shipped { pr, sha } => {
                    d.push(format!("shipped as PR #{pr} → {}", sha.short()))
                }
                _ => {}
            }
            if let Some(p) = r.pr {
                d.push(format!("pr     #{p}"));
            }
            d.push(format!(
                "queue  {}",
                if r.allowed {
                    "allow-listed (the loop may work it)"
                } else {
                    "NOT in the manifest allow-list — the loop will refuse it"
                }
            ));
            d.extend(trail_lines(r.trail, now));
            (format!("Detail · issue #{}", r.issue), d)
        }
    };
    (
        "Issues — the queue (allow-list + record)".to_string(),
        list,
        detail,
    )
}

fn stage_code(s: Stage) -> &'static str {
    match s {
        Stage::Draft => "2",
        Stage::QaWorking => "36",
        Stage::Changes => "33",
        Stage::Approved => "1;36",
        Stage::Merged => "32",
        Stage::GateRed => "1;31",
        Stage::GateGreen => "32",
        Stage::Promoted => "1;32",
        Stage::Closed => "2",
        Stage::Unknown => "35",
    }
}

/// `draft › qa › approved › merged › gate › promote` with the reached stages
/// filled in, so one glance says how far a PR has come.
fn pipeline(p: &PrLive, v: &View) -> String {
    let here = p.stage();
    let reached = |s: Stage| -> bool {
        match s {
            Stage::GateGreen => here >= Stage::GateGreen || here == Stage::GateRed,
            _ => here >= s && here != Stage::Unknown,
        }
    };
    Stage::PIPELINE
        .iter()
        .map(|s| {
            let short = match s {
                Stage::Draft => "draft",
                Stage::QaWorking => "qa",
                Stage::Approved => "appr",
                Stage::Merged => "merged",
                Stage::GateGreen => {
                    if here == Stage::GateRed {
                        "gate RED"
                    } else {
                        "gate"
                    }
                }
                _ => "promote",
            };
            if reached(*s) {
                paint(short, stage_code(here), v.color)
            } else {
                paint(short, "2", v.color)
            }
        })
        .collect::<Vec<_>>()
        .join(" › ")
}

pub(super) fn prs_tab(b: &Board, v: &View, now: u64) -> TabBody {
    let rows = pr_rows(b);
    let list: Vec<String> = rows
        .iter()
        .map(|p| {
            let st = p.stage();
            format!(
                "#{:<6} {} {}{} ago",
                p.pr,
                paint(&format!("{:<14}", st.label()), stage_code(st), v.color),
                p.issue.map(|i| format!("#{i} ")).unwrap_or_default(),
                fmt_secs(now.saturating_sub(p.since))
            )
        })
        .collect();
    let sel = v.selected().min(rows.len().saturating_sub(1));
    let detail = match rows.get(sel) {
        None => ("Detail".to_string(), vec!["no PRs in the record".into()]),
        Some(p) => {
            let st = p.stage();
            let mut d = vec![
                format!(
                    "PR #{}   closes {}",
                    p.pr,
                    p.issue
                        .map(|i| format!("#{i}"))
                        .unwrap_or_else(|| "-".into())
                ),
                format!("stage {}", paint(st.label(), stage_code(st), v.color)),
                pipeline(p, v),
                String::new(),
                format!("state {}", log::pr_name(&p.state)),
                format!(
                    "head  {}",
                    p.head
                        .as_ref()
                        .map(|h| h.short().to_string())
                        .unwrap_or_else(|| "-".into())
                ),
                format!(
                    "opened {} ago · last change {} ago",
                    fmt_secs(now.saturating_sub(p.opened)),
                    fmt_secs(now.saturating_sub(p.since))
                ),
            ];
            if let Some((seat, since)) = &p.qa {
                d.push(format!(
                    "qa    seat {seat} working for {}",
                    fmt_secs(now.saturating_sub(*since))
                ));
            }
            if let Some(sha) = &p.merge_sha {
                d.push(format!("merge {}", sha.short()));
            }
            for g in &p.gates {
                d.push(format!("gate  {}", gate_line(g)));
            }
            if let Some((branch, ts)) = &p.promoted {
                d.push(format!(
                    "promoted to {branch} {} ago",
                    fmt_secs(now.saturating_sub(*ts))
                ));
            }
            d.extend(trail_lines(b.trail_of(&format!("pr:{}", p.pr)), now));
            (format!("Detail · PR #{}", p.pr), d)
        }
    };
    ("PRs — the pipeline".to_string(), list, detail)
}

pub(super) fn decisions_tab(b: &Board, f: &Floor, v: &View, now: u64) -> TabBody {
    let needs = needs_you(b, f, now);
    let mut list: Vec<String> = needs
        .iter()
        .map(|n| format!("{} {n}", paint("⛔", "1;31", v.color)))
        .collect();
    if list.is_empty() {
        list.push(paint("✓ nothing needs you", "32", v.color));
    }
    let mut d = vec!["human actions, newest first".to_string()];
    if b.humans.is_empty() {
        d.push("  (no human action in this record)".into());
    }
    for (ts, actor, action, target) in b.humans.iter().rev().take(12) {
        d.push(format!(
            "  {:>8} ago  {actor} {action} {target}",
            fmt_secs(now.saturating_sub(*ts))
        ));
    }
    d.push(String::new());
    d.push("refusals, newest first".to_string());
    if b.refusals.is_empty() {
        d.push("  (none — nothing was refused)".into());
    }
    for (ts, what, why) in b.refusals.iter().rev().take(8) {
        d.push(format!(
            "  {:>8} ago  {what}: {why}",
            fmt_secs(now.saturating_sub(*ts))
        ));
    }
    (
        "Decisions — what only you can clear".to_string(),
        list,
        ("Detail · human actions".to_string(), d),
    )
}

/// The 1.0 cost ledger, kept whole: this is what `fwfd dash` printed before
/// the board arrived, and it is still the answer to "what did this cost".
pub fn usage(b: &Board, f: &Floor) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if b.hours.is_empty() {
        out.push("run record is empty: nothing has happened yet".into());
        return out;
    }
    let span_h = span_hours(b);
    let merges: u32 = b.hours.values().map(|h| h.merges).sum();
    let cycles: u32 = b.hours.values().map(|h| h.cycles).sum();
    let green: u32 = b.hours.values().map(|h| h.gate_green).sum();
    let red: u32 = b.hours.values().map(|h| h.gate_red).sum();
    let killed: u32 = b.hours.values().map(|h| h.gate_killed).sum();
    out.push(format!(
        "throughput   merges {merges} ({:.2}/h) · seat cycles {cycles} ({:.2}/h) · PRs open {}",
        merges as f64 / span_h,
        cycles as f64 / span_h,
        b.open_prs.len()
    ));
    out.push(format!(
        "gates        green {green} · red {red} · killed {killed} · last {}",
        b.last_gate
            .as_ref()
            .map(gate_line)
            .unwrap_or_else(|| "none".into())
    ));
    out.push(String::new());
    out.push("per hour     hour   merges opened cycles green red killed refused".into());
    for (h, val) in b
        .hours
        .iter()
        .rev()
        .take(12)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        out.push(format!(
            "             {}  {:>6} {:>6} {:>6} {:>5} {:>3} {:>6} {:>7}",
            hhmm(h * 3600),
            val.merges,
            val.prs_opened,
            val.cycles,
            val.gate_green,
            val.gate_red,
            val.gate_killed,
            val.refused
        ));
    }
    out.push(String::new());
    out.push("cost         role   cycles stalled  tokens-in  tokens-out  in/cycle".into());
    for (role, c) in &b.roles {
        out.push(format!(
            "             {:<6} {:>6} {:>7} {:>10} {:>11} {:>9}",
            role,
            c.cycles,
            c.stalled,
            k(c.tokens_in),
            k(c.tokens_out),
            if c.cycles > 0 {
                k(c.tokens_in / c.cycles as u64)
            } else {
                "-".into()
            }
        ));
    }
    // #581: these are each seat's own request-level tokens, measured from its
    // transcript in the window of the cycle. A warm seat's conversation keeps
    // growing and every request re-reads it, so in/cycle rises over a seat's
    // life: read it as an upper bound on what the work cost, not as a price.
    out.push("             in/cycle is an upper bound, not a per-task price: these are a".into());
    out.push("             seat's own requests, and its conversation grows — every".into());
    out.push(
        "             request re-reads it, so a later cycle costs more to do the same.".into(),
    );
    out.push(String::new());
    out.push(match &f.meter {
        Some(m) => format!(
            "meter        weekly {}% · session {} · read {} · the brake parks the floor at {}%",
            m.weekly,
            m.session
                .map(|s| format!("{s}%"))
                .unwrap_or_else(|| "?".into()),
            m.when,
            f.park_at
        ),
        None => "meter        no reading in ~/.fwf-meter-log (the brake cannot see the meter)"
            .to_string(),
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dash::fold;
    use crate::dash::view::fixture::*;
    use crate::dash::view::{render, Tab};
    use crate::log::Kind;
    use crate::types::{GateState, PrState};

    #[test]
    fn the_seats_tab_shows_live_state_the_job_and_the_pane() {
        let f = frame(Tab::Seats);
        assert!(f.contains("● impl1"), "{f}");
        assert!(f.contains("WORKING"));
        assert!(f.contains("#574 · 1m 10s in, 28m 50s left"));
        // detail follows the selection: seat impl1 is row 0
        assert!(f.contains("Detail · seat impl1"));
        assert!(f.contains("pane fwf-one:impl1"));
        assert!(f.contains("tmux live, 2.1.266"));
        assert!(f.contains("deadline"));
    }

    /// #581: a seat that has finished a cycle shows what it cost per cycle,
    /// and says in the same breath that the figure is an upper bound.
    #[test]
    fn a_finished_seats_per_cycle_line_carries_the_caveat() {
        let job = crate::types::JobRef {
            role: crate::types::Role::Impl,
            issue: Some(574),
            pr: None,
        };
        let b = fold(&[crate::log::Event {
            ts: 1_000_000,
            repo: "o/r".into(),
            kind: Kind::Seat {
                seat: 1,
                role: crate::types::Role::Impl,
                to: crate::types::SeatState::Reported { job },
                tokens_in: Some(94_550_809),
                tokens_out: Some(40_000),
            },
        }]);
        let v = View {
            tab: Tab::Seats,
            width: 110,
            height: 26,
            ..Default::default()
        };
        let (_, _, (_, detail)) = seats_tab(&b, &floor(), &v, 1_000_100);
        let line = detail
            .iter()
            .find(|l| l.starts_with("per cycle"))
            .unwrap_or_else(|| panic!("no per-cycle line in {detail:?}"));
        assert_eq!(line, "per cycle 94.6M in — upper bound (see Usage)");
    }

    #[test]
    fn the_issue_queue_shows_state_claim_and_allow_list() {
        let b = fold(&record());
        let mut v = View {
            tab: Tab::Issues,
            width: 110,
            height: 26,
            ..Default::default()
        };
        let f = render(&b, &floor(), &v, 1_000_100);
        assert!(f.contains("#574    claimed      seat 1 PR #9"), "{f}");
        assert!(f.contains("#575    gated"));
        assert!(f.contains("(not allow-listed)"));
        assert!(f.contains("Detail · issue #574"));
        assert!(f.contains("fence evt-1"));
        assert!(f.contains("jamie: ungate #574"));
        v.select(1);
        let f = render(&b, &floor(), &v, 1_000_100);
        assert!(f.contains("NOT in the manifest allow-list"), "{f}");
    }

    #[test]
    fn the_pr_pipeline_draws_every_stage_and_the_gate_verdict() {
        let mut evs = record();
        let merged = sha('b');
        evs.push(ev(
            1_000_070,
            Kind::Pr {
                pr: 9,
                issue: Some(574),
                to: PrState::Merged {
                    sha: merged.clone(),
                },
            },
        ));
        evs.push(ev(
            1_000_080,
            Kind::Gate {
                to: GateState::Red {
                    sha: merged,
                    suite: "e2e".into(),
                    failed: 3,
                },
            },
        ));
        let b = fold(&evs);
        let v = View {
            tab: Tab::Prs,
            width: 110,
            height: 26,
            ..Default::default()
        };
        let f = render(&b, &floor(), &v, 1_000_100);
        assert!(f.contains("#9      gate RED"), "{f}");
        assert!(f.contains("draft › qa › appr › merged › gate RED › promote"));
        assert!(f.contains("gate  RED e2e, 3 failed"));
        assert!(f.contains("merge bbbbbbbb"));
        assert!(needs_you(&b, &floor(), 1_000_100)
            .iter()
            .any(|n| n.contains("PR #9 merged but its gate is RED")));
    }

    #[test]
    fn the_decisions_tab_lists_needs_you_and_the_human_actions() {
        let f = frame(Tab::Decisions);
        assert!(f.contains("⛔ gated, awaiting `fwfd ungate`: #575"), "{f}");
        assert!(f.contains("Detail · human actions"));
        assert!(f.contains("jamie ungate #574"));
        assert!(f.contains("(none — nothing was refused)"));
    }

    #[test]
    fn the_usage_tab_is_the_old_ledger_whole() {
        let f = frame(Tab::Usage);
        assert!(f.contains("throughput   merges 0"), "{f}");
        assert!(f.contains("per hour     hour   merges opened cycles"));
        assert!(f.contains("cost         role   cycles stalled"));
        // #581: the per-cycle figure says what to make of itself
        assert!(
            f.contains("in/cycle is an upper bound, not a per-task price"),
            "{f}"
        );
        assert!(f.contains("seat's own requests"), "{f}");
        assert!(f.contains("request re-reads it"), "{f}");
        assert!(f.contains("meter        weekly 62%"));
        assert!(f.contains("parks the floor at 85%"));
    }
}
