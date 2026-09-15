//! #627 — the one dash test whose data is a real run record.
//!
//! Every other test in the suite hands `fold` a record it wrote itself, so
//! the kinds an operator's floor actually produces in bulk — `Note`,
//! `Promote`, `Human` — barely appear, and `log::read_all` is never part of
//! the path at all. Three live defects (narrow-width wrapping, stale
//! Decisions alerts, the one-shot default) shipped with that suite green.
//!
//! `testdata/golden_run.jsonl` is the last 400 lines of a real floor's
//! record (`~/.fwf/floors/transom/run.jsonl`, 2026-09-15), copied and
//! trimmed, not hand-authored. Being a tail, it starts mid-pipeline: issues
//! claimed by a cycle whose opening event was cut off, PRs with no merge in
//! sight. That is the point — `render` has to hold up on dangling state.
//!
//! The assertions are structural on purpose: row counts and line widths, not
//! exact strings. A golden string would pin this file to today's wording and
//! would be rewritten, not read, the first time the frame changed.

use crate::dash::view::fixture::{columns, floor as fixture_floor};
use crate::dash::view::{render, Tab, View};
use crate::dash::{fold, issue_rows, pr_rows, Floor};
use crate::log::{read_all, Event, Kind};
use std::path::PathBuf;

/// The record as checked in. Row counts below are pinned to THIS file: a
/// fixture that is replaced or extended updates them in the same commit.
fn golden() -> Vec<Event> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/dash/testdata/golden_run.jsonl");
    // `read_all` errors on a malformed line rather than skipping it, so this
    // also proves the trim never cut a line in half.
    read_all(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The fixture floor stands in for the manifest/tmux join (out of scope
/// here), with the allow-list cleared: this record is another repo's, and an
/// allow-list of `[574]` would hide every issue in it.
fn floor() -> Floor {
    Floor {
        allow: vec![],
        ..fixture_floor()
    }
}

#[test]
fn a_real_record_carries_the_kinds_no_other_fixture_does() {
    let evs = golden();
    assert_eq!(evs.len(), 400);
    let count = |f: fn(&Kind) -> bool| evs.iter().filter(|e| f(&e.kind)).count();
    assert_eq!(count(|k| matches!(k, Kind::Note { .. })), 101);
    assert_eq!(count(|k| matches!(k, Kind::Promote { .. })), 17);
    assert_eq!(count(|k| matches!(k, Kind::Human { .. })), 14);
    assert_eq!(count(|k| matches!(k, Kind::Refused { .. })), 2);
}

#[test]
fn a_real_record_folds_to_the_rows_this_fixture_pins() {
    let b = fold(&golden());
    let f = floor();
    // Live rows, not events: the tail carries 79 issue and 40 PR events, and
    // what survives the fold is the pipeline still in flight when the record
    // was cut. Pinned to this exact file.
    assert_eq!(issue_rows(&b, &f).len(), 11);
    assert_eq!(pr_rows(&b).len(), 10);
    // With the allow-list cleared, every issue on the board is workable — the
    // dimming an allow-list causes is the fixture floor's business, not this
    // record's.
    assert!(issue_rows(&b, &f).iter().all(|r| r.allowed));
    // The kinds this test exists for reach the board, rather than being read
    // and dropped: a human un-gate lands in `humans`, and the promotions feed
    // the per-PR trail the Decisions tab reads.
    assert_eq!(b.humans.len(), 14);
    assert!(b.humans.iter().any(|(_, _, action, _)| action == "ungate"));
    assert!(b.trails.values().any(|t| !t.is_empty()));
}

#[test]
fn every_tab_renders_a_real_record_inside_the_terminal() {
    let evs = golden();
    let b = fold(&evs);
    let f = floor();
    // An operator watching a live floor: the clock is just past the last
    // event, so every "… ago" is small and positive.
    let now = evs.last().expect("the fixture is not empty").ts + 60;
    for w in [40usize, 50, 60, 72, 100, 140] {
        for color in [false, true] {
            for tab in Tab::ALL {
                let v = View {
                    tab,
                    width: w,
                    height: 24,
                    color,
                    ..Default::default()
                };
                let out = render(&b, &f, &v, now);
                for l in out.lines() {
                    assert!(
                        columns(l) <= w,
                        "w={w} color={color} tab={tab:?} len={} line={l:?}",
                        columns(l)
                    );
                }
                assert_eq!(out.lines().count(), 24, "w={w} tab={tab:?}");
            }
        }
    }
}

/// A trimmed record can also be read by an operator who scrolled back: the
/// clock sits long after the last event. Nothing in the frame may panic or
/// overflow on the arithmetic that produces "3d ago".
#[test]
fn a_stale_clock_over_a_real_record_still_renders() {
    let evs = golden();
    let b = fold(&evs);
    let f = floor();
    let last = evs.last().unwrap().ts;
    for now in [0, last, last + 86_400 * 30] {
        for tab in Tab::ALL {
            let v = View {
                tab,
                ..Default::default()
            };
            let out = render(&b, &f, &v, now);
            assert!(out.starts_with("┌ fwf dash "), "tab={tab:?} now={now}");
        }
    }
}
