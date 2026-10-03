//! Bounded re-spec after a sign-off refusal (#697): GV's no sends the spec
//! back to PM with the reason, twice, and then parks the issue for a human.
//! Split from `tests.rs` to keep it under the 1,000-line rule (T-30).

use super::tests::{note, one_gated, queues, skip_labels};
use super::*;
use crate::log::{Event, Kind};
use crate::types::IssueState;

/// #697, transom #1460: a refused sign-off left the issue gated forever —
/// already specced, already signed off, judged ready, so no queue held it. A
/// refusal now buys PM a revision on GV's reason, twice; the third refusal
/// parks it for a human, and nothing wakes on it again.
#[test]
fn a_refused_sign_off_re_specs_twice_then_parks() {
    let snap = one_gated(653);
    let skip = skip_labels();
    let f = ReviewFilter::all_gated("product-wip", &skip);
    let gated_again = |ts| Event {
        ts,
        repo: "o/r".into(),
        kind: Kind::Issue {
            issue: 653,
            to: IssueState::Gated,
        },
    };
    let mut evs = vec![
        note(crate::triage::ready_note(653)),
        note(crate::spec::spec_note(653, 900, false, 1)),
    ];
    assert_eq!(queues(&snap, &f, &evs), (vec![], vec![], vec![653]));
    for round in 1..=MAX_RESPEC_ROUNDS {
        // what `triage::run` records for a not-ready verdict, then the refusal
        evs.push(gated_again(4));
        evs.push(note(signoff_refusal_note(
            653,
            round,
            &format!("why {round}"),
        )));
        // AC1/AC3: PM is re-woken, with this refusal's own reason
        assert_eq!(
            queues(&snap, &f, &evs),
            (vec![], vec![653], vec![]),
            "round {round}"
        );
        assert_eq!(
            respec_candidates(&snap, &f, &spec_rounds(&evs)),
            vec![(653, round, Some(format!("why {round}")))]
        );
        assert!(
            reviewed_issues(&evs).is_empty(),
            "a refused spec is never un-gated"
        );
        // AC2: the revision goes back to GV, not a stale queue entry
        evs.push(note(crate::spec::spec_note(653, 950, false, 0)));
        assert_eq!(
            queues(&snap, &f, &evs),
            (vec![], vec![], vec![653]),
            "round {round}"
        );
    }
    // AC4: the third refusal owes a park, and no wake
    evs.push(gated_again(5));
    evs.push(note(signoff_refusal_note(653, 3, "still wrong")));
    assert_eq!(queues(&snap, &f, &evs), (vec![], vec![], vec![]));
    assert_eq!(park_candidates(&snap, &f, &spec_rounds(&evs)), vec![653]);
    evs.push(note(parked_note(653)));
    assert!(park_candidates(&snap, &f, &spec_rounds(&evs)).is_empty());
    assert_eq!(queues(&snap, &f, &evs), (vec![], vec![], vec![]));
}

/// AC5: an approval at any round ends the cycle; AC7: everything above is a
/// replay of the record, so a restart lands on the same round.
#[test]
fn an_approval_at_any_round_ends_the_cycle() {
    let snap = one_gated(653);
    let skip = skip_labels();
    let f = ReviewFilter::all_gated("product-wip", &skip);
    for refusals in 0..=MAX_RESPEC_ROUNDS {
        let mut evs = vec![note(crate::triage::ready_note(653))];
        for r in 1..=refusals {
            evs.push(note(crate::spec::spec_note(653, 900, false, 0)));
            evs.push(note(signoff_refusal_note(653, r, "no")));
        }
        evs.push(note(crate::spec::spec_note(653, 900, false, 0)));
        evs.push(note(signoff_note(653, true)));
        assert_eq!(
            queues(&snap, &f, &evs),
            (vec![], vec![], vec![]),
            "{refusals}"
        );
        assert!(park_candidates(&snap, &f, &spec_rounds(&evs)).is_empty());
    }
    // A refusal from before #697 carries no reason, and still re-specs.
    let evs = vec![
        note(crate::triage::ready_note(653)),
        note(crate::spec::spec_note(653, 900, false, 0)),
        note(signoff_note(653, false)),
    ];
    assert_eq!(
        respec_candidates(&snap, &f, &spec_rounds(&evs)),
        vec![(653, 1, None)]
    );
}

/// A skip label still parks an issue mid-round (#652).
#[test]
fn a_skip_label_still_holds_back_a_re_spec() {
    let skip = skip_labels();
    let f = ReviewFilter::all_gated("product-wip", &skip);
    let mut snap = one_gated(653);
    snap.issues[0].labels.push(skip[0].clone());
    let evs = vec![
        note(crate::triage::ready_note(653)),
        note(crate::spec::spec_note(653, 900, false, 0)),
        note(signoff_refusal_note(653, 1, "no")),
    ];
    assert!(respec_candidates(&snap, &f, &spec_rounds(&evs)).is_empty());
}
