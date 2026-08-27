// Issue #153: embed this BUILD's version + build date into the binary, so a
// long-running `fwf dash` process can report what it actually is instead of
// silently rendering forever with whatever it was launched with.
//
// The top-level `VERSION` file (repo root, one level up from this crate) is
// the source of truth for a release's version -- `fwf-dash-X.Y.Z-<platform>`
// release assets are named after it (see `.github/workflows/release.yml`).
// Cargo.toml's own `version` field is NOT kept in sync with it and must
// never be used for this.
use std::process::Command;

fn main() {
    let version = std::fs::read_to_string("../VERSION")
        .unwrap_or_default()
        .trim()
        .to_string();
    println!("cargo:rustc-env=FWF_DASH_VERSION={version}");
    println!("cargo:rerun-if-changed=../VERSION");

    // `date` ships on every runner this crate is built on (Linux + macOS, per
    // release.yml's matrix) -- no extra crate needed for one timestamp.
    let build_date = Command::new("date")
        .args(["-u", "+%Y-%m-%d"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    println!("cargo:rustc-env=FWF_DASH_BUILD_DATE={}", build_date.trim());
}
