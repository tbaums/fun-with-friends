//! #653 — "is this box running the latest fwf, and if not, become it".
//!
//! A Hetzner devbox is restored from a hibernate snapshot, so the `fwf` on it
//! is whatever was installed the day the snapshot was taken (v1.0.4 while
//! v1.0.6 is out). Nothing noticed: the box booted and ran a floor on a stale
//! binary. This module is the machinery the boot hook calls — the hook itself
//! lives in `hetzner-devbox` and is not this repo's:
//!
//!   * `doctor` prints [`Check::line`] — installed vs. latest, one grep-able line;
//!   * `up` refuses to start a floor when [`up_gate`] says the binary is behind;
//!   * `self-upgrade` swaps the release asset in over the running binary.
//!
//! Every lookup is time-bounded and every failure is a warning, never a hang:
//! GitHub is unreachable on that box often enough (the #devbox-wake IPv4 loss)
//! that "cannot reach the API" must never be the thing that stops a floor.
//!
//! The tag spelling is checked against the remote, not guessed: `git ls-remote
//! --tags origin` lists `v1.0.4`, `v1.0.5`, `v1.0.6`, and `release-publish.sh`
//! tags `v$VERSION` to match. So the assets live under
//! `releases/download/v<version>/` and are `fwf-<version>-<slug>.tar.gz` plus
//! `.sha256`. `install.sh` built a `one-v<version>` URL — the pre-#641
//! spelling, which downloaded nothing — until #660 fixed it and pinned the two
//! together with a test. [`strip_tag`] still reads either spelling, so an old
//! tag in hand parses.

use std::path::Path;
use std::process::ExitCode;
use std::time::Duration;

/// The repo fwf is *released* from. Nothing to do with the floor's manifest
/// repo: a floor working on someone else's repo still upgrades from here.
pub const RELEASE_REPO: &str = "tbaums/fun-with-friends";
pub const API_BASE: &str = "https://api.github.com";
pub const DOWNLOAD_BASE: &str = "https://github.com";
/// The binary inside the release tarball, and the tarball's own prefix.
pub const BIN_NAME: &str = "fwf";
/// Set to 1 to start a floor on a stale fwf anyway. An env var, not a manifest
/// key: it is a one-shot boot override, not a per-floor setting.
pub const ALLOW_STALE_ENV: &str = "FWF_ALLOW_STALE";
/// A lookup that takes longer than this is a lookup that failed. `doctor` and
/// `up` both run it on the critical path of a boot.
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(5);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(120);
/// Nothing fwf publishes is near this; it caps what a redirect to somewhere
/// unexpected can make this process read.
const MAX_ASSET_BYTES: u64 = 64 * 1024 * 1024;

pub fn release_repo() -> String {
    std::env::var("FWF_RELEASE_REPO").unwrap_or_else(|_| RELEASE_REPO.to_string())
}

/// The version this binary was built as.
pub fn installed_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// A release tag without its prefix: `v1.0.6` and the pre-#641 `one-v1.0.4`
/// both read as the bare version. An already-bare version passes through.
pub fn strip_tag(tag: &str) -> &str {
    let t = tag.trim();
    let t = t.strip_prefix("one-").unwrap_or(t);
    t.strip_prefix('v').unwrap_or(t)
}

/// `major.minor.patch` as numbers, so `1.0.10` is newer than `1.0.9` — a
/// string compare says the opposite, which is the whole reason this exists.
/// Prerelease and build metadata are dropped (`1.0.6-rc1` is `1.0.6`); a
/// version this cannot read is `None` rather than a guess.
pub fn parse_version(s: &str) -> Option<(u64, u64, u64)> {
    let core = strip_tag(s).split(['-', '+']).next()?;
    let p: Vec<&str> = core.split('.').collect();
    if p.len() != 3 {
        return None;
    }
    Some((p[0].parse().ok()?, p[1].parse().ok()?, p[2].parse().ok()?))
}

/// Is `latest` newer than `installed`? A version neither side can parse is
/// never "newer": an unreadable tag must not refuse a floor.
pub fn is_behind(installed: &str, latest: &str) -> bool {
    match (parse_version(installed), parse_version(latest)) {
        (Some(a), Some(b)) => b > a,
        _ => false,
    }
}

/// The release asset slug for this host — the same mapping `install.sh` uses.
/// `None` where fwf publishes no asset, which becomes a refusal by name.
pub fn host_slug() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("macos-arm64"),
        ("linux", "x86_64") => Some("linux-x86_64"),
        _ => None,
    }
}

/// The unpacked directory (and so the tarball) a release publishes for one
/// version and host: `fwf-1.0.6-macos-arm64`.
pub fn asset_stem(version: &str, slug: &str) -> String {
    format!("{BIN_NAME}-{version}-{slug}")
}

/// Where that tarball is fetched from. The tag in the path is `v<version>` —
/// what the remote actually carries (`v1.0.4`, `v1.0.5`, `v1.0.6`), what
/// `release-publish.sh` tags, and what `install.sh` fetches; a test pins all
/// three (#660). The `.sha256` beside it is this URL plus that suffix.
pub fn asset_url(repo: &str, version: &str, slug: &str) -> String {
    format!(
        "{DOWNLOAD_BASE}/{repo}/releases/download/v{version}/{}.tar.gz",
        asset_stem(version, slug)
    )
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::builder()
        .timeout_connect(Duration::from_secs(3))
        .timeout(timeout)
        .build()
}

/// `tag_name` of `GET /repos/<repo>/releases/latest` — the API's own answer to
/// "what is the newest release", never a guess from a tag list or from
/// `install.sh`'s naming convention.
pub fn latest_tag(api_base: &str, repo: &str, token: Option<&str>) -> Result<String, String> {
    let url = format!(
        "{}/repos/{repo}/releases/latest",
        api_base.trim_end_matches('/')
    );
    let mut req = agent(LOOKUP_TIMEOUT)
        .get(&url)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "fwfd/0.1")
        .set("X-GitHub-Api-Version", "2022-11-28");
    if let Some(t) = token {
        req = req.set("Authorization", &format!("Bearer {t}"));
    }
    let body = match req.call() {
        Ok(r) => r.into_string().map_err(|e| e.to_string())?,
        Err(ureq::Error::Status(code, _)) => return Err(format!("github answered {code}")),
        Err(e) => return Err(e.to_string()),
    };
    let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    v["tag_name"]
        .as_str()
        .map(String::from)
        .ok_or_else(|| "the latest release has no tag_name".to_string())
}

/// An ops installation token when this host has App credentials, else `None`
/// and the lookup goes out unauthenticated. Never an error: a box with no
/// `apps.toml` still gets to know what the latest release is.
pub fn ops_token() -> Option<String> {
    let apps = crate::github::load_apps(&crate::github::apps_path()).ok()?;
    let ops = apps.0.get("ops")?;
    let perms = std::collections::BTreeMap::from([("contents", "read"), ("metadata", "read")]);
    crate::github::mint(ops, Some(&perms)).ok().map(|t| t.token)
}

/// What this host runs against what is published. `latest: None` is the
/// offline answer, and is never itself a failure.
pub struct Check {
    pub installed: String,
    pub latest: Option<String>,
    /// Why `latest` is unknown, kept for whoever asks.
    pub why: Option<String>,
}

impl Check {
    pub fn behind(&self) -> bool {
        self.latest
            .as_deref()
            .is_some_and(|l| is_behind(&self.installed, l))
    }

    /// The line `doctor` prints and a boot hook greps.
    pub fn line(&self) -> String {
        match &self.latest {
            None => format!(
                "fwf: installed v{} · latest unknown (offline)",
                self.installed
            ),
            Some(l) => format!(
                "fwf: installed v{} · latest v{l} · {}",
                self.installed,
                if self.behind() {
                    "BEHIND"
                } else {
                    "up to date"
                }
            ),
        }
    }
}

/// Ask GitHub once. Any failure — no network, a 5xx, a nonsense body — is
/// `latest: None`, which both callers treat as "say so and carry on".
pub fn check(api_base: &str, repo: &str, token: Option<&str>) -> Check {
    let installed = installed_version().to_string();
    match latest_tag(api_base, repo, token) {
        Ok(tag) => Check {
            installed,
            latest: Some(strip_tag(&tag).to_string()),
            why: None,
        },
        Err(e) => Check {
            installed,
            latest: None,
            why: Some(e),
        },
    }
}

/// The floor's own check, as `doctor` and `up` run it.
pub fn check_release() -> Check {
    check(API_BASE, &release_repo(), ops_token().as_deref())
}

/// What `up` does about it.
pub enum UpGate {
    /// Current (or ahead of the last release): start the floor, say nothing.
    Go,
    /// Start the floor, but say this first.
    Warn(String),
    /// Do not start a floor; exit 1 with this.
    Refuse(String),
}

/// A stale box must not start a floor silently — but an unreachable GitHub
/// must not stop one either, so only a *known* older version refuses.
pub fn up_gate(c: &Check, allow_stale: bool) -> UpGate {
    match (&c.latest, c.behind()) {
        (None, _) => UpGate::Warn(format!("{} — starting anyway", c.line())),
        (Some(_), false) => UpGate::Go,
        (Some(l), true) if allow_stale => UpGate::Warn(format!(
            "WARNING stale fwf — installed v{} · latest v{l}; {ALLOW_STALE_ENV} says start anyway",
            c.installed
        )),
        (Some(l), true) => UpGate::Refuse(format!(
            "refusing to start a floor on a stale fwf — installed v{} · latest v{l}. Run `fwf self-upgrade`, or set {ALLOW_STALE_ENV}=1 to start anyway.",
            c.installed
        )),
    }
}

/// Is the stale override set? Any non-empty value but `0` means yes.
pub fn allow_stale() -> bool {
    std::env::var(ALLOW_STALE_ENV).is_ok_and(|v| !v.is_empty() && v != "0")
}

/// The sha256 of a file, via whichever tool this host has — `shasum -a 256`
/// (macOS) or `sha256sum` (Linux), the pair `install.sh` already depends on.
/// No tool is a refusal: an unverified download is never installed.
pub fn sha256_file(p: &Path) -> Result<String, String> {
    for (bin, args) in [("shasum", &["-a", "256"][..]), ("sha256sum", &[][..])] {
        let Ok(out) = std::process::Command::new(bin).args(args).arg(p).output() else {
            continue;
        };
        if !out.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(h) = text.split_whitespace().next() {
            if h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) {
                return Ok(h.to_ascii_lowercase());
            }
        }
    }
    Err("no usable sha256 tool on this host (shasum -a 256 / sha256sum)".into())
}

/// Install the binary out of a downloaded release tarball, atomically:
/// checksum, unpack, write-then-rename over `dest`.
///
/// Nothing touches `dest` until the published checksum matches and the tarball
/// really carries a binary, so every refusal in here leaves the running fwf
/// byte-identical — the property that makes a boot-time upgrade safe at all.
pub fn install_asset(
    tarball: &Path,
    sha_text: &str,
    version: &str,
    slug: &str,
    dest: &Path,
) -> Result<(), String> {
    let name = format!("{BIN_NAME}-{version}-{slug}");
    let want = sha_text
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    if want.len() != 64 {
        return Err(format!(
            "the published checksum for {name}.tar.gz is unreadable ({sha_text:?}) — not installing it"
        ));
    }
    let got = sha256_file(tarball)?;
    if got != want {
        return Err(format!(
            "sha256 mismatch for {name}.tar.gz (want {want}, got {got}) — not installing it"
        ));
    }
    let work = tarball
        .parent()
        .unwrap_or(Path::new("."))
        .join(format!("unpack-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).map_err(|e| format!("cannot unpack into {work:?}: {e}"))?;
    let out = std::process::Command::new("tar")
        .arg("-C")
        .arg(&work)
        .arg("-xzf")
        .arg(tarball)
        .output()
        .map_err(|e| format!("tar: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{name}.tar.gz did not unpack: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let bin = work.join(&name).join(BIN_NAME);
    if !bin.is_file() {
        let _ = std::fs::remove_dir_all(&work);
        return Err(format!(
            "{name}.tar.gz carries no {BIN_NAME} binary — not installing it"
        ));
    }
    // Staged in dest's own directory: a rename is only atomic within one
    // filesystem, and the temp dir is often not the one the binary lives on.
    let staged = dest
        .parent()
        .unwrap_or(Path::new("."))
        .join(format!(".{BIN_NAME}-upgrade-{}", std::process::id()));
    std::fs::copy(&bin, &staged).map_err(|e| format!("cannot stage next to {dest:?}: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("cannot make {staged:?} executable: {e}"))?;
    }
    let landed =
        std::fs::rename(&staged, dest).map_err(|e| format!("cannot replace {dest:?}: {e}"));
    let _ = std::fs::remove_dir_all(&work);
    if landed.is_err() {
        let _ = std::fs::remove_file(&staged);
    }
    landed
}

fn download(url: &str, to: &Path) -> Result<(), String> {
    let resp = agent(DOWNLOAD_TIMEOUT)
        .get(url)
        .set("User-Agent", "fwfd/0.1")
        .call()
        .map_err(|e| format!("{url}: {e}"))?;
    let mut f = std::fs::File::create(to).map_err(|e| format!("cannot write {to:?}: {e}"))?;
    let mut r = std::io::Read::take(resp.into_reader(), MAX_ASSET_BYTES);
    std::io::copy(&mut r, &mut f).map_err(|e| format!("{url}: {e}"))?;
    Ok(())
}

fn download_string(url: &str) -> Result<String, String> {
    agent(DOWNLOAD_TIMEOUT)
        .get(url)
        .set("User-Agent", "fwfd/0.1")
        .call()
        .map_err(|e| format!("{url}: {e}"))?
        .into_string()
        .map_err(|e| format!("{url}: {e}"))
}

/// `fwf self-upgrade [--to vX.Y.Z] [--force]`: replace this binary with the
/// published release asset for this host. Release assets only — a devbox that
/// has to build fwf from source at boot is a devbox that boots in ten minutes.
///
/// Exit 1 for every refusal (already current, no asset for this host, a
/// download or a checksum that did not hold up), and the binary is untouched
/// in all of them. A floor already running is unaffected: this swaps the file
/// on disk, nothing more, and the running process keeps its own image until it
/// restarts.
pub fn self_upgrade(args: &[String]) -> ExitCode {
    let repo = release_repo();
    let installed = installed_version();
    let force = args.iter().any(|a| a == "--force");
    let target = match crate::verbs::get(args, "--to") {
        Some(t) => strip_tag(&t).to_string(),
        None => match latest_tag(API_BASE, &repo, ops_token().as_deref()) {
            Ok(t) => strip_tag(&t).to_string(),
            Err(e) => {
                eprintln!("fwf self-upgrade: cannot read the latest release of {repo} ({e}); nothing was changed");
                return ExitCode::from(1);
            }
        },
    };
    if parse_version(&target).is_none() {
        eprintln!("fwf self-upgrade: {target:?} is not a version (expected --to X.Y.Z)");
        return ExitCode::from(2);
    }
    if target == installed && !force {
        println!("fwf self-upgrade: already at v{installed} (--force reinstalls it)");
        return ExitCode::from(1);
    }
    let Some(slug) = host_slug() else {
        eprintln!(
            "fwf self-upgrade: no prebuilt fwf asset for {}-{}",
            std::env::consts::OS,
            std::env::consts::ARCH
        );
        return ExitCode::from(1);
    };
    let dest = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("fwf self-upgrade: cannot find the running binary ({e})");
            return ExitCode::from(1);
        }
    };
    let tmp = std::env::temp_dir().join(format!("fwf-upgrade-{}", std::process::id()));
    let code = match fetch_and_install(&repo, &target, slug, &tmp, &dest) {
        Ok(()) => {
            println!(
                "fwf self-upgrade: upgraded v{installed} → v{target} ({})",
                dest.display()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("fwf self-upgrade: {e}");
            ExitCode::from(1)
        }
    };
    let _ = std::fs::remove_dir_all(&tmp);
    code
}

fn fetch_and_install(
    repo: &str,
    version: &str,
    slug: &str,
    tmp: &Path,
    dest: &Path,
) -> Result<(), String> {
    std::fs::create_dir_all(tmp).map_err(|e| format!("cannot use {tmp:?}: {e}"))?;
    let url = asset_url(repo, version, slug);
    let tarball = tmp.join(format!("{}.tar.gz", asset_stem(version, slug)));
    download(&url, &tarball)?;
    let sha = download_string(&format!("{url}.sha256"))?;
    install_asset(&tarball, &sha, version, slug, dest)
}

#[cfg(test)]
mod tests;
