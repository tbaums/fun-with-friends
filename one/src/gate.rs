//! T-19 — the gate runner.
//!
//! One suite, one sha, one venue, one verdict. The venue caps memory and
//! the supervisor caps wall-clock time; nothing else ever kills a gate.
//! Every exit is mapped onto [`GateState`]: 0 → `Green`, non-zero → `Red`
//! (with the failure count parsed from the last lines of the log when the
//! runner printed one), and a kill by the cap or the clock → `Killed`.
//! A verdict, once reached, is written to
//! `<workdir>/.fwfd/gate/<sha>-<suite>.json` and a second `run` for the same
//! (sha, suite) returns it without starting a process.

use crate::types::{GateState, Sha};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

extern "C" {
    /// libc `kill(2)`; std links libc already, so no crate is needed.
    fn kill(pid: i32, sig: i32) -> i32;
}
const SIGKILL: i32 = 9;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Venue {
    /// `sh -c cmd` in `workdir`, no memory cap (dev / tests only).
    Local,
    /// `container run --rm --memory {n}g -v workdir:/work -w /work image sh -c cmd`.
    AppleContainer { image: String },
    /// `systemd-run --scope -p MemoryMax={n}G -p RuntimeMaxSec=… sh -c cmd`.
    SystemdRun,
}

#[derive(Clone, Debug)]
pub struct Gate {
    pub venue: Venue,
    pub memory_gb: u32,
    pub timeout: Duration,
    pub workdir: PathBuf,
}

impl Gate {
    pub fn verdict_path(&self, sha: &Sha, suite: &str) -> PathBuf {
        self.workdir
            .join(".fwfd/gate")
            .join(format!("{}-{}.json", sha.as_str(), suite))
    }

    /// The recorded verdict for (sha, suite), if one exists and parses.
    pub fn recorded(&self, sha: &Sha, suite: &str) -> Option<GateState> {
        let text = fs::read_to_string(self.verdict_path(sha, suite)).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// Drop a recorded verdict (the "re-run once" path for `Killed`).
    pub fn forget(&self, sha: &Sha, suite: &str) -> std::io::Result<()> {
        match fs::remove_file(self.verdict_path(sha, suite)) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            r => r,
        }
    }

    /// Run `cmd` for `suite` at `sha`, stdout+stderr appended to `log_path`.
    /// Idempotent: a recorded verdict is returned without running anything.
    pub fn run(&self, sha: &Sha, suite: &str, cmd: &str, log_path: &Path) -> GateState {
        if let Some(v) = self.recorded(sha, suite) {
            return v;
        }
        // The workdir must BE the sha under test. A checkout that failed to
        // update (mirror not fetched, wrong branch) would otherwise produce
        // a verdict for one tree and record it against another — found live
        // on fwf a632811 (gate-wt was still at 4ccf8d3). Unknown, not
        // recorded: the gate did not run.
        if let Some(head) = workdir_head(&self.workdir) {
            if head != sha.as_str() {
                eprintln!(
                    "gate: workdir {} is at {} not {}; refusing to run",
                    self.workdir.display(),
                    &head[..8.min(head.len())],
                    sha.short()
                );
                return GateState::Unknown;
            }
        }
        let verdict = self.run_uncached(sha, suite, cmd, log_path);
        if !matches!(verdict, GateState::Unknown) {
            self.record(sha, suite, &verdict);
        }
        verdict
    }

    fn record(&self, sha: &Sha, suite: &str, v: &GateState) {
        let path = self.verdict_path(sha, suite);
        let Some(dir) = path.parent() else { return };
        if fs::create_dir_all(dir).is_err() {
            return;
        }
        let tmp = path.with_extension(format!("tmp{}", std::process::id()));
        if let Ok(text) = serde_json::to_string(v) {
            if fs::write(&tmp, text).is_ok() {
                let _ = fs::rename(&tmp, &path);
            }
        }
    }

    fn command(&self, sha: &Sha, suite: &str, cmd: &str) -> (Command, Option<String>) {
        match &self.venue {
            Venue::Local => {
                // pipefail: a suite that ends in `| tail` must not turn Red into Green.
                let mut c = Command::new("bash");
                c.arg("-o")
                    .arg("pipefail")
                    .arg("-c")
                    .arg(cmd)
                    .current_dir(&self.workdir);
                (c, None)
            }
            Venue::AppleContainer { image } => {
                let name = format!("fwf-gate-{}-{}-{}", sha.short(), suite, std::process::id());
                let mut c = Command::new("container");
                c.arg("run")
                    .arg("--rm")
                    .arg("--name")
                    .arg(&name)
                    .arg("--memory")
                    .arg(format!("{}g", self.memory_gb))
                    .arg("-v")
                    .arg(format!("{}:/work", self.workdir.display()))
                    .arg("-w")
                    .arg("/work")
                    .arg(image)
                    .arg("sh")
                    .arg("-c")
                    .arg(cmd);
                (c, Some(name))
            }
            Venue::SystemdRun => {
                let mut c = Command::new("systemd-run");
                c.arg("--scope")
                    .arg("--quiet")
                    .arg(NO_ASK_PASSWORD)
                    .arg("-p")
                    .arg(format!("MemoryMax={}G", self.memory_gb))
                    .arg("-p")
                    .arg(format!("RuntimeMaxSec={}", self.timeout.as_secs().max(1)))
                    .arg("bash")
                    .arg("-o")
                    .arg("pipefail")
                    .arg("-c")
                    .arg(cmd)
                    .current_dir(&self.workdir);
                (c, None)
            }
        }
    }

    /// Can this venue run a trivial command at all? A venue that cannot (no
    /// systemd user bus on a CI runner, no container runtime) must yield
    /// Killed, never a Red that reads as "the suite failed".
    pub fn venue_preflight(&self) -> Result<(), String> {
        match self.venue {
            Venue::Local => Ok(()),
            Venue::SystemdRun => {
                let mut c = Command::new("systemd-run");
                c.args(SYSTEMD_PREFLIGHT_ARGS);
                match bounded_check(c, PREFLIGHT_TIMEOUT)? {
                    Check::Ok => Ok(()),
                    Check::Refused(why) => Err(format!("systemd-run --scope refused: {why}")),
                    Check::TimedOut => Err(format!(
                        "systemd-run preflight timed out after {}s",
                        PREFLIGHT_TIMEOUT.as_secs()
                    )),
                }
            }
            Venue::AppleContainer { .. } => {
                let out = Command::new("container")
                    .args(["system", "status"])
                    .output()
                    .map_err(|e| format!("container: {e}"))?;
                if out.status.success() {
                    Ok(())
                } else {
                    Err("container runtime is not running (`container system start`)".into())
                }
            }
        }
    }

    fn run_uncached(&self, sha: &Sha, suite: &str, cmd: &str, log_path: &Path) -> GateState {
        let killed = |reason: String| GateState::Killed {
            sha: sha.clone(),
            suite: suite.to_string(),
            reason,
        };
        let log = match open_log(log_path) {
            Ok(f) => f,
            Err(e) => return killed(format!("cannot open log {}: {e}", log_path.display())),
        };
        let log_start = log.metadata().map(|m| m.len()).unwrap_or(0);
        if let Err(why) = self.venue_preflight() {
            return killed(format!("venue unavailable: {why}"));
        }
        let (mut command, container_name) = self.command(sha, suite, cmd);
        let err_log = match log.try_clone() {
            Ok(f) => f,
            Err(e) => return killed(format!("cannot clone log handle: {e}")),
        };
        command
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(err_log))
            .process_group(0);
        let started = Instant::now();
        let mut child = match command.spawn() {
            Ok(c) => c,
            Err(e) => return killed(format!("spawn failed: {e}")),
        };
        let outcome = wait_or_kill(&mut child, self.timeout, container_name.as_deref());
        let secs = started.elapsed().as_secs();
        match outcome {
            Outcome::TimedOut => killed(format!("timeout after {}s", self.timeout.as_secs())),
            Outcome::Exited(status) => match status.code() {
                Some(0) => GateState::Green {
                    sha: sha.clone(),
                    suite: suite.to_string(),
                    secs,
                },
                Some(137) => killed(match self.venue {
                    Venue::Local => "killed (exit 137)".into(),
                    _ => "oom or killed".into(),
                }),
                Some(143) => killed("terminated (exit 143)".into()),
                Some(_code) => GateState::Red {
                    sha: sha.clone(),
                    suite: suite.to_string(),
                    failed: parse_failed(log_path, log_start).unwrap_or(1).max(1),
                    // a non-zero exit with no parsable count is at least one
                    // failure; `code` is in the log, not the verdict
                },
                None => killed(format!("killed by signal {}", status.signal().unwrap_or(0))),
            },
        }
    }
}

/// Never let a venue check ask a human anything (#684).
///
/// As a non-root user, `systemd-run --scope` needs polkit authorization; with
/// a controlling tty it registers a tty password agent and waits for a
/// password nobody is going to type. On a floor under tmux that is not a
/// slow failure, it is no failure at all: the operator measured 17+ minutes
/// before killing the child by hand, and `stdin=/dev/null` did not help —
/// the agent keys off the ctty, not stdin. With this flag the same denial
/// comes back as a refusal in milliseconds; where the action is already
/// permitted (root, or a polkit rule that allows it) the flag does nothing.
const NO_ASK_PASSWORD: &str = "--no-ask-password";

/// The venue check: can this box run a trivial scope at all?
const SYSTEMD_PREFLIGHT_ARGS: [&str; 6] = [
    "--scope",
    "--quiet",
    NO_ASK_PASSWORD,
    "-p",
    "MemoryMax=1G",
    "true",
];

/// How long a venue check may take before the venue is called unusable.
/// Its own clock, deliberately far shorter than the suite's: `true` under an
/// authorized scope returns in well under a second, and a check that has not
/// answered in five is the thing this bound exists for — whatever the reason,
/// not only the polkit one above.
const PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(5);

/// What a venue check came to.
enum Check {
    Ok,
    /// It answered, and the answer was no. Carries the child's stderr.
    Refused(String),
    /// It did not answer inside the bound, and has been killed.
    TimedOut,
}

/// Run one venue check under its own clock: its own process group (so the
/// kill reaches whatever it spawned), no stdin to read, stderr kept for the
/// refusal. `Err` is a check that could not be started at all.
fn bounded_check(mut cmd: Command, timeout: Duration) -> Result<Check, String> {
    use std::io::Read as _;
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| format!("{:?}: {e}", cmd.get_program()))?;
    match wait_or_kill(&mut child, timeout, None) {
        Outcome::TimedOut => Ok(Check::TimedOut),
        Outcome::Exited(status) if status.success() => Ok(Check::Ok),
        Outcome::Exited(_) => {
            let mut why = String::new();
            if let Some(mut err) = child.stderr.take() {
                let _ = err.read_to_string(&mut why);
            }
            Ok(Check::Refused(why.trim().to_string()))
        }
    }
}

enum Outcome {
    Exited(ExitStatus),
    TimedOut,
}

/// Poll the child until it exits or the wall clock runs out; on timeout kill
/// its whole process group (and the named container, if any) and reap it.
fn wait_or_kill(child: &mut Child, timeout: Duration, container: Option<&str>) -> Outcome {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Outcome::Exited(status),
            Ok(None) => {}
            Err(_) => return Outcome::TimedOut,
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    if let Some(name) = container {
        // The CLI client is only a proxy for the VM; ask the runtime to kill
        // the container itself, then fall through to the group kill.
        let _ = Command::new("container")
            .args(["kill", name])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    kill_group(child.id());
    let _ = child.wait();
    Outcome::TimedOut
}

/// `process_group(0)` made the child its own group leader: pgid == pid.
fn kill_group(pid: u32) {
    let pid = pid as i32;
    // SAFETY: plain libc kill(2) with a negative pid targets the group.
    unsafe {
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
    }
}

/// HEAD of a git checkout, or None when the workdir is not a checkout (tests
/// use bare scratch directories).
fn workdir_head(dir: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(dir)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn open_log(path: &Path) -> std::io::Result<File> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            fs::create_dir_all(dir)?;
        }
    }
    OpenOptions::new().create(true).append(true).open(path)
}

/// "N failed" from the last lines the runner wrote (cargo: `3 failed;`,
/// pytest: `3 failed,`, go/jest variants). Only the part of the log this
/// run appended is read, scanning from the end.
fn parse_failed(log_path: &Path, from: u64) -> Option<u32> {
    let mut f = File::open(log_path).ok()?;
    f.seek(SeekFrom::Start(from)).ok()?;
    let lines: Vec<String> = BufReader::new(f).lines().map_while(Result::ok).collect();
    let tail = lines.iter().rev().take(40);
    for line in tail {
        let toks: Vec<&str> = line.split_whitespace().collect();
        for (i, t) in toks.iter().enumerate() {
            let t = t.trim_matches(|c: char| !c.is_ascii_alphanumeric());
            if t.eq_ignore_ascii_case("failed") && i > 0 {
                let n = toks[i - 1].trim_matches(|c: char| !c.is_ascii_digit());
                if let Ok(n) = n.parse::<u32>() {
                    return Some(n);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sha(c: char) -> Sha {
        Sha::parse(&std::iter::repeat_n(c, 40).collect::<String>()).unwrap()
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fwfd-gate-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn local(dir: &Path, timeout: Duration) -> Gate {
        Gate {
            venue: Venue::Local,
            memory_gb: 1,
            timeout,
            workdir: dir.to_path_buf(),
        }
    }

    #[test]
    fn exit_zero_is_green_and_log_captured() {
        let d = scratch("green");
        let g = local(&d, Duration::from_secs(10));
        let log = d.join("logs/fast.log");
        let v = g.run(&sha('a'), "fast", "echo hello; echo err >&2; exit 0", &log);
        assert!(
            matches!(v, GateState::Green { secs, .. } if secs < 10),
            "{v:?}"
        );
        let text = fs::read_to_string(&log).unwrap();
        assert!(text.contains("hello") && text.contains("err"), "{text}");
        assert!(g.verdict_path(&sha('a'), "fast").exists());
    }

    #[test]
    fn nonzero_is_red_with_parsed_count() {
        let d = scratch("red");
        let g = local(&d, Duration::from_secs(10));
        let v = g.run(
            &sha('b'),
            "fast",
            "echo running; echo 'test result: FAILED. 2 passed; 3 failed; 0 ignored'; exit 1",
            &d.join("red.log"),
        );
        assert_eq!(
            v,
            GateState::Red {
                sha: sha('b'),
                suite: "fast".into(),
                failed: 3
            }
        );
        // no count in the output → at least one failure
        let v = g.run(&sha('c'), "fast", "exit 2", &d.join("red2.log"));
        assert!(matches!(v, GateState::Red { failed: 1, .. }), "{v:?}");
    }

    #[test]
    fn timeout_kills_the_whole_group_and_leaves_no_orphan() {
        let d = scratch("timeout");
        let g = local(&d, Duration::from_secs(1));
        // a unique sleep so `ps` can find (or not find) this exact grandchild
        let marker = format!("30.{}", std::process::id());
        let cmd = format!("sleep {marker}; echo never");
        let t0 = Instant::now();
        let v = g.run(&sha('d'), "slow", &cmd, &d.join("slow.log"));
        assert!(
            t0.elapsed() < Duration::from_secs(5),
            "took {:?}",
            t0.elapsed()
        );
        assert!(
            matches!(&v, GateState::Killed { reason, .. } if reason.starts_with("timeout")),
            "{v:?}"
        );
        // the grandchild `sleep` (reparented after sh died) must be gone
        let mut alive = true;
        for _ in 0..20 {
            let ps = Command::new("ps")
                .args(["-axo", "command="])
                .output()
                .unwrap();
            let out = String::from_utf8_lossy(&ps.stdout);
            alive = out.lines().any(|l| l.contains(&format!("sleep {marker}")));
            if !alive {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(!alive, "orphaned `sleep {marker}` survived the group kill");
        assert!(!fs::read_to_string(d.join("slow.log"))
            .unwrap()
            .contains("never"));
    }

    #[test]
    fn second_run_returns_the_recorded_verdict_without_a_process() {
        let d = scratch("idem");
        let g = local(&d, Duration::from_secs(10));
        let stamp = d.join("ran");
        let cmd = format!("touch {}; exit 0", stamp.display());
        let first = g.run(&sha('e'), "fast", &cmd, &d.join("a.log"));
        assert!(matches!(first, GateState::Green { .. }));
        fs::remove_file(&stamp).unwrap();
        // a different command, same (sha, suite): must not run, must not go Red
        let second = g.run(
            &sha('e'),
            "fast",
            "touch should-not-exist; exit 1",
            &d.join("b.log"),
        );
        assert_eq!(second, first);
        assert!(!stamp.exists() && !d.join("should-not-exist").exists());
        assert!(!d.join("b.log").exists(), "no log means no process");
        // a different suite for the same sha is its own verdict
        let other = g.run(&sha('e'), "e2e", "exit 1", &d.join("c.log"));
        assert!(matches!(other, GateState::Red { .. }));
        // forget → runs again
        g.forget(&sha('e'), "fast").unwrap();
        let third = g.run(&sha('e'), "fast", "exit 1", &d.join("d.log"));
        assert!(matches!(third, GateState::Red { .. }));
    }

    #[test]
    fn signal_exit_is_killed_not_red() {
        let d = scratch("sig");
        let g = local(&d, Duration::from_secs(10));
        let v = g.run(&sha('f'), "fast", "kill -9 $$", &d.join("sig.log"));
        assert!(matches!(v, GateState::Killed { .. }), "{v:?}");
        let v = g.run(&sha('f'), "e2e", "exit 137", &d.join("sig2.log"));
        assert!(
            matches!(&v, GateState::Killed { reason, .. } if reason.contains("137")),
            "{v:?}"
        );
    }

    // ---- Apple container -------------------------------------------------

    /// `container system status` says running and alpine is cached; else why not.
    fn container_ready() -> Result<(), String> {
        let st = Command::new("container")
            .args(["system", "status"])
            .output()
            .map_err(|e| format!("`container` not runnable: {e}"))?;
        let out = String::from_utf8_lossy(&st.stdout);
        if !out
            .lines()
            .any(|l| l.starts_with("status") && l.contains("running"))
        {
            return Err(format!("container system not running:\n{out}"));
        }
        let imgs = Command::new("container")
            .args(["image", "list"])
            .output()
            .map_err(|e| e.to_string())?;
        if !String::from_utf8_lossy(&imgs.stdout).contains("alpine") {
            return Err("alpine image not cached (would pull)".into());
        }
        Ok(())
    }

    fn apple(dir: &Path) -> Gate {
        Gate {
            venue: Venue::AppleContainer {
                image: "alpine".into(),
            },
            memory_gb: 1,
            timeout: Duration::from_secs(60),
            workdir: dir.to_path_buf(),
        }
    }

    #[test]
    fn apple_container_echo_ok_is_green() {
        if let Err(why) = container_ready() {
            eprintln!("SKIP apple_container_echo_ok_is_green: {why}");
            return;
        }
        let d = scratch("ac-ok");
        let g = apple(&d);
        let log = d.join("ac.log");
        let v = g.run(&sha('1'), "fast", "echo ok; ls /work", &log);
        assert!(matches!(v, GateState::Green { .. }), "{v:?}");
        assert!(fs::read_to_string(&log).unwrap().contains("ok"));
    }

    #[test]
    fn apple_container_memory_cap_kills() {
        if let Err(why) = container_ready() {
            eprintln!("SKIP apple_container_memory_cap_kills: {why}");
            return;
        }
        let d = scratch("ac-oom");
        let g = apple(&d);
        // ~1.5 GB in-process (awk string doubling) under --memory 1g
        let cmd = r#"awk 'BEGIN{s="x";while(length(s)<1500000000)s=s s;print length(s)}'"#;
        let v = g.run(&sha('2'), "fast", cmd, &d.join("oom.log"));
        assert_eq!(
            v,
            GateState::Killed {
                sha: sha('2'),
                suite: "fast".into(),
                reason: "oom or killed".into()
            }
        );
    }

    // ---- systemd-run (Linux only) ----------------------------------------

    #[cfg(target_os = "linux")]
    #[test]
    fn systemd_run_exit_zero_is_green() {
        let d = scratch("sd");
        let g = Gate {
            venue: Venue::SystemdRun,
            memory_gb: 1,
            timeout: Duration::from_secs(30),
            workdir: d.clone(),
        };
        let v = g.run(&sha('3'), "fast", "echo ok", &d.join("sd.log"));
        match g.venue_preflight() {
            // A runner without a usable systemd scope must report Killed with
            // the venue's reason, never a Red (CI proved the old test wrong).
            Err(why) => {
                eprintln!("systemd-run unusable here ({why}); asserting Killed");
                assert!(matches!(v, GateState::Killed { .. }), "{v:?}");
            }
            Ok(()) => assert!(matches!(v, GateState::Green { .. }), "{v:?}"),
        }
    }

    #[test]
    fn a_checkout_at_the_wrong_sha_is_refused_not_gated() {
        let d = scratch("wrongsha");
        let sh = |args: &[&str]| {
            assert!(Command::new("git")
                .args(args)
                .current_dir(&d)
                .output()
                .unwrap()
                .status
                .success());
        };
        sh(&["init", "--quiet"]);
        sh(&[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "one",
        ]);
        let head = String::from_utf8_lossy(
            &Command::new("git")
                .args(["rev-parse", "HEAD"])
                .current_dir(&d)
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_string();
        let g = Gate {
            venue: Venue::Local,
            memory_gb: 1,
            timeout: Duration::from_secs(30),
            workdir: d.clone(),
        };
        // Wrong sha: Unknown and nothing recorded.
        let v = g.run(&sha('9'), "fast", "echo ok", &d.join("g.log"));
        assert!(matches!(v, GateState::Unknown), "{v:?}");
        assert!(g.recorded(&sha('9'), "fast").is_none());
        // Right sha: runs and records.
        let real = Sha::parse(&head).unwrap();
        let v = g.run(&real, "fast", "echo ok", &d.join("g.log"));
        assert!(matches!(v, GateState::Green { .. }), "{v:?}");
    }

    /// #684, AC2: the flag that keeps a polkit-denied scope from registering a
    /// tty password agent has to be on BOTH systemd-run invocations — the
    /// preflight and the suite itself. Only the preflight is reached today
    /// (it fails first), which is exactly how the real run's identical gap
    /// went unnoticed.
    #[test]
    fn every_systemd_run_invocation_refuses_to_ask_for_a_password() {
        let d = scratch("noask");
        let g = Gate {
            venue: Venue::SystemdRun,
            memory_gb: 1,
            timeout: Duration::from_secs(30),
            workdir: d.clone(),
        };
        let (cmd, _) = g.command(&sha('9'), "fast", "echo ok");
        assert_eq!(cmd.get_program(), "systemd-run");
        let args: Vec<String> = cmd
            .get_args()
            .map(|a| a.to_string_lossy().to_string())
            .collect();
        assert!(args.contains(&NO_ASK_PASSWORD.to_string()), "{args:?}");
        assert!(
            SYSTEMD_PREFLIGHT_ARGS.contains(&NO_ASK_PASSWORD),
            "preflight"
        );
        // and the flag is where systemd-run takes it: before the command
        let flag = args.iter().position(|a| a == NO_ASK_PASSWORD).unwrap();
        let bash = args.iter().position(|a| a == "bash").unwrap();
        assert!(flag < bash, "{args:?}");
        // the other venues are untouched by this
        let local = Gate {
            venue: Venue::Local,
            ..g
        };
        assert_eq!(
            local.command(&sha('9'), "fast", "echo ok").0.get_program(),
            "bash"
        );
    }

    /// #684, AC3: a venue check that never answers is killed on its own clock,
    /// far short of the suite's. The polkit hang is one way for that to
    /// happen; the bound does not care which.
    #[test]
    fn a_venue_check_that_never_answers_is_killed_on_its_own_clock() {
        // Stands in for a systemd-run waiting on a password nobody will type.
        let mut hang = Command::new("sleep");
        hang.arg("600");
        let started = Instant::now();
        let out = bounded_check(hang, Duration::from_millis(400)).unwrap();
        assert!(matches!(out, Check::TimedOut), "the check was not bounded");
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "took {:?}",
            started.elapsed()
        );

        // an answer inside the bound is the answer, either way
        let mut yes = Command::new("true");
        yes.arg0("true");
        assert!(matches!(
            bounded_check(yes, Duration::from_secs(5)).unwrap(),
            Check::Ok
        ));
        let mut no = Command::new("bash");
        no.args(["-c", "echo 'Access denied' >&2; exit 1"]);
        match bounded_check(no, Duration::from_secs(5)).unwrap() {
            Check::Refused(why) => assert_eq!(why, "Access denied"),
            other => panic!("{}", matches!(other, Check::Ok)),
        }
        // a program that does not exist is not a verdict about the venue
        assert!(bounded_check(Command::new("fwf-no-such-binary"), PREFLIGHT_TIMEOUT).is_err());

        // the bound is the preflight's own, and nothing like a suite timeout
        assert_eq!(PREFLIGHT_TIMEOUT, Duration::from_secs(5));
    }

    /// #684, AC1: whatever this box says about systemd-run, it says it fast.
    /// The verdict is unchanged — a venue that cannot run `true` is `Killed`,
    /// never a Red — but before this the answer could take 15–20 minutes, and
    /// this very test is where the operator first hit it.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_systemd_venue_answers_within_its_preflight_bound() {
        let d = scratch("sd-fast");
        let g = Gate {
            venue: Venue::SystemdRun,
            memory_gb: 1,
            timeout: Duration::from_secs(600),
            workdir: d.clone(),
        };
        let started = Instant::now();
        let answer = g.venue_preflight();
        let took = started.elapsed();
        assert!(
            took <= PREFLIGHT_TIMEOUT + Duration::from_secs(2),
            "preflight took {took:?}: {answer:?}"
        );
        // a refusal and a timeout are different sentences in the record
        if let Err(why) = &answer {
            assert!(
                why.starts_with("systemd-run --scope refused:")
                    || why == "systemd-run preflight timed out after 5s",
                "{why}"
            );
        }
        // and the gate's own verdict is the venue's reason, not a Red
        let v = g.run(&sha('8'), "fast", "echo ok", &d.join("sd.log"));
        match answer {
            Err(_) => assert!(matches!(v, GateState::Killed { .. }), "{v:?}"),
            Ok(()) => assert!(matches!(v, GateState::Green { .. }), "{v:?}"),
        }
    }
}
