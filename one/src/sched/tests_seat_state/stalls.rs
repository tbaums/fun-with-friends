//! #688 — the stall that froze a pair, end to end against the fake GitHub.
//!
//! Seen on the claude-concierge floor on 2026-09-19 (fwf 1.0.17): qa1 stalled
//! on PR #13 with "no verdict", and from then on every tick was `0 actions`
//! with an un-gated issue waiting and impl1 idle. Three rules met:
//! `live_jobs` counts a Stalled seat's job as live (#667), `idle_seats`
//! disqualifies a seat id while ANY slot on it is non-Idle, and nothing in the
//! system ever wrote the later `Idle` that would end either.
//!
//! The fix is one event. This is the proof that writing it — by the cool-off
//! or by `fwf release` — hands back both halves of the pair and the PR.

use super::*;
use crate::fake_github::FakeGitHub;
use crate::poll::Poller;
use crate::verbs::release::{self, Released};

const O: &str = "tbaums";
const R: &str = "claude-concierge";

fn qa_job(pr: u64) -> JobRef {
    JobRef {
        role: Role::Qa,
        issue: None,
        pr: Some(pr),
    }
}

/// The four slots of a `pairs = 2` floor, read back from a record.
fn slots(evs: &[Event]) -> Vec<SeatSlot> {
    let states = crate::log::seat_states(evs);
    [
        (1, Role::Impl),
        (2, Role::Impl),
        (1, Role::Qa),
        (2, Role::Qa),
    ]
    .into_iter()
    .map(|(n, role)| SeatSlot::from_record(n, role, states.get(&(n, role))))
    .collect()
}

/// AC5. The floor as it really stood: impl2's PR is open and awaiting QA, qa1
/// took it and stalled, and the next issue is signed off and waiting. Nothing
/// can move — and one `Idle` event moves all of it.
#[test]
fn a_stalled_qa_seat_freezes_its_pair_until_the_record_says_idle() {
    let fake = FakeGitHub::start();
    let ops = fake.token("fwf-ops[bot]", &[]);
    let implr = fake.token("fwf-impl[bot]", &[]);
    fake.seed_ref(O, R, "heads/staging", &FakeGitHub::sha("s"));
    fake.seed_ref(
        O,
        R,
        "heads/impl2/issue-12-thin-slice",
        &FakeGitHub::sha("h"),
    );
    let built = fake.seed_issue(O, R, "the one impl2 built", O, &[]);
    let waiting = fake.seed_issue(O, R, "the one nobody could start", O, &[]);
    let pr = ureq::post(&format!("{}/repos/{O}/{R}/pulls", fake.base_url()))
        .set("Authorization", &format!("Bearer {implr}"))
        .send_string(
            &serde_json::json!({
                "title": "the one impl2 built",
                "head": "impl2/issue-12-thin-slice",
                "base": "staging",
                "draft": true,
                "body": format!("Closes #{built}")
            })
            .to_string(),
        )
        .unwrap()
        .into_json::<serde_json::Value>()
        .unwrap()["number"]
        .as_u64()
        .unwrap();
    let poller = Poller::new(fake.base_url(), &ops, O, R);
    let snapshot = poller.poll(1).unwrap();
    let reviewed = BTreeSet::from([built, waiting]);
    let stalled_at = 1_000;
    let plan_now = |evs: &[Event], now: u64| {
        plan(
            &snapshot,
            &slots(evs),
            true,
            &reviewed,
            &BTreeSet::new(),
            &BTreeSet::new(),
            now,
        )
        .actions
    };

    // qa1 was woken on the PR and never answered; the tick that noticed wrote
    // Stalled, and that was the record's last word about seat 1.
    let mut evs = vec![ev(
        stalled_at,
        Kind::Seat {
            seat: 1,
            role: Role::Qa,
            to: SeatState::Stalled { job: qa_job(pr) },
            tokens_in: None,
            tokens_out: None,
        },
    )];
    // The symptom, exactly: 0 actions. impl1 is disqualified by qa1's stall on
    // the same seat id, impl2 by its own open PR, and the PR is qa1's live job.
    assert_eq!(plan_now(&evs, stalled_at + 60), vec![Action::Nothing]);
    assert!(idle_seats(&slots(&evs), Role::Impl).all(|s| s != 1));
    let (_, busy_prs) = live_jobs(&slots(&evs), stalled_at + 60);
    assert!(busy_prs.contains(&pr), "the stalled PR is still a live job");
    // and it is still the symptom one tick short of the cool-off
    assert!(
        crate::log::seats::cold_stalls(&evs, stalled_at + crate::log::STALL_COOLOFF_SECS - 1)
            .is_empty()
    );

    // AC1: the tick past the cool-off writes the Idle nobody else would.
    let dir = std::env::temp_dir().join(format!("fwfd-stall-cooloff-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let log_path = dir.join("run.jsonl");
    {
        let mut l = crate::log::Log::open(&log_path).unwrap();
        l.append(&evs[0]).unwrap();
    }
    let released_at = stalled_at + crate::log::STALL_COOLOFF_SECS;
    assert_eq!(
        crate::log::reconcile_cold_stalls(&log_path, &format!("{O}/{R}"), released_at).unwrap(),
        1
    );
    // …once. The next tick has nothing left to say.
    assert_eq!(
        crate::log::reconcile_cold_stalls(&log_path, &format!("{O}/{R}"), released_at + 300)
            .unwrap(),
        0
    );
    let after = crate::log::read_all(&log_path).unwrap();
    assert!(
        matches!(
            &after[1].kind,
            Kind::Seat {
                seat: 1,
                role: Role::Qa,
                to: SeatState::Idle,
                ..
            }
        ),
        "{:?}",
        after[1]
    );
    match &after[2].kind {
        Kind::Note { text } => {
            assert!(text.contains(&format!("PR #{pr}")), "{text}");
            assert!(text.contains("cool-off"), "{text}");
        }
        other => panic!("expected the explanatory note, got {other:?}"),
    }
    let _ = std::fs::remove_dir_all(&dir);

    // AC2: the seat id is assignable for BOTH roles again and the PR has
    // dropped out of `live_jobs` — so the waiting issue goes to impl1 and the
    // PR is QA-eligible again, on the very next tick. QA lands on qa2 because
    // one plan never double-books a seat id (impl1 has just taken it); the
    // cross-role rule itself is untouched here, only how long a stall may
    // hold a seat id hostage.
    let freed = plan_now(&after, released_at + 1);
    assert_eq!(
        freed,
        vec![
            Action::WakeImpl {
                seat: 1,
                issue: waiting
            },
            Action::WakeQa { seat: 2, pr },
        ],
        "the pair is working again"
    );
    let (_, busy) = live_jobs(&slots(&after), released_at + 1);
    assert!(!busy.contains(&pr));

    // AC3/AC5's other half: `fwf release` writes the same event, now, with a
    // name on it — and the plan it produces is identical.
    assert_eq!(
        release::decide(&evs, 1, Role::Qa),
        Released::Idle(format!("PR #{pr}"))
    );
    evs.extend(release::events(
        &format!("{O}/{R}"),
        1,
        Role::Qa,
        "tbaums",
        stalled_at + 120,
    ));
    assert_eq!(plan_now(&evs, stalled_at + 121), freed);
    // and once released, there is nothing left for the operator to release
    assert!(matches!(
        release::decide(&evs, 1, Role::Qa),
        Released::Refused(_)
    ));
}

/// An impl stall is bounded the same way (#688 covers both roles), and the
/// clock is the stall's own: a seat marked Stalled long after its deadline
/// gets the full cool-off from the moment it was marked, not from the deadline.
#[test]
fn an_impl_stall_is_released_on_its_own_clock_and_frees_its_claim() {
    let stalled_at = 5_000;
    let evs = vec![
        ev(
            100,
            Kind::Issue {
                issue: 688,
                to: IssueState::Claimed {
                    seat: 2,
                    fence: Fence("f".repeat(40)),
                },
            },
        ),
        seat_ev(
            2,
            Role::Impl,
            SeatState::Working {
                job: job(Some(688), None),
                deadline: 200,
            },
        ),
        ev(
            stalled_at,
            Kind::Seat {
                seat: 2,
                role: Role::Impl,
                to: SeatState::Stalled {
                    job: job(Some(688), None),
                },
                tokens_in: None,
                tokens_out: None,
            },
        ),
    ];
    // measured from the stall, not from the deadline it blew through
    assert!(crate::log::seats::cold_stalls(&evs, 200 + crate::log::STALL_COOLOFF_SECS).is_empty());
    assert_eq!(
        crate::log::seats::cold_stalls(&evs, stalled_at + crate::log::STALL_COOLOFF_SECS)
            .into_iter()
            .map(|(s, r, _)| (s, r))
            .collect::<Vec<_>>(),
        vec![(2, Role::Impl)]
    );
    // #669's late adoption still has the whole cool-off to run in: until the
    // release lands the claim is the seat's and the adoption path still sees it
    assert_eq!(
        crate::log::stalled_claims(&evs).get(&688).map(|(s, _)| *s),
        Some(2)
    );

    // released: the issue is nobody's live job, so the planner can answer for
    // the claim the record still holds — a fenced release, then a fresh start.
    let mut after = evs.clone();
    after.extend(release::events("o/r", 2, Role::Impl, "tbaums", 5_100));
    let mut snapshot = snap(vec![issue(688, &[], "OWNER")], vec![]);
    snapshot.issues[0].claim = Some(Fence("f".repeat(40)));
    let seats = [
        seat(1, Role::Impl, SeatState::Idle),
        SeatSlot::from_record(
            2,
            Role::Impl,
            crate::log::seat_states(&after).get(&(2, Role::Impl)),
        ),
    ];
    let actions = plan(
        &snapshot,
        &seats,
        true,
        &all_reviewed(&snapshot),
        &BTreeSet::new(),
        &BTreeSet::new(),
        5_200,
    )
    .actions;
    assert_eq!(
        actions,
        vec![Action::ReleaseClaim {
            issue: 688,
            fence: Fence("f".repeat(40))
        }],
        "the stale claim is answerable again: {actions:?}"
    );
}
