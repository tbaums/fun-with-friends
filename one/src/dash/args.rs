//! #628 — what `fwf dash` decides before it touches a manifest or a record.
//!
//! `fwf dash --help` used to draw a board, for whatever floor `default_log()`
//! happened to point at: the verb read only the flags it knew, so `--help`
//! and every typo were silently ignored, and a manifest that failed to load
//! was swallowed by `.ok()`. An operator working the transom floor got a
//! screen of fun-with-friends and no hint that anything had gone wrong.
//!
//! Everything here is pure — argv in, a decision and a string out — so the
//! three early exits are testable without a terminal, a manifest or a record.

use crate::manifest::{Manifest, ManifestError};
use std::path::{Path, PathBuf};

/// Flags `dash` accepts. Anything else starting with `-` is a typo, and a
/// typo that renders someone else's floor is worse than a refusal. A new
/// dash flag is added here in the same commit that adds it to `USAGE`.
const KNOWN: [&str; 8] = [
    "--manifest",
    "--log",
    "--tab",
    "--watch",
    "--once",
    "--no-color",
    "--help",
    "-h",
];

/// The four of those that take a value; their value is never a flag.
const TAKES_VALUE: [&str; 4] = ["--manifest", "--log", "--tab", "--watch"];

#[derive(Debug, PartialEq, Eq)]
pub enum Dash {
    /// Print this and exit 0, before any manifest or record is read.
    Help(&'static str),
    /// Name this flag on stderr and exit 2.
    Unknown(String),
    /// `--tab` given a value that is not a tab; exit 2.
    BadTab(String),
    Run,
}

/// Help wins over everything, including a typo in the same command line:
/// someone asking what the flags are is not asking for a board.
pub fn parse(args: &[String]) -> Dash {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Dash::Help(usage_line());
    }
    let mut skip = false;
    for a in args {
        if std::mem::take(&mut skip) {
            continue;
        }
        if a.starts_with('-') && !KNOWN.contains(&a.as_str()) {
            return Dash::Unknown(a.clone());
        }
        skip = TAKES_VALUE.contains(&a.as_str());
    }
    // Checked here too, so every refusal about a flag happens before a
    // manifest is loaded or a record is read.
    if let Some(t) = value(args, "--tab") {
        if crate::dash::view::Tab::parse(&t).is_none() {
            return Dash::BadTab(t);
        }
    }
    Dash::Run
}

/// The tab to open on, once `parse` has accepted the flags.
pub fn tab(args: &[String]) -> crate::dash::view::Tab {
    value(args, "--tab")
        .and_then(|t| crate::dash::view::Tab::parse(&t))
        .unwrap_or(crate::dash::view::Tab::Seats)
}

/// The value given to `flag`, if any.
fn value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1).cloned())
}

/// The dash's own line out of the one `USAGE` string — the flags and the
/// watch keys are already documented there, and a second copy would be the
/// one that goes stale.
pub fn usage_line() -> &'static str {
    crate::USAGE
        .lines()
        .find(|l| l.trim_start().starts_with("fwf dash "))
        .map(str::trim_start)
        .unwrap_or("fwf dash [--manifest PATH] [--log PATH] [--watch SECS] [--once] [--tab 1-5] [--no-color]")
}

/// Said out loud when no manifest loads: which one was tried, why it did not,
/// and — the part the operator actually needs — which record is on screen
/// instead. Warn, never refuse: `--log` on its own, with no manifest
/// anywhere, is a legitimate way to read a record.
pub fn fallback_note(attempted: &Path, err: &ManifestError, log: &Path) -> String {
    // `ManifestError` names the path when it is a missing file and does not
    // when it is a parse error; the operator needs it either way, so it is
    // appended only where the message lacks it.
    let reason = err.to_string();
    let path = attempted.display().to_string();
    let reason = if reason.contains(&path) {
        reason
    } else {
        format!("{reason} ({path})")
    };
    format!(
        "fwf dash: {reason} — reading {} instead; the board below is whatever floor that record belongs to",
        log.display()
    )
}

/// The manifest and the record this invocation will read, plus the warning it
/// owes the operator. Resolved once per invocation, so a watch loop cannot
/// repeat the warning every tick.
pub fn sources(args: &[String]) -> (Option<Manifest>, PathBuf, Option<String>) {
    let attempted = value(args, "--manifest")
        .map(PathBuf::from)
        .unwrap_or_else(|| Manifest::default_path(Path::new(".")));
    let loaded = Manifest::load(&attempted);
    let m = loaded.as_ref().ok();
    let log = value(args, "--log").map(PathBuf::from).unwrap_or_else(|| {
        m.map(|m| crate::slice::defaults(&m.floor()).0)
            .filter(|p| p.exists())
            .unwrap_or_else(crate::default_log)
    });
    let note = loaded
        .as_ref()
        .err()
        .map(|e| fallback_note(&attempted, e, &log));
    (loaded.ok(), log, note)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn help_wins_over_every_other_flag_and_quotes_the_usage_line() {
        let u = usage_line();
        assert!(u.starts_with("fwf dash "), "{u}");
        assert!(u.contains("--watch SECS") && u.contains("--tab"), "{u}");
        for a in [
            &["--help"][..],
            &["-h"][..],
            &["--watch", "5", "--help"][..],
            &["--bogus", "--help"][..],
        ] {
            assert_eq!(parse(&argv(a)), Dash::Help(u), "{a:?}");
        }
    }

    #[test]
    fn an_unknown_flag_is_named_and_a_known_flags_value_is_never_mistaken_for_one() {
        assert_eq!(parse(&argv(&["--bogus"])), Dash::Unknown("--bogus".into()));
        assert_eq!(
            parse(&argv(&["--tab", "3", "-x"])),
            Dash::Unknown("-x".into())
        );
        assert_eq!(parse(&argv(&[])), Dash::Run);
        assert_eq!(
            parse(&argv(&[
                "--manifest",
                "m.toml",
                "--log",
                "r.jsonl",
                "--tab",
                "2",
                "--watch",
                "5",
                "--once",
                "--no-color",
            ])),
            Dash::Run,
            "every flag the usage line documents is known"
        );
        // a value that looks like a flag belongs to its flag, not to the scan
        assert_eq!(parse(&argv(&["--log", "--weird-name"])), Dash::Run);
    }

    #[test]
    fn a_manifest_that_does_not_load_names_the_record_now_on_screen() {
        let missing = Path::new("/nonexistent/.fwf/fwf.toml");
        let log = Path::new("/tmp/some-floor/run.jsonl");
        let err = Manifest::load(missing).unwrap_err();
        let note = fallback_note(missing, &err, log);
        assert!(note.starts_with("fwf dash: "), "{note}");
        assert!(note.contains("/nonexistent/.fwf/fwf.toml"), "{note}");
        assert!(note.contains("/tmp/some-floor/run.jsonl"), "{note}");
        // and an unparseable one says so about the path it actually read
        let dir = std::env::temp_dir().join(format!("fwfd-dash628-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let bad = dir.join("fwf.toml");
        std::fs::write(&bad, "repo = [not toml\n").unwrap();
        let note = fallback_note(&bad, &Manifest::load(&bad).unwrap_err(), log);
        assert!(note.contains(&bad.display().to_string()), "{note}");
        assert!(note.contains("/tmp/some-floor/run.jsonl"), "{note}");
        let _ = std::fs::remove_file(&bad);
    }

    /// `ExitCode` is opaque — no `PartialEq` — so the code a verb returns is
    /// compared the only way it can be: by its own `Debug`.
    fn code(c: std::process::ExitCode) -> String {
        format!("{c:?}")
    }

    /// The bug itself: `fwf dash --help` rendered a board. The `--log` here
    /// points at nothing, so a run that reads the record exits 2 — help and
    /// the unknown-flag refusal can only pass by returning first.
    #[test]
    fn help_and_a_typo_answer_without_reading_a_record() {
        let ok = code(std::process::ExitCode::SUCCESS);
        let two = code(std::process::ExitCode::from(2));
        for a in [&["--help"][..], &["-h"][..]] {
            let mut v = argv(a);
            v.extend(argv(&["--log", "/nonexistent/run.jsonl"]));
            assert_eq!(code(crate::verbs::dash(&v)), ok, "{a:?}");
        }
        let mut v = argv(&["--bogus"]);
        v.extend(argv(&["--log", "/nonexistent/run.jsonl"]));
        assert_eq!(code(crate::verbs::dash(&v)), two);
        assert_eq!(code(crate::verbs::dash(&argv(&["--tab", "9"]))), two);
        // and without those guards the same command line does read the record
        assert_eq!(
            code(crate::verbs::dash(&argv(&[
                "--log",
                "/nonexistent/run.jsonl"
            ]))),
            two
        );
    }

    /// An unloadable manifest warns and falls back; it never panics and never
    /// refuses, because a `--log`-only dash is a legitimate invocation.
    #[test]
    fn an_unloadable_manifest_still_renders_the_record_it_fell_back_to() {
        let golden = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/dash/testdata/golden_run.jsonl"
        );
        let v = argv(&[
            "--manifest",
            "/nonexistent/.fwf/fwf.toml",
            "--log",
            golden,
            "--once",
            "--no-color",
        ]);
        let (m, log, note) = sources(&v);
        assert!(m.is_none() && note.is_some());
        assert_eq!(log, PathBuf::from(golden));
        assert_eq!(
            code(crate::verbs::dash(&v)),
            code(std::process::ExitCode::SUCCESS)
        );
    }

    #[test]
    fn sources_warns_once_and_still_hands_back_a_record_to_read() {
        let a = argv(&[
            "--manifest",
            "/nonexistent/.fwf/fwf.toml",
            "--log",
            "/tmp/some-floor/run.jsonl",
        ]);
        let (m, log, note) = sources(&a);
        assert!(m.is_none());
        assert_eq!(log, PathBuf::from("/tmp/some-floor/run.jsonl"));
        let note = note.expect("a failed load is never silent");
        assert!(note.contains("/tmp/some-floor/run.jsonl"), "{note}");
        // one string, resolved once: the watch loop has nothing left to repeat
        assert_eq!(note.matches("fwf dash:").count(), 1);
    }
}
