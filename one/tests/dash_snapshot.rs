//! `fwf dash` into a pipe: one frame, labelled, exit 0 (#626).
//!
//! The binary is driven for real because the thing being checked is what a
//! script or a redirect gets — a dash that watched here would hang forever,
//! which is precisely the failure this asserts against.

use std::process::{Command, Stdio};

#[test]
fn a_piped_dash_prints_one_labelled_snapshot_and_exits() {
    let dir = std::env::temp_dir().join(format!("fwfd-dash-snap-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("run.jsonl");
    std::fs::write(
        &log,
        "{\"ts\":1000,\"repo\":\"o/r\",\"kind\":\"note\",\"text\":\"thin slice start: issue #626\"}\n",
    )
    .unwrap();
    // stdin null so the `stty` behind `is_tty()` has no terminal to find,
    // whatever terminal `cargo test` itself was run from.
    let out = Command::new(env!("CARGO_BIN_EXE_fwf"))
        .args(["dash", "--no-color", "--log"])
        .arg(&log)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "exit {:?}: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    // one frame: the board is drawn once, with its top border once
    assert_eq!(text.matches("┌ fwf dash ").count(), 1, "{text}");
    // and it says what it is, with the time it was taken
    let label = text.lines().last().unwrap_or_default();
    assert!(label.contains("snapshot"), "{label:?}");
    assert!(
        label.contains(':') && label.chars().any(|c| c.is_ascii_digit()),
        "no clock time in {label:?}"
    );
    assert!(!label.contains('┐'), "the label is not part of the frame");
    let _ = std::fs::remove_dir_all(&dir);
}
