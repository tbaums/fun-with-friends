//! T-27 / #574 — `fwfd dash`: the board, computed from the run record alone.
//!
//! This module is the FOLD half and nothing else: append-only JSONL in, one
//! `Board` out, no clock, no tmux, no GitHub call. It works offline on any
//! copy of `run.jsonl`. The submodules take it from there: `floor` joins the
//! manifest and tmux liveness, `view` and `panes` render the board, `tty` is
//! the thin terminal layer.
//!
//! What the fold keeps, in the order an operator reaches for it:
//!   * live seats — each seat's last transition, since when, its cycles/cost,
//!   * the issue queue — gated → ready → claimed(seat) → PR → shipped,
//!   * the PR pipeline — draft → QA → approved@head → merged → gate → promoted,
//!   * the human decisions and refusals (the "needs you" list),
//!   * throughput and measured tokens per role (the 1.0 cost ledger).
//!
//! Every entity also keeps a short trail of its own events, so a detail pane
//! is a lookup rather than a second scan.

use crate::log::{self, Event, Kind};
use crate::types::{GateState, IssueState, PrState, Role, SeatState, Sha};
use std::collections::BTreeMap;

/// How many of an entity's own events a detail pane can show.
pub const TRAIL: usize = 14;

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

/// One seat as the record last saw it. `state` is the last transition, not a
/// guess: a seat with no events at all is simply absent from `Board::seats`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatLive {
    pub seat: u8,
    pub role: Role,
    pub state: SeatState,
    pub since: u64,
    pub cycles: u32,
    pub stalls: u32,
    pub tokens_in: u64,
    pub tokens_out: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IssueLive {
    pub issue: u64,
    pub state: IssueState,
    pub since: u64,
    /// The seat holding the claim, while it holds it.
    pub seat: Option<u8>,
    /// The PR that names this issue (the last one, if it was re-opened).
    pub pr: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrLive {
    pub pr: u64,
    pub issue: Option<u64>,
    pub state: PrState,
    pub since: u64,
    pub opened: u64,
    pub head: Option<Sha>,
    pub merge_sha: Option<Sha>,
    /// The QA seat that is working on it right now, and since when.
    pub qa: Option<(u8, u64)>,
    /// Gate verdicts recorded for the merge sha, oldest first.
    pub gates: Vec<GateState>,
    /// The branch its merge sha was promoted to, and when.
    pub promoted: Option<(String, u64)>,
}

/// Where a PR sits in the pipeline. One value, ordered as the pipeline runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stage {
    Draft,
    QaWorking,
    Changes,
    Approved,
    Merged,
    GateRed,
    GateGreen,
    Promoted,
    Closed,
    Unknown,
}

impl Stage {
    pub fn label(self) -> &'static str {
        match self {
            Stage::Draft => "draft",
            Stage::QaWorking => "qa working",
            Stage::Changes => "changes req",
            Stage::Approved => "approved@head",
            Stage::Merged => "merged",
            Stage::GateRed => "gate RED",
            Stage::GateGreen => "gate green",
            Stage::Promoted => "promoted",
            Stage::Closed => "closed",
            Stage::Unknown => "UNKNOWN",
        }
    }
    /// The pipeline as the dash draws it, left to right.
    pub const PIPELINE: [Stage; 6] = [
        Stage::Draft,
        Stage::QaWorking,
        Stage::Approved,
        Stage::Merged,
        Stage::GateGreen,
        Stage::Promoted,
    ];
}

impl PrLive {
    pub fn stage(&self) -> Stage {
        if self.promoted.is_some() {
            return Stage::Promoted;
        }
        if matches!(self.state, PrState::Merged { .. }) {
            return match self.gates.last() {
                Some(GateState::Green { .. }) => Stage::GateGreen,
                Some(GateState::Red { .. }) | Some(GateState::Killed { .. }) => Stage::GateRed,
                _ => Stage::Merged,
            };
        }
        match &self.state {
            PrState::ClosedUnmerged => Stage::Closed,
            PrState::Approved { .. } => Stage::Approved,
            PrState::ChangesRequested { .. } => Stage::Changes,
            PrState::Stale { .. } => Stage::Changes,
            PrState::Draft { .. } | PrState::Open { .. } => {
                if self.qa.is_some() {
                    Stage::QaWorking
                } else {
                    Stage::Draft
                }
            }
            PrState::Merged { .. } => Stage::Merged,
            PrState::Unknown => Stage::Unknown,
        }
    }
}

#[derive(Debug, Default)]
pub struct Board {
    pub first_ts: u64,
    pub last_ts: u64,
    pub hours: BTreeMap<u64, Hour>,
    pub roles: BTreeMap<String, RoleCost>,
    /// Keyed (role rank, seat number) so the board reads impl, qa, pm, gv.
    pub seats: BTreeMap<(u8, u8), SeatLive>,
    pub issues: BTreeMap<u64, IssueLive>,
    pub prs: BTreeMap<u64, PrLive>,
    pub merged_prs: Vec<u64>,
    pub open_prs: Vec<u64>,
    pub gated_issues: Vec<u64>,
    pub last_gate: Option<GateState>,
    pub refusals: Vec<(u64, String, String)>,
    pub humans: Vec<(u64, String, String, String)>,
    /// Rework rounds per PR (#576): one per impl wake whose job names the PR.
    pub rework_rounds: BTreeMap<u64, u32>,
    /// Per-entity event trails, keyed `seat:impl1` / `issue:574` / `pr:9`.
    pub trails: BTreeMap<String, Vec<(u64, String)>>,
}

pub fn role_name(r: Role) -> &'static str {
    match r {
        Role::Impl => "impl",
        Role::Qa => "qa",
        Role::Pm => "pm",
        Role::Gv => "gv",
        Role::Captain => "captain",
    }
}

/// Display order: the seats that do the work first.
pub fn role_rank(r: Role) -> u8 {
    match r {
        Role::Impl => 0,
        Role::Qa => 1,
        Role::Pm => 2,
        Role::Gv => 3,
        Role::Captain => 4,
    }
}

pub fn seat_key(role: Role, seat: u8) -> String {
    format!("seat:{}{seat}", role_name(role))
}

impl Board {
    fn trail(&mut self, key: String, ts: u64, what: &str) {
        let v = self.trails.entry(key).or_default();
        v.push((ts, what.to_string()));
        if v.len() > TRAIL {
            v.remove(0);
        }
    }
    pub fn trail_of(&self, key: &str) -> &[(u64, String)] {
        self.trails.get(key).map(|v| v.as_slice()).unwrap_or(&[])
    }
}

pub fn fold(events: &[Event]) -> Board {
    let mut b = Board::default();
    let mut open: BTreeMap<u64, ()> = BTreeMap::new();
    // Gate and promote events name a sha, not a PR; attach them once every
    // merge sha is known so record order cannot matter.
    let mut gates: Vec<(u64, GateState)> = Vec::new();
    let mut promotes: Vec<(u64, String, String)> = Vec::new();
    for e in events {
        if b.first_ts == 0 {
            b.first_ts = e.ts;
        }
        b.last_ts = b.last_ts.max(e.ts);
        let h = b.hours.entry(e.ts / 3600).or_default();
        let what = log::describe(&e.kind);
        match &e.kind {
            Kind::Pr { pr, issue, to } => {
                match to {
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
                }
                let ts = e.ts;
                let p = b.prs.entry(*pr).or_insert_with(|| PrLive {
                    pr: *pr,
                    issue: *issue,
                    state: PrState::Unknown,
                    since: ts,
                    opened: ts,
                    head: None,
                    merge_sha: None,
                    qa: None,
                    gates: Vec::new(),
                    promoted: None,
                });
                if issue.is_some() {
                    p.issue = *issue;
                }
                p.state = to.clone();
                p.since = ts;
                match to {
                    PrState::Draft { head }
                    | PrState::Open { head }
                    | PrState::ChangesRequested { head }
                    | PrState::Stale { head, .. }
                    | PrState::Approved { head, .. } => p.head = Some(head.clone()),
                    PrState::Merged { sha } => {
                        p.merge_sha = Some(sha.clone());
                        p.qa = None;
                    }
                    PrState::ClosedUnmerged | PrState::Unknown => {}
                }
                b.trail(format!("pr:{pr}"), e.ts, &what);
                if let Some(i) = issue {
                    b.trail(format!("issue:{i}"), e.ts, &what);
                    if let Some(li) = b.issues.get_mut(i) {
                        li.pr = Some(*pr);
                    }
                }
            }
            Kind::Seat {
                seat,
                role,
                to,
                tokens_in,
                tokens_out,
            } => {
                let rc = b.roles.entry(role_name(*role).to_string()).or_default();
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
                let s = b
                    .seats
                    .entry((role_rank(*role), *seat))
                    .or_insert_with(|| SeatLive {
                        seat: *seat,
                        role: *role,
                        state: SeatState::Unknown,
                        since: e.ts,
                        cycles: 0,
                        stalls: 0,
                        tokens_in: 0,
                        tokens_out: 0,
                    });
                s.state = to.clone();
                s.since = e.ts;
                match to {
                    SeatState::Reported { .. } => {
                        s.cycles += 1;
                        s.tokens_in += tokens_in.unwrap_or(0);
                        s.tokens_out += tokens_out.unwrap_or(0);
                    }
                    SeatState::Stalled { .. } => s.stalls += 1,
                    _ => {}
                }
                b.trail(seat_key(*role, *seat), e.ts, &what);
                // A seat's job names the issue and PR it is moving; the
                // queue and the pipeline want to show that, not just the seat.
                let job = match to {
                    SeatState::Working { job, .. }
                    | SeatState::Reported { job }
                    | SeatState::Stalled { job } => Some(job.clone()),
                    _ => None,
                };
                if let Some(job) = job {
                    if let Some(i) = job.issue {
                        b.trail(format!("issue:{i}"), e.ts, &what);
                    }
                    if let Some(n) = job.pr {
                        b.trail(format!("pr:{n}"), e.ts, &what);
                        // An impl seat woken on a PR is a rework round (#576);
                        // the slice's impl job names an issue, never a PR. Same
                        // rule as `rework::rounds`, folded in one pass here.
                        if *role == Role::Impl && matches!(to, SeatState::Working { .. }) {
                            *b.rework_rounds.entry(n).or_default() += 1;
                        }
                        if let Some(p) = b.prs.get_mut(&n) {
                            p.qa = match (role, to) {
                                (Role::Qa, SeatState::Working { .. }) => Some((*seat, e.ts)),
                                (Role::Qa, _) => None,
                                _ => p.qa,
                            };
                        }
                    }
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
                gates.push((e.ts, to.clone()));
            }
            Kind::Issue { issue, to } => {
                match to {
                    IssueState::Gated => {
                        if !b.gated_issues.contains(issue) {
                            b.gated_issues.push(*issue)
                        }
                    }
                    _ => b.gated_issues.retain(|i| i != issue),
                }
                let ts = e.ts;
                let li = b.issues.entry(*issue).or_insert_with(|| IssueLive {
                    issue: *issue,
                    state: IssueState::Unknown,
                    since: ts,
                    seat: None,
                    pr: None,
                });
                li.state = to.clone();
                li.since = ts;
                li.seat = match to {
                    IssueState::Claimed { seat, .. } => Some(*seat),
                    _ => None,
                };
                if let IssueState::Shipped { pr, .. } = to {
                    li.pr = Some(*pr);
                }
                b.trail(format!("issue:{issue}"), e.ts, &what);
            }
            Kind::Refused { what: w, why } => {
                h.refused += 1;
                b.refusals.push((e.ts, w.clone(), why.clone()));
                if let Some(n) = number_in(w) {
                    b.trail(format!("issue:{n}"), e.ts, &what);
                    b.trail(format!("pr:{n}"), e.ts, &what);
                }
            }
            Kind::Human {
                actor,
                action,
                target,
            } => {
                b.humans
                    .push((e.ts, actor.clone(), action.clone(), target.clone()));
                if let Some(n) = number_in(target) {
                    b.trail(format!("issue:{n}"), e.ts, &what);
                    b.trail(format!("pr:{n}"), e.ts, &what);
                }
            }
            Kind::Promote { branch, to, .. } => promotes.push((e.ts, branch.clone(), to.clone())),
            Kind::Note { .. } => {}
        }
    }
    b.open_prs = open.into_keys().collect();
    // Second pass: a gate verdict or a promotion belongs to the PR whose
    // merge sha it names. Nothing is attached on a guess.
    let by_sha: BTreeMap<String, u64> = b
        .prs
        .values()
        .filter_map(|p| p.merge_sha.as_ref().map(|s| (s.to_string(), p.pr)))
        .collect();
    for (ts, g) in gates {
        let Some(sha) = gate_sha(&g) else { continue };
        if let Some(p) = by_sha.get(sha.as_str()).and_then(|n| b.prs.get_mut(n)) {
            p.gates.push(g.clone());
            let what = log::describe(&Kind::Gate { to: g });
            let pr = p.pr;
            b.trail(format!("pr:{pr}"), ts, &what);
        }
    }
    for (ts, branch, to) in promotes {
        if let Some(p) = by_sha.get(&to).and_then(|n| b.prs.get_mut(n)) {
            p.promoted = Some((branch.clone(), ts));
            let what = format!("promote {branch} ← {}", &to[..8.min(to.len())]);
            let pr = p.pr;
            b.trail(format!("pr:{pr}"), ts, &what);
        }
    }
    b
}

/// One gate verdict in a phrase.
pub fn gate_line(g: &GateState) -> String {
    match g {
        GateState::Green { suite, secs, .. } => format!("green {suite} in {}", fmt_secs(*secs)),
        GateState::Red { suite, failed, .. } => format!("RED {suite}, {failed} failed"),
        GateState::Killed { suite, reason, .. } => format!("KILLED {suite}: {reason}"),
        GateState::Running { suite, .. } => format!("running {suite}"),
        GateState::Queued { suite, .. } => format!("queued {suite}"),
        GateState::Unknown => "unknown".into(),
    }
}

fn gate_sha(g: &GateState) -> Option<&Sha> {
    match g {
        GateState::Queued { sha, .. }
        | GateState::Running { sha, .. }
        | GateState::Green { sha, .. }
        | GateState::Red { sha, .. }
        | GateState::Killed { sha, .. } => Some(sha),
        GateState::Unknown => None,
    }
}

/// The `#123` in a refusal's subject or a human action's target.
fn number_in(s: &str) -> Option<u64> {
    let i = s.find('#')?;
    s[i + 1..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .ok()
}
/// The joins the record cannot make on its own: the manifest, tmux
/// liveness, the meter — and the rows the board draws from them.
pub mod floor;
/// The four tab bodies and the cost ledger.
pub mod panes;
/// The terminal layer: size, raw mode, keys, the frame loop.
pub mod tty;
/// The frame: header, tabs, banner, the two panes, footer.
pub mod view;

// The floor-side joins read as part of the dash's own surface: `dash::Floor`,
// `dash::needs_you`, `dash::seat_rows`.
pub use floor::*;

/// `2h 05m`, `7m 12s`, `41s` — an elapsed time an operator can read at a
/// glance, never a bare count of seconds.
pub fn fmt_secs(s: u64) -> String {
    if s >= 3600 {
        format!("{}h {:02}m", s / 3600, (s % 3600) / 60)
    } else if s >= 60 {
        format!("{}m {:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

pub fn hhmm(ts: u64) -> String {
    let s = ts % 86400;
    format!("{:02}:{:02}Z", s / 3600, (s % 3600) / 60)
}

pub fn k(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1e6)
    } else if n >= 1000 {
        format!("{}k", n / 1000)
    } else {
        n.to_string()
    }
}

#[cfg(test)]
pub(crate) mod fixture {
    //! One small record every dash test folds: a merged PR, a
    //! reported impl cycle, a green gate, a gated issue, a refusal
    //! and a stalled QA seat.
    use super::*;
    use crate::types::{JobRef, Role};
    pub fn sha() -> Sha {
        Sha::parse(&"a".repeat(40)).unwrap()
    }
    pub fn ev(ts: u64, kind: Kind) -> Event {
        Event {
            ts,
            repo: "o/r".into(),
            kind,
        }
    }
    pub fn job() -> JobRef {
        JobRef {
            role: Role::Impl,
            issue: Some(1),
            pr: None,
        }
    }

    pub(crate) fn test_record() -> Vec<Event> {
        vec![
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
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{JobRef, Role};
    use fixture::*;

    #[test]
    fn folds_merges_cycles_gates_and_needs_you() {
        let b = fold(&test_record());
        assert_eq!(b.hours[&1].prs_opened, 1);
        assert_eq!(b.hours[&1].cycles, 1);
        assert_eq!(b.hours[&1].gate_green, 1);
        assert_eq!(b.hours[&2].merges, 1);
        assert_eq!(b.merged_prs, vec![5]);
        assert_eq!(b.open_prs, vec![6]);
        assert_eq!(b.gated_issues, vec![9]);
        assert_eq!(b.roles["impl"].tokens_in, 500_000);
        assert_eq!(b.roles["qa"].stalled, 1);
    }

    #[test]
    fn ungate_clears_the_gated_list() {
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
        let b = fold(&evs);
        assert!(b.gated_issues.is_empty());
        assert_eq!(b.issues[&9].state, IssueState::Ready);
        assert_eq!(b.issues[&9].since, 20);
    }

    #[test]
    fn seats_carry_their_last_transition_and_their_cost() {
        let b = fold(&test_record());
        let impl1 = &b.seats[&(role_rank(Role::Impl), 1)];
        assert!(matches!(impl1.state, SeatState::Reported { .. }));
        assert_eq!(impl1.cycles, 1);
        assert_eq!(impl1.tokens_in, 500_000);
        let qa1 = &b.seats[&(role_rank(Role::Qa), 1)];
        assert!(matches!(qa1.state, SeatState::Stalled { .. }));
        assert_eq!(qa1.stalls, 1);
        // and the seat's own trail is there for the detail pane
        assert_eq!(b.trail_of("seat:impl1").len(), 1);
        assert!(b.trail_of("seat:impl1")[0].1.contains("reported"));
    }

    #[test]
    fn the_pr_pipeline_walks_draft_qa_approved_merged_gate_promoted() {
        let head = sha();
        let merged = Sha::parse(&"b".repeat(40)).unwrap();
        let qa_job = JobRef {
            role: Role::Qa,
            issue: Some(41),
            pr: Some(7),
        };
        let mut evs = vec![
            ev(
                10,
                Kind::Pr {
                    pr: 7,
                    issue: Some(41),
                    to: PrState::Draft { head: head.clone() },
                },
            ),
            ev(
                20,
                Kind::Seat {
                    seat: 1,
                    role: Role::Qa,
                    to: SeatState::Working {
                        job: qa_job.clone(),
                        deadline: 900,
                    },
                    tokens_in: None,
                    tokens_out: None,
                },
            ),
        ];
        let b = fold(&evs);
        assert_eq!(b.prs[&7].stage(), Stage::QaWorking);
        assert_eq!(b.prs[&7].qa, Some((1, 20)));

        evs.push(ev(
            30,
            Kind::Seat {
                seat: 1,
                role: Role::Qa,
                to: SeatState::Reported { job: qa_job },
                tokens_in: Some(10),
                tokens_out: Some(1),
            },
        ));
        evs.push(ev(
            40,
            Kind::Pr {
                pr: 7,
                issue: Some(41),
                to: PrState::Approved {
                    head: head.clone(),
                    reviewer: Role::Qa,
                },
            },
        ));
        assert_eq!(fold(&evs).prs[&7].stage(), Stage::Approved);

        evs.push(ev(
            50,
            Kind::Pr {
                pr: 7,
                issue: Some(41),
                to: PrState::Merged {
                    sha: merged.clone(),
                },
            },
        ));
        assert_eq!(fold(&evs).prs[&7].stage(), Stage::Merged);

        // a gate for an unrelated sha must not attach
        evs.push(ev(
            55,
            Kind::Gate {
                to: GateState::Green {
                    sha: head.clone(),
                    suite: "fast".into(),
                    secs: 1,
                },
            },
        ));
        assert_eq!(fold(&evs).prs[&7].gates.len(), 0);

        evs.push(ev(
            60,
            Kind::Gate {
                to: GateState::Red {
                    sha: merged.clone(),
                    suite: "e2e".into(),
                    failed: 7,
                },
            },
        ));
        assert_eq!(fold(&evs).prs[&7].stage(), Stage::GateRed);
        evs.push(ev(
            70,
            Kind::Gate {
                to: GateState::Green {
                    sha: merged.clone(),
                    suite: "e2e".into(),
                    secs: 300,
                },
            },
        ));
        assert_eq!(fold(&evs).prs[&7].stage(), Stage::GateGreen);

        evs.push(ev(
            80,
            Kind::Promote {
                branch: "main".into(),
                from: "0".repeat(40),
                to: merged.to_string(),
            },
        ));
        let b = fold(&evs);
        assert_eq!(b.prs[&7].stage(), Stage::Promoted);
        assert_eq!(b.prs[&7].promoted.as_ref().unwrap().0, "main");
        assert_eq!(b.prs[&7].qa, None, "merge clears the QA seat");
        assert!(b
            .trail_of("pr:7")
            .iter()
            .any(|(_, w)| w.contains("promote main")));
    }

    #[test]
    fn elapsed_reads_like_a_clock() {
        assert_eq!(fmt_secs(41), "41s");
        assert_eq!(fmt_secs(432), "7m 12s");
        assert_eq!(fmt_secs(7500), "2h 05m");
    }
}
