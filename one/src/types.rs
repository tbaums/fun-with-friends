//! The four state machines of fwf 1.0, as data.
//!
//! Every fact the old harness inferred from prose markers, tick files or
//! ambient environment is one of these enums, and every transition is a
//! function that either returns the next state or a typed refusal. `Unknown`
//! is a first-class value everywhere (issue #211: a read that cannot complete
//! must never collapse into a confident value).

use serde::{Deserialize, Serialize};
use std::fmt;

/// A git object id, always the full 40 hex characters (`gh api -f sha=` refuses
/// short forms; so does every promote path here).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Sha(String);

impl Sha {
    pub fn parse(s: &str) -> Result<Sha, Refusal> {
        let ok = s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit());
        if ok {
            Ok(Sha(s.to_ascii_lowercase()))
        } else {
            Err(Refusal::MalformedSha(s.to_string()))
        }
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn short(&self) -> &str {
        &self.0[..8]
    }
}

impl fmt::Display for Sha {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Seat roles. PM/GV/captain are cheap verdict roles; impl/qa do the work;
/// the conductor is code in 1.0 and is deliberately not a seat role.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Pm,
    Gv,
    Captain,
    Impl,
    Qa,
}

/// A fencing token for a claim: the id of the GitHub event (or the SHA of
/// the `claim/<n>` ref) that recorded the claim. A merge whose fence does not
/// match the live claim is refused.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Fence(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum IssueState {
    /// Filed; carries the gate label or is not owner-authored. Not eligible.
    Gated,
    /// A human un-gated it (label event by the ops App with a human actor).
    Ready,
    /// One seat holds it, with a fence.
    Claimed { seat: u8, fence: Fence },
    /// A PR that closes it was merged to `staging`.
    Shipped { pr: u64, sha: Sha },
    /// Closed without code (not_planned, duplicate).
    Closed,
    /// The tracker could not be read; hold.
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum PrState {
    Draft {
        head: Sha,
    },
    /// Ready for review, no review anchored to the current head.
    Open {
        head: Sha,
    },
    /// A review by the QA App whose `commit_id` equals the head.
    Approved {
        head: Sha,
        reviewer: Role,
    },
    /// A review requesting changes anchored to the current head.
    ChangesRequested {
        head: Sha,
    },
    /// Approval existed but the head moved; GitHub dismisses, we mirror it.
    Stale {
        head: Sha,
        approved_head: Sha,
    },
    Merged {
        sha: Sha,
    },
    ClosedUnmerged,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum SeatState {
    /// Pane is up and warm, nothing typed in. Costs zero requests.
    Idle,
    /// A job was typed in; a verdict is awaited before `deadline` (unix secs).
    Working {
        job: JobRef,
        deadline: u64,
    },
    /// The verdict arrived and parsed.
    Reported {
        job: JobRef,
    },
    /// The deadline passed with no verdict. The supervisor is the only killer.
    Stalled {
        job: JobRef,
    },
    /// The pane is gone (exited, killed, or never came up).
    Gone,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobRef {
    pub role: Role,
    pub issue: Option<u64>,
    pub pr: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum GateState {
    Queued {
        sha: Sha,
        suite: String,
    },
    Running {
        sha: Sha,
        suite: String,
        started: u64,
    },
    Green {
        sha: Sha,
        suite: String,
        secs: u64,
    },
    Red {
        sha: Sha,
        suite: String,
        failed: u32,
    },
    /// The venue killed it (OOM, timeout). Not red, not green. Re-run once.
    Killed {
        sha: Sha,
        suite: String,
        reason: String,
    },
    Unknown,
}

/// Why a transition was refused. Refusals are values, not log lines.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "refusal", rename_all = "snake_case")]
pub enum Refusal {
    MalformedSha(String),
    NotReady(String),
    FenceMismatch { expected: Fence, got: Fence },
    NotApproved { head: Sha },
    ApprovalStale { head: Sha, approved_head: Sha },
    GateNotGreen { sha: Sha },
    UnknownState(&'static str),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::MalformedSha(s) => write!(f, "malformed sha: {s:?} (need 40 hex chars)"),
            Refusal::NotReady(why) => write!(f, "issue is not Ready: {why}"),
            Refusal::FenceMismatch { expected, got } => {
                write!(
                    f,
                    "fence mismatch: live claim {} but caller holds {}",
                    expected.0, got.0
                )
            }
            Refusal::NotApproved { head } => {
                write!(f, "no approval anchored to head {}", head.short())
            }
            Refusal::ApprovalStale {
                head,
                approved_head,
            } => write!(
                f,
                "approval is for {} but head is {}",
                approved_head.short(),
                head.short()
            ),
            Refusal::GateNotGreen { sha } => {
                write!(f, "no green gate recorded for {}", sha.short())
            }
            Refusal::UnknownState(what) => write!(f, "{what} is Unknown; holding (never guess)"),
        }
    }
}

// ---- transitions ----------------------------------------------------------

impl IssueState {
    /// A human un-gate. Only a Gated issue becomes Ready; anything else is a
    /// no-op refusal so a stray label event cannot re-open a shipped issue.
    pub fn ungate(&self) -> Result<IssueState, Refusal> {
        match self {
            IssueState::Gated => Ok(IssueState::Ready),
            IssueState::Unknown => Err(Refusal::UnknownState("issue")),
            other => Err(Refusal::NotReady(format!("cannot un-gate from {other:?}"))),
        }
    }

    /// A seat claims a Ready issue. The fence is whatever recorded the claim.
    pub fn claim(&self, seat: u8, fence: Fence) -> Result<IssueState, Refusal> {
        match self {
            IssueState::Ready => Ok(IssueState::Claimed { seat, fence }),
            IssueState::Unknown => Err(Refusal::UnknownState("issue")),
            other => Err(Refusal::NotReady(format!("cannot claim from {other:?}"))),
        }
    }

    /// The seat exited without a PR (or its deadline passed): release.
    pub fn release(&self, fence: &Fence) -> Result<IssueState, Refusal> {
        match self {
            IssueState::Claimed { fence: live, .. } if live == fence => Ok(IssueState::Ready),
            IssueState::Claimed { fence: live, .. } => Err(Refusal::FenceMismatch {
                expected: live.clone(),
                got: fence.clone(),
            }),
            IssueState::Unknown => Err(Refusal::UnknownState("issue")),
            other => Err(Refusal::NotReady(format!("cannot release from {other:?}"))),
        }
    }

    /// A PR closing this issue merged. Requires the caller's fence to match.
    pub fn ship(&self, fence: &Fence, pr: u64, sha: Sha) -> Result<IssueState, Refusal> {
        match self {
            IssueState::Claimed { fence: live, .. } if live == fence => {
                Ok(IssueState::Shipped { pr, sha })
            }
            IssueState::Claimed { fence: live, .. } => Err(Refusal::FenceMismatch {
                expected: live.clone(),
                got: fence.clone(),
            }),
            IssueState::Unknown => Err(Refusal::UnknownState("issue")),
            other => Err(Refusal::NotReady(format!("cannot ship from {other:?}"))),
        }
    }
}

impl PrState {
    /// The head moved. Any approval becomes Stale; drafts stay drafts.
    pub fn head_moved(&self, new_head: Sha) -> PrState {
        match self {
            PrState::Draft { .. } => PrState::Draft { head: new_head },
            PrState::Approved { head, .. } => PrState::Stale {
                head: new_head,
                approved_head: head.clone(),
            },
            PrState::Open { .. } | PrState::ChangesRequested { .. } | PrState::Stale { .. } => {
                PrState::Open { head: new_head }
            }
            PrState::Merged { .. } | PrState::ClosedUnmerged => self.clone(),
            PrState::Unknown => PrState::Unknown,
        }
    }

    /// A review by `reviewer` anchored to `commit_id`. Only a review whose
    /// commit_id equals the current head counts; anything else is ignored
    /// (this is the "approval survives a force-push" cluster, closed).
    pub fn reviewed(&self, commit_id: &Sha, approve: bool, reviewer: Role) -> PrState {
        match self {
            PrState::Open { head }
            | PrState::Stale { head, .. }
            | PrState::ChangesRequested { head }
                if head == commit_id =>
            {
                if approve {
                    PrState::Approved {
                        head: head.clone(),
                        reviewer,
                    }
                } else {
                    PrState::ChangesRequested { head: head.clone() }
                }
            }
            _ => self.clone(),
        }
    }

    /// The merge precondition, as a value: approved at exactly this head.
    pub fn mergeable(&self) -> Result<Sha, Refusal> {
        match self {
            PrState::Approved { head, .. } => Ok(head.clone()),
            PrState::Stale {
                head,
                approved_head,
            } => Err(Refusal::ApprovalStale {
                head: head.clone(),
                approved_head: approved_head.clone(),
            }),
            PrState::Open { head }
            | PrState::Draft { head }
            | PrState::ChangesRequested { head } => {
                Err(Refusal::NotApproved { head: head.clone() })
            }
            PrState::Unknown => Err(Refusal::UnknownState("pr")),
            PrState::Merged { sha } => Err(Refusal::NotReady(format!(
                "already merged as {}",
                sha.short()
            ))),
            PrState::ClosedUnmerged => Err(Refusal::NotReady("closed unmerged".into())),
        }
    }
}

impl GateState {
    /// Promotion precondition: a Green verdict for exactly this sha and suite.
    pub fn promotable(&self, sha: &Sha, suite: &str) -> Result<(), Refusal> {
        match self {
            GateState::Green {
                sha: s, suite: u, ..
            } if s == sha && u == suite => Ok(()),
            GateState::Unknown => Err(Refusal::UnknownState("gate")),
            _ => Err(Refusal::GateNotGreen { sha: sha.clone() }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sha(c: char) -> Sha {
        Sha::parse(&std::iter::repeat(c).take(40).collect::<String>()).unwrap()
    }

    #[test]
    fn sha_parse_refuses_short_and_non_hex() {
        assert!(matches!(
            Sha::parse("abc123"),
            Err(Refusal::MalformedSha(_))
        ));
        assert!(Sha::parse(&"g".repeat(40)).is_err());
        assert_eq!(sha('A').as_str(), &"a".repeat(40));
    }

    #[test]
    fn issue_happy_path_and_fence() {
        let f = Fence("evt-1".into());
        let ready = IssueState::Gated.ungate().unwrap();
        let claimed = ready.claim(1, f.clone()).unwrap();
        let wrong = Fence("evt-2".into());
        assert!(matches!(
            claimed.ship(&wrong, 7, sha('b')),
            Err(Refusal::FenceMismatch { .. })
        ));
        assert!(matches!(
            claimed.ship(&f, 7, sha('b')),
            Ok(IssueState::Shipped { pr: 7, .. })
        ));
        assert!(matches!(claimed.release(&f), Ok(IssueState::Ready)));
    }

    #[test]
    fn unknown_never_collapses() {
        assert!(matches!(
            IssueState::Unknown.ungate(),
            Err(Refusal::UnknownState("issue"))
        ));
        assert!(matches!(
            IssueState::Unknown.claim(1, Fence("x".into())),
            Err(Refusal::UnknownState(_))
        ));
        assert!(matches!(
            PrState::Unknown.mergeable(),
            Err(Refusal::UnknownState("pr"))
        ));
        assert!(matches!(
            GateState::Unknown.promotable(&sha('a'), "fast"),
            Err(Refusal::UnknownState("gate"))
        ));
    }

    #[test]
    fn approval_is_anchored_to_head() {
        let h1 = sha('1');
        let h2 = sha('2');
        let open = PrState::Open { head: h1.clone() };
        // a review for a different commit is ignored
        assert_eq!(open.reviewed(&h2, true, Role::Qa), open);
        let approved = open.reviewed(&h1, true, Role::Qa);
        assert_eq!(approved.mergeable().unwrap(), h1);
        // head moves: approval goes stale, merge refused
        let moved = approved.head_moved(h2.clone());
        assert!(matches!(moved, PrState::Stale { .. }));
        assert!(matches!(
            moved.mergeable(),
            Err(Refusal::ApprovalStale { .. })
        ));
        // re-review at the new head restores mergeability
        assert_eq!(moved.reviewed(&h2, true, Role::Qa).mergeable().unwrap(), h2);
    }

    #[test]
    fn gate_green_must_match_sha_and_suite() {
        let g = GateState::Green {
            sha: sha('c'),
            suite: "e2e".into(),
            secs: 100,
        };
        assert!(g.promotable(&sha('c'), "e2e").is_ok());
        assert!(g.promotable(&sha('c'), "fast").is_err());
        assert!(g.promotable(&sha('d'), "e2e").is_err());
        let k = GateState::Killed {
            sha: sha('c'),
            suite: "e2e".into(),
            reason: "oom".into(),
        };
        assert!(matches!(
            k.promotable(&sha('c'), "e2e"),
            Err(Refusal::GateNotGreen { .. })
        ));
    }

    #[test]
    fn states_round_trip_json() {
        let s = IssueState::Claimed {
            seat: 2,
            fence: Fence("evt-9".into()),
        };
        let j = serde_json::to_string(&s).unwrap();
        assert!(j.contains("\"state\":\"claimed\""));
        assert_eq!(serde_json::from_str::<IssueState>(&j).unwrap(), s);
    }
}
