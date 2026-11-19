//! `one/scripts/release-publish.sh` only tags (#727). Every release asset is
//! built by GitHub CI, so the script refuses what it must, then pushes an
//! annotated tag whose message is the notes — and never builds, never runs
//! `gh`. Each test runs the real script in a throwaway repo with a bare
//! `origin`, `cargo` wrapped to log its arguments and `gh` replaced by a shim
//! that logs and fails.
//!
//! The stale-lock refusal is pinned in `promote.rs`
//! (`the_publisher_refuses_a_stale_lock_before_it_tags_anything`) and the
//! `TAG="v$VERSION"` spelling in `upgrade/tests.rs`.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const NOTES: &str = "## fwf 1.0.27\n\n# Highlights\n\n- every asset is built by CI\n";

struct Rig {
    root: PathBuf,
    work: PathBuf,
    origin: PathBuf,
    notes: PathBuf,
    log: PathBuf,
    shims: PathBuf,
}

/// Git with no user or system config, so a signing or hook setting on the
/// host cannot change what is tested; the identity comes from the env.
fn git_cmd(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir);
    isolate(&mut c);
    c
}

fn isolate(c: &mut Command) {
    c.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t");
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = git_cmd(dir).args(args).output().unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn lock(v: &str) -> String {
    format!("version = 4\n\n[[package]]\nname = \"fwfd\"\nversion = \"{v}\"\n")
}

fn rig(name: &str) -> Rig {
    let root = std::env::temp_dir().join(format!("fwfd-relpub-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (work, origin, shims) = (
        root.join("work"),
        root.join("origin.git"),
        root.join("shims"),
    );
    let one = work.join("one");
    std::fs::create_dir_all(one.join("src")).unwrap();
    std::fs::create_dir_all(one.join("scripts")).unwrap();
    std::fs::create_dir_all(&shims).unwrap();
    std::fs::copy(
        concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/release-publish.sh"),
        one.join("scripts/release-publish.sh"),
    )
    .unwrap();
    std::fs::write(
        one.join("Cargo.toml"),
        "[package]\nname = \"fwfd\"\nversion = \"1.0.27\"\nedition = \"2021\"\n\n[[bin]]\nname = \"fwf\"\npath = \"src/main.rs\"\n",
    )
    .unwrap();
    std::fs::write(one.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(one.join("Cargo.lock"), lock("1.0.27")).unwrap();
    std::fs::write(work.join(".gitignore"), "target/\n").unwrap();
    // the notes live outside the tree, as an operator's notes file would
    let notes = root.join("notes.md");
    std::fs::write(&notes, NOTES).unwrap();
    let log = root.join("calls.log");
    std::fs::write(&log, "").unwrap();
    // cargo: log, then the real one (the lock check needs it); gh: log, fail
    // an absolute path, so the shim never finds itself on PATH
    let real_cargo = std::env::var("CARGO").unwrap_or_else(|_| {
        let out = Command::new("sh")
            .args(["-c", "command -v cargo"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    });
    assert!(
        real_cargo.starts_with('/'),
        "no absolute cargo: {real_cargo:?}"
    );
    let shim = |n: &str, body: String| {
        let p = shims.join(n);
        std::fs::write(&p, body).unwrap();
        Command::new("chmod").arg("+x").arg(&p).status().unwrap();
    };
    shim(
        "cargo",
        format!(
            "#!/bin/sh\necho \"cargo $*\" >> '{}'\nexec '{real_cargo}' \"$@\"\n",
            log.display()
        ),
    );
    shim(
        "gh",
        format!("#!/bin/sh\necho \"gh $*\" >> '{}'\nexit 1\n", log.display()),
    );
    let out = git_cmd(&root)
        .args(["init", "-q", "--bare", "-b", "main"])
        .arg(&origin)
        .output()
        .unwrap();
    assert!(out.status.success());
    git(&work, &["init", "-q", "-b", "main"]);
    git(&work, &["add", "-A"]);
    git(&work, &["commit", "-qm", "release 1.0.27"]);
    git(
        &work,
        &["remote", "add", "origin", origin.to_str().unwrap()],
    );
    git(&work, &["push", "-q", "origin", "main"]);
    Rig {
        root,
        work,
        origin,
        notes,
        log,
        shims,
    }
}

impl Rig {
    fn cut_with(&self, notes: Option<&Path>) -> (Output, String) {
        let mut c = Command::new("bash");
        c.arg(self.work.join("one/scripts/release-publish.sh"));
        if let Some(n) = notes {
            c.arg(n);
        }
        isolate(&mut c);
        let path = format!(
            "{}:{}",
            self.shims.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let out = c
            .env("PATH", path)
            .current_dir(&self.work)
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        (out, text)
    }
    fn cut(&self) -> (Output, String) {
        self.cut_with(Some(&self.notes.clone()))
    }
    fn tags(&self) -> (String, String) {
        (
            git(&self.work, &["tag", "--list"]),
            git(&self.origin, &["tag", "--list"]),
        )
    }
    /// Refused with `needle`, and no tag anywhere.
    fn refuses(&self, notes: Option<&Path>, needle: &str) {
        let before = self.tags();
        let (out, text) = self.cut_with(notes);
        assert!(!out.status.success(), "not refused: {text}");
        assert!(text.contains(needle), "want {needle:?}: {text}");
        assert_eq!(self.tags(), before, "a refusal tagged something: {text}");
    }
    fn calls(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap()
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn a_cut_pushes_an_annotated_tag_carrying_the_notes_and_nothing_else() {
    let r = rig("ok");
    let head = git(&r.work, &["rev-parse", "HEAD"]);
    let (out, text) = r.cut();
    assert!(out.status.success(), "{text}");
    // on origin, annotated, at HEAD
    assert_eq!(
        git(&r.origin, &["cat-file", "-t", "refs/tags/v1.0.27"]),
        "tag",
        "not an annotated tag"
    );
    assert_eq!(git(&r.origin, &["rev-parse", "v1.0.27^{commit}"]), head);
    // the message is the notes, Markdown headings included (the default
    // cleanup would strip every line starting with `#`)
    let msg = git(
        &r.origin,
        &["for-each-ref", "--format=%(contents)", "refs/tags/v1.0.27"],
    );
    assert_eq!(msg, NOTES.trim_end(), "{msg}");
    // it points at CI and at the operator's proof
    assert!(text.contains("actions/workflows/one-release.yml"), "{text}");
    assert!(
        text.contains("release-check --repo tbaums/fun-with-friends --tag v1.0.27 --expect 4"),
        "{text}"
    );
    // no gh at all, and cargo only asked about the lock: no build, no gate
    let calls = r.calls();
    assert!(!calls.contains("gh "), "{calls}");
    for line in calls.lines() {
        assert!(line.starts_with("cargo metadata --locked"), "{calls}");
    }
    assert!(!calls.is_empty(), "the lock was never checked");
}

#[test]
fn the_script_has_no_build_and_no_release_create() {
    let s = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/scripts/release-publish.sh"
    ))
    .unwrap();
    for line in s.lines() {
        let code = line.split('#').next().unwrap_or_default();
        for banned in ["cargo build", "gh release", "cargo test", "cargo clippy"] {
            assert!(
                !code.contains(banned),
                "release-publish.sh runs {banned}: {line}"
            );
        }
    }
}

#[test]
fn no_notes_or_empty_notes_are_refused() {
    let r = rig("notes");
    r.refuses(None, "usage:");
    r.refuses(Some(&r.root.join("nope.md")), "no notes file");
    let blank = r.root.join("blank.md");
    std::fs::write(&blank, " \n\t\n").unwrap();
    r.refuses(Some(&blank), "is empty");
    std::fs::write(&blank, "").unwrap();
    r.refuses(Some(&blank), "is empty");
}

#[test]
fn a_dirty_tree_is_refused() {
    let r = rig("dirty");
    std::fs::write(r.work.join("stray.txt"), "x").unwrap();
    r.refuses(Some(&r.notes), "the tree is dirty");
}

#[test]
fn a_stale_lock_is_refused() {
    let r = rig("lock");
    std::fs::write(r.work.join("one/Cargo.lock"), lock("1.0.26")).unwrap();
    git(&r.work, &["commit", "-qam", "lock left behind"]);
    git(&r.work, &["push", "-q", "origin", "main"]);
    r.refuses(Some(&r.notes), "Cargo.lock is stale");
}

#[test]
fn head_that_is_not_origin_main_is_refused() {
    let r = rig("head");
    // ahead of origin/main: a commit nobody promoted
    std::fs::write(r.work.join("one/src/main.rs"), "fn main() { }\n").unwrap();
    git(&r.work, &["commit", "-qam", "unpromoted"]);
    r.refuses(Some(&r.notes), "is not origin/main");
    // and behind it: main moved on since this checkout
    git(&r.work, &["push", "-q", "origin", "main"]);
    git(&r.work, &["reset", "-q", "--hard", "HEAD~1"]);
    r.refuses(Some(&r.notes), "is not origin/main");
}

#[test]
fn a_version_already_tagged_here_or_on_origin_is_refused() {
    let r = rig("tagged");
    git(&r.work, &["tag", "-a", "v1.0.27", "-m", "by hand"]);
    r.refuses(Some(&r.notes), "already exists locally");
    git(&r.work, &["push", "-q", "origin", "v1.0.27"]);
    git(&r.work, &["tag", "-d", "v1.0.27"]);
    r.refuses(Some(&r.notes), "already exists on origin");
}

#[test]
fn a_rejected_push_leaves_no_local_tag() {
    let r = rig("rejected");
    let hook = r.origin.join("hooks/pre-receive");
    std::fs::write(&hook, "#!/bin/sh\necho no tags today >&2\nexit 1\n").unwrap();
    Command::new("chmod").arg("+x").arg(&hook).status().unwrap();
    let (out, text) = r.cut();
    assert!(!out.status.success(), "{text}");
    assert!(text.contains("pushing v1.0.27 failed"), "{text}");
    assert_eq!(r.tags(), (String::new(), String::new()), "{text}");
}
