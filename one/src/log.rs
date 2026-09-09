//! The one append-only run record.
//!
//! Every seat cycle, claim, review, gate verdict, promotion and human action
//! is one JSON line here. The dash reads this file; `fwf why <pr>` is a query
//! over it; nothing else in the system is a source of truth for "what
//! happened". Appends are single-writer (the supervisor) and fsync'd.

use crate::types::{GateState, IssueState, PrState, Role, SeatState};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Kind {
    Issue {
        issue: u64,
        to: IssueState,
    },
    Pr {
        pr: u64,
        issue: Option<u64>,
        to: PrState,
    },
    Seat {
        seat: u8,
        role: Role,
        to: SeatState,
        tokens_in: Option<u64>,
        tokens_out: Option<u64>,
    },
    Gate {
        to: GateState,
    },
    Promote {
        branch: String,
        from: String,
        to: String,
    },
    Human {
        actor: String,
        action: String,
        target: String,
    },
    Refused {
        what: String,
        why: String,
    },
    Note {
        text: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    /// Unix seconds. Monotonic per file; ties allowed.
    pub ts: u64,
    pub repo: String,
    #[serde(flatten)]
    pub kind: Kind,
}

pub struct Log {
    file: File,
}

impl Log {
    pub fn open(path: &Path) -> std::io::Result<Log> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Log { file })
    }

    /// Append one event and fsync. One line, one event, never partial.
    pub fn append(&mut self, ev: &Event) -> std::io::Result<()> {
        let mut line = serde_json::to_string(ev).map_err(std::io::Error::other)?;
        line.push('\n');
        self.file.write_all(line.as_bytes())?;
        self.file.sync_data()
    }
}

/// Read every event; a malformed line is returned as an error rather than
/// skipped (a truncated record is a fact worth knowing, not noise).
pub fn read_all(path: &Path) -> std::io::Result<Vec<Event>> {
    let f = File::open(path)?;
    let mut out = Vec::new();
    for (i, line) in BufReader::new(f).lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let ev: Event = serde_json::from_str(&line)
            .map_err(|e| std::io::Error::other(format!("line {}: {e}", i + 1)))?;
        out.push(ev);
    }
    Ok(out)
}

/// The timeline of one PR: every event that names it, or names the issue it
/// closes, or is a gate/promote event for its merge sha.
pub fn why(events: &[Event], pr: u64) -> Vec<&Event> {
    let issue = events.iter().find_map(|e| match &e.kind {
        Kind::Pr { pr: p, issue, .. } if *p == pr => *issue,
        _ => None,
    });
    let merge_sha = events.iter().find_map(|e| match &e.kind {
        Kind::Pr {
            pr: p,
            to: PrState::Merged { sha },
            ..
        } if *p == pr => Some(sha.clone()),
        _ => None,
    });
    events
        .iter()
        .filter(|e| match &e.kind {
            Kind::Pr { pr: p, .. } => *p == pr,
            Kind::Issue { issue: i, .. } => Some(*i) == issue,
            Kind::Seat {
                to: SeatState::Working { job, .. },
                ..
            }
            | Kind::Seat {
                to: SeatState::Reported { job },
                ..
            }
            | Kind::Seat {
                to: SeatState::Stalled { job },
                ..
            } => job.pr == Some(pr) || (job.issue.is_some() && job.issue == issue),
            Kind::Seat {
                to: SeatState::Idle,
                ..
            }
            | Kind::Seat {
                to: SeatState::Gone,
                ..
            }
            | Kind::Seat {
                to: SeatState::Unknown,
                ..
            } => false,
            Kind::Gate { to } => match (to, &merge_sha) {
                (GateState::Green { sha, .. }, Some(m))
                | (GateState::Red { sha, .. }, Some(m))
                | (GateState::Killed { sha, .. }, Some(m))
                | (GateState::Running { sha, .. }, Some(m))
                | (GateState::Queued { sha, .. }, Some(m)) => sha == m,
                _ => false,
            },
            Kind::Promote { to, .. } => merge_sha
                .as_ref()
                .map(|m| m.as_str() == to)
                .unwrap_or(false),
            Kind::Refused { what, .. } => what.contains(&format!("#{pr}")),
            Kind::Human { target, .. } => {
                target == &format!("#{pr}")
                    || issue.map(|i| target == &format!("#{i}")).unwrap_or(false)
            }
            Kind::Note { .. } => false,
        })
        .collect()
}

/// Render a timeline as one line per event, for humans.
pub fn render(events: &[&Event]) -> String {
    let mut s = String::new();
    let t0 = events.first().map(|e| e.ts).unwrap_or(0);
    for e in events {
        let dt = e.ts.saturating_sub(t0);
        let what = match &e.kind {
            Kind::Issue { issue, to } => format!("issue #{issue} → {}", state_name(to)),
            Kind::Pr { pr, to, .. } => format!("pr #{pr} → {}", pr_name(to)),
            Kind::Seat {
                seat,
                role,
                to,
                tokens_in,
                tokens_out,
            } => format!(
                "seat {seat} ({role:?}) → {}{}",
                seat_name(to),
                match (tokens_in, tokens_out) {
                    (Some(i), Some(o)) => format!(" [{i} in / {o} out]"),
                    _ => String::new(),
                }
            ),
            Kind::Gate { to } => format!("gate → {}", gate_name(to)),
            Kind::Promote { branch, from, to } => format!(
                "promote {branch} {}..{}",
                &from[..8.min(from.len())],
                &to[..8.min(to.len())]
            ),
            Kind::Human {
                actor,
                action,
                target,
            } => format!("human {actor}: {action} {target}"),
            Kind::Refused { what, why } => format!("REFUSED {what}: {why}"),
            Kind::Note { text } => format!("note: {text}"),
        };
        s.push_str(&format!("+{:>6}s  {what}\n", dt));
    }
    s
}

fn state_name(s: &IssueState) -> &'static str {
    match s {
        IssueState::Gated => "gated",
        IssueState::Ready => "ready",
        IssueState::Claimed { .. } => "claimed",
        IssueState::Shipped { .. } => "shipped",
        IssueState::Closed => "closed",
        IssueState::Unknown => "UNKNOWN",
    }
}
fn pr_name(s: &PrState) -> &'static str {
    match s {
        PrState::Draft { .. } => "draft",
        PrState::Open { .. } => "open",
        PrState::Approved { .. } => "approved",
        PrState::ChangesRequested { .. } => "changes-requested",
        PrState::Stale { .. } => "stale-approval",
        PrState::Merged { .. } => "merged",
        PrState::ClosedUnmerged => "closed-unmerged",
        PrState::Unknown => "UNKNOWN",
    }
}
fn seat_name(s: &SeatState) -> &'static str {
    match s {
        SeatState::Idle => "idle",
        SeatState::Working { .. } => "working",
        SeatState::Reported { .. } => "reported",
        SeatState::Stalled { .. } => "STALLED",
        SeatState::Gone => "gone",
        SeatState::Unknown => "UNKNOWN",
    }
}
fn gate_name(s: &GateState) -> &'static str {
    match s {
        GateState::Queued { .. } => "queued",
        GateState::Running { .. } => "running",
        GateState::Green { .. } => "green",
        GateState::Red { .. } => "red",
        GateState::Killed { .. } => "KILLED",
        GateState::Unknown => "UNKNOWN",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Fence, JobRef, Sha};

    fn sha(c: char) -> Sha {
        Sha::parse(&std::iter::repeat(c).take(40).collect::<String>()).unwrap()
    }

    fn fixture(dir: &Path) -> std::path::PathBuf {
        let p = dir.join("run.jsonl");
        let mut log = Log::open(&p).unwrap();
        let r = "x/y".to_string();
        let evs = vec![
            Event {
                ts: 100,
                repo: r.clone(),
                kind: Kind::Human {
                    actor: "jamie".into(),
                    action: "ungate".into(),
                    target: "#41".into(),
                },
            },
            Event {
                ts: 101,
                repo: r.clone(),
                kind: Kind::Issue {
                    issue: 41,
                    to: IssueState::Ready,
                },
            },
            Event {
                ts: 102,
                repo: r.clone(),
                kind: Kind::Issue {
                    issue: 41,
                    to: IssueState::Claimed {
                        seat: 1,
                        fence: Fence("e1".into()),
                    },
                },
            },
            Event {
                ts: 103,
                repo: r.clone(),
                kind: Kind::Seat {
                    seat: 1,
                    role: Role::Impl,
                    to: SeatState::Working {
                        job: JobRef {
                            role: Role::Impl,
                            issue: Some(41),
                            pr: None,
                        },
                        deadline: 9999,
                    },
                    tokens_in: None,
                    tokens_out: None,
                },
            },
            Event {
                ts: 900,
                repo: r.clone(),
                kind: Kind::Pr {
                    pr: 7,
                    issue: Some(41),
                    to: PrState::Open { head: sha('a') },
                },
            },
            Event {
                ts: 950,
                repo: r.clone(),
                kind: Kind::Pr {
                    pr: 8,
                    issue: Some(42),
                    to: PrState::Open { head: sha('e') },
                },
            },
            Event {
                ts: 1000,
                repo: r.clone(),
                kind: Kind::Pr {
                    pr: 7,
                    issue: Some(41),
                    to: PrState::Approved {
                        head: sha('a'),
                        reviewer: Role::Qa,
                    },
                },
            },
            Event {
                ts: 1100,
                repo: r.clone(),
                kind: Kind::Pr {
                    pr: 7,
                    issue: Some(41),
                    to: PrState::Merged { sha: sha('b') },
                },
            },
            Event {
                ts: 1200,
                repo: r.clone(),
                kind: Kind::Gate {
                    to: GateState::Green {
                        sha: sha('b'),
                        suite: "e2e".into(),
                        secs: 300,
                    },
                },
            },
            Event {
                ts: 1300,
                repo: r.clone(),
                kind: Kind::Promote {
                    branch: "main".into(),
                    from: sha('0').to_string(),
                    to: sha('b').to_string(),
                },
            },
            Event {
                ts: 1301,
                repo: r,
                kind: Kind::Note {
                    text: "unrelated".into(),
                },
            },
        ];
        for e in &evs {
            log.append(e).unwrap();
        }
        p
    }

    #[test]
    fn append_then_read_round_trips_every_event() {
        let dir = std::env::temp_dir().join(format!("fwfd-log-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = fixture(&dir);
        let evs = read_all(&p).unwrap();
        assert_eq!(evs.len(), 11);
        assert!(matches!(
            evs[2].kind,
            Kind::Issue {
                issue: 41,
                to: IssueState::Claimed { seat: 1, .. }
            }
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn why_selects_the_prs_timeline_and_nothing_else() {
        let dir = std::env::temp_dir().join(format!("fwfd-why-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = fixture(&dir);
        let evs = read_all(&p).unwrap();
        let tl = why(&evs, 7);
        // human ungate, issue ready, claimed, seat working, pr open/approved/merged, gate green, promote = 9
        assert_eq!(tl.len(), 9, "{}", render(&tl));
        assert!(tl.iter().all(|e| !matches!(e.kind, Kind::Pr { pr: 8, .. })));
        assert!(tl.iter().all(|e| !matches!(e.kind, Kind::Note { .. })));
        let text = render(&tl);
        assert!(text.contains("pr #7 → merged"));
        assert!(text.contains("gate → green"));
        assert!(text.contains("promote main"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn malformed_line_is_an_error_not_silence() {
        let dir = std::env::temp_dir().join(format!("fwfd-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("run.jsonl");
        std::fs::write(
            &p,
            "{\"ts\":1,\"repo\":\"x/y\",\"kind\":\"note\",\"text\":\"ok\"}\n{not json\n",
        )
        .unwrap();
        let err = read_all(&p).unwrap_err();
        assert!(err.to_string().contains("line 2"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
