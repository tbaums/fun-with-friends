//! #668 — whether a working seat is actually moving.
//!
//! `job_timeout_secs` on the wall clock was the only thing a wait watched, and
//! it called the impl seat Stalled at 40 minutes while it sat in `cargo test
//! --workspace` on a 16 GB Mac. The two signals here are the answer: what the
//! seat's worktree looks like, and what its pane last printed. Both are
//! injected, so the rule is testable without a real seat.
//!
//! Split out of `seat.rs` to keep that file inside the 1,000-line rule (T-30),
//! the same way `run/cycle.rs` and `slice/tests.rs` are.

use super::tmux;
use std::path::Path;

/// How often the progress signals are sampled while a seat works (#668).
/// Fixed, and deliberately far apart from the 2s verdict poll: each sample
/// shells out to `git` and `tmux`, which is not something to do every 2s.
pub const SAMPLE_EVERY: u64 = 60;

/// A short, stable digest of one signal's text. Only ever compared with
/// another digest from the same process, so any hasher will do.
fn digest(text: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut h);
    format!("{:016x}", h.finish())
}

/// Signal 1 (#668): the seat's worktree — its HEAD and its index. A seat that
/// commits, or edits a file, has moved even if its pane is silent.
pub fn worktree_signal(wt: &Path) -> Option<String> {
    let head = crate::mirror::git_in(wt, &["rev-parse", "HEAD"]).ok()?;
    let status = crate::mirror::git_in(wt, &["status", "--porcelain"]).ok()?;
    Some(digest(&format!("{head}\n{status}")))
}

/// Signal 2 (#668): the last 40 lines on the pane. A seat mid-`cargo test`
/// writes nothing to its worktree for half an hour and everything here.
pub fn pane_signal(target: &str) -> Option<String> {
    let text = tmux(&["capture-pane", "-p", "-t", target]).ok()?;
    let mut tail: Vec<&str> = text.lines().rev().take(40).collect();
    tail.reverse();
    Some(digest(&tail.join("\n")))
}

/// Liveness for a working seat: is it moving, not just how long it has been
/// out (#668).
///
/// `job_timeout_secs` alone marked a seat Stalled at 40 minutes while it was
/// mid-`cargo test --workspace` on a 16 GB Mac — its second commit landed five
/// minutes after that false verdict, and the verdict wedged the claim. So a
/// seat is quiet only when BOTH signals — worktree and pane — have been
/// unchanged for `quiet_limit`; either one moving is the seat working.
///
/// Both samplers are injected, so the rule is testable without a real seat,
/// and both fail *open*: a sampler that cannot read (pane gone, worktree
/// missing) counts as movement, because a broken probe is not evidence that a
/// seat has stopped. Notes go to the caller's sink — this module never writes
/// to the record.
pub struct Watch<'a> {
    /// `impl1 #1383`: who this is about, as the notes name them.
    who: String,
    quiet_limit: u64,
    started: u64,
    signals: [Box<dyn FnMut() -> Option<String> + 'a>; 2],
    note: Box<dyn FnMut(String) + 'a>,
    last: [Option<String>; 2],
    quiet_since: u64,
    /// Which signal moved last, and when. `None` until one does.
    last_change: Option<(&'static str, u64)>,
}

const SIGNAL_NAMES: [&str; 2] = ["worktree", "pane"];

impl<'a> Watch<'a> {
    /// Both samplers are read once here, at the wake: the first real sample
    /// compares against what the seat started from, not against nothing.
    pub fn new(
        who: String,
        quiet_limit: u64,
        started: u64,
        worktree: impl FnMut() -> Option<String> + 'a,
        pane: impl FnMut() -> Option<String> + 'a,
        note: impl FnMut(String) + 'a,
    ) -> Watch<'a> {
        let mut signals: [Box<dyn FnMut() -> Option<String> + 'a>; 2] =
            [Box::new(worktree), Box::new(pane)];
        let last = [signals[0](), signals[1]()];
        Watch {
            who,
            quiet_limit,
            started,
            signals,
            note: Box::new(note),
            last,
            quiet_since: started,
            last_change: None,
        }
    }

    /// One sample of both signals. `true` means the seat has been quiet for
    /// `quiet_limit` and should be called Stalled; the note explaining that
    /// has already gone to the sink.
    pub fn sample(&mut self, now: u64) -> bool {
        let mut moved = false;
        for (i, signal) in SIGNAL_NAMES.into_iter().enumerate() {
            let Some(cur) = (self.signals[i])() else {
                // A probe that cannot read says nothing about the seat, so it
                // says "alive": stderr only, and the last good sample stands.
                eprintln!(
                    "fwf: {} {signal} could not be sampled; counting it as progress",
                    self.who
                );
                moved = true;
                continue;
            };
            if self.last[i].as_deref() != Some(cur.as_str()) {
                moved = true;
                self.last_change = Some((signal, now));
                (self.note)(progress_note(&self.who, signal, now));
            }
            self.last[i] = Some(cur);
        }
        if moved {
            self.quiet_since = now;
        }
        // 0 is the knob turned off; the wall-clock deadline is still the ceiling.
        if self.quiet_limit == 0 {
            return false;
        }
        let quiet = now.saturating_sub(self.quiet_since);
        if quiet < self.quiet_limit {
            return false;
        }
        let (signal, at) = self.last_change.unwrap_or(("wake", self.started));
        (self.note)(stalled_note(&self.who, quiet, signal, at));
        true
    }
}

/// What the record says when a signal moves. Written only on an observed
/// change, so a pane printing continuously costs one note a minute, not one
/// per line.
pub fn progress_note(who: &str, signal: &str, at: u64) -> String {
    format!("progress: {who} {signal} changed at {at}")
}

/// What the record says when both signals stopped: a stall verdict has to be
/// explainable afterwards, so it names the signal that moved last and when.
pub fn stalled_note(who: &str, quiet: u64, signal: &str, at: u64) -> String {
    format!("stalled: {who} quiet {quiet}s (last change: {signal} at {at})")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The two signal values a fake seat shows, and the notes it produces.
    fn cells() -> (
        std::cell::RefCell<String>,
        std::cell::RefCell<String>,
        std::cell::RefCell<Vec<String>>,
    ) {
        Default::default()
    }

    /// A seat's cycle, sampled minute by minute: the two signals it would
    /// read, the notes it would write, and a clock the test owns.
    fn watched<'a>(
        quiet_limit: u64,
        wt: &'a std::cell::RefCell<String>,
        pane: &'a std::cell::RefCell<String>,
        notes: &'a std::cell::RefCell<Vec<String>>,
    ) -> Watch<'a> {
        Watch::new(
            "impl1 #1383".into(),
            quiet_limit,
            1_000,
            || Some(wt.borrow().clone()),
            || Some(pane.borrow().clone()),
            |t| notes.borrow_mut().push(t),
        )
    }

    /// #668, fwf floor 2026-09-16: the impl seat was called Stalled at 40
    /// minutes while it sat in `cargo test --workspace` on a 16 GB Mac — its
    /// second commit landed five minutes after that false verdict, and the
    /// verdict wedged the claim. A pane that is still printing is a seat that
    /// is still working, however long the wall clock says.
    #[test]
    fn a_seat_whose_pane_keeps_moving_is_never_quiet() {
        let (wt, pane, notes) = cells();
        let mut w = watched(900, &wt, &pane, &notes);
        // 40 minutes of `cargo test` output: the worktree never changes.
        for m in 1..=40u64 {
            *pane.borrow_mut() = format!("test {m} ... ok");
            assert!(
                !w.sample(1_000 + m * 60),
                "quiet at minute {m} with the pane still printing"
            );
        }
        assert_eq!(notes.borrow().len(), 40, "one note per observed change");
        assert_eq!(
            notes.borrow()[0],
            "progress: impl1 #1383 pane changed at 1060"
        );
        // and the other way round: a silent pane while the worktree moves —
        // either signal alone is the seat working.
        for m in 41..=60u64 {
            *wt.borrow_mut() = format!("head-{m}");
            assert!(!w.sample(1_000 + m * 60), "quiet at minute {m}");
        }
    }

    /// The seat that really has stopped: nothing in the worktree, nothing on
    /// the pane. It is called Stalled at the first sample past the limit —
    /// before `job_timeout_secs`, which stays the ceiling either way.
    #[test]
    fn a_seat_quiet_on_both_signals_is_stalled_at_the_limit() {
        let (wt, pane, notes) = cells();
        *pane.borrow_mut() = "waiting".to_string();
        let mut w = watched(900, &wt, &pane, &notes);
        // it moved once, two minutes in, and then stopped
        *pane.borrow_mut() = "the last thing it ever said".to_string();
        assert!(!w.sample(1_120));
        for m in [4u64, 8, 12, 14] {
            assert!(!w.sample(1_000 + m * 60), "stalled early at minute {m}");
        }
        // 15 minutes after that last change, and not before
        assert!(w.sample(1_120 + 900));
        // the note explains the verdict: which signal moved last, and when
        let last = notes.borrow().last().cloned().unwrap();
        assert_eq!(
            last,
            "stalled: impl1 #1383 quiet 900s (last change: pane at 1120)"
        );
    }

    /// A probe is not evidence. A pane that tmux cannot read, or a worktree
    /// that is not there, must never be the reason a working seat is stalled.
    #[test]
    fn a_signal_that_cannot_be_sampled_counts_as_progress() {
        let notes = std::cell::RefCell::new(Vec::new());
        let mut w = Watch::new(
            "impl1 #1383".into(),
            900,
            1_000,
            || None,
            || None,
            |t| notes.borrow_mut().push(t),
        );
        for m in 1..=40u64 {
            assert!(!w.sample(1_000 + m * 60), "stalled on a broken probe");
        }
        assert!(notes.borrow().is_empty(), "stderr only, not the record");
        // a seat with no change and no signal it can read at all still stalls
        // only on real quiet — here nothing is readable, so it never does.
        let (wt, pane, notes2) = cells();
        let mut off = watched(0, &wt, &pane, &notes2);
        assert!(!off.sample(1_000 + 86_400), "0 turns the early stall off");
    }
}
