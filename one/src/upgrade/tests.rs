//! What #653 has to get right: which of two versions is newer, what happens
//! when the checksum does not hold up, and what both `doctor` and `up` do when
//! GitHub cannot be reached at all.

use super::*;
use std::path::PathBuf;
use std::sync::Arc;

/// A one-request GitHub stand-in. `fake_github` is grandfathered at its
/// current size and this needs one route, so it gets its own four lines.
struct Stub {
    server: Arc<tiny_http::Server>,
    base: String,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Stub {
    fn start(status: u16, body: &str) -> Stub {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind 127.0.0.1:0"));
        let addr = server.server_addr().to_ip().expect("tcp listener");
        let (srv, body) = (server.clone(), body.to_string());
        let thread = std::thread::spawn(move || {
            while let Ok(rq) = srv.recv() {
                let resp = tiny_http::Response::from_string(&body)
                    .with_status_code(status)
                    .with_header(
                        tiny_http::Header::from_bytes("Content-Type", "application/json")
                            .expect("ascii header"),
                    );
                let _ = rq.respond(resp);
            }
        });
        Stub {
            server,
            base: format!("http://{addr}"),
            thread: Some(thread),
        }
    }
}

impl Drop for Stub {
    fn drop(&mut self) {
        self.server.unblock();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Nothing is listening here, ever: port 1 is the offline case without a
/// timeout to wait out.
const OFFLINE: &str = "http://127.0.0.1:1";

/// A string compare puts 1.0.10 *below* 1.0.9, which would leave a box one
/// patch short of the fix it was upgraded for and call it up to date.
#[test]
fn versions_compare_as_numbers_and_tags_lose_their_prefix() {
    assert_eq!(parse_version("1.0.10"), Some((1, 0, 10)));
    assert!(parse_version("1.0.10") > parse_version("1.0.9"));
    assert!(is_behind("1.0.9", "1.0.10"));
    assert!(!is_behind("1.0.10", "1.0.9"));
    assert!(!is_behind("1.0.6", "1.0.6"));
    // `release-publish.sh` tags v<version> (#641); the pre-#641 `one-v` tags
    // are still on the remote, and both have to read.
    assert_eq!(strip_tag("v1.0.6"), "1.0.6");
    assert_eq!(strip_tag("one-v1.0.4"), "1.0.4");
    assert_eq!(strip_tag(" 1.0.4 "), "1.0.4");
    assert!(is_behind("1.0.4", "v1.0.6"));
    // prerelease and build metadata are ignored, not refused
    assert_eq!(parse_version("v1.2.3-rc1+build9"), Some((1, 2, 3)));
    // and anything that is not a version refuses rather than sorts
    for junk in ["", "latest", "1.0", "1.0.6.1", "v1.0.x"] {
        assert_eq!(parse_version(junk), None, "{junk:?}");
    }
    assert!(
        !is_behind("1.0.6", "not-a-tag"),
        "an unreadable tag is not newer"
    );
}

/// The tag in the download path is the one the remote actually carries.
/// `git ls-remote --tags origin` lists `v1.0.4`, `v1.0.5`, `v1.0.6`, and
/// `release-publish.sh` tags `v$VERSION`; `install.sh` still writes
/// `one-v<version>`, which is a 404 and is what this asserts we did not copy.
#[test]
fn the_download_url_carries_the_v_tag_the_remote_actually_has() {
    let url = asset_url("tbaums/fun-with-friends", "1.0.6", "linux-x86_64");
    assert_eq!(
        url,
        "https://github.com/tbaums/fun-with-friends/releases/download/v1.0.6/fwf-1.0.6-linux-x86_64.tar.gz"
    );
    assert!(!url.contains("one-v"), "the pre-#641 tag spelling: {url}");
    assert!(url.contains("/download/v1.0.6/"), "{url}");
    // the checksum sits beside it, under the same tag
    assert_eq!(
        format!("{url}.sha256"),
        "https://github.com/tbaums/fun-with-friends/releases/download/v1.0.6/fwf-1.0.6-linux-x86_64.tar.gz.sha256"
    );
    // the macOS asset differs only by slug, and the stem is the directory
    // inside the tarball
    assert!(asset_url("tbaums/fun-with-friends", "1.0.6", "macos-arm64")
        .ends_with("/download/v1.0.6/fwf-1.0.6-macos-arm64.tar.gz"));
    assert_eq!(asset_stem("1.0.6", "macos-arm64"), "fwf-1.0.6-macos-arm64");
    // a `--to v1.0.6` still resolves to the bare version, so the path never
    // doubles the prefix
    assert!(!asset_url("o/r", strip_tag("v1.0.6"), "linux-x86_64").contains("vv"));
}

/// Build a tarball shaped like a published asset: `fwf-<version>-<slug>/fwf`.
fn stage_asset(dir: &Path, version: &str, slug: &str, contents: &str) -> PathBuf {
    let name = format!("{BIN_NAME}-{version}-{slug}");
    std::fs::create_dir_all(dir.join(&name)).unwrap();
    std::fs::write(dir.join(&name).join(BIN_NAME), contents).unwrap();
    let tarball = dir.join(format!("{name}.tar.gz"));
    let out = std::process::Command::new("tar")
        .arg("-C")
        .arg(dir)
        .arg("-czf")
        .arg(&tarball)
        .arg(&name)
        .output()
        .unwrap();
    assert!(out.status.success(), "tar: {out:?}");
    tarball
}

/// The property that makes a boot-time upgrade safe: a download that does not
/// match its published checksum never reaches the binary. The old fwf is still
/// there, byte for byte, and the verb's exit code says so.
#[test]
fn a_checksum_mismatch_refuses_and_leaves_the_running_binary_untouched() {
    let dir = std::env::temp_dir().join(format!("fwf-upgrade-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let tarball = stage_asset(&dir, "9.9.9", "test-slug", "NEW BINARY");
    let dest = dir.join("installed-fwf");
    std::fs::write(&dest, "OLD BINARY").unwrap();

    let wrong = format!("{}  x.tar.gz", "0".repeat(64));
    let e = install_asset(&tarball, &wrong, "9.9.9", "test-slug", &dest).unwrap_err();
    assert!(e.contains("sha256 mismatch"), "{e}");
    assert_eq!(std::fs::read(&dest).unwrap(), b"OLD BINARY");

    // a checksum that is not a checksum is refused before anything is unpacked
    let e = install_asset(&tarball, "not-a-hash", "9.9.9", "test-slug", &dest).unwrap_err();
    assert!(e.contains("unreadable"), "{e}");
    assert_eq!(std::fs::read(&dest).unwrap(), b"OLD BINARY");

    // and the published checksum, matching, swaps the binary in place
    let real = sha256_file(&tarball).unwrap();
    install_asset(
        &tarball,
        &format!("{real}  {BIN_NAME}-9.9.9-test-slug.tar.gz"),
        "9.9.9",
        "test-slug",
        &dest,
    )
    .unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), b"NEW BINARY");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&dest).unwrap().permissions().mode();
        assert_eq!(mode & 0o111, 0o111, "the installed binary is executable");
    }

    // a tarball with no binary in it is named, not installed
    let empty = dir.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    std::fs::create_dir_all(empty.join(format!("{BIN_NAME}-8.8.8-test-slug"))).unwrap();
    let out = std::process::Command::new("tar")
        .arg("-C")
        .arg(&empty)
        .arg("-czf")
        .arg(empty.join("a.tar.gz"))
        .arg(format!("{BIN_NAME}-8.8.8-test-slug"))
        .output()
        .unwrap();
    assert!(out.status.success());
    let t = empty.join("a.tar.gz");
    let sha = sha256_file(&t).unwrap();
    let e = install_asset(&t, &sha, "8.8.8", "test-slug", &dest).unwrap_err();
    assert!(e.contains("carries no fwf binary"), "{e}");
    assert_eq!(std::fs::read(&dest).unwrap(), b"NEW BINARY");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The devbox case that started this: GitHub is unreachable after a wake
/// (#devbox-wake, IPv4 loss). `doctor` says so and stays green; `up` says so
/// and starts the floor. Neither hangs.
#[test]
fn an_unreachable_github_is_a_line_for_doctor_and_a_warning_for_up() {
    let c = check(OFFLINE, "tbaums/fun-with-friends", None);
    assert!(c.latest.is_none());
    assert!(c.why.is_some(), "the reason is kept for whoever asks");
    assert_eq!(
        c.line(),
        format!(
            "fwf: installed v{} · latest unknown (offline)",
            installed_version()
        )
    );
    assert!(!c.behind(), "unknown is not behind");
    assert!(
        matches!(up_gate(&c, false), UpGate::Warn(_)),
        "up never blocks on an unreachable GitHub"
    );
}

/// The three answers `up` gives once it does know the latest release.
#[test]
fn up_refuses_a_stale_binary_unless_the_override_is_set() {
    let at = |installed: &str, latest: &str| Check {
        installed: installed.into(),
        latest: Some(latest.into()),
        why: None,
    };
    assert!(matches!(up_gate(&at("1.0.6", "1.0.6"), false), UpGate::Go));
    let stale = at("1.0.4", "1.0.6");
    match up_gate(&stale, false) {
        UpGate::Refuse(m) => {
            assert!(m.contains("v1.0.4") && m.contains("v1.0.6"), "{m}");
            assert!(m.contains("fwf self-upgrade"), "{m}");
        }
        _ => panic!("a stale fwf must not start a floor"),
    }
    match up_gate(&stale, true) {
        UpGate::Warn(m) => assert!(m.contains(ALLOW_STALE_ENV), "{m}"),
        _ => panic!("{ALLOW_STALE_ENV} is the way through"),
    }
}

/// What `doctor` prints, read off the releases API itself — `tag_name`, not a
/// tag list and not `install.sh`'s naming convention.
#[test]
fn doctor_reads_tag_name_from_the_releases_api() {
    let stub = Stub::start(200, r#"{"tag_name":"v99.0.0","name":"fwf 99.0.0"}"#);
    let c = check(&stub.base, "tbaums/fun-with-friends", None);
    assert_eq!(c.latest.as_deref(), Some("99.0.0"));
    assert!(c.behind());
    assert_eq!(
        c.line(),
        format!(
            "fwf: installed v{} · latest v99.0.0 · BEHIND",
            installed_version()
        )
    );
    assert!(matches!(up_gate(&c, false), UpGate::Refuse(_)));

    // the installed version is the released one: nothing to say, nothing to do
    let stub = Stub::start(
        200,
        &format!(r#"{{"tag_name":"v{}"}}"#, installed_version()),
    );
    let c = check(&stub.base, "tbaums/fun-with-friends", None);
    assert!(c.line().ends_with("· up to date"), "{}", c.line());
    assert!(matches!(up_gate(&c, false), UpGate::Go));

    // a repo with no releases at all reads as offline, not as a crash
    let stub = Stub::start(404, r#"{"message":"Not Found"}"#);
    let c = check(&stub.base, "tbaums/fun-with-friends", None);
    assert!(c.latest.is_none());
    assert!(c.line().contains("latest unknown (offline)"));
}

/// The asset names this host asks for are the ones the release publishes.
#[test]
fn the_host_slug_is_the_one_install_sh_uses() {
    assert!(matches!(
        host_slug(),
        Some("macos-arm64") | Some("linux-x86_64") | None
    ));
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        assert_eq!(host_slug(), Some("macos-arm64"));
    }
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        assert_eq!(host_slug(), Some("linux-x86_64"));
    }
}
