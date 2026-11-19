//! `one/scripts/release-draft.sh` (#734): one-release.yml's draft job. v1.0.27
//! never got a release because that job ran `gh release create … --repo …
//! --notes-from-tag`, which gh refuses before any network call, and nothing
//! ran that line before a real tag push. Each test runs the real script in a
//! throwaway repo whose bare `origin` holds the tag, with a fake `gh` first on
//! `PATH`. The fake logs its argv, copies the notes file, answers the releases
//! list from a fixture, and refuses `--notes-from-tag` with `--repo` the way gh
//! does: the only gh rule this needs.

use std::path::{Path, PathBuf};
use std::process::Command;

const TAG: &str = "v1.0.28";
/// What release-publish.sh writes: Markdown headings a default cleanup strips.
const NOTES: &str = "## fwf 1.0.28\n\n# Highlights\n\n- the draft step works again\n";
const REFUSAL: &str = "using `--notes-from-tag` with `--repo` is not supported";

struct Rig {
    root: PathBuf,
    work: PathBuf,
    shims: PathBuf,
}

fn git(dir: &Path, args: &[&str]) {
    let mut c = Command::new("git");
    let out = isolate(c.arg("-C").arg(dir).args(args)).output().unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// No user or system git config, so a host's signing or hook setting cannot
/// change what is tested.
fn isolate(c: &mut Command) -> &mut Command {
    c.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
}

/// A repo at `root/work` with one commit, tagged `TAG` with message `msg`
/// (verbatim, annotated) or lightweight (`None`), pushed to a bare `origin`;
/// the local tag is then deleted, so the script has to fetch it. `releases`
/// is the fixture: the ids the releases list answers for `TAG`, one a line.
fn rig(name: &str, msg: Option<&str>, releases: &str) -> Rig {
    let root = std::env::temp_dir().join(format!("fwfd-reldraft-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (work, origin, shims) = (
        root.join("work"),
        root.join("origin.git"),
        root.join("shims"),
    );
    std::fs::create_dir_all(&work).unwrap();
    std::fs::create_dir_all(&shims).unwrap();
    std::fs::write(root.join("releases"), releases).unwrap();
    std::fs::write(root.join("calls.log"), "").unwrap();
    git(&root, &["init", "-q", "--bare", origin.to_str().unwrap()]);
    git(&work, &["init", "-q"]);
    git(
        &work,
        &["commit", "-q", "--allow-empty", "-m", "release 1.0.28"],
    );
    git(
        &work,
        &["remote", "add", "origin", origin.to_str().unwrap()],
    );
    let msg_file = root.join("tag-message");
    match msg {
        Some(m) => {
            std::fs::write(&msg_file, m).unwrap();
            let f = msg_file.to_str().unwrap();
            git(&work, &["tag", "-a", "--cleanup=verbatim", "-F", f, TAG]);
        }
        None => git(&work, &["tag", TAG]),
    }
    git(&work, &["push", "-q", "origin", TAG]);
    git(&work, &["tag", "-d", TAG]);
    let gh = shims.join("gh");
    std::fs::write(&gh, fake_gh(&root)).unwrap();
    Command::new("chmod").arg("+x").arg(&gh).status().unwrap();
    Rig { root, work, shims }
}

/// Every call is one log line of `[arg]`s. `release create` is refused as gh
/// refuses it, or its `--notes-file` is copied to `notes.got`.
fn fake_gh(root: &Path) -> String {
    let r = root.display();
    format!(
        r#"#!/bin/sh
for a in "$@"; do printf '[%s]' "$a"; done >> '{r}/calls.log'
echo >> '{r}/calls.log'
case "$1 $2" in
  "api repos/o/r/releases?per_page=100") cat '{r}/releases' ;;
  "api repos/o/r/releases/"*) echo "reusing release ${{2##*/}}" ;;
  "release create")
    nft= repo= prev= file=
    for a in "$@"; do
      case "$a" in --notes-from-tag) nft=1 ;; --repo) repo=1 ;; esac
      [ "$prev" = --notes-file ] && file=$a
      prev=$a
    done
    if [ -n "$nft" ] && [ -n "$repo" ]; then echo '{REFUSAL}' >&2; exit 1; fi
    if [ -n "$file" ]; then cp "$file" '{r}/notes.got'; fi ;;
  *) echo "fake gh: unexpected call" >&2; exit 1 ;;
esac
"#
    )
}

impl Rig {
    /// (exit code, stdout+stderr, the calls that were `gh release create`)
    fn run(&self) -> (i32, String, Vec<String>) {
        let path = format!(
            "{}:{}",
            self.shims.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let out = isolate(Command::new("bash").arg(script()).args([TAG, "1.0.28"]))
            .env("PATH", path)
            .env("GITHUB_REPOSITORY", "o/r")
            .current_dir(&self.work)
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let calls = std::fs::read_to_string(self.root.join("calls.log")).unwrap();
        let creates = calls
            .lines()
            .filter(|l| l.starts_with("[release][create]"))
            .map(String::from)
            .collect();
        (out.status.code().unwrap_or(-1), text, creates)
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/release-draft.sh")
}

#[test]
fn no_release_yet_creates_one_draft_whose_notes_are_the_tag_message() {
    let r = rig("ok", Some(NOTES), "");
    let (code, text, creates) = r.run();
    assert_eq!(code, 0, "{text}");
    assert_eq!(creates.len(), 1, "{creates:?}\n{text}");
    let c = &creates[0];
    for want in [
        "[v1.0.28]",
        "[--repo][o/r]",
        "[--draft]",
        "[--verify-tag]",
        "[--title][fwf 1.0.28]",
        "[--notes-file][",
    ] {
        assert!(c.contains(want), "no {want} in {c}");
    }
    assert!(!c.contains("--notes-from-tag"), "{c}");
    // the notes file lives outside the checkout
    assert!(!c.contains(&r.work.display().to_string()), "{c}");
    let got = std::fs::read(r.root.join("notes.got")).expect("no notes file reached gh");
    assert_eq!(String::from_utf8_lossy(&got), NOTES, "not byte for byte");
    assert!(
        text.contains("created a draft release for v1.0.28"),
        "{text}"
    );
}

#[test]
fn one_release_is_reused_and_more_than_one_is_refused() {
    let r = rig("one", Some(NOTES), "42\n");
    let (code, text, creates) = r.run();
    assert_eq!((code, creates.len()), (0, 0), "{text}");
    assert!(text.contains("reusing release 42"), "{text}");

    let r = rig("two", Some(NOTES), "41\n42\n");
    let (code, text, creates) = r.run();
    assert_eq!((code, creates.len()), (1, 0), "{text}");
    assert!(text.contains("v1.0.28 has 2 releases"), "{text}");
}

#[test]
fn a_lightweight_tag_or_an_empty_message_creates_nothing() {
    for (name, msg, needle) in [
        ("light", None, "is a lightweight tag"),
        ("empty", Some(""), "has an empty message"),
        ("blank", Some(" \n\t\n"), "has an empty message"),
    ] {
        let r = rig(name, msg, "");
        let (code, text, creates) = r.run();
        assert_eq!((code, creates.len()), (1, 0), "{name}: {text}");
        assert!(text.contains(needle), "{name}: want {needle:?}: {text}");
    }
}

/// The workflow cannot drift back: its only release creation is the script.
#[test]
fn the_workflow_drafts_only_through_the_script_and_ci_runs_on_it() {
    let dot_github = Path::new(env!("CARGO_MANIFEST_DIR")).join("../.github/workflows");
    let wf = std::fs::read_to_string(dot_github.join("one-release.yml")).unwrap();
    assert!(
        !wf.contains("gh release create"),
        "one-release.yml runs gh release create itself; draft through scripts/release-draft.sh"
    );
    let draft: Vec<&str> = wf
        .lines()
        .skip_while(|l| *l != "  draft:")
        .skip(1)
        .take_while(|l| !(l.starts_with("  ") && !l.starts_with("   ") && l.ends_with(':')))
        .collect();
    assert!(
        draft
            .iter()
            .any(|l| l.trim_start().starts_with("run: scripts/release-draft.sh")),
        "the draft job does not run scripts/release-draft.sh: {draft:#?}"
    );
    let ci = std::fs::read_to_string(dot_github.join("one-ci.yml")).unwrap();
    let paths: Vec<&str> = ci
        .lines()
        .filter(|l| l.trim_start().starts_with("paths:"))
        .collect();
    assert_eq!(paths.len(), 2, "{paths:?}");
    for p in paths {
        assert!(p.contains("'.github/workflows/one-release.yml'"), "{p}");
    }
}
