//! #652 — the filter the gated spec cycle (#629) applies before it may wake
//! GV or PM, and the two candidate lists it plans from.
//!
//! The cycle shipped with no filter at all: on 2026-09-15 a floor allow-listed
//! to one ticket woke GV and then PM on transom's #1371 — a `discovery` ticket
//! its owner had parked — because neither `skip_labels` nor the allow-list was
//! read here. A skip label parks a gated issue under either scope (that is
//! what the label means), and `review_scope = "allow-list"` is the opt-in that
//! narrows the rest to the manifest's `issues`.
//!
//! Split out of `run.rs` to keep that file inside the 1,000-line rule (T-30).

use super::{note_issue, RunConfig};
use crate::poll::{IssueView, Snapshot};
use std::collections::{BTreeMap, BTreeSet};

/// How far the spec cycle reaches (manifest `review_scope`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReviewScope {
    /// Every open gated issue no skip label parks — #629's default, and the
    /// operator's intent: a ticket filed with the gate label is meant to reach
    /// PM without anyone typing a verb.
    #[default]
    AllGated,
    /// Only the manifest's `issues`. An empty allow-list stays unrestricted,
    /// the same meaning it already has on the impl path.
    AllowList,
}

impl ReviewScope {
    /// Read the manifest spelling. Validation is the manifest's job, so an
    /// unknown value never reaches here; the default is what a missing key
    /// means.
    pub fn from_manifest(s: &str) -> ReviewScope {
        match s {
            crate::manifest::REVIEW_SCOPE_ALLOW_LIST => ReviewScope::AllowList,
            _ => ReviewScope::AllGated,
        }
    }
}

/// Why the cycle passed over a gated issue.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SkipReason {
    /// The `skip_labels` tag that parks it — the first one that matched.
    Label(String),
    NotAllowListed,
}

impl std::fmt::Display for SkipReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SkipReason::Label(l) => write!(f, "skip_labels: {l}"),
            SkipReason::NotAllowListed => write!(f, "not in allow-list"),
        }
    }
}

/// What the spec cycle is allowed to look at: which label gates an issue,
/// which labels park one, and how far the allow-list reaches.
pub struct ReviewFilter<'a> {
    pub gate_label: &'a str,
    pub skip_labels: &'a [String],
    pub scope: ReviewScope,
    pub allow_issues: &'a [u64],
}

impl<'a> ReviewFilter<'a> {
    /// The running floor's own filter.
    pub fn of(cfg: &'a RunConfig) -> ReviewFilter<'a> {
        ReviewFilter {
            gate_label: &cfg.gate_label,
            skip_labels: &cfg.skip_labels,
            scope: cfg.review_scope,
            allow_issues: &cfg.allow_issues,
        }
    }

    /// The default scope: labels only, no allow-list narrowing.
    pub fn all_gated(gate_label: &'a str, skip_labels: &'a [String]) -> ReviewFilter<'a> {
        ReviewFilter {
            gate_label,
            skip_labels,
            scope: ReviewScope::AllGated,
            allow_issues: &[],
        }
    }

    /// `None` when the cycle may spend a wake on this issue. A skip label
    /// answers first and answers under either scope: it marks a parked or
    /// human-decision ticket, and no scoping makes it the loop's business.
    pub fn skipped(&self, i: &IssueView) -> Option<SkipReason> {
        if let Some(l) = i.labels.iter().find(|l| self.skip_labels.contains(l)) {
            return Some(SkipReason::Label(l.clone()));
        }
        if self.scope == ReviewScope::AllowList
            && !self.allow_issues.is_empty()
            && !self.allow_issues.contains(&i.number)
        {
            return Some(SkipReason::NotAllowListed);
        }
        None
    }
}

/// Open and carrying the gate label — before the filter has a say.
fn gated(i: &IssueView, gate_label: &str) -> bool {
    i.state == "open" && i.labels.iter().any(|l| l == gate_label)
}

/// Open, gated, and the filter's to review. The two halves of the spec cycle
/// share this and then differ only in what the record must (not) already say.
fn reviewable<'a>(snap: &'a Snapshot, f: &ReviewFilter) -> Vec<&'a IssueView> {
    let mut v: Vec<&IssueView> = snap
        .issues
        .iter()
        .filter(|i| gated(i, f.gate_label) && f.skipped(i).is_none())
        .collect();
    v.sort_unstable_by_key(|i| i.number);
    v
}

/// Gated issues GV has never judged, oldest first. These are the tickets the
/// operator's convention files with the gate label already on: before #629
/// nothing ever looked at them, because the in-loop `triage_new` filter only
/// ever considered issues *without* the gate.
///
/// A not-ready issue comes back once it has changed since the verdict (#693):
/// its `updated_at` is later than the baseline recorded right after fwf's own
/// gate write. A fresh verdict replaces the baseline, so it is one re-triage
/// per edit. No baseline (a record older than #693) means no re-offer.
pub fn gv_gated_candidates(
    snap: &Snapshot,
    f: &ReviewFilter,
    judged: &BTreeMap<u64, bool>,
    baselines: &BTreeMap<u64, String>,
) -> Vec<u64> {
    reviewable(snap, f)
        .into_iter()
        .filter(|i| match judged.get(&i.number) {
            None => true,
            Some(true) => false,
            // Fixed-width ISO-8601, so the string order is the time order.
            Some(false) => baselines
                .get(&i.number)
                .is_some_and(|b| i.updated_at.as_str() > b.as_str()),
        })
        .map(|i| i.number)
        .collect()
}

/// Gated issues GV judged ready and PM has not specced, oldest first. A
/// not-ready verdict keeps an issue out of here until it is edited and a fresh
/// GV verdict lands (the edit re-offers it to GV, #693).
///
/// The filter is re-applied here, not inherited from GV's half: a skip label
/// added after GV judged an issue ready still blocks the PM wake.
pub fn pm_candidates(
    snap: &Snapshot,
    f: &ReviewFilter,
    judged: &BTreeMap<u64, bool>,
    specced: &BTreeSet<u64>,
) -> Vec<u64> {
    reviewable(snap, f)
        .into_iter()
        .filter(|i| judged.get(&i.number) == Some(&true) && !specced.contains(&i.number))
        .map(|i| i.number)
        .collect()
}

/// Gated issues PM has specced and GV has not yet read back, oldest first —
/// the sign-off queue (#655).
///
/// A first-pass ready verdict judged the *raw ticket*; the spec an implementer
/// builds from did not exist yet. So a specced issue owes one more GV read
/// before anything un-gates it, and it stays here until that read is recorded.
/// A sign-off that never finished (a stalled seat records no note) is offered
/// again next tick, like every other cycle here.
pub fn signoff_candidates(
    snap: &Snapshot,
    f: &ReviewFilter,
    specced: &BTreeSet<u64>,
    signed: &BTreeSet<u64>,
) -> Vec<u64> {
    reviewable(snap, f)
        .into_iter()
        .filter(|i| specced.contains(&i.number) && !signed.contains(&i.number))
        .map(|i| i.number)
        .collect()
}

/// Every "GV read the spec back" note starts with this.
pub const SIGNOFF_NOTE_PREFIX: &str = "GV sign-off: #";

/// The record's note for a sign-off verdict, either way it went. Written for a
/// refusal too: the question "has GV read this spec" is answered once, and a
/// refusal is an answer.
pub fn signoff_note(issue: u64, ready: bool) -> String {
    format!(
        "{SIGNOFF_NOTE_PREFIX}{issue} {} the spec",
        if ready { "approved" } else { "refused" }
    )
}

/// The `updated_at` each not-ready issue had right after GV gated it (#693),
/// replayed from the record. A baseline counts only for the verdict it
/// follows: any later `Gated` event (a re-gate after sign-off, or a verdict
/// whose read-back failed) or ready note drops it, so a stale one never
/// re-offers an issue.
///
/// A record from before #693 has `Gated` events and no GV note of either kind
/// for the issue at all (#695). Its baseline falls back to the latest `Gated`
/// event's own time, so an edit since then earns it one re-triage, whose
/// verdict writes a real note and retires the fallback. The event time is
/// ours, not GitHub's: clock skew against fwf's own label and comment write
/// can re-offer a legacy issue nobody edited — accepted as a one-time cost.
/// An issue with any ready or baseline note in its history never falls back,
/// so the drops above still hold for everything written since #693.
pub fn gv_gate_baselines(events: &[crate::log::Event]) -> BTreeMap<u64, String> {
    use crate::log::Kind;
    use crate::types::IssueState;
    let mut out = BTreeMap::new();
    let mut last_gated = BTreeMap::new();
    let mut noted = BTreeSet::new();
    for e in events {
        match &e.kind {
            Kind::Issue {
                issue,
                to: IssueState::Gated,
            } => {
                out.remove(issue);
                last_gated.insert(*issue, e.ts);
            }
            Kind::Note { text } => {
                if let Some(n) = note_issue(text, crate::triage::READY_NOTE_PREFIX) {
                    out.remove(&n);
                    noted.insert(n);
                } else if let Some(n) = note_issue(text, crate::triage::GATE_BASELINE_NOTE_PREFIX) {
                    noted.insert(n);
                    if let Some((_, at)) = text.split_once(" updated_at ") {
                        out.insert(n, at.to_string());
                    }
                }
            }
            _ => {}
        }
    }
    for (n, ts) in last_gated {
        if !noted.contains(&n) {
            out.entry(n).or_insert_with(|| utc_rfc3339(ts));
        }
    }
    out
}

/// Unix seconds as GitHub's `updated_at` spelling, `2026-09-25T10:00:00Z`:
/// fixed-width UTC, so it compares as a string against the real thing.
/// Self-contained on purpose — a correctness comparison, not a display string
/// (compare `seat::local_hhmm`). Howard Hinnant's civil_from_days.
fn utc_rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Issues whose spec GV has already read back.
pub fn signed_off(events: &[crate::log::Event]) -> BTreeSet<u64> {
    events
        .iter()
        .filter_map(|e| match &e.kind {
            crate::log::Kind::Note { text } => note_issue(text, SIGNOFF_NOTE_PREFIX),
            _ => None,
        })
        .collect()
}

/// The gated issues this tick's filter drops, with the reason, oldest first —
/// minus the ones `seen` says the record already named.
pub fn gated_skips(
    snap: &Snapshot,
    f: &ReviewFilter,
    seen: &BTreeSet<u64>,
) -> Vec<(u64, SkipReason)> {
    let mut v: Vec<(u64, SkipReason)> = snap
        .issues
        .iter()
        .filter(|i| gated(i, f.gate_label) && !seen.contains(&i.number))
        .filter_map(|i| f.skipped(i).map(|why| (i.number, why)))
        .collect();
    v.sort_unstable_by_key(|(n, _)| *n);
    v
}

/// Every "the cycle passed this over" note starts with this; the loop reads
/// the issue number back out of it to know the reason was already said.
pub const SKIP_NOTE_PREFIX: &str = "review skipped: #";

pub fn skip_note(issue: u64, why: &SkipReason) -> String {
    format!("{SKIP_NOTE_PREFIX}{issue} — {why}")
}

/// Issues the record already says the cycle passed over.
pub fn skip_noted(events: &[crate::log::Event]) -> BTreeSet<u64> {
    events
        .iter()
        .filter_map(|e| match &e.kind {
            crate::log::Kind::Note { text } => note_issue(text, SKIP_NOTE_PREFIX),
            _ => None,
        })
        .collect()
}

/// Say it once — on `run.out` and in the record — when the cycle passes over a
/// gated issue (#652). Once, not once per tick: an operator needs to know why
/// a ticket is sitting there, and a line every minute is how that gets tuned
/// out. The dedup is the run log's seen-set, the same shape triage uses.
pub fn note_gated_skips(cfg: &RunConfig, snap: &Snapshot) {
    let evs = crate::log::read_all(&cfg.run_log).unwrap_or_default();
    let seen = skip_noted(&evs);
    for (n, why) in gated_skips(snap, &ReviewFilter::of(cfg), &seen) {
        if let Ok(mut log) = crate::log::Log::open(&cfg.run_log) {
            let _ = log.append(&crate::log::Event {
                ts: crate::seat::now(),
                repo: format!("{}/{}", cfg.owner, cfg.repo),
                kind: crate::log::Kind::Note {
                    text: skip_note(n, &why),
                },
            });
        }
        println!("fwf run: gated #{n} not reviewed — {why}");
    }
}
