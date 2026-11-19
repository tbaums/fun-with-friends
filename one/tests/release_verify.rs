//! `one/scripts/release-verify.sh` (#727): the check between a draft release
//! and a public one. one-release.yml publishes only on its exit 0, so each way
//! a set of assets can be wrong has to exit 1 here, and a good set exit 0.
//!
//! Driven for real: the script is bash plus `tar` and a sha256 tool, run on the
//! same kind of host (macOS and Linux runners) that runs it in CI.

use std::path::{Path, PathBuf};
use std::process::Command;

const BIN: &str = "fwf";
const VERSION: &str = "1.0.27";
const SLUGS: [&str; 2] = ["macos-arm64", "linux-x86_64"];

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/release-verify.sh")
}

fn sh(dir: &Path, cmd: &str) {
    let out = Command::new("bash")
        .arg("-c")
        .arg(cmd)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{cmd}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A tarball for `slug` holding `members` (the binary gets `bin_bytes`), with
/// a `.sha256` written the way the workflow writes it.
fn pack(work: &Path, assets: &Path, slug: &str, members: &[&str], bin_bytes: &[u8]) {
    let name = format!("{BIN}-{VERSION}-{slug}");
    let stage = work.join(&name);
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).unwrap();
    for m in members {
        let body: &[u8] = if *m == BIN { bin_bytes } else { b"doc\n" };
        std::fs::write(stage.join(m), body).unwrap();
    }
    let tar = assets.join(format!("{name}.tar.gz"));
    sh(work, &format!("tar -czf '{}' '{name}'", tar.display()));
    sh(
        assets,
        &format!(
            "(sha256sum '{name}.tar.gz' 2>/dev/null || shasum -a 256 '{name}.tar.gz') > '{name}.tar.gz.sha256'"
        ),
    );
}

/// A fresh, good set of four assets; returns (scratch dir, assets dir).
fn good_set(tag: &str) -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!("fwfd-relverify-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (work, assets) = (root.join("work"), root.join("assets"));
    std::fs::create_dir_all(&work).unwrap();
    std::fs::create_dir_all(&assets).unwrap();
    for slug in SLUGS {
        pack(
            &work,
            &assets,
            slug,
            &[BIN, "README.md", "RELEASING.md", "CHANGELOG.md"],
            b"\x7fELF binary",
        );
    }
    (root, assets)
}

fn verify(assets: &Path) -> (i32, String) {
    let out = Command::new("bash")
        .arg(script())
        .arg(assets)
        .args([BIN, VERSION])
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    )
}

#[test]
fn a_good_set_of_four_passes() {
    let (root, assets) = good_set("good");
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 0, "{out}");
    assert!(out.contains("4 assets, checksums match"), "{out}");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_missing_asset_fails() {
    let (root, assets) = good_set("missing");
    std::fs::remove_file(assets.join(format!("{BIN}-{VERSION}-macos-arm64.tar.gz.sha256")))
        .unwrap();
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("missing asset: fwf-1.0.27-macos-arm64.tar.gz.sha256"),
        "{out}"
    );
    // a whole slug gone (the macOS leg never uploaded) is two missing assets
    std::fs::remove_file(assets.join(format!("{BIN}-{VERSION}-macos-arm64.tar.gz"))).unwrap();
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("missing asset: fwf-1.0.27-macos-arm64.tar.gz\n"),
        "{out}"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn an_extra_asset_fails() {
    let (root, assets) = good_set("extra");
    std::fs::write(assets.join("fwf-1.0.26-linux-x86_64.tar.gz"), b"stale").unwrap();
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("unexpected asset: fwf-1.0.26-linux-x86_64.tar.gz"),
        "{out}"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_bad_checksum_fails() {
    let (root, assets) = good_set("badsum");
    let sum = assets.join(format!("{BIN}-{VERSION}-linux-x86_64.tar.gz.sha256"));
    std::fs::write(
        &sum,
        format!("{}  {BIN}-{VERSION}-linux-x86_64.tar.gz\n", "0".repeat(64)),
    )
    .unwrap();
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("fwf-1.0.27-linux-x86_64.tar.gz checksum mismatch"),
        "{out}"
    );
    // a checksum file that names another tarball is as bad as a wrong hash
    let (root2, assets2) = good_set("badname");
    let mac =
        std::fs::read_to_string(assets2.join("fwf-1.0.27-macos-arm64.tar.gz.sha256")).unwrap();
    std::fs::write(assets2.join("fwf-1.0.27-linux-x86_64.tar.gz.sha256"), mac).unwrap();
    let (rc, out) = verify(&assets2);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("names 'fwf-1.0.27-macos-arm64.tar.gz'"),
        "{out}"
    );
    let _ = std::fs::remove_dir_all(root);
    let _ = std::fs::remove_dir_all(root2);
}

#[test]
fn a_tarball_without_the_binary_fails() {
    let (root, assets) = good_set("nobin");
    // re-packed without fwf, with a checksum that matches: only the contents
    // check can catch it
    pack(
        &root.join("work"),
        &assets,
        "macos-arm64",
        &["README.md", "RELEASING.md", "CHANGELOG.md"],
        b"",
    );
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(out.contains("holds no fwf-1.0.27-macos-arm64/fwf"), "{out}");
    assert!(!out.contains("checksum mismatch"), "{out}");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_tarball_with_an_empty_binary_or_no_docs_fails() {
    let (root, assets) = good_set("empty");
    pack(
        &root.join("work"),
        &assets,
        "linux-x86_64",
        &[BIN, "README.md", "CHANGELOG.md"],
        b"",
    );
    let (rc, out) = verify(&assets);
    assert_eq!(rc, 1, "{out}");
    assert!(
        out.contains("fwf-1.0.27-linux-x86_64/fwf is empty"),
        "{out}"
    );
    assert!(
        out.contains("holds no fwf-1.0.27-linux-x86_64/RELEASING.md"),
        "{out}"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn bad_arguments_exit_2() {
    let out = Command::new("bash").arg(script()).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let out = Command::new("bash")
        .arg(script())
        .args(["/nonexistent-fwfd-dir", BIN, VERSION])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
}
