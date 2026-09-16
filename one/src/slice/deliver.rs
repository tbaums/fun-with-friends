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
use crate::types::{Fence, PrState, Sha};
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
