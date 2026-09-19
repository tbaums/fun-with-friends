//! #675 — the run loop's pidfile, and the one safe way to stop it.
//!
//! Over ssh on 2026-09-18 the operator lost three sessions to `pkill`:
//! `pkill -f "fwf run"` matches the ssh shell's own command line and killed
//! the session issuing it, and `pkill -x fwf` killed every sibling verb —
//! `fwf gate`, `fwf qa` — because they are the same binary. Nothing in the
//! product could name the loop and only the loop.
//!
//! So `fwf run` writes its own pid to `<floor>/run.pid` and `fwf stop` reads
//! it back and signals exactly that process. A pid that is no longer alive is
//! reclaimed rather than believed: a SIGKILLed loop cannot clean up after
//! itself, and a floor must not be wedged by a file nobody can remove.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Where a floor records the pid of the loop running it.
pub fn path(floor: &Path) -> PathBuf {
    floor.join("run.pid")
}

/// `kill -0`: the process exists and we may signal it. A shell out rather
/// than a libc call because fwf carries no `libc` dependency, and this runs
/// twice per floor lifetime, not in a loop.
pub fn alive(pid: u32) -> bool {
    signal(pid, "-0")
}

fn signal(pid: u32, sig: &str) -> bool {
    Command::new("kill")
        .arg(sig)
        .arg(pid.to_string())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The pid this floor's pidfile names, if it holds one.
pub fn read(floor: &Path) -> Option<u32> {
    std::fs::read_to_string(path(floor))
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// Take the floor for this process, or say who already has it.
///
/// A live pid is a refusal: two loops on one floor would both plan, both
/// claim and both wake the same panes. A dead one is this process's to take —
/// see the module note on SIGKILL.
pub fn claim(floor: &Path, me: u32) -> Result<PathBuf, String> {
    let p = path(floor);
    if let Some(pid) = read(floor) {
        if pid != me && alive(pid) {
            return Err(format!(
                "already running as pid {pid} ({}); `fwf stop` first",
                p.display()
            ));
        }
    }
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(&p, format!("{me}\n")).map_err(|e| format!("{}: {e}", p.display()))?;
    Ok(p)
}

/// What `fwf stop` did. Both outcomes are exit 0: "the loop is not running"
/// is the state the operator asked for, however it got there.
#[derive(Debug, PartialEq, Eq)]
pub enum Stopped {
    /// SIGTERM was sent to this pid, and to nothing else.
    Signalled(u32),
    /// No pidfile, or one naming a process that is gone (the file is removed).
    NotRunning { stale: Option<u32> },
}

/// Stop the loop this floor's pidfile names — that pid, by number, never a
/// pattern. A pid that is already gone leaves no file behind.
pub fn stop(floor: &Path) -> Stopped {
    let p = path(floor);
    match read(floor) {
        Some(pid) if alive(pid) && signal(pid, "-TERM") => Stopped::Signalled(pid),
        Some(pid) => {
            let _ = std::fs::remove_file(&p);
            Stopped::NotRunning { stale: Some(pid) }
        }
        None => {
            let _ = std::fs::remove_file(&p);
            Stopped::NotRunning { stale: None }
        }
    }
}

/// What `fwf status` says about the loop (#675): the record alone cannot tell
/// a floor whose loop exited cleanly from one whose loop is mid-wait.
pub fn status_line(floor: &Path) -> String {
    status_line_at(&path(floor))
}

/// [`status_line`], given the pidfile itself — what `fwf status` holds.
pub fn status_line_at(pidfile: &Path) -> String {
    match std::fs::read_to_string(pidfile)
        .ok()
        .and_then(|t| t.trim().parse::<u32>().ok())
    {
        Some(pid) if alive(pid) => format!("loop: pid {pid} (alive)"),
        Some(pid) => format!("loop: pid {pid} (missing)"),
        None => "loop: no pidfile".to_string(),
    }
}

/// `fwf stop [--manifest PATH]` — SIGTERM the loop this floor's pidfile
/// names, and nothing else. Exit 0 either way: a floor with no loop running
/// is the state the verb was asked for.
///
/// In-flight jobs are left exactly as `pkill` left them — a seat mid-job
/// keeps its pane and its verdict file; the record says Working until the
/// next loop reconciles it.
pub fn verb(args: &[String]) -> std::process::ExitCode {
    let path = super::get(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::manifest::Manifest::default_path(Path::new(".")));
    let m = match crate::manifest::Manifest::load(&path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("fwf stop: {e}");
            return std::process::ExitCode::from(2);
        }
    };
    let floor = m.floor();
    match stop(&floor) {
        Stopped::Signalled(pid) => println!("fwf stop: stopped the loop (pid {pid}, SIGTERM)"),
        Stopped::NotRunning { stale: Some(pid) } => println!(
            "fwf stop: not running (pid {pid} is gone); removed the stale {}",
            path_of(&floor)
        ),
        Stopped::NotRunning { stale: None } => {
            println!("fwf stop: not running (no pidfile at {})", path_of(&floor))
        }
    }
    std::process::ExitCode::SUCCESS
}

fn path_of(floor: &Path) -> String {
    path(floor).display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("fwfd-pid-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// A process we can start, ask about and outlive.
    fn sleeper() -> std::process::Child {
        Command::new("sleep")
            .arg("30")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap()
    }

    /// #675: a second loop on one floor is refused by name, and a pidfile
    /// left behind by a loop that is gone is this one's to take.
    #[test]
    fn a_live_pid_refuses_the_floor_and_a_dead_one_is_reclaimed() {
        let floor = tmp("claim");
        // nothing there yet: the floor is free
        let p = claim(&floor, std::process::id()).unwrap();
        assert_eq!(p, floor.join("run.pid"));
        assert_eq!(read(&floor), Some(std::process::id()));

        // someone else's loop, alive: refused, and the file is left alone
        let mut live = sleeper();
        std::fs::write(&p, format!("{}\n", live.id())).unwrap();
        let err = claim(&floor, std::process::id()).unwrap_err();
        assert!(err.contains(&live.id().to_string()), "{err}");
        assert!(err.contains("fwf stop"), "{err}");
        assert_eq!(read(&floor), Some(live.id()), "the file was overwritten");

        // the same pid asking again is this process, not a second loop
        assert!(claim(&floor, live.id()).is_ok());

        // once it is gone the pid is reclaimed, whatever the file still says
        live.kill().unwrap();
        live.wait().unwrap();
        assert!(!alive(live.id()));
        claim(&floor, std::process::id()).unwrap();
        assert_eq!(read(&floor), Some(std::process::id()));

        // and a floor directory that does not exist yet is created
        let fresh = floor.join("never-made");
        claim(&fresh, 4242).unwrap();
        assert_eq!(read(&fresh), Some(4242));
        let _ = std::fs::remove_dir_all(&floor);
    }

    /// #675: `fwf stop` signals the pid in the file and nothing else — the
    /// whole point, after `pkill -x fwf` took out the sibling verbs.
    #[test]
    fn stop_signals_only_the_pid_in_the_file() {
        let floor = tmp("stop");
        // no pidfile at all
        assert_eq!(stop(&floor), Stopped::NotRunning { stale: None });
        assert!(!path(&floor).exists());

        let mut loop_proc = sleeper();
        let mut sibling = sleeper();
        claim(&floor, loop_proc.id()).unwrap();
        assert_eq!(stop(&floor), Stopped::Signalled(loop_proc.id()));
        assert!(loop_proc.wait().unwrap().code().is_none(), "not signalled");
        assert!(
            alive(sibling.id()),
            "a sibling verb was signalled; only the pidfile's pid may be"
        );
        sibling.kill().unwrap();
        sibling.wait().unwrap();

        // a pidfile naming a process that is gone: not running, no file left
        claim(&floor, loop_proc.id()).unwrap();
        assert_eq!(
            stop(&floor),
            Stopped::NotRunning {
                stale: Some(loop_proc.id())
            }
        );
        assert!(!path(&floor).exists());
        // and stopping twice is the same answer, not an error
        assert_eq!(stop(&floor), Stopped::NotRunning { stale: None });
        let _ = std::fs::remove_dir_all(&floor);
    }

    #[test]
    fn the_status_line_says_what_the_pidfile_and_the_process_table_agree_on() {
        let floor = tmp("status");
        assert_eq!(status_line(&floor), "loop: no pidfile");
        let mut live = sleeper();
        claim(&floor, live.id()).unwrap();
        assert_eq!(
            status_line(&floor),
            format!("loop: pid {} (alive)", live.id())
        );
        live.kill().unwrap();
        live.wait().unwrap();
        assert_eq!(
            status_line(&floor),
            format!("loop: pid {} (missing)", live.id())
        );
        let _ = std::fs::remove_dir_all(&floor);
    }

    /// #675: the operator's rules live in the repo, not out of band — and the
    /// repo is public, so the floor's own hosts and people stay out of them.
    /// The two product rules here are the ones this module exists for.
    #[test]
    fn the_operations_doc_carries_the_rules_and_names_nobody() {
        let doc = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../docs/operations.md"
        ))
        .unwrap();
        assert!(!doc.contains("Content pending"), "still a stub");
        let lower = doc.to_lowercase();
        for private in ["jamie", "devbox", "pdt"] {
            assert!(!lower.contains(private), "{private:?} is in operations.md");
        }
        for rule in [
            "fwf stop",
            "run.pid",
            "pkill",
            // #678: the one sentence the incident came down to
            "`pkill -x fwf` is never correct — use `fwf stop`.",
            "record age",
            "waiting:",
            "tmux new-session",
            "date",
            "gate-wt",
            // #684: the venue that used to hang, and how the hang looked
            "`fwf gate --venue systemd-run` fails fast",
            "`systemd-run … true` child alive for minutes",
            "refs/heads/impl1/*",
            "fwf ungate",
        ] {
            assert!(doc.contains(rule), "operations.md never mentions {rule:?}");
        }
        // the hand-driving sequence, in the order the loop calls it
        let by_hand = &doc[doc
            .find("## Driving a floor by hand")
            .expect("no hand-driving section")..];
        let seq: Vec<usize> = [
            "fwf ungate",
            "fwf gate",
            "fwf qa",
            "fwf merge",
            "fwf release-check",
        ]
        .iter()
        .map(|v| by_hand.find(v).unwrap_or_else(|| panic!("no {v:?}")))
        .collect();
        assert!(seq.windows(2).all(|w| w[0] < w[1]), "{seq:?}");
        assert!(
            doc.contains("releasing.md"),
            "no pointer to the release doc"
        );
    }
}
