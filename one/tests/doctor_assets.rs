//! `fwf doctor --assets` from `/` with a fresh `HOME` (#719).
//!
//! Driven for real because what is being checked is the binary: that it needs
//! no checkout, no manifest, no Apps and no network to say what it carries, and
//! that the prompts a seat will read land under `$HOME/.fwf/prompts`.

use std::path::Path;
use std::process::Command;

#[test]
fn doctor_assets_writes_the_prompts_under_home_and_passes() {
    let home = std::env::temp_dir().join(format!("fwfd-doctor-assets-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_fwf"))
        .args(["doctor", "--assets"])
        .current_dir("/")
        .env("HOME", &home)
        .env_remove("FWF_APPS_TOML")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{text}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(text.contains("seat-up.sh (embedded)"), "{text}");
    assert!(
        !text.contains("apps"),
        "--assets must not look at the Apps: {text}"
    );
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prompts");
    for r in ["impl", "qa", "gv", "pm"] {
        let name = format!("dev/{r}-job.md");
        assert_eq!(
            std::fs::read(home.join(".fwf/prompts").join(&name)).unwrap(),
            std::fs::read(src.join(&name)).unwrap(),
            "{name}"
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}

/// No `HOME`, no prompts — and never a quiet fall back to a build path.
#[test]
fn doctor_assets_without_home_fails_and_names_home() {
    let out = Command::new(env!("CARGO_BIN_EXE_fwf"))
        .args(["doctor", "--assets"])
        .current_dir("/")
        .env_remove("HOME")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("HOME is not set"), "{text}");
}
