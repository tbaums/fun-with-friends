//! #677 — what the loop does when GitHub will not merge an approved PR.
//!
//! transom PR #1419: the base moved past the claim fence while impl3 built,
//! QA approved the diff in isolation, the gate was green at the old base, and
//! `PUT pulls/1419/merge` came back 405 "not mergeable". `finish_pr` is
//! re-planned every tick for any PR approved at head and carries no state
//! between attempts, so the loop retried the identical merge forever —
//! nothing changed the head, so it could never succeed.
//!
//! The answer is the rework mechanism that already exists, not a `git rebase`
//! in the supervisor: the seat has the worktree and bash, so it is told to
//! rebase. Capped like every other round, so a PR that conflicts on every
//! tick becomes a human's decision instead of spinning.

use super::RunConfig;
use crate::github::Apps;

/// GitHub's "not mergeable": 405 on the merge PUT, which is what it answers
/// when the branch conflicts with a base that moved on. A 409 ("head branch
/// was modified") is not this — that is the head moving, and the next tick
/// sees the new one.
fn not_mergeable(e: &crate::merge::MergeError) -> bool {
    matches!(e, crate::merge::MergeError::Api { what, status: 405, .. } if what.contains("/merge"))
}

/// What a merge that did not happen earns: the line on stderr always, plus —
/// when GitHub called the PR not mergeable — a rebase round on the seat that
/// owns the branch, in this same tick (#677). Retrying the identical merge
/// next tick changes nothing (the head is the same, the base has moved), so
/// the only thing that can move the PR is the seat with the worktree.
pub(super) fn after_failed_merge(
    cfg: &RunConfig,
    apps: &Apps,
    snap: &crate::poll::Snapshot,
    pr: u64,
    e: &FinishError,
) {
    eprintln!("fwf run: #{pr} approved but not merged: {e}");
    let Some(head_ref) = head_ref_of(snap, pr) else {
        return;
    };
    let Some((seat, brief)) = merge_rework_order(e, &head_ref, &cfg.base_branch, pr) else {
        return;
    };
    println!(
        "fwf run: #{pr} is not mergeable ({head_ref} vs {}); impl seat {seat} gets a rebase round",
        cfg.base_branch
    );
    let issue = snap
        .prs
        .iter()
        .find(|p| p.number == pr)
        .and_then(|p| p.closes_issue);
    rework_round(cfg, apps, seat, pr, issue, Some(&brief));
}

/// One rework round on `seat`'s own branch, whoever asked for it: the QA App,
/// a human reviewer, or the loop itself with a `brief` after GitHub refused
/// the merge (#677). One function so all three draw on the same `rework_cap`
/// and report the same way — a conflict that repeats every tick becomes a
/// human's decision after the cap, exactly like a review nobody answered.
pub(super) fn rework_round(
    cfg: &RunConfig,
    apps: &Apps,
    seat: u8,
    pr: u64,
    issue: Option<u64>,
    brief: Option<&str>,
) {
    let (Some(impl_app), Some((_, target))) = (
        apps.0.get("impl"),
        cfg.impl_seats.iter().find(|(n, _)| *n == seat),
    ) else {
        eprintln!("fwf run: no impl App or no seat {seat}; #{pr} not reworked");
        return;
    };
    let rc = crate::rework::ReworkConfig {
        owner: cfg.owner.clone(),
        repo: cfg.repo.clone(),
        pr,
        seat_no: seat,
        seat_target: target.clone(),
        seat_expect_cmd: cfg.seat_expect_cmd.clone(),
        base_branch: cfg.base_branch.clone(),
        floor_dir: cfg.floor_dir.clone(),
        mirror_dir: cfg.mirror_dir.clone(),
        job_template: crate::prompts::rework_path(&cfg.prompts_dir, &cfg.template),
        run_log: cfg.run_log.clone(),
        timeout: cfg.job_timeout,
        check_cmd: cfg.gate_cmd.clone(),
        cap: cfg.rework_cap,
        reviewers: cfg.reviewers.clone(),
    };
    match crate::rework::run_with_brief(&rc, impl_app, apps.0.get("ops"), brief) {
        Ok(crate::rework::Outcome::Pushed { head, round }) => println!(
            "fwf run: impl seat {seat} reworked #{pr} (round {round}) → {}",
            head.short()
        ),
        // Past the cap nothing is closed and no issue released:
        // two passes that did not convince QA are a human's call.
        Ok(crate::rework::Outcome::AtCap { rounds }) => eprintln!(
            "fwf run: #{pr} has had {rounds} rework round(s) (cap {}); close it or push it yourself — the loop will not wake the seat again",
            cfg.rework_cap
        ),
        Ok(crate::rework::Outcome::Gone) => {
            println!("fwf run: #{pr} is no longer open; nothing to rework")
        }
        Err(e) => eprintln!(
            "fwf run: rework of #{pr}{} failed: {}",
            issue.map(|i| format!(" (#{i})")).unwrap_or_default(),
            e.0
        ),
    }
}

/// Why a `finish_pr` did not merge. The loop needs one distinction out of it
/// (#677): GitHub calling the PR not mergeable is work for the seat that owns
/// the branch, and everything else is a line on stderr and another tick.
#[derive(Debug)]
pub struct FinishError {
    pub why: String,
    pub not_mergeable: bool,
}

impl std::fmt::Display for FinishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.why)
    }
}

impl FinishError {
    /// What `finish_pr` makes of a merge that did not happen.
    pub fn from_merge(e: crate::merge::MergeError) -> FinishError {
        FinishError {
            why: e.to_string(),
            not_mergeable: not_mergeable(&e),
        }
    }
}

impl From<String> for FinishError {
    fn from(why: String) -> FinishError {
        FinishError {
            why,
            not_mergeable: false,
        }
    }
}

impl From<&str> for FinishError {
    fn from(why: &str) -> FinishError {
        FinishError::from(why.to_string())
    }
}

/// The brief the loop writes for a merge GitHub refused as not mergeable
/// (#677). Nobody reviewed this round, so there is no review body to hand the
/// seat: the supervisor says what GitHub said and what to do about it. The
/// seat has a worktree and bash; the supervisor does not run `git rebase`
/// itself.
pub fn rebase_brief(branch: &str, base: &str, pr: u64) -> String {
    format!(
        "GitHub could not merge this PR (not mergeable): `{branch}` conflicts with `{base}`, \
         which moved on after your claim was fenced. No reviewer asked for this round — \
         rebase `{branch}` onto `{base}`, resolve the conflicts (keep the change PR #{pr} \
         is for AND whatever landed on `{base}` meanwhile), re-run the repo's own check, \
         and deliver the branch as usual."
    )
}

/// The rework a failed merge earns: `Some((seat, brief))` when GitHub called
/// the PR not mergeable and its branch names an impl seat. Everything else is
/// `None` — a 409 ("head branch was modified") resolves against the new head
/// next tick, and a refused precondition is not a conflict.
fn merge_rework_order(
    e: &FinishError,
    head_ref: &str,
    base: &str,
    pr: u64,
) -> Option<(u8, String)> {
    if !e.not_mergeable {
        return None;
    }
    let seat = crate::sched::impl_seat_of(head_ref)?;
    Some((seat, rebase_brief(head_ref, base, pr)))
}

/// The branch a PR in this snapshot is on.
fn head_ref_of(snap: &crate::poll::Snapshot, pr: u64) -> Option<String> {
    snap.prs
        .iter()
        .find(|p| p.number == pr)
        .map(|p| p.head_ref.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    /// #677, transom PR #1419: the base moved past the claim fence while the seat
    /// built, QA approved the diff in isolation, and the merge PUT came back 405.
    /// `finish_pr` is re-planned every tick for any PR approved at head, so the
    /// loop retried the identical merge forever — nothing changed the head, so it
    /// never succeeded. The 405 is now a rebase round on the seat that owns the
    /// branch, in the same tick.
    #[test]
    fn a_merge_github_calls_not_mergeable_becomes_a_rebase_round_for_that_seat() {
        let api = |status: u16| crate::merge::MergeError::Api {
            what: "PUT pulls/1419/merge".into(),
            status,
            body: "{\"message\":\"Pull Request is not mergeable\"}".into(),
        };
        // exactly what finish_pr makes of a merge error
        let finish = FinishError::from_merge;
        let branch = "impl3/issue-1411-thin-slice";

        let e = finish(api(405));
        assert!(e.not_mergeable, "{e:?}");
        let (seat, brief) = merge_rework_order(&e, branch, "staging", 1419)
            .expect("a 405 is work for the seat, not another identical merge");
        assert_eq!(seat, 3, "the branch names the seat that must rebase");
        assert!(
            brief.contains(branch) && brief.contains("staging"),
            "{brief}"
        );
        assert!(brief.contains("rebase"), "{brief}");
        assert!(brief.contains("#1419"), "{brief}");
        assert_eq!(brief, rebase_brief(branch, "staging", 1419));

        // 409 is the head moving under us, not a conflict: next tick sees the new
        // head, so it earns no round.
        assert!(merge_rework_order(&finish(api(409)), branch, "staging", 1419).is_none());
        // and a precondition refusal is not a conflict either
        let refused = finish(crate::merge::MergeError::Refused(
            crate::types::Refusal::NotReady("pr #1419 is a draft".into()),
        ));
        assert!(!refused.not_mergeable);
        assert!(merge_rework_order(&refused, branch, "staging", 1419).is_none());
        // a 405 on some other call is not the merge's
        let elsewhere = finish(crate::merge::MergeError::Api {
            what: "GET pulls/1419/reviews".into(),
            status: 405,
            body: String::new(),
        });
        assert!(!elsewhere.not_mergeable);
        // a branch that names no impl seat has nobody to wake
        assert!(merge_rework_order(&e, "hotfix/by-hand", "staging", 1419).is_none());
    }
}
