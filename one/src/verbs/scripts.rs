//! The seat scripts, carried inside the binary (#674).
//!
//! `seats --up` used to spawn `scripts/seat-up.sh` under the crate's manifest
//! directory, a path `env!` bakes in when the binary is *built*. A release
//! asset from `one-release.yml` therefore names
//! `/home/runner/work/fun-with-friends/fun-with-friends/one/scripts/seat-up.sh`
//! — a directory that exists on no installed machine. Every seat on devbox1
//! cloned and then failed with `seat-up: No such file or directory (os error
//! 2)` (v1.0.12, 2026-09-18); source builds never saw it because the path they
//! bake in happens to be right.
//!
//! So the scripts come along as `include_str!` and are written to the floor at
//! `seats --up` time. Both of them: `seat-up.sh` installs `seat-push-guard.sh`
//! from its *own* directory (`dirname "${BASH_SOURCE[0]}"`), so shipping
//! seat-up alone would move the same failure one line down, into the guard.
//!
//! The write is unconditional on every run — the content is static, not user
//! data, so last-writer-wins is fine and an upgraded binary heals a floor that
//! still holds an older copy.

use std::io;
use std::path::{Path, PathBuf};

/// `one/scripts/seat-up.sh`, as of the build.
pub const SEAT_UP: &str = include_str!("../../scripts/seat-up.sh");
/// The push policy seat-up.sh installs beside the floor's settings (#621).
pub const SEAT_PUSH_GUARD: &str = include_str!("../../scripts/seat-push-guard.sh");

/// Write the embedded seat scripts into `<home>/.fwf/`, creating it (and the
/// floor's `home/`) if it is not there yet, and answer with the path to run.
pub fn install(home: &Path) -> io::Result<PathBuf> {
    let dir = home.join(".fwf");
    std::fs::create_dir_all(&dir)?;
    let up = dir.join("seat-up.sh");
    write_exec(&up, SEAT_UP)?;
    // Named by seat-up.sh relative to itself, so it has to be its neighbour.
    write_exec(&dir.join("seat-push-guard.sh"), SEAT_PUSH_GUARD)?;
    Ok(up)
}

fn write_exec(path: &Path, body: &str) -> io::Result<()> {
    std::fs::write(path, body)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
}

/// What `fwf doctor` says about them: the binary is the source of truth, so a
/// stale or missing `one/scripts/` checkout on this host means nothing.
pub fn doctor_line() -> String {
    format!(
        "  seat scripts: embedded ({} B seat-up.sh, {} B push-guard; rewritten under <floor>/home/.fwf/ by `fwf seats --up`)",
        SEAT_UP.len(),
        SEAT_PUSH_GUARD.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #674: the release binary has no source tree to read from. Nothing here
    /// touches `one/scripts/` at runtime — the bytes are the ones the compiler
    /// put in — and the floor's `home/` need not exist yet.
    #[test]
    fn seats_up_installs_the_scripts_from_the_binary_not_from_disk() {
        use std::os::unix::fs::PermissionsExt;
        let floor = std::env::temp_dir().join(format!("fwfd-scripts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&floor);
        let home = floor.join("home");
        assert!(!home.exists(), "the floor starts empty");

        let up = install(&home).unwrap();

        assert_eq!(up, home.join(".fwf/seat-up.sh"));
        let guard = home.join(".fwf/seat-push-guard.sh");
        for (path, embedded) in [(&up, SEAT_UP), (&guard, SEAT_PUSH_GUARD)] {
            assert_eq!(
                std::fs::read_to_string(path).unwrap(),
                embedded,
                "{} is not byte-for-byte the embedded script",
                path.display()
            );
            let mode = std::fs::metadata(path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755, "{} is {mode:o}", path.display());
        }
        // The guard is seat-up.sh's neighbour because seat-up.sh looks for it
        // beside itself; if that ever stops being true this test says so.
        assert!(
            SEAT_UP.contains(r#"/seat-push-guard.sh" "$guard""#),
            "{SEAT_UP}"
        );
        assert_eq!(up.parent(), guard.parent());

        // an upgraded binary overwrites whatever the last one left behind
        std::fs::write(&up, "#!/bin/sh\nexit 1\n").unwrap();
        assert_eq!(install(&home).unwrap(), up);
        assert_eq!(std::fs::read_to_string(&up).unwrap(), SEAT_UP);

        let _ = std::fs::remove_dir_all(&floor);
    }

    #[test]
    fn doctor_says_the_scripts_are_embedded() {
        assert!(
            doctor_line().contains("seat scripts: embedded"),
            "{}",
            doctor_line()
        );
    }
}
