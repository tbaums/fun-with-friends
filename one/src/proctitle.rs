//! #678 — one binary, three long-running verbs, one process name.
//!
//! `fwf run`, `fwf gate` and `fwf qa` are the same executable, so every
//! name-based signal is ambiguous. On 2026-09-18 `pkill -x fwf`, meant for a
//! loop that looked hung, also killed the in-flight gate and QA verbs (exit
//! 143, both re-run by hand), and `pkill -f "fwf run"` over ssh matched the
//! ssh shell's own command line and killed the operator's session — twice.
//!
//! So each of the three re-executes itself once, early, through a symlink
//! named after the verb: `~/.fwf/bin/fwf-<verb>`. The symlink is the part
//! that does the work. Linux takes `/proc/<pid>/comm` from the basename of
//! the *file* handed to `execve`, not from `argv[0]`, so rewriting `argv[0]`
//! alone (or `prctl(PR_SET_NAME)`, which is Linux-only anyway) would leave
//! `ps -o comm=` and `pkill -x` reading `fwf` on one platform or both. Exec
//! the symlink and both platforms report `fwf-run` / `fwf-gate` / `fwf-qa`;
//! `arg0` on top of it makes the full command line say so too.
//!
//! A rename is cosmetic and must never stop a floor: every failure here is a
//! warning on stderr and the verb runs on under its old name.

use std::path::{Path, PathBuf};

/// The name `fwf <verb>` runs under once it has re-executed itself.
pub fn title(verb: &str) -> String {
    format!("fwf-{verb}")
}

/// Whether this process is already the re-executed one. Checked first and by
/// `argv[0]`, which the re-exec sets: nothing else would stop it exec'ing
/// itself forever.
pub fn already_titled(argv0: &str, verb: &str) -> bool {
    Path::new(argv0).file_name().and_then(|s| s.to_str()) == Some(title(verb).as_str())
}

/// Where the verb-named symlink lives, beside the rest of `~/.fwf/`.
pub fn link_path(home: &Path, verb: &str) -> PathBuf {
    home.join(".fwf/bin").join(title(verb))
}

/// Point `~/.fwf/bin/fwf-<verb>` at `exe`, whatever it pointed at before.
///
/// Replaced rather than created-if-missing: `fwf self-upgrade` swaps the
/// binary underneath, and a link left pointing at the old one would run a
/// version nobody asked for.
pub fn install_link(home: &Path, exe: &Path, verb: &str) -> std::io::Result<PathBuf> {
    let link = link_path(home, verb);
    if let Some(dir) = link.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // `remove_file` unlinks a symlink itself, dangling or not; only its
    // absence is not a problem.
    if let Err(e) = std::fs::remove_file(&link) {
        if e.kind() != std::io::ErrorKind::NotFound {
            return Err(e);
        }
    }
    std::os::unix::fs::symlink(exe, &link)?;
    Ok(link)
}

/// Re-exec this process as `fwf-<verb>`, once. Returns — having changed
/// nothing but stderr — when it cannot: no `HOME`, an unwritable `~/.fwf/bin`,
/// an `exec` the kernel refused. The verb then runs under the old name, which
/// is exactly what it did before this existed.
pub fn retitle(verb: &str) {
    use std::os::unix::process::CommandExt;
    let argv0 = std::env::args().next().unwrap_or_default();
    if already_titled(&argv0, verb) {
        return;
    }
    let warn = |why: String| {
        eprintln!(
            "fwf {verb}: running as `{argv0}`, not `{}` ({why}); `pkill -x fwf` would hit sibling verbs",
            title(verb)
        );
    };
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        warn("no HOME".into());
        return;
    };
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => return warn(e.to_string()),
    };
    let link = match install_link(&home, &exe, verb) {
        Ok(l) => l,
        Err(e) => return warn(format!("{}: {e}", link_path(&home, verb).display())),
    };
    // Same argv, same environment, same fds, same cwd: to everything above
    // this process, only its name changed. `exec` returns only on failure.
    let e = std::process::Command::new(&link)
        .arg0(title(verb))
        .args(std::env::args_os().skip(1))
        .exec();
    warn(format!("{}: {e}", link.display()));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("fwfd-title-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// AC5: the re-exec'd process must recognise itself, or it would exec
    /// forever. `argv[0]` is what the re-exec sets, and it arrives either as
    /// the bare name or as the path the kernel was handed.
    #[test]
    fn a_process_already_running_under_the_verbs_name_knows_it() {
        for argv0 in ["fwf-run", "/home/someone/.fwf/bin/fwf-run", "./fwf-run"] {
            assert!(already_titled(argv0, "run"), "{argv0}");
        }
        for argv0 in ["fwf", "/usr/local/bin/fwf", "fwf-runner", "fwf-gate", ""] {
            assert!(!already_titled(argv0, "run"), "{argv0}");
        }
        assert_eq!(title("gate"), "fwf-gate");
        assert_eq!(
            link_path(Path::new("/home/someone"), "qa"),
            Path::new("/home/someone/.fwf/bin/fwf-qa")
        );
    }

    /// The link is refreshed, never merely created: `self-upgrade` replaces
    /// the binary under it.
    #[test]
    fn the_link_is_made_in_a_missing_directory_and_repointed_when_it_is_stale() {
        let home = tmp("link");
        let old = home.join("fwf-1.0.15");
        let new = home.join("fwf-1.0.16");
        std::fs::write(&old, "old").unwrap();
        std::fs::write(&new, "new").unwrap();
        assert!(!home.join(".fwf/bin").exists(), "the dir is ours to create");

        let link = install_link(&home, &old, "run").unwrap();
        assert_eq!(link, home.join(".fwf/bin/fwf-run"));
        assert_eq!(std::fs::read_link(&link).unwrap(), old);

        // an upgrade swaps the binary: the next start repoints the link
        assert_eq!(install_link(&home, &new, "run").unwrap(), link);
        assert_eq!(std::fs::read_link(&link).unwrap(), new);

        // a link left dangling by a deleted binary is replaced too
        std::fs::remove_file(&new).unwrap();
        assert!(std::fs::read_link(&link).is_ok(), "still a symlink");
        assert!(!link.exists(), "and a dangling one");
        std::fs::write(&new, "new again").unwrap();
        install_link(&home, &new, "run").unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), new);

        // each verb gets its own name, in one shared directory
        install_link(&home, &new, "gate").unwrap();
        install_link(&home, &new, "qa").unwrap();
        let mut names: Vec<String> = std::fs::read_dir(home.join(".fwf/bin"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        assert_eq!(names, vec!["fwf-gate", "fwf-qa", "fwf-run"]);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// AC2, the whole point: the kernel's own short name — what `ps -o comm=`
    /// prints and what `pkill -x` matches — has to change, on Linux as well as
    /// macOS. Linux takes it from the executed file's basename, so this proves
    /// the symlink is doing the work; `arg0` alone would leave it `sleep`.
    ///
    /// Stands in a real binary for fwf (a test binary cannot exec itself and
    /// come back), and only ever READS the process table: `pgrep`, never
    /// `pkill` — this suite runs on a machine with real floors on it.
    #[test]
    fn the_process_table_reports_the_verb_name_and_not_the_binarys() {
        // Not a coreutils tool: this box ships them as one multi-call binary
        // that dispatches on `argv[0]` and refuses an unknown one. `bash` is
        // what the rest of the suite already depends on.
        let Some(bash) = ["/bin/bash", "/usr/bin/bash"]
            .into_iter()
            .map(PathBuf::from)
            .find(|p| p.exists())
        else {
            eprintln!("skip: no bash");
            return;
        };
        let home = tmp("comm");
        let link = install_link(&home, &bash, "run").unwrap();
        let mut child = {
            use std::os::unix::process::CommandExt;
            Command::new(&link)
                .arg0(title("run"))
                // Two commands, so bash does not optimise the single-command
                // form into an `exec` and become `sleep` itself.
                .args(["-c", "sleep 5; :"])
                .spawn()
        }
        .unwrap();
        let pid = child.id();

        let comm = Command::new("ps")
            .args(["-o", "comm=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let comm = String::from_utf8_lossy(&comm.stdout).trim().to_string();
        // macOS `ps -o comm=` prints the path it was executed as; Linux prints
        // the basename the kernel stored. Both must end in the verb's name.
        assert!(
            Path::new(&comm).file_name().and_then(|s| s.to_str()) == Some("fwf-run"),
            "ps said {comm:?}, not fwf-run"
        );

        let pgrep = |pattern: &str| {
            let out = Command::new("pgrep")
                .args(["-x", pattern])
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .map(str::to_string)
                .collect::<Vec<_>>()
        };
        let me = pid.to_string();
        assert!(
            pgrep("fwf-run").contains(&me),
            "`pgrep -x fwf-run` missed {me}"
        );
        // the incident itself: a name-based signal aimed at `fwf` must not
        // reach this process, and it is no longer called after its binary
        assert!(!pgrep("fwf").contains(&me), "`pkill -x fwf` would kill it");
        assert!(!pgrep("bash").contains(&me), "still named after the binary");

        child.kill().unwrap();
        child.wait().unwrap();
        let _ = std::fs::remove_dir_all(&home);
    }
}
