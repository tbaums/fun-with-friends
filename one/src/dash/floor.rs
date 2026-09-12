//! #574 — the joins the run record cannot make on its own.
//!
//! The record knows every transition; it cannot know which seats the
//! manifest asks for, whether their panes are alive, whether the loop
//! is up, or where the meter stands. Those arrive as a `Floor`, and
//! this module joins them with the fold into the rows the board draws
//! plus the one list that matters most — what only a human can clear.
//! Still pure: `now` and tmux's answer are arguments.

use super::{fmt_secs, gate_line, role_name, role_rank, seat_key, Board, PrLive, Stage};
use crate::types::{GateState, IssueState, Role, SeatState};

/// Is the supervisor loop up, and if not, why. Computed from the manifest's
/// brake threshold and the meter file by `loop_state`; never guessed.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum LoopState {
    Running,
    /// Up, but the meter brake is holding it (the reason, in words).
    Parked(String),
    NotRunning,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Meter {
    pub weekly: u8,
    pub session: Option<u8>,
    pub when: String,
    /// How old the reading is; `None` when the stamp could not be parsed.
    pub age: Option<u64>,
}

/// One seat the manifest says should exist, and what tmux says about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Slot {
    pub role: Role,
    pub seat: u8,
    /// tmux target, e.g. `fwf-one:impl1`.
    pub target: String,
    /// The pane's foreground command; `None` when tmux could not be read.
    pub pane: Option<String>,
}

impl Slot {
    /// A warm seat runs `claude` — the native install names its binary by
    /// version, so a digit counts too (the same test `fwfd seats` uses).
    pub fn live(&self) -> Option<bool> {
        self.pane
            .as_deref()
            .map(|c| c == "claude" || c.chars().next().is_some_and(|ch| ch.is_ascii_digit()))
    }
    pub fn label(&self) -> String {
        format!("{}{}", role_name(self.role), self.seat)
    }
}

/// The floor around the record: the manifest's facts plus tmux liveness.
#[derive(Clone, Debug, Default)]
pub struct Floor {
    pub repo: String,
    pub base: String,
    pub release: String,
    pub session: String,
    pub version: String,
    pub slots: Vec<Slot>,
    /// The manifest's `issues = [...]` allow-list (empty = any eligible).
    pub allow: Vec<u64>,
    pub loop_state: LoopState,
    pub meter: Option<Meter>,
    pub park_at: u8,
    /// Manifest `rework_cap`: rounds the loop gives a refused PR before it
    /// becomes a human's decision (#576).
    pub rework_cap: u32,
}

/// How old a meter reading may be before the brake treats it as absent —
/// the same 45 minutes `fwfd run` uses, restated here so the dash agrees
/// with the loop rather than approximating it.
pub const METER_MAX_AGE: u64 = crate::run::METER_MAX_AGE;

/// The loop's state as the operator would work it out: the `run` window has
/// to be alive, and the brake has to not be holding. `window` is `None` when
/// tmux could not be read — that is Unknown, never "not running".
pub fn loop_state(window: Option<bool>, meter: Option<&Meter>, park_at: u8) -> LoopState {
    match window {
        None => LoopState::Unknown,
        Some(false) => LoopState::NotRunning,
        Some(true) => match meter {
            Some(m) if m.age.is_none_or(|a| a > METER_MAX_AGE) => LoopState::Parked(format!(
                "meter reading is {} (logged {})",
                m.age
                    .map(|a| format!("{}m old", a / 60))
                    .unwrap_or_else(|| "unparseable".into()),
                m.when
            )),
            Some(m) if m.weekly >= park_at => {
                LoopState::Parked(format!("weekly meter {}% ≥ {park_at}%", m.weekly))
            }
            _ => LoopState::Running,
        },
    }
}

/// The seat rows the board draws: every seat the manifest names, joined with
/// whatever the record last said about it, plus any seat the record knows and
/// the manifest does not (a seat that used to exist still has a cost).
pub struct SeatRow<'a> {
    pub label: String,
    pub target: String,
    pub role: Role,
    pub seat: u8,
    pub live: Option<bool>,
    /// The pane's foreground command, when tmux could be read.
    pub pane: Option<String>,
    pub state: SeatState,
    pub since: u64,
    pub cycles: u32,
    pub stalls: u32,
    pub tokens_in: u64,
    pub tokens_out: u64,
    pub key: String,
    pub trail: &'a [(u64, String)],
}

pub fn seat_rows<'a>(b: &'a Board, f: &Floor) -> Vec<SeatRow<'a>> {
    let mut keys: Vec<(u8, u8, Role)> = f
        .slots
        .iter()
        .map(|s| (role_rank(s.role), s.seat, s.role))
        .collect();
    for ((rank, n), s) in &b.seats {
        if !keys.iter().any(|(r, m, _)| r == rank && m == n) {
            keys.push((*rank, *n, s.role));
        }
    }
    keys.sort_unstable_by_key(|(rank, n, _)| (*rank, *n));
    keys.iter()
        .map(|(rank, n, role)| {
            let slot = f
                .slots
                .iter()
                .find(|s| role_rank(s.role) == *rank && s.seat == *n);
            let live = slot.and_then(|s| s.live());
            let l = b.seats.get(&(*rank, *n));
            SeatRow {
                label: format!("{}{n}", role_name(*role)),
                target: slot
                    .map(|s| s.target.clone())
                    .unwrap_or_else(|| "-".to_string()),
                role: *role,
                seat: *n,
                live,
                pane: slot.and_then(|s| s.pane.clone()),
                state: l.map(|s| s.state.clone()).unwrap_or(SeatState::Unknown),
                since: l.map(|s| s.since).unwrap_or(0),
                cycles: l.map(|s| s.cycles).unwrap_or(0),
                stalls: l.map(|s| s.stalls).unwrap_or(0),
                tokens_in: l.map(|s| s.tokens_in).unwrap_or(0),
                tokens_out: l.map(|s| s.tokens_out).unwrap_or(0),
                key: seat_key(*role, *n),
                trail: b.trail_of(&seat_key(*role, *n)),
            }
        })
        .collect()
}

/// A seat's headline: the state word plus what it is doing, in one phrase.
pub fn seat_phrase(row: &SeatRow, now: u64) -> (&'static str, String) {
    let ago = |t: u64| fmt_secs(now.saturating_sub(t));
    match &row.state {
        SeatState::Working { job, deadline } => (
            "WORKING",
            format!(
                "{} · {} in, {} left",
                job_name(job),
                ago(row.since),
                fmt_secs(deadline.saturating_sub(now.min(*deadline)))
            ),
        ),
        SeatState::Reported { job } => (
            "REPORTED",
            format!("{} · {} ago", job_name(job), ago(row.since)),
        ),
        SeatState::Stalled { job } => (
            "STALLED",
            format!("{} · no verdict, {} ago", job_name(job), ago(row.since)),
        ),
        SeatState::Idle => ("IDLE", format!("since {} ago", ago(row.since))),
        SeatState::Gone => ("GONE", format!("since {} ago", ago(row.since))),
        SeatState::Unknown if row.cycles == 0 && row.since == 0 => {
            ("IDLE", "no cycle in this record".to_string())
        }
        SeatState::Unknown => ("UNKNOWN", "the record does not say".to_string()),
    }
}

pub fn job_name(job: &crate::types::JobRef) -> String {
    match (job.issue, job.pr) {
        (_, Some(pr)) => format!("PR #{pr}"),
        (Some(i), None) => format!("#{i}"),
        (None, None) => format!("{:?}", job.role).to_lowercase(),
    }
}

/// The issue queue: every allow-listed issue plus every issue the record
/// mentions, in number order. An allow-listed issue with no events is a real
/// row — "nothing has happened yet" is the answer an operator needs.
pub struct IssueRow<'a> {
    pub issue: u64,
    pub state: IssueState,
    pub since: u64,
    pub seat: Option<u8>,
    pub pr: Option<u64>,
    pub allowed: bool,
    pub key: String,
    pub trail: &'a [(u64, String)],
}

pub fn issue_rows<'a>(b: &'a Board, f: &Floor) -> Vec<IssueRow<'a>> {
    let mut nums: Vec<u64> = b.issues.keys().copied().collect();
    for n in &f.allow {
        if !nums.contains(n) {
            nums.push(*n);
        }
    }
    nums.sort_unstable();
    nums.iter()
        .map(|n| {
            let li = b.issues.get(n);
            IssueRow {
                issue: *n,
                state: li.map(|i| i.state.clone()).unwrap_or(IssueState::Unknown),
                since: li.map(|i| i.since).unwrap_or(0),
                seat: li.and_then(|i| i.seat),
                pr: li
                    .and_then(|i| i.pr)
                    .or_else(|| b.prs.values().find(|p| p.issue == Some(*n)).map(|p| p.pr)),
                allowed: f.allow.is_empty() || f.allow.contains(n),
                key: format!("issue:{n}"),
                trail: b.trail_of(&format!("issue:{n}")),
            }
        })
        .collect()
}

/// The PR pipeline, newest first (a PR the operator just opened is the one
/// they are looking for).
pub fn pr_rows(b: &Board) -> Vec<&PrLive> {
    let mut v: Vec<&PrLive> = b.prs.values().collect();
    v.sort_by_key(|p| std::cmp::Reverse(p.pr));
    v
}

/// Everything only a human can clear. The banner shows the first line; the
/// Decisions tab shows them all.
pub fn needs_you(b: &Board, f: &Floor, now: u64) -> Vec<String> {
    let mut v = Vec::new();
    if let LoopState::NotRunning = f.loop_state {
        v.push(format!(
            "the loop is not running: no `{}:run` window — start `fwfd run`",
            f.session
        ));
    }
    if let LoopState::Parked(why) = &f.loop_state {
        v.push(format!("the loop is PARKED: {why}"));
    }
    for row in seat_rows(b, f) {
        if matches!(row.state, SeatState::Stalled { .. }) {
            v.push(format!(
                "seat {} STALLED on {} — its verdict never arrived",
                row.label,
                seat_phrase(&row, now).1
            ));
        }
        if row.live == Some(false) {
            v.push(format!(
                "seat {} pane is gone ({}): `fwfd seats --up`",
                row.label,
                row.pane_word()
            ));
        }
    }
    if !b.gated_issues.is_empty() {
        v.push(format!(
            "gated, awaiting `fwfd ungate`: {}",
            b.gated_issues
                .iter()
                .map(|i| format!("#{i}"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    for p in pr_rows(b) {
        match p.stage() {
            Stage::Approved => v.push(format!(
                "PR #{} is approved at head: `fwfd merge --pr {}`",
                p.pr, p.pr
            )),
            // Changes requested is the loop's work now: it re-wakes the impl
            // seat on its own branch. Only a PR out of rounds needs a human.
            Stage::Changes => {
                let rounds = b.rework_rounds.get(&p.pr).copied().unwrap_or(0);
                if rounds >= f.rework_cap {
                    v.push(format!(
                        "PR #{} hit the rework cap ({}): close it or push a fix yourself",
                        p.pr, f.rework_cap
                    ));
                }
            }
            _ => {}
        }
        // A red or killed gate on the merge sha is a human's problem whether
        // or not the sha was already promoted.
        if let Some(g @ (GateState::Red { .. } | GateState::Killed { .. })) = p.gates.last() {
            v.push(match &p.promoted {
                Some((branch, _)) => format!(
                    "PR #{} was promoted to {branch} but its last gate is {}",
                    p.pr,
                    gate_line(g)
                ),
                None => format!(
                    "PR #{} merged but its gate is {} — do not promote this sha",
                    p.pr,
                    gate_line(g)
                ),
            });
        }
    }
    // The loop re-refuses the same issue every tick, so a raw list would be
    // one line per tick. Collapse by subject, newest first, with the count.
    let mut seen: Vec<&str> = Vec::new();
    for (ts, what, why) in b.refusals.iter().rev() {
        if seen.contains(&what.as_str()) {
            continue;
        }
        seen.push(what);
        let n = b.refusals.iter().filter(|(_, w, _)| w == what).count();
        v.push(format!(
            "refused {what} {} ago{}: {why}",
            fmt_secs(now.saturating_sub(*ts)),
            if n > 1 {
                format!(" ({n}× in this record)")
            } else {
                String::new()
            }
        ));
        if seen.len() == 5 {
            break;
        }
    }
    v
}

impl SeatRow<'_> {
    /// What tmux says about the pane, never a guess when it said nothing.
    pub fn pane_word(&self) -> String {
        match (self.pane.as_deref(), self.live) {
            (Some(c), Some(true)) => format!("live, {c}"),
            // `fwfd seats` reports a missing window as "absent"; a pane that
            // exists but dropped to a shell is a different problem.
            (Some("absent"), Some(false)) => "no pane in tmux".to_string(),
            (Some(c), Some(false)) => format!("gone, running {c}"),
            _ => "pane unknown (tmux not read)".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dash::fixture::test_record;
    use crate::dash::{fold, Sha};
    use crate::log::{Event, Kind};
    use crate::types::{Fence, PrState};

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

    /// #576: changes requested is the loop's work until the rounds run out.
    #[test]
    fn a_refused_pr_needs_a_human_only_once_it_is_out_of_rounds() {
        let refused = |head: Sha| {
            vec![
                ev(
                    10,
                    Kind::Pr {
                        pr: 1270,
                        issue: Some(575),
                        to: PrState::Draft { head: head.clone() },
                    },
                ),
                ev(
                    20,
                    Kind::Pr {
                        pr: 1270,
                        issue: Some(575),
                        to: PrState::ChangesRequested { head },
                    },
                ),
            ]
        };
        let round = |ts: u64| {
            ev(
                ts,
                Kind::Seat {
                    seat: 1,
                    role: Role::Impl,
                    to: SeatState::Working {
                        job: crate::types::JobRef {
                            role: Role::Impl,
                            issue: Some(575),
                            pr: Some(1270),
                        },
                        deadline: ts + 100,
                    },
                    tokens_in: None,
                    tokens_out: None,
                },
            )
        };
        let f = Floor {
            rework_cap: 2,
            ..Default::default()
        };
        let cap_line = |evs: &[Event]| {
            needs_you(&fold(evs), &f, 9000)
                .into_iter()
                .find(|l| l.contains("rework cap"))
        };
        // no rounds yet, and after one: the loop handles it, no banner
        let mut evs = refused(sha());
        assert_eq!(cap_line(&evs), None);
        assert_eq!(fold(&evs).rework_rounds.get(&1270), None);
        evs.push(round(30));
        assert_eq!(cap_line(&evs), None);
        assert_eq!(fold(&evs).rework_rounds.get(&1270), Some(&1));
        // the second round uses the cap up: now a human has to decide
        evs.push(round(40));
        assert_eq!(fold(&evs).rework_rounds.get(&1270), Some(&2));
        assert_eq!(
            cap_line(&evs).as_deref(),
            Some("PR #1270 hit the rework cap (2): close it or push a fix yourself")
        );
        // a QA wake on the same PR is not a rework round
        let mut qa = refused(sha());
        qa.push(ev(
            30,
            Kind::Seat {
                seat: 1,
                role: Role::Qa,
                to: SeatState::Working {
                    job: crate::types::JobRef {
                        role: Role::Qa,
                        issue: Some(575),
                        pr: Some(1270),
                    },
                    deadline: 130,
                },
                tokens_in: None,
                tokens_out: None,
            },
        ));
        assert_eq!(fold(&qa).rework_rounds.get(&1270), None);
    }

    #[test]
    fn the_issue_queue_walks_gated_ready_claimed_shipped() {
        let evs = vec![
            ev(
                10,
                Kind::Issue {
                    issue: 41,
                    to: IssueState::Gated,
                },
            ),
            ev(
                20,
                Kind::Human {
                    actor: "jamie".into(),
                    action: "ungate".into(),
                    target: "#41".into(),
                },
            ),
            ev(
                21,
                Kind::Issue {
                    issue: 41,
                    to: IssueState::Ready,
                },
            ),
            ev(
                30,
                Kind::Issue {
                    issue: 41,
                    to: IssueState::Claimed {
                        seat: 2,
                        fence: Fence("e1".into()),
                    },
                },
            ),
            ev(
                40,
                Kind::Pr {
                    pr: 7,
                    issue: Some(41),
                    to: PrState::Draft { head: sha() },
                },
            ),
            ev(
                50,
                Kind::Issue {
                    issue: 41,
                    to: IssueState::Shipped { pr: 7, sha: sha() },
                },
            ),
        ];
        let b = fold(&evs);
        let f = Floor {
            allow: vec![41, 99],
            ..Default::default()
        };
        let rows = issue_rows(&b, &f);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].issue, 41);
        assert!(matches!(rows[0].state, IssueState::Shipped { pr: 7, .. }));
        assert_eq!(rows[0].pr, Some(7));
        assert!(rows[0].trail.iter().any(|(_, w)| w.contains("ungate")));
        // an allow-listed issue with no events is still a row
        assert_eq!(rows[1].issue, 99);
        assert_eq!(rows[1].state, IssueState::Unknown);
        assert!(rows[1].trail.is_empty());
        // the claim is only live while it is held
        let mid = fold(&evs[..4]);
        assert_eq!(mid.issues[&41].seat, Some(2));
        assert_eq!(b.issues[&41].seat, None);
    }

    #[test]
    fn loop_state_is_unknown_when_tmux_cannot_be_read() {
        let fresh = Meter {
            weekly: 40,
            session: Some(10),
            when: "2026-09-12 03:00:00".into(),
            age: Some(60),
        };
        assert_eq!(loop_state(None, Some(&fresh), 85), LoopState::Unknown);
        assert_eq!(
            loop_state(Some(false), Some(&fresh), 85),
            LoopState::NotRunning
        );
        assert_eq!(loop_state(Some(true), Some(&fresh), 85), LoopState::Running);
        assert_eq!(loop_state(Some(true), None, 85), LoopState::Running);
        let hot = Meter {
            weekly: 90,
            ..fresh.clone()
        };
        assert!(matches!(
            loop_state(Some(true), Some(&hot), 85),
            LoopState::Parked(w) if w.contains("90%")
        ));
        let stale = Meter {
            age: Some(METER_MAX_AGE + 1),
            ..fresh.clone()
        };
        assert!(matches!(
            loop_state(Some(true), Some(&stale), 85),
            LoopState::Parked(w) if w.contains("m old")
        ));
        let unparseable = Meter { age: None, ..fresh };
        assert!(matches!(
            loop_state(Some(true), Some(&unparseable), 85),
            LoopState::Parked(w) if w.contains("unparseable")
        ));
    }

    #[test]
    fn seat_rows_join_the_manifest_with_the_record() {
        let b = fold(&test_record());
        let f = Floor {
            session: "fwf-one".into(),
            slots: vec![
                Slot {
                    role: Role::Impl,
                    seat: 1,
                    target: "fwf-one:impl1".into(),
                    pane: Some("2.1.266".into()),
                },
                Slot {
                    role: Role::Pm,
                    seat: 1,
                    target: "fwf-one:pm1".into(),
                    pane: Some("bash".into()),
                },
                Slot {
                    role: Role::Gv,
                    seat: 1,
                    target: "fwf-one:gv1".into(),
                    pane: None,
                },
            ],
            ..Default::default()
        };
        let rows = seat_rows(&b, &f);
        // impl1 (manifest + record), qa1 (record only), pm1, gv1
        assert_eq!(
            rows.iter().map(|r| r.label.clone()).collect::<Vec<_>>(),
            vec!["impl1", "qa1", "pm1", "gv1"]
        );
        assert_eq!(rows[0].live, Some(true));
        assert_eq!(rows[0].target, "fwf-one:impl1");
        assert_eq!(rows[1].live, None, "no slot: tmux says nothing");
        assert_eq!(rows[2].live, Some(false));
        assert_eq!(rows[3].live, None, "tmux unreadable is Unknown, not gone");
        let (word, _) = seat_phrase(&rows[2], 9000);
        assert_eq!(word, "IDLE");
        let needs = needs_you(&b, &f, 9000);
        assert!(needs.iter().any(|n| n.contains("qa1 STALLED")));
        assert!(needs.iter().any(|n| n.contains("pm1 pane is gone")));
        assert!(!needs.iter().any(|n| n.contains("gv1 pane is gone")));
        assert!(needs
            .iter()
            .any(|n| n.contains("awaiting `fwfd ungate`: #9")));
        assert!(needs.iter().any(|n| n.contains("refused #7")));
        // the loop re-refuses the same issue every tick: one line, with a count
        let mut evs = test_record();
        for ts in [7800, 7900] {
            evs.push(ev(
                ts,
                Kind::Refused {
                    what: "#7".into(),
                    why: "not on the allow-list".into(),
                },
            ));
        }
        let lines = needs_you(&fold(&evs), &f, 9000);
        let refusals: Vec<&String> = lines.iter().filter(|l| l.starts_with("refused")).collect();
        assert_eq!(refusals.len(), 1, "{refusals:?}");
        assert!(refusals[0].contains("(3× in this record)"), "{refusals:?}");
    }
}
