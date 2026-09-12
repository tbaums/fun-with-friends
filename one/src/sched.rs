//! The scheduler (T-09): a pure function from one [`Snapshot`] and the seat
//! table to a [`Plan`]. No I/O, no clock reads, no GitHub — every input is a
//! value, so the properties below are checkable by proptest and a plan can
//! be replayed from the run record.

use crate::poll::{IssueView, PrView, Snapshot, CLAIM_LABEL};
use crate::types::{Fence, Role, SeatState};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatSlot {
    pub seat: u8,
    pub role: Role,
    pub state: SeatState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    WakeImpl {
        seat: u8,
        issue: u64,
    },
    WakeQa {
        seat: u8,
        pr: u64,
    },
    /// An open PR approved at its head by a reviewer who is not its author:
    /// finish it (ready-for-review + typed merge). Covers the case where the
    /// approval landed but the merge step failed in an earlier tick.
    FinishPr {
        pr: u64,
    },
    /// An open PR whose QA review asked for changes at its head: wake the impl
    /// seat that owns the branch on that same branch. No new claim, no new PR
    /// — the cap on rounds is the executor's (the plan is not a budget).
    Rework {
        seat: u8,
        pr: u64,
        issue: Option<u64>,
    },
    /// A claim whose seat is not working it (stalled, gone, or absent) and
    /// that no open PR closes: release it, fenced by the live claim SHA.
    ReleaseClaim {
        issue: u64,
        fence: Fence,
    },
    /// The snapshot was readable and there is nothing to do.
    Nothing,
}

impl Action {
    pub fn issue(&self) -> Option<u64> {
        match self {
            Action::WakeImpl { issue, .. } | Action::ReleaseClaim { issue, .. } => Some(*issue),
            Action::Rework { issue, .. } => *issue,
            _ => None,
        }
    }
    pub fn seat(&self) -> Option<u8> {
        match self {
            Action::WakeImpl { seat, .. }
            | Action::WakeQa { seat, .. }
            | Action::Rework { seat, .. } => Some(*seat),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Plan {
    pub actions: Vec<Action>,
}

impl Plan {
    /// True when the plan carries no work (empty, or only `Nothing`).
    pub fn is_empty(&self) -> bool {
        self.actions.iter().all(|a| *a == Action::Nothing)
    }
}

/// Seat ids of `role` that are assignable: every slot for that id is `Idle`.
/// A busy or dead slot anywhere disqualifies the id.
fn idle_seats(seats: &[SeatSlot], role: Role) -> std::vec::IntoIter<u8> {
    let not_idle: BTreeSet<u8> = seats
        .iter()
        .filter(|s| s.state != SeatState::Idle)
        .map(|s| s.seat)
        .collect();
    let ids: BTreeSet<u8> = seats
        .iter()
        .filter(|s| s.role == role && !not_idle.contains(&s.seat))
        .map(|s| s.seat)
        .collect();
    ids.into_iter().collect::<Vec<_>>().into_iter()
}

/// The issue/PR numbers some live seat is currently occupied with. A seat
/// Working past its deadline is treated as Stalled: its job is *not* live.
fn live_jobs(seats: &[SeatSlot], now: u64) -> (BTreeSet<u64>, BTreeSet<u64>) {
    let mut issues = BTreeSet::new();
    let mut prs = BTreeSet::new();
    for s in seats {
        let job = match &s.state {
            SeatState::Working { job, deadline } if *deadline >= now => job,
            SeatState::Reported { job } => job,
            _ => continue,
        };
        issues.extend(job.issue);
        prs.extend(job.pr);
    }
    (issues, prs)
}

fn issue_eligible(i: &IssueView, gate_label: &str, owner_only: bool) -> bool {
    i.state == "open"
        && !i.labels.iter().any(|l| l == gate_label || l == CLAIM_LABEL)
        && (!owner_only || i.author_association == "OWNER")
        && i.assignees.is_empty()
        && i.claim.is_none()
}

/// Approved at the current head by someone other than the PR's own App.
/// The author's login is not in the view; the QA App's login ends in
/// `-qa[bot]`, which is the only reviewer whose approval counts here.
fn pr_approved_at_head(p: &PrView) -> bool {
    p.state == "open"
        && p.reviews.iter().any(|(login, state, commit)| {
            state == "APPROVED" && *commit == p.head_sha && login.ends_with("-qa[bot]")
        })
}

/// Changes requested at the current head by the QA App: the PR's own impl
/// seat owes it another round. Read exactly like [`pr_approved_at_head`], and
/// an approval at the same head wins (the planner prefers finishing).
fn pr_changes_requested_at_head(p: &PrView) -> bool {
    p.state == "open"
        && !pr_approved_at_head(p)
        && p.reviews.iter().any(|(login, state, commit)| {
            state == "CHANGES_REQUESTED" && *commit == p.head_sha && login.ends_with("-qa[bot]")
        })
}

/// The impl seat a branch belongs to: `impl<n>/…` → `n`.
fn impl_seat_of(head_ref: &str) -> Option<u8> {
    head_ref
        .strip_prefix("impl")?
        .split('/')
        .next()?
        .parse::<u8>()
        .ok()
}

fn touched_prs_pre(actions: &[Action], pr: u64) -> bool {
    !actions
        .iter()
        .any(|a| matches!(a, Action::FinishPr { pr: p } if *p == pr))
}

fn pr_qa_eligible(p: &PrView) -> bool {
    // Drafts ARE QA work: seats open every PR as a draft, QA reviews it, and
    // the supervisor marks it ready only after an anchored approval.
    p.state == "open" && !p.reviews.iter().any(|(_, _, commit)| *commit == p.head_sha)
}

/// The whole scheduler. Rules:
/// - an issue is eligible when open, ungated, OWNER-authored (unless
///   `owner_only` is false), unassigned, unclaimed, not closed by an open PR
///   and not the live job of some seat;
/// - a PR is QA-eligible when open (drafts included), with no review anchored to
///   its head and not the live job of some seat;
/// - a PR with changes requested at its head is rework for the idle impl seat
///   its branch names (#576), so a refused PR never parks its seat;
/// - eligible items are served FIFO by number to idle seats of the matching
///   role, one job per seat, one action per item;
/// - an Unknown snapshot plans nothing (empty, not even `Nothing`).
pub fn plan(
    snapshot: &Snapshot,
    seats: &[SeatSlot],
    gate_label: &str,
    owner_only: bool,
    now: u64,
) -> Plan {
    if !snapshot.known {
        return Plan::default();
    }
    let (busy_issues, busy_prs) = live_jobs(seats, now);
    let closed_by_open_pr: BTreeSet<u64> = snapshot
        .prs
        .iter()
        .filter(|p| p.state == "open")
        .filter_map(|p| p.closes_issue)
        .collect();

    let mut actions = Vec::new();
    let mut touched_issues = BTreeSet::new();

    // Stale claims: a fenced claim nobody live is working and no PR closes.
    for i in &snapshot.issues {
        if let Some(fence) = &i.claim {
            if i.state == "open"
                && !busy_issues.contains(&i.number)
                && !closed_by_open_pr.contains(&i.number)
                && touched_issues.insert(i.number)
            {
                actions.push(Action::ReleaseClaim {
                    issue: i.number,
                    fence: fence.clone(),
                });
            }
        }
    }

    // One PR in flight per impl seat: a seat whose branch `impl<n>/…` is
    // still open (awaiting QA, changes, or merge) does not start the next
    // issue — the next issue would branch from a base that lacks its work.
    let seats_with_open_pr: BTreeSet<u8> = snapshot
        .prs
        .iter()
        .filter(|p| p.state == "open")
        .filter_map(|p| impl_seat_of(&p.head_ref))
        .collect();
    let idle_impl: BTreeSet<u8> = idle_seats(seats, Role::Impl).collect();
    let mut impl_seats = idle_impl
        .iter()
        .copied()
        .filter(|s| !seats_with_open_pr.contains(s));

    let mut issues: Vec<&IssueView> = snapshot
        .issues
        .iter()
        .filter(|i| issue_eligible(i, gate_label, owner_only))
        .filter(|i| !closed_by_open_pr.contains(&i.number))
        .filter(|i| !busy_issues.contains(&i.number))
        .collect();
    issues.sort_by_key(|i| i.number);
    for i in issues {
        if !touched_issues.insert(i.number) {
            continue;
        }
        let Some(seat) = impl_seats.next() else { break };
        actions.push(Action::WakeImpl {
            seat,
            issue: i.number,
        });
    }

    // A seat id listed under two roles is a config error; never double-book it.
    let mut used: BTreeSet<u8> = actions.iter().filter_map(Action::seat).collect();
    let mut touched_prs = BTreeSet::new();

    // Changes requested at head: the seat that owns `impl<n>/…` gets another
    // round on its own branch. A seat here is one the WakeImpl pass skipped
    // (it has an open PR), so the two never compete for the same pane.
    let mut refused: Vec<&PrView> = snapshot
        .prs
        .iter()
        .filter(|p| pr_changes_requested_at_head(p))
        .filter(|p| !busy_prs.contains(&p.number))
        .collect();
    refused.sort_by_key(|p| p.number);
    for p in refused {
        let Some(seat) = impl_seat_of(&p.head_ref) else {
            continue;
        };
        if !idle_impl.contains(&seat) || !used.insert(seat) {
            continue;
        }
        if p.closes_issue.is_some_and(|i| !touched_issues.insert(i))
            || !touched_prs.insert(p.number)
        {
            used.remove(&seat);
            continue;
        }
        actions.push(Action::Rework {
            seat,
            pr: p.number,
            issue: p.closes_issue,
        });
    }
    let mut qa_seats = idle_seats(seats, Role::Qa).filter(|s| !used.contains(s));

    for p in snapshot.prs.iter().filter(|p| pr_approved_at_head(p)) {
        if !busy_prs.contains(&p.number) && touched_prs_pre(&actions, p.number) {
            actions.push(Action::FinishPr { pr: p.number });
        }
    }

    let mut prs: Vec<&PrView> = snapshot
        .prs
        .iter()
        .filter(|p| pr_qa_eligible(p))
        .filter(|p| !busy_prs.contains(&p.number))
        .collect();
    prs.sort_by_key(|p| p.number);
    for p in prs {
        if !touched_prs.insert(p.number) {
            continue;
        }
        let Some(seat) = qa_seats.next() else { break };
        actions.push(Action::WakeQa { seat, pr: p.number });
    }

    if actions.is_empty() {
        actions.push(Action::Nothing);
    }
    Plan { actions }
}

#[cfg(test)]
mod tests;
