//! Seats: interactive Claude Code panes that the supervisor WAKES.
//!
//! Jamie's decision (2026-09-09): no `/loop` polling and no `claude -p` seats.
//! A seat is a warm tmux pane. It costs nothing while idle. The supervisor
//! types one job into it only when the scheduler has work, then waits for a
//! structured verdict file the seat writes when done. Liveness is not a tick
//! file: a seat is Working until its verdict appears or its deadline passes,
//! and the supervisor is the only thing that ever kills a pane.
//!
//! This module is deliberately small and testable against a *fake seat*: a
//! shell loop in a real tmux pane that reads the typed job and writes a
//! verdict, so the waker/reader contract is exercised without a model.

use crate::types::{JobRef, Role, SeatState};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// What a seat writes when it finishes a job. One file per job, atomic
/// rename, JSON. The supervisor performs every GitHub write from this; the
/// seat itself never holds a write token.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "verdict", rename_all = "snake_case")]
pub enum Verdict {
    /// Implementer: work is on `branch` in the local mirror; open/refresh a PR.
    Implemented {
        branch: String,
        head: String,
        summary: String,
    },
    /// QA: approve (anchored to the head it reviewed) or request changes.
    Reviewed {
        head: String,
        approve: bool,
        notes: String,
    },
    /// PM/GV: a triage verdict on an issue.
    Triaged { ready: bool, reason: String },
    /// PM: a spec for a gated issue; the supervisor writes it into the issue.
    Specced {
        title: String,
        body: String,
        #[serde(default)]
        discovery: bool,
        #[serde(default)]
        questions: Vec<String>,
    },
    /// The seat could not complete the job; the supervisor decides what next.
    Blocked { reason: String },
}

#[derive(Clone, Debug)]
pub struct Pane {
    /// tmux target, e.g. `fwf-build:impl1` or a `%id`.
    pub target: String,
    pub role: Role,
    pub seat: u8,
}

#[derive(Debug)]
pub enum SeatError {
    Tmux(String),
    NotIdle(String),
    Malformed(String),
}

impl std::fmt::Display for SeatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SeatError::Tmux(e) => write!(f, "tmux: {e}"),
            SeatError::NotIdle(w) => write!(f, "pane not idle: {w}"),
            SeatError::Malformed(w) => write!(f, "verdict malformed: {w}"),
        }
    }
}

fn tmux(args: &[&str]) -> Result<String, SeatError> {
    let out = Command::new("tmux")
        .args(args)
        .output()
        .map_err(|e| SeatError::Tmux(e.to_string()))?;
    if !out.status.success() {
        return Err(SeatError::Tmux(
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

pub fn tmux_available() -> bool {
    Command::new("tmux")
        .arg("-V")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// The foreground command in the pane. `claude` means a warm seat; `bash`/`zsh`
/// means the seat's process is gone (SeatState::Gone) even though the pane
/// exists — the old harness inferred this from tick files instead.
/// tmux resolves an unmatched `session:window` to the session's CURRENT
/// window, so a gone seat would read as whatever pane happens to be active.
/// Require an exact window-name match first; `%id` targets pass through.
pub fn window_exists(target: &str) -> Result<bool, SeatError> {
    let Some((session, window)) = target.split_once(':') else {
        return Ok(true);
    };
    let names = tmux(&["list-windows", "-t", session, "-F", "#{window_name}"])?;
    Ok(names.lines().any(|n| n.trim() == window))
}

pub fn pane_command(target: &str) -> Result<String, SeatError> {
    if !window_exists(target)? {
        return Ok("absent".into());
    }
    tmux(&[
        "display-message",
        "-p",
        "-t",
        target,
        "#{pane_current_command}",
    ])
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A name no other wake will use: the seat, this process, a counter within it,
/// and a nanosecond stamp.
///
/// Both namespaces a wake writes into are shared far wider than one seat (#586).
/// tmux's buffer namespace belongs to the *server*, so the loop's wake and a
/// hand-run `fwfd spec` both loaded `fwfd-1` and one's `paste-buffer -d`
/// deleted the other's buffer ("no buffer fwfd-1"). The temp dir is shared too:
/// two tests in one process waking seat 1 both wrote `fwfd-job-<pid>-1.txt` and
/// one removed the other's file mid-paste (ubuntu CI on PR #593). A unique name
/// per call replaces every lock this would otherwise need.
fn wake_token(seat: u8) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!(
        "{seat}-{}-{}-{nanos:09}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    )
}

/// Type one job into an idle pane. The job text ends with a line naming the
/// verdict path so the seat knows where to write. Returns the Working state.
pub fn wake(
    pane: &Pane,
    expect_cmd: &str,
    job: &JobRef,
    job_text: &str,
    verdict_path: &Path,
    timeout: Duration,
) -> Result<SeatState, SeatError> {
    let cmd = pane_command(&pane.target)?;
    // The native Claude Code install names its binary by version (e.g.
    // `2.1.266`), so a pane running claude reports that, not `claude`.
    let is_claude =
        expect_cmd == "claude" && cmd.chars().next().is_some_and(|c| c.is_ascii_digit());
    if cmd != expect_cmd && !is_claude {
        return Err(SeatError::NotIdle(format!(
            "{} is running {cmd}, expected {expect_cmd}",
            pane.target
        )));
    }
    if verdict_path.exists() {
        std::fs::remove_file(verdict_path).map_err(|e| SeatError::Tmux(e.to_string()))?;
    }
    let text = format!(
        "{job_text}\nWhen done, write your verdict JSON to: {}",
        verdict_path.display()
    );
    // Deliver the job as ONE bracketed paste (load-buffer + paste-buffer -p),
    // so a multi-line job lands in the input box intact instead of each line
    // being submitted as its own prompt; Enter is sent separately so a job
    // containing the word "Enter" is never interpreted as a key.
    // The job file and the tmux buffer both carry this wake's own token, so no
    // other wake — in this process or any other on this tmux server — can
    // delete either out from under us (#586).
    let token = wake_token(pane.seat);
    let buf = std::env::temp_dir().join(format!("fwfd-job-{token}.txt"));
    std::fs::write(&buf, &text).map_err(|e| SeatError::Tmux(e.to_string()))?;
    // Clear anything staged in the input box first (ghost text is never
    // ours to send; a stale draft must not be prepended to the job).
    tmux(&["send-keys", "-t", &pane.target, "Escape"])?;
    tmux(&["send-keys", "-t", &pane.target, "C-u"])?;
    let bufname = format!("fwfd-{token}");
    tmux(&[
        "load-buffer",
        "-b",
        &bufname,
        buf.to_str().unwrap_or_default(),
    ])?;
    tmux(&[
        "paste-buffer",
        "-p",
        "-d",
        "-b",
        &bufname,
        "-t",
        &pane.target,
    ])?;
    let _ = std::fs::remove_file(&buf);
    std::thread::sleep(Duration::from_millis(300));
    tmux(&["send-keys", "-t", &pane.target, "Enter"])?;
    Ok(SeatState::Working {
        job: job.clone(),
        deadline: now() + timeout.as_secs(),
    })
}

/// The whole verdict in `path`, if there is one there yet.
///
/// `Ok(None)` — no file (including one that vanished between two polls).
/// `Err(_)` — a file that is not a verdict *yet*: half-written by a seat that
/// redirected straight into `<path>` instead of writing `<path>.tmp` and
/// renaming, or JSON the seat typed by hand with an unescaped quote in it.
/// Both are "not yet" to [`wait_verdict`], never its answer.
fn read_verdict(path: &Path) -> Result<Option<Verdict>, SeatError> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(SeatError::Malformed(format!("unreadable: {e}"))),
    };
    serde_json::from_str(&text).map(Some).map_err(|e| {
        SeatError::Malformed(format!(
            "{e}; the file holds: {}",
            text.chars().take(400).collect::<String>()
        ))
    })
}

/// Wait for the verdict file. Returns Reported (with the verdict) or Stalled.
/// Never kills anything; the caller decides.
///
/// A verdict is a file that *parses*, not a file that exists (#587): `fwfd spec`
/// read a half-written `verdict-spec-1268.json` and failed outright, seconds
/// before the file held a valid verdict. So a read or parse failure is simply
/// "not yet" and polling continues to the deadline; only the deadline decides,
/// and it says Stalled — with the parse error and the raw text on stderr, so a
/// seat that hand-typed its JSON can be seen doing it.
pub fn wait_verdict(
    job: &JobRef,
    verdict_path: &Path,
    deadline: u64,
    poll: Duration,
) -> Result<(SeatState, Option<Verdict>), SeatError> {
    let start = Instant::now();
    let mut last_bad: Option<SeatError> = None;
    loop {
        match read_verdict(verdict_path) {
            Ok(Some(v)) => return Ok((SeatState::Reported { job: job.clone() }, Some(v))),
            Ok(None) => {}
            Err(e) => last_bad = Some(e),
        }
        if now() >= deadline {
            break;
        }
        std::thread::sleep(poll);
        if start.elapsed()
            > Duration::from_secs(
                deadline
                    .saturating_sub(now())
                    .saturating_add(poll.as_secs() * 2),
            )
            && now() >= deadline
        {
            break;
        }
    }
    // Stalled. If something was there but never became a verdict, say what it
    // was: the caller turns Stalled into a non-zero exit either way, and this
    // is the only record of why a present file did not count.
    if let Some(e) = last_bad {
        eprintln!(
            "fwfd: {} never became a verdict by the deadline: {e}",
            verdict_path.display()
        );
    }
    Ok((SeatState::Stalled { job: job.clone() }, None))
}

/// Kill a pane. The supervisor is the only caller; nothing else in the
/// system ever signals a seat.
pub fn kill(pane: &Pane) -> Result<(), SeatError> {
    tmux(&["kill-pane", "-t", &pane.target]).map(|_| ())
}

/// A fake seat for tests: a tmux session whose pane runs a shell loop that
/// reads each typed line and, on the line starting with `JOB`, writes the
/// verdict named in the job to the path named in the job. Its foreground
/// command is `bash`, which the tests pass as `expect_cmd`.
pub struct FakeSeat {
    pub session: String,
    pub pane: Pane,
    _dir: PathBuf,
}

impl FakeSeat {
    pub fn spawn(role: Role, seat: u8) -> Result<FakeSeat, SeatError> {
        // Unique per spawn, like a wake's own names: two fakes may stand for the
        // same seat number in different roles, which is the case #586 broke.
        let session = format!("fwfd-fake-{}", wake_token(seat));
        let dir = std::env::temp_dir().join(&session);
        std::fs::create_dir_all(&dir).map_err(|e| SeatError::Tmux(e.to_string()))?;
        let script = dir.join("seat.sh");
        // The loop: on a JOB line, parse `verdict=<json-file-to-copy> path=<out>`;
        // "stall" as the verdict name means never answer (for the Stalled test).
        std::fs::write(
            &script,
            r#"#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    "When done, write your verdict JSON to: "*) out="${line#When done, write your verdict JSON to: }"; if [ "$mode" != stall ]; then printf '%s' "$verdict" > "$out.tmp" && mv "$out.tmp" "$out"; fi ;;
    JOB*) mode="${line#JOB }"; verdict="${line#*verdict=}"; verdict="${verdict%% mode=*}"; mode="${line##*mode=}" ;;
  esac
done
"#,
        )
        .map_err(|e| SeatError::Tmux(e.to_string()))?;
        tmux(&[
            "new-session",
            "-d",
            "-s",
            &session,
            "-x",
            "120",
            "-y",
            "20",
            "bash",
            script.to_str().unwrap(),
        ])?;
        // wait until the pane reports bash as its command
        for _ in 0..50 {
            if pane_command(&session).map(|c| c == "bash").unwrap_or(false) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Ok(FakeSeat {
            pane: Pane {
                target: session.clone(),
                role,
                seat,
            },
            session,
            _dir: dir,
        })
    }
}

impl Drop for FakeSeat {
    fn drop(&mut self) {
        let _ = tmux(&["kill-session", "-t", &self.session]);
        let _ = std::fs::remove_dir_all(&self._dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job() -> JobRef {
        JobRef {
            role: Role::Impl,
            issue: Some(41),
            pr: None,
        }
    }

    /// A seat that writes straight into `<path>` instead of `<path>.tmp` + `mv`,
    /// in two chunks with a pause between them — transom #1268's `fwfd spec`
    /// (#587). The reader must see the half-written file as "not yet".
    fn sloppy_writer(path: PathBuf, text: String, finish: bool) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            let (head, tail) = text.split_at(text.len() / 2);
            std::fs::write(&path, head).unwrap();
            std::thread::sleep(Duration::from_millis(400));
            if finish {
                std::fs::write(&path, format!("{head}{tail}")).unwrap();
            }
        })
    }

    #[test]
    fn a_half_written_verdict_is_not_yet_and_the_finished_one_is_read() {
        let dir = std::env::temp_dir().join(format!("fwfd-partial-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let out = dir.join("verdict-spec-1268.json");
        let text = serde_json::json!({
            "verdict": "specced", "title": "a spec", "body": "the body", "discovery": false
        })
        .to_string();
        let w = sloppy_writer(out.clone(), text, true);
        // polls much faster than the writer's pause, so the partial file IS seen
        let (st, v) = wait_verdict(&job(), &out, now() + 10, Duration::from_millis(20))
            .expect("a partial read is not an error");
        w.join().unwrap();
        assert!(matches!(st, SeatState::Reported { .. }), "{st:?}");
        assert!(
            matches!(v, Some(Verdict::Specced { ref title, .. }) if title == "a spec"),
            "{v:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_verdict_that_never_parses_is_stalled_at_the_deadline_not_an_error() {
        let dir = std::env::temp_dir().join(format!("fwfd-unparsable-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // the write that never completes
        let out = dir.join("verdict-spec-1.json");
        let w = sloppy_writer(
            out.clone(),
            serde_json::json!({"verdict": "triaged", "ready": true, "reason": "ok"}).to_string(),
            false,
        );
        let (st, v) = wait_verdict(&job(), &out, now() + 1, Duration::from_millis(20))
            .expect("an unfinished write is not an error");
        w.join().unwrap();
        assert!(matches!(st, SeatState::Stalled { .. }), "{st:?}");
        assert!(v.is_none());
        // and the file the seat typed by hand, quotes and all: complete, valid
        // UTF-8, not JSON. Still Stalled, still not an error (#587's round two).
        let typed = dir.join("verdict-triage-579.json");
        std::fs::write(
            &typed,
            "{\"verdict\":\"triaged\",\"ready\":true,\"reason\":\"it[\"user\"][\"login\"] is empty\"}",
        )
        .unwrap();
        let (st, v) = wait_verdict(&job(), &typed, now() + 1, Duration::from_millis(20)).unwrap();
        assert!(matches!(st, SeatState::Stalled { .. }), "{st:?}");
        assert!(v.is_none(), "a tolerant read must not invent a verdict");
        // syntactically valid JSON that is not a verdict is also not one
        let empty = dir.join("verdict-empty.json");
        std::fs::write(&empty, "{}").unwrap();
        let (st, v) = wait_verdict(&job(), &empty, now() + 1, Duration::from_millis(20)).unwrap();
        assert!(matches!(st, SeatState::Stalled { .. }), "{st:?}");
        assert!(v.is_none());
        // a file that disappears between polls is "not yet", not a failure
        let gone = dir.join("verdict-gone.json");
        std::fs::write(&gone, "{\"verdict\":\"blocked\"").unwrap();
        let g = gone.clone();
        let rm = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            std::fs::remove_file(&g).unwrap();
        });
        let (st, v) = wait_verdict(&job(), &gone, now() + 1, Duration::from_millis(20)).unwrap();
        rm.join().unwrap();
        assert!(matches!(st, SeatState::Stalled { .. }), "{st:?}");
        assert!(v.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #586: the names a wake writes into are shared with every other wake on
    /// the machine, so they have to differ per call — including two calls for
    /// the same seat in one process (two tests in one `cargo test`, which is how
    /// ubuntu CI found it).
    #[test]
    fn every_wake_gets_names_no_other_wake_will_use() {
        let mine = wake_token(1);
        assert_ne!(mine, wake_token(1));
        assert!(mine.starts_with("1-"), "{mine}");
        assert!(
            mine.contains(&std::process::id().to_string()),
            "{mine} lacks the pid"
        );
        // many at once, from several threads, all distinct
        let made: Vec<String> = std::thread::scope(|s| {
            let hs: Vec<_> = (0..4)
                .map(|_| s.spawn(|| (0..250).map(|_| wake_token(1)).collect::<Vec<_>>()))
                .collect();
            hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
        });
        let uniq: std::collections::BTreeSet<&String> = made.iter().collect();
        assert_eq!(uniq.len(), made.len(), "{} of {}", uniq.len(), made.len());
        // and a name tmux and the filesystem both accept
        assert!(made
            .iter()
            .all(|t| t.chars().all(|c| c.is_ascii_digit() || c == '-')));
    }

    /// #586: two logical seats that share a seat number — the loop's GV seat 1
    /// and a hand-run `fwfd spec` seat 1 — woken at the same time. Both wakes
    /// land, and each pane gets ITS OWN job, not the other's.
    #[test]
    fn two_concurrent_wakes_for_the_same_seat_number_do_not_steal_each_others_buffer() {
        if !tmux_available() {
            eprintln!("skip: no tmux");
            return;
        }
        let one = FakeSeat::spawn(Role::Gv, 1).unwrap();
        let two = FakeSeat::spawn(Role::Pm, 1).unwrap();
        assert_eq!(one.pane.seat, two.pane.seat);
        assert_ne!(one.pane.target, two.pane.target, "different tmux sessions");
        let dir = std::env::temp_dir().join(format!("fwfd-race-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // distinct job texts, so a stolen buffer shows up as the wrong verdict
        let plan = |n: u8, fake: &FakeSeat| {
            let out = dir.join(format!("verdict-{n}.json"));
            let verdict = serde_json::json!({
                "verdict": "triaged", "ready": true, "reason": format!("seat {n} did its own job")
            })
            .to_string();
            (
                out,
                format!("JOB verdict={verdict} mode=answer"),
                fake.pane.clone(),
            )
        };
        let (out1, text1, pane1) = plan(1, &one);
        let (out2, text2, pane2) = plan(2, &two);
        let go = |pane: Pane, text: String, out: std::path::PathBuf| {
            move || -> Result<(SeatState, Option<Verdict>), SeatError> {
                let st = wake(&pane, "bash", &job(), &text, &out, Duration::from_secs(20))?;
                let deadline = match st {
                    SeatState::Working { deadline, .. } => deadline,
                    other => panic!("expected Working, got {other:?}"),
                };
                wait_verdict(&job(), &out, deadline, Duration::from_millis(100))
            }
        };
        let (a, b) = std::thread::scope(|s| {
            let h1 = s.spawn(go(pane1, text1, out1));
            let h2 = s.spawn(go(pane2, text2, out2));
            (h1.join().unwrap(), h2.join().unwrap())
        });
        // neither wake hit "no buffer", and neither job file went missing
        let (st1, v1) = a.expect("seat 1's wake");
        let (st2, v2) = b.expect("seat 2's wake");
        assert!(matches!(st1, SeatState::Reported { .. }), "{st1:?}");
        assert!(matches!(st2, SeatState::Reported { .. }), "{st2:?}");
        let reason = |v: Option<Verdict>| match v {
            Some(Verdict::Triaged { reason, .. }) => reason,
            other => panic!("expected a triaged verdict, got {other:?}"),
        };
        assert_eq!(reason(v1), "seat 1 did its own job");
        assert_eq!(reason(v2), "seat 2 did its own job");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn verdict_round_trips_and_rejects_garbage() {
        let v = Verdict::Reviewed {
            head: "a".repeat(40),
            approve: true,
            notes: "ok".into(),
        };
        let j = serde_json::to_string(&v).unwrap();
        assert!(j.contains("\"verdict\":\"reviewed\""));
        assert_eq!(serde_json::from_str::<Verdict>(&j).unwrap(), v);
        assert!(serde_json::from_str::<Verdict>("{\"verdict\":\"nope\"}").is_err());
    }

    #[test]
    fn wake_types_a_job_and_reads_the_verdict_back() {
        if !tmux_available() {
            eprintln!("skip: no tmux");
            return;
        }
        let fake = FakeSeat::spawn(Role::Impl, 1).unwrap();
        let out = std::env::temp_dir().join(format!("fwfd-verdict-{}.json", std::process::id()));
        let verdict = serde_json::json!({"verdict":"implemented","branch":"impl1/issue-41","head":"b".repeat(40),"summary":"did it"}).to_string();
        let job_text = format!("JOB verdict={verdict} mode=answer");
        let st = wake(
            &fake.pane,
            "bash",
            &job(),
            &job_text,
            &out,
            Duration::from_secs(10),
        )
        .unwrap();
        let deadline = match st {
            SeatState::Working { deadline, .. } => deadline,
            other => panic!("expected Working, got {other:?}"),
        };
        let (st, v) = wait_verdict(&job(), &out, deadline, Duration::from_millis(100)).unwrap();
        assert!(matches!(st, SeatState::Reported { .. }), "{st:?}");
        assert!(
            matches!(v, Some(Verdict::Implemented { ref branch, .. }) if branch == "impl1/issue-41")
        );
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_silent_seat_is_stalled_not_dead_and_is_not_killed() {
        if !tmux_available() {
            eprintln!("skip: no tmux");
            return;
        }
        let fake = FakeSeat::spawn(Role::Qa, 2).unwrap();
        let out = std::env::temp_dir().join(format!("fwfd-stall-{}.json", std::process::id()));
        let job_text = "JOB verdict={} mode=stall".to_string();
        let st = wake(
            &fake.pane,
            "bash",
            &job(),
            &job_text,
            &out,
            Duration::from_secs(1),
        )
        .unwrap();
        let deadline = match st {
            SeatState::Working { deadline, .. } => deadline,
            _ => unreachable!(),
        };
        let (st, v) = wait_verdict(&job(), &out, deadline, Duration::from_millis(100)).unwrap();
        assert!(matches!(st, SeatState::Stalled { .. }), "{st:?}");
        assert!(v.is_none());
        // the pane is still there: stalled is a verdict about the job, not the seat
        assert_eq!(pane_command(&fake.pane.target).unwrap(), "bash");
    }

    #[test]
    fn wake_refuses_a_pane_that_is_not_running_the_expected_command() {
        if !tmux_available() {
            eprintln!("skip: no tmux");
            return;
        }
        let fake = FakeSeat::spawn(Role::Impl, 3).unwrap();
        let out = std::env::temp_dir().join("fwfd-never.json");
        let err = wake(
            &fake.pane,
            "claude",
            &job(),
            "JOB",
            &out,
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert!(matches!(err, SeatError::NotIdle(_)), "{err}");
    }

    #[test]
    fn an_unmatched_window_name_is_absent_not_the_current_pane() {
        let fake = FakeSeat::spawn(Role::Impl, 9).unwrap();
        // tmux itself would resolve `session:no-such` to the current window.
        let cmd = pane_command(&format!("{}:no-such-window", fake.session)).unwrap();
        assert_eq!(cmd, "absent");
        assert!(
            window_exists(&fake.session).unwrap(),
            "a bare session target passes through"
        );
    }
}
