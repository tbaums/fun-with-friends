//! `fwf release --seat N --role impl|qa [--by NAME]` (#688): the operator's
//! version of the stall cool-off.
//!
//! A Stalled seat blocks its seat id for both roles until something writes a
//! later `Idle`, and until #688 nothing ever did. The loop now writes one
//! after [`STALL_COOLOFF_SECS`](crate::log::STALL_COOLOFF_SECS); this is the
//! same event, written now, for the stall an operator has already judged dead
//! — the pane is at a prompt, the branch is untouched, the model is gone.
//!
//! Shaped like `fwf ungate`: a `--by` name that defaults to `$USER`, an event
//! pair (the state change plus the `Human` line that says who), and a refusal
//! rather than a crash when the thing being asked for is not true. A seat that
//! is not Stalled is not this verb's to touch: releasing a WORKING seat would
//! hand its live job to somebody else mid-cycle.

use crate::log;
use crate::types::{Role, SeatState};
use crate::USAGE;
use std::process::ExitCode;

/// What an operator gets back, so the verb's decision is testable without a
/// process, a manifest or a terminal.
#[derive(Debug, PartialEq, Eq)]
pub enum Released {
    /// The seat was Stalled and is now Idle; the string is the job it dropped.
    Idle(String),
    /// It was not Stalled, so there is nothing to release.
    Refused(String),
}

/// Decide, from the record alone, whether this seat/role may be released.
pub fn decide(events: &[log::Event], seat: u8, role: Role) -> Released {
    match log::seat_states(events).get(&(seat, role)) {
        Some(SeatState::Stalled { job }) => Released::Idle(match (job.pr, job.issue) {
            (Some(pr), _) => format!("PR #{pr}"),
            (None, Some(issue)) => format!("#{issue}"),
            (None, None) => role.name().to_string(),
        }),
        // Everything else — Working, Gone, Unknown, a seat the record has
        // never seen, a seat already Idle — is somebody else's business. The
        // word names what the record actually says so the operator can tell an
        // already-cleared stall from a typo'd seat number.
        other => Released::Refused(match other {
            None => "the record has never seen it".to_string(),
            Some(s @ SeatState::Working { .. }) => format!(
                "it is {}; wait for its deadline",
                log::seat_name(s).to_uppercase()
            ),
            Some(s) => format!("it is {}", log::seat_name(s).to_uppercase()),
        }),
    }
}

/// The events a release appends: the `Idle` that frees the seat id for both
/// roles, and the `Human` line that says whose call it was.
pub fn events(repo: &str, seat: u8, role: Role, by: &str, ts: u64) -> [log::Event; 2] {
    [
        log::idle_event(repo, seat, role, ts),
        log::Event {
            ts,
            repo: repo.to_string(),
            kind: log::Kind::Human {
                actor: by.to_string(),
                action: "release".into(),
                target: format!("{}{seat}", role.name()),
            },
        },
    ]
}

pub fn verb(args: &[String]) -> ExitCode {
    let (Some(seat), Some(role)) = (
        super::get(args, "--seat").and_then(|s| s.parse::<u8>().ok()),
        super::get(args, "--role").as_deref().and_then(Role::parse),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let by = super::get(args, "--by")
        .unwrap_or_else(|| std::env::var("USER").unwrap_or_else(|_| "operator".into()));
    let (m, path, note) = crate::dash::args::sources(args);
    note.inspect(|n| eprintln!("{n}"));
    let evs = match log::read_all(&path) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("fwf release: cannot read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };
    let label = format!("{}{seat}", role.name());
    match decide(&evs, seat, role) {
        Released::Refused(why) => {
            eprintln!("fwf release: {label} is not STALLED — {why}");
            ExitCode::from(1)
        }
        Released::Idle(job) => {
            // The record's own repo first: this event joins that file, and
            // `--log` can name a floor the manifest in this directory knows
            // nothing about. The manifest answers only for an empty record.
            let repo = evs
                .first()
                .map(|e| e.repo.clone())
                .or_else(|| m.map(|m| m.repo.clone()))
                .unwrap_or_default();
            let mut l = match log::Log::open(&path) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("fwf release: cannot append to {}: {e}", path.display());
                    return ExitCode::from(1);
                }
            };
            for ev in events(&repo, seat, role, &by, crate::seat::now()) {
                if let Err(e) = l.append(&ev) {
                    eprintln!("fwf release: cannot append to {}: {e}", path.display());
                    return ExitCode::from(1);
                }
            }
            println!("{label} released by {by} — idle; its stalled job ({job}) is dropped and will be re-planned");
            ExitCode::SUCCESS
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::JobRef;

    fn seat_ev(seat: u8, role: Role, to: SeatState) -> log::Event {
        log::Event {
            ts: 100,
            repo: "tbaums/claude-concierge".into(),
            kind: log::Kind::Seat {
                seat,
                role,
                to,
                tokens_in: None,
                tokens_out: None,
            },
        }
    }

    fn qa_job(pr: u64) -> JobRef {
        JobRef {
            role: Role::Qa,
            issue: None,
            pr: Some(pr),
        }
    }

    /// AC3, the happy path: qa1 stalled on PR #13, an operator calls it dead.
    #[test]
    fn a_stalled_seat_is_released_and_the_record_says_who_did_it() {
        let evs = vec![seat_ev(1, Role::Qa, SeatState::Stalled { job: qa_job(13) })];
        assert_eq!(decide(&evs, 1, Role::Qa), Released::Idle("PR #13".into()));
        let pair = events("o/r", 1, Role::Qa, "tbaums", 900);
        assert!(matches!(
            &pair[0].kind,
            log::Kind::Seat {
                seat: 1,
                role: Role::Qa,
                to: SeatState::Idle,
                ..
            }
        ));
        assert!(matches!(
            &pair[1].kind,
            log::Kind::Human { actor, action, target }
                if actor == "tbaums" && action == "release" && target == "qa1"
        ));
        // and the record, replayed, now calls the seat assignable
        let after: Vec<log::Event> = evs.into_iter().chain(pair).collect();
        assert_eq!(
            log::seat_states(&after).get(&(1, Role::Qa)),
            Some(&SeatState::Idle)
        );
    }

    /// AC3's other half, and the edge cases: a seat that is not Stalled is
    /// refused — including one this release already cleared, and one the
    /// record has never heard of. No panic, no event, an exit code.
    #[test]
    fn anything_that_is_not_stalled_is_refused_and_says_what_the_record_says() {
        let working = SeatState::Working {
            job: qa_job(13),
            deadline: 9_000,
        };
        for (state, expect) in [
            (Some(working), "WORKING"),
            (Some(SeatState::Idle), "IDLE"),
            (Some(SeatState::Gone), "GONE"),
            // a finished cycle: already assignable, nothing owed
            (Some(SeatState::Reported { job: qa_job(13) }), "REPORTED"),
            (Some(SeatState::Unknown), "UNKNOWN"),
            (None, "never seen"),
        ] {
            let evs: Vec<log::Event> = state
                .map(|s| vec![seat_ev(1, Role::Qa, s)])
                .unwrap_or_default();
            let Released::Refused(why) = decide(&evs, 1, Role::Qa) else {
                panic!("{expect}: released something that was not stalled");
            };
            assert!(why.contains(expect), "{expect}: {why}");
        }
        // the same seat id in the other role is a different seat
        let evs = vec![seat_ev(1, Role::Qa, SeatState::Stalled { job: qa_job(13) })];
        assert!(matches!(decide(&evs, 1, Role::Impl), Released::Refused(_)));
        assert!(matches!(decide(&evs, 9, Role::Qa), Released::Refused(_)));
    }

    /// `--role` is required because seat ids repeat across roles, and an
    /// unparseable one is a usage error, not a guess.
    #[test]
    fn the_role_flag_is_the_two_words_the_usage_line_names() {
        assert_eq!(Role::parse("qa"), Some(Role::Qa));
        assert_eq!(Role::parse("impl"), Some(Role::Impl));
        assert_eq!(Role::parse("QA"), None);
        assert_eq!(Role::parse(""), None);
        assert_eq!(Role::Qa.name(), "qa");
    }
}
