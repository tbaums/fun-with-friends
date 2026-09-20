//! What the reviewers have said about one head — the single answer the
//! planner and the merge path both read (#690).
//!
//! There used to be two. `sched::pr_approved_at_head` called a PR approved if
//! **any** `-qa[bot]` review anchored to the head was APPROVED, whatever came
//! after it; `merge::verdict` took the **latest** review per login at that
//! head, where CHANGES_REQUESTED beats APPROVED. On PR #689 an operator
//! approved and then, at the same head, asked for changes. The planner went on
//! calling it approved — and `pr_changes_requested_at_head` was gated on
//! `!pr_approved_at_head`, so the later refusal was invisible to it — while
//! `merge_pr` refused with "no approval anchored to head". Every tick: one
//! merge attempt, one refusal, no rework, forever. The operator had to dismiss
//! the stale approval through the API by hand.
//!
//! So there is one rule now, in one place, and both callers are wrappers over
//! it. The rule is `merge`'s, unchanged, because it is the one GitHub itself
//! enforces at the merge button:
//!
//! - the PR's own author never reviews it (GitHub refuses; so do we);
//! - per login, only that login's **latest** review counts;
//! - among those, only reviews anchored to `head` decide, and one
//!   CHANGES_REQUESTED outranks every APPROVED;
//! - failing that, an APPROVED (or head-move-DISMISSED) review for some other
//!   commit is a [`Verdict::Stale`], which names the commit it was for.

use crate::types::Sha;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Approved { by: String },
    ChangesRequested { by: String },
    Stale { approved_head: Sha },
    None,
}

/// The verdict for `head`, from reviews in submission order as
/// `(login, state, commit)` — the shape `poll::PrView.reviews` already has,
/// and the shape `merge::verdict_of` maps GitHub's raw JSON into.
///
/// `state` is GitHub's own spelling (`APPROVED`, `CHANGES_REQUESTED`,
/// `DISMISSED`, `COMMENTED`); anything else is a review that decides nothing.
/// A `commit` that is not a 40-char sha can never be `head`, so it is simply
/// never at head — and is skipped when looking for a stale approval, where a
/// sha is the whole point of the answer.
pub fn verdict<'a, I>(reviews: I, head: &str, author: &str) -> Verdict
where
    I: IntoIterator<Item = (&'a str, &'a str, &'a str)>,
{
    let all: Vec<(&str, &str, &str)> = reviews.into_iter().collect();
    // Latest per login, in list order (GitHub returns submission order).
    let mut latest: Vec<(&str, &str, &str)> = Vec::new();
    for rv in all.iter().copied() {
        if rv.0 == author {
            continue;
        }
        match latest.iter_mut().find(|(l, _, _)| *l == rv.0) {
            Some(slot) => *slot = rv,
            None => latest.push(rv),
        }
    }
    if let Some((by, _, _)) = latest
        .iter()
        .find(|(_, state, commit)| *state == "CHANGES_REQUESTED" && *commit == head)
    {
        return Verdict::ChangesRequested { by: by.to_string() };
    }
    if let Some((by, _, _)) = latest
        .iter()
        .find(|(_, state, commit)| *state == "APPROVED" && *commit == head)
    {
        return Verdict::Approved { by: by.to_string() };
    }
    // An approval (live, or dismissed by the head move) for another commit.
    let stale = all.iter().rev().find_map(|(login, state, commit)| {
        let approved = *state == "APPROVED" || *state == "DISMISSED";
        if *login != author && approved && *commit != head {
            Sha::parse(commit).ok()
        } else {
            None
        }
    });
    match stale {
        Some(approved_head) => Verdict::Stale { approved_head },
        None => Verdict::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const QA: &str = "fwf-qa[bot]";
    const IMPL: &str = "fwf-impl[bot]";
    fn head() -> String {
        "h".repeat(40)
    }
    fn other() -> String {
        "0".repeat(40)
    }

    /// The #690 shape itself: approve, then ask for changes at the same head.
    /// The later word is the word.
    #[test]
    fn a_later_changes_requested_supersedes_that_logins_own_approval() {
        let h = head();
        assert_eq!(
            verdict(
                [(QA, "APPROVED", h.as_str()), (QA, "CHANGES_REQUESTED", &h)],
                &h,
                IMPL
            ),
            Verdict::ChangesRequested { by: QA.into() }
        );
        // and the flip-flop back: latest wins there too, so it is approved
        assert_eq!(
            verdict(
                [
                    (QA, "APPROVED", h.as_str()),
                    (QA, "CHANGES_REQUESTED", &h),
                    (QA, "APPROVED", &h)
                ],
                &h,
                IMPL
            ),
            Verdict::Approved { by: QA.into() }
        );
    }

    /// One refusal outranks every approval, whoever left it — the rule
    /// `merge_pr` has always applied, now the planner's too.
    #[test]
    fn a_refusal_at_head_outranks_another_logins_approval() {
        let h = head();
        assert_eq!(
            verdict(
                [
                    (QA, "APPROVED", h.as_str()),
                    ("tbaums", "CHANGES_REQUESTED", &h)
                ],
                &h,
                IMPL
            ),
            Verdict::ChangesRequested {
                by: "tbaums".into()
            }
        );
    }

    /// The author's own reviews are nobody's verdict, and a review for a head
    /// that has since moved is Stale, not a refusal and not an approval.
    #[test]
    fn the_author_is_ignored_and_an_older_head_is_stale() {
        let (h, o) = (head(), other());
        assert_eq!(
            verdict([(IMPL, "APPROVED", h.as_str())], &h, IMPL),
            Verdict::None
        );
        assert_eq!(
            verdict([(QA, "APPROVED", o.as_str())], &h, IMPL),
            Verdict::Stale {
                approved_head: Sha::parse(&o).unwrap()
            }
        );
        assert_eq!(
            verdict([(QA, "DISMISSED", o.as_str())], &h, IMPL),
            Verdict::Stale {
                approved_head: Sha::parse(&o).unwrap()
            }
        );
        // a comment decides nothing, and an unparseable commit is no sha to
        // report back
        assert_eq!(
            verdict([(QA, "COMMENTED", h.as_str())], &h, IMPL),
            Verdict::None
        );
        assert_eq!(
            verdict([(QA, "APPROVED", "not-a-sha")], &h, IMPL),
            Verdict::None
        );
    }
}
