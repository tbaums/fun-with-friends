//! Delivering a finished cycle: the claim it runs under, the push upstream
//! and the draft PR — and what happens when GitHub refuses the push (#602).
//!
//! Split out of `slice.rs` so that file stays under the size ratchet; the
//! order of events is still the one `run_with` walks, and every function here
//! is called from there or from the loop's per-tick retry.

use super::{events, record, SliceConfig, SliceError};
use crate::github::{self, AppEntry};
use crate::log::{Kind, Log};
use crate::mirror::{Mirror, MirrorError};
use crate::poll::Poller;
use crate::seat::Verdict;
use crate::types::{Fence, IssueState, JobRef, PrState, Role, SeatState, Sha};
use std::collections::BTreeMap;

/// The claim for this cycle. Normally a fresh `refs/claims/<n>` at the base.
///
/// A claim ref that already exists upstream is only a hard failure when it is
/// not this floor's (#602): after a cycle whose push was refused the claim is
/// deliberately still there, and re-taking it made every later tick fail with
/// `refs/claims/<n> already exists upstream`. If the record says this floor
/// claimed the issue and upstream still holds exactly that fence, reuse it; if
/// upstream holds a different sha for a claim the record says is ours (the
/// base moved between cycles), release that one explicitly and take a new one.
pub(super) fn claim(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    mirror: &Mirror,
    base: &Sha,
    push_tok: &str,
) -> Result<Fence, SliceError> {
    let taken = match mirror.create_claim_ref(cfg.issue, base, push_tok) {
        Ok(fence) => return Ok(fence),
        Err(MirrorError::ClaimTaken(_)) => mirror.upstream_claim_ref(cfg.issue, push_tok)?,
        Err(e) => return Err(SliceError(e.to_string())),
    };
    let ours = crate::log::claimed_issues(&events(cfg))
        .get(&cfg.issue)
        .cloned();
    let (Some(upstream), Some((seat, fence))) = (taken, ours) else {
        return Err(SliceError(format!(
            "refs/claims/{} exists upstream and this floor's record does not own it; leave it alone",
            cfg.issue
        )));
    };
    if fence.0 == upstream.as_str() {
        record(
            log,
            repo,
            Kind::Note {
                text: format!(
                    "reusing this floor's claim on #{} (impl{seat}, fence {})",
                    cfg.issue,
                    upstream.short()
                ),
            },
        )?;
        return Ok(fence);
    }
    mirror.release_claim_ref(cfg.issue, &Fence(upstream.as_str().to_string()), push_tok)?;
    record(
        log,
        repo,
        Kind::Note {
            text: format!(
                "released this floor's stale claim on #{} ({} → {})",
                cfg.issue,
                upstream.short(),
                base.short()
            ),
        },
    )?;
    Ok(mirror.create_claim_ref(cfg.issue, base, push_tok)?)
}

/// Hand the claim back before returning an error (#656).
///
/// Every step between taking `refs/claims/<n>` and waking the seat used to
/// `?` straight out: a dirty seat worktree, a checkout that would not align,
/// an issue GitHub would not hand back. The ref stayed upstream, the record's
/// next word was nothing, and after a restart `claim`'s reuse path could not
/// prove the claim was this floor's — so every later tick refused with
/// `refs/claims/<n> exists upstream and this floor's record does not own it`,
/// wedged until somebody deleted the ref by hand. That is what happened to
/// #653 and #655 on 2026-09-15.
///
/// The release is what makes the retry clean, so it decides what the record
/// says next: released, and the issue is `Ready` again with the claim gone;
/// refused by upstream, and the `Claimed` event stands, which is exactly what
/// [`claim`]'s reuse path needs to adopt the ref next tick instead of walking
/// into `ClaimTaken`.
pub(super) fn release_and_refuse(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    mirror: &Mirror,
    fence: &Fence,
    push_tok: &str,
    why: String,
) -> SliceError {
    let freed = mirror.release_claim_ref(cfg.issue, fence, push_tok);
    let _ = record(
        log,
        repo,
        Kind::Refused {
            what: format!("#{}", cfg.issue),
            why: why.clone(),
        },
    );
    match freed {
        Ok(()) => {
            let _ = record(
                log,
                repo,
                Kind::Issue {
                    issue: cfg.issue,
                    to: crate::types::IssueState::Ready,
                },
            );
            SliceError(format!("{why}; claim released"))
        }
        // The record keeps the claim on purpose: the ref is still up there,
        // and only a record that owns it can take it back.
        Err(e) => SliceError(format!(
            "{why}; the claim on #{} could NOT be released ({e}) — the record keeps it so the next cycle can reuse that fence",
            cfg.issue
        )),
    }
}

/// Steps 7 and 8 of a cycle: sync the seat's branch from the mirror up to
/// GitHub, then open the draft PR under the impl App. Shared by the cycle
/// that produced the verdict and by the per-tick retry below.
///
/// A push upstream refuses *after* a valid `implemented` verdict, and that is
/// not a failed implementation (#602): the work exists, only the write is
/// missing — most often the App lacks `workflows: write` and the branch
/// touches `.github/workflows/`. So the claim stays, the branch stays, the
/// record gets a `pending-push` note carrying upstream's own words, and
/// `Ok(None)` means "nothing opened yet; retry the push next tick".
#[allow(clippy::too_many_arguments)]
pub(super) fn push_and_open_pr(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    mirror: &Mirror,
    tok: &str,
    push_tok: &str,
    seat_no: u8,
    branch: &str,
    head: &Sha,
    fence: &Fence,
    title: &str,
    summary: &str,
) -> Result<Option<String>, SliceError> {
    let mirror_head = mirror
        .branch_head(branch)?
        .ok_or_else(|| SliceError(format!("mirror has no {branch}")))?;
    if mirror_head != *head {
        return Err(SliceError(format!(
            "mirror {} != verdict head {}",
            mirror_head.short(),
            head.short()
        )));
    }
    let pushed = match mirror.sync_branch(branch, None, push_tok) {
        Ok(p) => p,
        // An earlier attempt whose push landed but whose PR create did not:
        // the expect-empty lease reads that as lost, and it is not a refusal.
        Err(MirrorError::LeaseLost { actual, .. }) if actual == head.as_str() => head.clone(),
        Err(e) if e.refusal().is_some() => {
            let why = e.refusal().unwrap_or_default().to_string();
            let pending = crate::log::PendingPush {
                issue: cfg.issue,
                seat: seat_no,
                branch: branch.to_string(),
                head: head.as_str().to_string(),
                why: why.clone(),
            };
            // One note per distinct reason: the retry runs every tick and a
            // record that repeats itself buries everything else.
            if crate::log::pending_pushes(&events(cfg)).get(&cfg.issue) != Some(&pending) {
                record(
                    log,
                    repo,
                    Kind::Note {
                        text: pending.note(),
                    },
                )?;
            }
            return Ok(None);
        }
        Err(e) => return Err(SliceError(e.to_string())),
    };
    record(
        log,
        repo,
        Kind::Promote {
            branch: branch.to_string(),
            from: "".into(),
            to: pushed.to_string(),
        },
    )?;

    let pr_body = format!("Closes #{}\n\nfwf-Provenance: fwf thin slice\nfwf-Seat: impl{seat_no}\nfwf-Fence: {}\n\n{summary}", cfg.issue, fence.0);
    let payload = serde_json::json!({ "title": format!("{title} (#{})", cfg.issue), "head": branch, "base": cfg.base_branch, "draft": true, "body": pr_body });
    let (code, body) = github::send_json("POST", tok, &format!("/repos/{repo}/pulls"), &payload)?;
    if code != 201 {
        return Err(SliceError(format!(
            "PR create refused ({code}): {}",
            body.chars().take(200).collect::<String>()
        )));
    }
    let pr_json: serde_json::Value = serde_json::from_str(&body)?;
    let pr_num = pr_json["number"].as_u64().unwrap_or(0);
    let url = pr_json["html_url"].as_str().unwrap_or("").to_string();
    record(
        log,
        repo,
        Kind::Pr {
            pr: pr_num,
            issue: Some(cfg.issue),
            to: PrState::Draft { head: pushed },
        },
    )?;
    Ok(Some(url))
}

/// Retry the push a cycle was refused, and open the PR if it lands (#602).
/// No seat is woken and no claim is taken: the verdict already exists, this
/// is the write it is still waiting on. `Ok(None)` means there is nothing
/// pending for `cfg.issue`, or the push was refused again.
pub fn retry_pending_push(
    cfg: &SliceConfig,
    app: &AppEntry,
    ops: Option<&AppEntry>,
) -> Result<Option<String>, SliceError> {
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let Some(pending) = crate::log::pending_pushes(&events(cfg))
        .get(&cfg.issue)
        .cloned()
    else {
        return Ok(None);
    };
    let head = Sha::parse(&pending.head)?;
    let fence = crate::log::claimed_issues(&events(cfg))
        .get(&cfg.issue)
        .map(|(_, f)| f.clone())
        .unwrap_or_else(|| Fence(head.as_str().to_string()));
    let mut log = Log::open(&cfg.run_log)?;
    let perms = BTreeMap::from([
        ("contents", "read"),
        ("pull_requests", "write"),
        ("issues", "read"),
        ("metadata", "read"),
    ]);
    let tok = github::mint(app, Some(&perms))?;
    let push_perms = BTreeMap::from([("contents", "write"), ("metadata", "read")]);
    let push_tok = github::mint(ops.unwrap_or(app), Some(&push_perms))?;
    let mirror = Mirror::init_with(
        &cfg.mirror_dir,
        &format!("https://github.com/{repo}.git"),
        &tok.token,
    )?;
    let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
    let title = poller
        .get(&format!(
            "https://api.github.com/repos/{repo}/issues/{}",
            cfg.issue
        ))?
        .and_then(|j| j["title"].as_str().map(str::to_string))
        .unwrap_or_default();
    push_and_open_pr(
        &mut log,
        &repo,
        cfg,
        &mirror,
        &tok.token,
        &push_tok.token,
        pending.seat,
        &pending.branch,
        &head,
        &fence,
        &title,
        "the seat's verdict; the push upstream was refused when it was written",
    )
}

/// A verdict that arrived after its seat was already called Stalled (#669).
pub(super) enum Late {
    /// Nothing usable on that path yet — `wait_verdict`'s own "not yet", and
    /// the loop asks again next tick.
    Wait,
    Implemented {
        branch: String,
        head: Sha,
        summary: String,
    },
    Blocked {
        reason: String,
    },
}

/// What the loop did with one stalled seat's verdict path this tick.
#[derive(Debug)]
pub enum Adopted {
    /// No verdict there (yet); the claim, the seat and the record stand.
    Nothing,
    /// Delivered as the cycle would have: the PR's URL, or `None` when
    /// upstream refused the push and the #602 retry owns it from here.
    Delivered(Option<String>),
    /// A late `blocked`: the claim is back and the issue is `Ready` again.
    Released(String),
}

/// Re-read the verdict path the wake pointed the seat at.
pub(super) fn late_verdict(cfg: &SliceConfig) -> Late {
    match crate::seat::read_verdict(&super::verdict_path(cfg)) {
        Ok(Some(Verdict::Implemented {
            branch,
            head,
            summary,
        })) => match Sha::parse(&head) {
            Ok(head) => Late::Implemented {
                branch,
                head,
                summary,
            },
            // A verdict whose head is not a sha is not a verdict yet, the same
            // way half-written JSON is not: say nothing, look again next tick.
            Err(_) => Late::Wait,
        },
        Ok(Some(Verdict::Blocked { reason })) => Late::Blocked { reason },
        // Some other role's verdict on this path, no file at all, or a file
        // that does not parse: all "not yet".
        Ok(Some(_)) | Ok(None) | Err(_) => Late::Wait,
    }
}

/// The record half of adopting a late verdict, with the two things that need
/// GitHub — the push/PR and the claim release — handed in, so the order of
/// events is exactly what a test can drive.
///
/// `Stalled` is not a verdict on the work: the pane was never killed, so a
/// seat past its deadline that finishes anyway has produced a real cycle. The
/// record says so — `Reported`, then whatever the verdict earned — and from
/// there QA and merge run as if it had been on time.
pub(super) fn adopt_with(
    log: &mut Log,
    repo: &str,
    cfg: &SliceConfig,
    seat_no: u8,
    late: Late,
    deliver: impl FnOnce(&mut Log, &str, &Sha, &str) -> Result<Option<String>, SliceError>,
    release: impl FnOnce() -> Result<(), SliceError>,
) -> Result<Adopted, SliceError> {
    let (branch, head, summary) = match late {
        Late::Wait => return Ok(Adopted::Nothing),
        Late::Implemented {
            branch,
            head,
            summary,
        } => (branch, head, summary),
        Late::Blocked { reason } => {
            reported(log, repo, cfg, seat_no)?;
            release()?;
            record(
                log,
                repo,
                Kind::Issue {
                    issue: cfg.issue,
                    to: IssueState::Ready,
                },
            )?;
            return Ok(Adopted::Released(reason));
        }
    };
    // Checked before the record says `Reported`, because that word is what
    // takes the issue out of `stalled_claims`: a verdict this stage refuses
    // must still be there to refuse again next tick.
    let expected = format!("impl{seat_no}/issue-{}-thin-slice", cfg.issue);
    if branch != expected {
        return Err(SliceError(format!(
            "the late verdict for #{} names branch {branch}, expected {expected}",
            cfg.issue
        )));
    }
    reported(log, repo, cfg, seat_no)?;
    Ok(Adopted::Delivered(deliver(log, &branch, &head, &summary)?))
}

/// The seat reported after all — said once, with the note that explains why
/// the record shows `Stalled` immediately before it.
fn reported(log: &mut Log, repo: &str, cfg: &SliceConfig, seat_no: u8) -> Result<(), SliceError> {
    record(
        log,
        repo,
        Kind::Seat {
            seat: seat_no,
            role: Role::Impl,
            to: SeatState::Reported {
                job: JobRef {
                    role: Role::Impl,
                    issue: Some(cfg.issue),
                    pr: None,
                },
            },
            tokens_in: None,
            tokens_out: None,
        },
    )?;
    record(
        log,
        repo,
        Kind::Note {
            text: format!(
                "adopted impl{seat_no}'s late verdict for #{}: it finished after the wait gave up",
                cfg.issue
            ),
        },
    )
}

/// Deliver the verdict a stalled seat wrote after its deadline (#669).
///
/// Run every tick for every claim [`crate::log::stalled_claims`] names, beside
/// the #602 push retry: no seat is woken and no claim is taken, because the
/// cycle already happened — this is only the write it never got. `Nothing`
/// costs no token: the path is read before anything is minted.
pub fn adopt_stalled_verdict(
    cfg: &SliceConfig,
    app: &AppEntry,
    ops: Option<&AppEntry>,
) -> Result<Adopted, SliceError> {
    let Some((seat_no, fence)) = crate::log::stalled_claims(&events(cfg))
        .get(&cfg.issue)
        .cloned()
    else {
        return Ok(Adopted::Nothing);
    };
    let late = late_verdict(cfg);
    if matches!(late, Late::Wait) {
        return Ok(Adopted::Nothing);
    }
    let repo = format!("{}/{}", cfg.owner, cfg.repo);
    let perms = BTreeMap::from([
        ("contents", "read"),
        ("pull_requests", "write"),
        ("issues", "read"),
        ("metadata", "read"),
    ]);
    let tok = github::mint(app, Some(&perms))?;
    let (push_app, push_perms) = super::push_token_mint(app, ops);
    let push_tok = github::mint(push_app, Some(&push_perms))?;
    let mirror = Mirror::init_with(
        &cfg.mirror_dir,
        &format!("https://github.com/{repo}.git"),
        &tok.token,
    )?;
    let poller = Poller::new("https://api.github.com", &tok.token, &cfg.owner, &cfg.repo);
    let title = poller
        .get(&format!(
            "https://api.github.com/repos/{repo}/issues/{}",
            cfg.issue
        ))?
        .and_then(|j| j["title"].as_str().map(str::to_string))
        .unwrap_or_default();
    let mut log = Log::open(&cfg.run_log)?;
    adopt_with(
        &mut log,
        &repo,
        cfg,
        seat_no,
        late,
        |log, branch, head, summary| {
            push_and_open_pr(
                log,
                &repo,
                cfg,
                &mirror,
                &tok.token,
                &push_tok.token,
                seat_no,
                branch,
                head,
                &fence,
                &title,
                summary,
            )
        },
        || {
            mirror
                .release_claim_ref(cfg.issue, &fence, &push_tok.token)
                .map_err(SliceError::from)
        },
    )
}
