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
pub fn pane_command(target: &str) -> Result<String, SeatError> {
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
    let buf =
        std::env::temp_dir().join(format!("fwfd-job-{}-{}.txt", std::process::id(), pane.seat));
    std::fs::write(&buf, &text).map_err(|e| SeatError::Tmux(e.to_string()))?;
    // Clear anything staged in the input box first (ghost text is never
    // ours to send; a stale draft must not be prepended to the job).
    tmux(&["send-keys", "-t", &pane.target, "Escape"])?;
    tmux(&["send-keys", "-t", &pane.target, "C-u"])?;
    let bufname = format!("fwfd-{}", pane.seat);
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

/// Wait for the verdict file. Returns Reported (with the verdict) or Stalled.
/// Never kills anything; the caller decides.
pub fn wait_verdict(
    job: &JobRef,
    verdict_path: &Path,
    deadline: u64,
    poll: Duration,
) -> Result<(SeatState, Option<Verdict>), SeatError> {
    let start = Instant::now();
    loop {
        if verdict_path.exists() {
            let text = std::fs::read_to_string(verdict_path)
                .map_err(|e| SeatError::Malformed(e.to_string()))?;
            let v: Verdict = serde_json::from_str(&text).map_err(|e| {
                SeatError::Malformed(format!(
                    "{e}: {}",
                    text.chars().take(120).collect::<String>()
                ))
            })?;
            return Ok((SeatState::Reported { job: job.clone() }, Some(v)));
        }
        if now() >= deadline {
            return Ok((SeatState::Stalled { job: job.clone() }, None));
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
            return Ok((SeatState::Stalled { job: job.clone() }, None));
        }
    }
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
        let session = format!("fwfd-fake-{}-{}", std::process::id(), seat);
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
}
