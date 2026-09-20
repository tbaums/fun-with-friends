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

impl SeatSlot {
    /// The slot to plan this seat with, given the record's last word about it
    /// (`log::seat_states`) — which is the only place a seat's state is
    /// written down (#667).
    ///
    /// `None` is a seat the record has never seen, and `Reported` is a cycle
    /// that is over: both are Idle, because the verdict is in and the pane is
    /// free again, and nothing ever writes an `Idle` event to say so. Working,
    /// Stalled, Gone and Unknown are taken exactly as they stand — a job the
    /// supervisor never killed is still typed into that pane.
    pub fn from_record(seat: u8, role: Role, recorded: Option<&SeatState>) -> SeatSlot {
        let state = match recorded {
            None | Some(SeatState::Reported { .. }) => SeatState::Idle,
            Some(s) => s.clone(),
        };
        SeatSlot { seat, role, state }
    }
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

/// The issue/PR numbers some live seat is currently occupied with.
///
/// A Stalled seat's job counts (#667): the supervisor is the only thing that
/// ever kills a pane, so a seat past its deadline may well still be running
/// that job — transom #1383 finished minutes after its stall verdict — and its
/// issue is nobody else's to take meanwhile. A seat left Working past its
/// deadline with no Stalled event yet is an interrupted supervisor's leftover,
/// not a live seat: `log::reconcile_stale_working` says so at startup, and
/// until then the stale-claim release below is what answers for it.
fn live_jobs(seats: &[SeatSlot], now: u64) -> (BTreeSet<u64>, BTreeSet<u64>) {
    let mut issues = BTreeSet::new();
    let mut prs = BTreeSet::new();
    for s in seats {
        let job = match &s.state {
            SeatState::Working { job, deadline } if *deadline >= now => job,
            SeatState::Reported { job } | SeatState::Stalled { job } => job,
            _ => continue,
        };
        issues.extend(job.issue);
        prs.extend(job.pr);
    }
    (issues, prs)
}

/// The one per-issue opt-out (#630): a human applies it by hand to say "build
/// this without the review path". Never a default, never implied by a missing
/// label — the bypass has to be somebody's deliberate act, and the loop says
/// so in the record the first time it serves one.
pub const FAST_TRACK_LABEL: &str = "fast-track";

pub fn is_fast_track(i: &IssueView) -> bool {
    i.labels.iter().any(|l| l == FAST_TRACK_LABEL)
}

/// What the record says when the loop served a fast-tracked issue. Written by
/// `run`, read back by `run` so it is written once, not once per tick.
pub fn fast_track_note(issue: u64) -> String {
    format!("fast-track: #{issue} bypassed review")
}

/// Eligible for an impl seat. The review half is the point of #630: an issue
/// becomes claimable because the RECORD says a human signed it off (an
/// `IssueState::Ready` event, which `fwf ungate` and the delegated un-gate
/// both write), or because someone applied `fast-track` on purpose. Before
/// this, the absence of the gate label was enough — so a ticket filed without
/// it went straight to impl, unspecced and unreviewed, which is how transom
/// #1313 was built and rolled back.
///
/// The gate label is no longer consulted here: unreviewed issues are already
/// ineligible whether or not they carry it, and a sign-off is final in v1
/// (re-review after a re-gate is a follow-up).
fn issue_eligible(i: &IssueView, owner_only: bool, reviewed: &BTreeSet<u64>) -> bool {
    i.state == "open"
        && !i.labels.iter().any(|l| l == CLAIM_LABEL)
        && (!owner_only || i.author_association == "OWNER")
        && i.assignees.is_empty()
        && i.claim.is_none()
        && (is_fast_track(i) || reviewed.contains(&i.number))
}

/// The plan with no refusal history behind it — what every test written
/// before #656's tie-break means by "the plan".
#[cfg(test)]
pub fn plan_fifo(
    snapshot: &Snapshot,
    seats: &[SeatSlot],
    owner_only: bool,
    reviewed: &BTreeSet<u64>,
    now: u64,
) -> Plan {
    plan(
        snapshot,
        seats,
        owner_only,
        reviewed,
        &BTreeSet::new(),
        &BTreeSet::new(),
        now,
    )
}

/// Every issue in a snapshot, as a reviewed set. Tests written before #630
/// were about seats, claims and PR flow; this says "all of these were signed
/// off" so they keep testing what they were testing.
#[cfg(test)]
pub fn all_reviewed(s: &Snapshot) -> BTreeSet<u64> {
    s.issues.iter().map(|i| i.number).collect()
}

/// What the reviewers have said about this PR's current head, by the one rule
/// `merge_pr` enforces at the merge button (#690): latest review per login,
/// the author's own never counted, CHANGES_REQUESTED at head beating APPROVED.
///
/// The planner used to have its own reading of that — any QA APPROVED at the
/// head, whatever came after — and the two deadlocked the loop whenever they
/// disagreed (PR #689: approved, then refused at the same head; every tick one
/// merge attempt, one refusal, no rework, forever).
fn head_verdict(p: &PrView) -> crate::review::Verdict {
    crate::review::verdict(
        p.reviews
            .iter()
            .map(|(l, s, c)| (l.as_str(), s.as_str(), c.as_str())),
        &p.head_sha,
        &p.author,
    )
}

/// Approved at the current head by the QA App, whose login ends in `-qa[bot]`
/// — the only reviewer whose approval starts a merge.
///
/// A changes-requested at that same head takes it away again, whoever left it:
/// [`head_verdict`] never returns `Approved` while one stands, so the planner
/// cannot ask for a merge GitHub would refuse as "not approved" (transom PR
/// #1419, fwf PR #689). An approval by anyone else is not this loop's cue.
fn pr_approved_at_head(p: &PrView) -> bool {
    p.state == "open"
        && matches!(head_verdict(p), crate::review::Verdict::Approved { by } if by.ends_with("-qa[bot]"))
}

/// Changes requested at the current head by a reviewer the loop answers to:
/// the QA App, or one of `humans` — the repo owner and the manifest's
/// `reviewers` (#677). The PR's own impl seat owes it another round.
///
/// The mirror of [`pr_approved_at_head`] over the same verdict, so the two can
/// no longer both be false while a refusal stands at the head — which is how
/// the loop used to lose PRs. A refusal by a login outside {`-qa[bot]`} ∪
/// `humans` still plans nothing: not a merge either, since `merge_pr` honours
/// it, but nothing this loop knows how to answer.
fn pr_changes_requested_at_head(p: &PrView, humans: &BTreeSet<String>) -> bool {
    p.state == "open"
        && matches!(head_verdict(p), crate::review::Verdict::ChangesRequested { by }
            if by.ends_with("-qa[bot]") || humans.contains(&by))
}

/// Opened by this floor's impl App, whose login ends in `-impl[bot]` — the same
/// convention `pr_approved_at_head` reads QA's `-qa[bot]` by. A PR on an
/// `impl<n>/…` branch that the floor did not author (a 0.x leftover, a human's)
/// is not its seat's work in flight.
fn is_floor_pr(p: &PrView) -> bool {
    p.author.ends_with("-impl[bot]")
}

/// The impl seat a branch belongs to: `impl<n>/…` → `n`.
pub fn impl_seat_of(head_ref: &str) -> Option<u8> {
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
/// - a PR with changes requested at its head — by the QA App or by one of
///   `humans` (#677) — is rework for the idle impl seat its branch names
///   (#576), so a refused PR never parks its seat;
/// - eligible items are served FIFO by number to idle seats of the matching
///   role, one job per seat, one action per item — except that an issue that
///   just refused goes to the back of that queue (#656);
/// - an Unknown snapshot plans nothing (empty, not even `Nothing`).
pub fn plan(
    snapshot: &Snapshot,
    seats: &[SeatSlot],
    owner_only: bool,
    // Issues the run record says were signed off (#630).
    reviewed: &BTreeSet<u64>,
    // Issues that refused a cycle within the last poll interval (#656).
    refused: &BTreeSet<u64>,
    // Logins whose CHANGES_REQUESTED counts like QA's: the repo owner and the
    // manifest's `reviewers` (#677).
    humans: &BTreeSet<String>,
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
    // Only this floor's own PRs count (#579): the 0.x factory used the same
    // `impl<n>/` prefix, so a legacy draft would otherwise hold a 1.0 seat
    // forever. An unknown or foreign author is nobody's work in flight.
    let seats_with_open_pr: BTreeSet<u8> = snapshot
        .prs
        .iter()
        .filter(|p| p.state == "open" && is_floor_pr(p))
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
        .filter(|i| issue_eligible(i, owner_only, reviewed))
        .filter(|i| !closed_by_open_pr.contains(&i.number))
        .filter(|i| !busy_issues.contains(&i.number))
        .collect();
    // FIFO by number, except that an issue whose last cycle refused waits
    // behind every other eligible one (#656). Not a skip and not a cap: with
    // nothing else eligible it is still served this tick, and one bad ticket
    // can no longer hold the floor's only seat against all the good ones.
    issues.sort_by_key(|i| (refused.contains(&i.number), i.number));
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
        .filter(|p| pr_changes_requested_at_head(p, humans))
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
#[cfg(test)]
mod tests_reviewers;
#[cfg(test)]
mod tests_seat_state;
#[cfg(test)]
mod tests_verdict;
