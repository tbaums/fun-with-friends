//! T-27 — `fwfd dash`: the board, computed from the run record alone.
//!
//! The old dash scraped pane text and guessed. This one folds the append-only
//! JSONL into a few honest numbers: merges and cycles per hour (throughput),
//! gate outcomes (CI throughput), measured tokens per role, refusals, and the
//! "needs you" list. No model, no GitHub call; it works offline on any copy of
//! `run.jsonl`. `--watch N` re-renders every N seconds in place.

use crate::log::{Event, Kind};
use crate::types::{GateState, PrState, SeatState};
use std::collections::BTreeMap;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Hour {
    pub merges: u32,
    pub prs_opened: u32,
    pub cycles: u32,
    pub gate_green: u32,
    pub gate_red: u32,
    pub gate_killed: u32,
    pub refused: u32,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct RoleCost {
    pub cycles: u32,
    pub tokens_in: u64,
    pub tokens_out: u64,
    pub stalled: u32,
}

#[derive(Debug, Default)]
pub struct Board {
    pub first_ts: u64,
    pub last_ts: u64,
    pub hours: BTreeMap<u64, Hour>,
    pub roles: BTreeMap<String, RoleCost>,
    pub merged_prs: Vec<u64>,
    pub open_prs: Vec<u64>,
    pub gated_issues: Vec<u64>,
    pub last_gate: Option<GateState>,
    pub refusals: Vec<(u64, String, String)>,
    pub humans: Vec<(u64, String, String, String)>,
}

pub fn fold(events: &[Event]) -> Board {
    let mut b = Board::default();
    let mut open: BTreeMap<u64, ()> = BTreeMap::new();
    for e in events {
        if b.first_ts == 0 {
            b.first_ts = e.ts;
        }
        b.last_ts = b.last_ts.max(e.ts);
        let h = b.hours.entry(e.ts / 3600).or_default();
        match &e.kind {
            Kind::Pr { pr, to, .. } => match to {
                PrState::Merged { .. } => {
                    h.merges += 1;
                    open.remove(pr);
                    b.merged_prs.push(*pr);
                }
                PrState::ClosedUnmerged => {
                    open.remove(pr);
                }
                _ => {
                    if open.insert(*pr, ()).is_none() {
                        h.prs_opened += 1;
                    }
                }
            },
            Kind::Seat {
                role,
                to,
                tokens_in,
                tokens_out,
                ..
            } => {
                let rc = b
                    .roles
                    .entry(format!("{role:?}").to_lowercase())
                    .or_default();
                match to {
                    SeatState::Reported { .. } => {
                        rc.cycles += 1;
                        h.cycles += 1;
                        rc.tokens_in += tokens_in.unwrap_or(0);
                        rc.tokens_out += tokens_out.unwrap_or(0);
                    }
                    SeatState::Stalled { .. } => rc.stalled += 1,
                    _ => {}
                }
            }
            Kind::Gate { to } => {
                match to {
                    GateState::Green { .. } => h.gate_green += 1,
                    GateState::Red { .. } => h.gate_red += 1,
                    GateState::Killed { .. } => h.gate_killed += 1,
                    _ => {}
                }
                b.last_gate = Some(to.clone());
            }
            Kind::Issue { issue, to } => {
                use crate::types::IssueState;
                match to {
                    IssueState::Gated => {
                        if !b.gated_issues.contains(issue) {
                            b.gated_issues.push(*issue)
                        }
                    }
                    _ => b.gated_issues.retain(|i| i != issue),
                }
            }
            Kind::Refused { what, why } => {
                h.refused += 1;
                b.refusals.push((e.ts, what.clone(), why.clone()));
            }
            Kind::Human {
                actor,
                action,
                target,
            } => b
                .humans
                .push((e.ts, actor.clone(), action.clone(), target.clone())),
            Kind::Promote { .. } | Kind::Note { .. } => {}
        }
    }
    b.open_prs = open.into_keys().collect();
    b
}

fn hhmm(ts: u64) -> String {
    let s = ts % 86400;
    format!("{:02}:{:02}Z", s / 3600, (s % 3600) / 60)
}

fn k(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1e6)
    } else if n >= 1000 {
        format!("{}k", n / 1000)
    } else {
        n.to_string()
    }
}

pub fn render(b: &Board, now: u64) -> String {
    let mut out = String::new();
    if b.hours.is_empty() {
        out.push_str("run record is empty: nothing has happened yet\n");
        return out;
    }
    let span_h = ((b.last_ts.saturating_sub(b.first_ts)) as f64 / 3600.0).max(1.0 / 60.0);
    let merges: u32 = b.hours.values().map(|h| h.merges).sum();
    let cycles: u32 = b.hours.values().map(|h| h.cycles).sum();
    let green: u32 = b.hours.values().map(|h| h.gate_green).sum();
    let red: u32 = b.hours.values().map(|h| h.gate_red).sum();
    let killed: u32 = b.hours.values().map(|h| h.gate_killed).sum();
    out.push_str(&format!(
        "fwfd dash · record {} → {} ({:.1}h) · last event {}s ago\n",
        hhmm(b.first_ts),
        hhmm(b.last_ts),
        span_h,
        now.saturating_sub(b.last_ts)
    ));
    out.push_str(&format!(
        "throughput   merges {merges} ({:.2}/h) · seat cycles {cycles} ({:.2}/h) · PRs open {}\n",
        merges as f64 / span_h,
        cycles as f64 / span_h,
        b.open_prs.len()
    ));
    out.push_str(&format!(
        "gates        green {green} · red {red} · killed {killed} · last {}\n",
        match &b.last_gate {
            Some(GateState::Green { suite, secs, .. }) => format!("green {suite} {secs}s"),
            Some(GateState::Red { suite, failed, .. }) => format!("RED {suite} {failed} failed"),
            Some(GateState::Killed { suite, reason, .. }) => format!("KILLED {suite} {reason}"),
            Some(other) => format!("{other:?}"),
            None => "none".into(),
        }
    ));
    out.push_str("per hour     hour   merges opened cycles green red killed refused\n");
    for (h, v) in b
        .hours
        .iter()
        .rev()
        .take(12)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        out.push_str(&format!(
            "             {}  {:>6} {:>6} {:>6} {:>5} {:>3} {:>6} {:>7}\n",
            hhmm(h * 3600),
            v.merges,
            v.prs_opened,
            v.cycles,
            v.gate_green,
            v.gate_red,
            v.gate_killed,
            v.refused
        ));
    }
    out.push_str("cost         role   cycles stalled  tokens-in  tokens-out  in/cycle\n");
    for (role, c) in &b.roles {
        out.push_str(&format!(
            "             {:<6} {:>6} {:>7} {:>10} {:>11} {:>9}\n",
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
    out.push_str("needs you\n");
    let mut needs = 0;
    for (ts, what, why) in b.refusals.iter().rev().take(5) {
        out.push_str(&format!("  - {} refused {what}: {why}\n", hhmm(*ts)));
        needs += 1;
    }
    if !b.gated_issues.is_empty() {
        out.push_str(&format!(
            "  - gated, awaiting `fwfd ungate`: {}\n",
            b.gated_issues
                .iter()
                .map(|i| format!("#{i}"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
        needs += 1;
    }
    if !b.open_prs.is_empty() {
        out.push_str(&format!(
            "  - PRs still open in the record: {}\n",
            b.open_prs
                .iter()
                .map(|p| format!("#{p}"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
        needs += 1;
    }
    if needs == 0 {
        out.push_str("  nothing\n");
    }
    if let Some((ts, actor, action, target)) = b.humans.last() {
        out.push_str(&format!(
            "last human   {} {actor} {action} {target}\n",
            hhmm(*ts)
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{IssueState, JobRef, Role, Sha};

    fn sha() -> Sha {
        Sha::parse(&"a".repeat(40)).unwrap()
    }
    fn ev(ts: u64, kind: Kind) -> Event {
        Event {
            ts,
            repo: "o/r".into(),
            kind,
        }
    }
    fn job() -> JobRef {
        JobRef {
            role: Role::Impl,
            issue: Some(1),
            pr: None,
        }
    }

    #[test]
    fn folds_merges_cycles_gates_and_needs_you() {
        let evs = vec![
            ev(
                3600,
                Kind::Pr {
                    pr: 5,
                    issue: Some(1),
                    to: PrState::Draft { head: sha() },
                },
            ),
            ev(
                3700,
                Kind::Seat {
                    seat: 1,
                    role: Role::Impl,
                    to: SeatState::Reported { job: job() },
                    tokens_in: Some(500_000),
                    tokens_out: Some(5_000),
                },
            ),
            ev(
                3800,
                Kind::Gate {
                    to: GateState::Green {
                        sha: sha(),
                        suite: "fast".into(),
                        secs: 3,
                    },
                },
            ),
            ev(
                7300,
                Kind::Pr {
                    pr: 5,
                    issue: Some(1),
                    to: PrState::Merged { sha: sha() },
                },
            ),
            ev(
                7400,
                Kind::Pr {
                    pr: 6,
                    issue: Some(2),
                    to: PrState::Draft { head: sha() },
                },
            ),
            ev(
                7500,
                Kind::Issue {
                    issue: 9,
                    to: IssueState::Gated,
                },
            ),
            ev(
                7600,
                Kind::Refused {
                    what: "#7".into(),
                    why: "not on the allow-list".into(),
                },
            ),
            ev(
                7700,
                Kind::Seat {
                    seat: 1,
                    role: Role::Qa,
                    to: SeatState::Stalled { job: job() },
                    tokens_in: None,
                    tokens_out: None,
                },
            ),
        ];
        let b = fold(&evs);
        assert_eq!(b.hours[&1].prs_opened, 1);
        assert_eq!(b.hours[&1].cycles, 1);
        assert_eq!(b.hours[&1].gate_green, 1);
        assert_eq!(b.hours[&2].merges, 1);
        assert_eq!(b.merged_prs, vec![5]);
        assert_eq!(b.open_prs, vec![6]);
        assert_eq!(b.gated_issues, vec![9]);
        assert_eq!(b.roles["impl"].tokens_in, 500_000);
        assert_eq!(b.roles["qa"].stalled, 1);
        let r = render(&b, 8000);
        assert!(r.contains("merges 1"));
        assert!(r.contains("gated, awaiting `fwfd ungate`: #9"));
        assert!(r.contains("refused #7"));
        assert!(r.contains("PRs still open in the record: #6"));
        assert!(r.contains("impl        1       0       500k"));
    }

    #[test]
    fn ungate_clears_the_gated_list_and_empty_record_says_so() {
        let evs = vec![
            ev(
                10,
                Kind::Issue {
                    issue: 9,
                    to: IssueState::Gated,
                },
            ),
            ev(
                20,
                Kind::Issue {
                    issue: 9,
                    to: IssueState::Ready,
                },
            ),
        ];
        assert!(fold(&evs).gated_issues.is_empty());
        assert!(render(&fold(&[]), 0).starts_with("run record is empty"));
    }
}
