//! T-16 — per-cycle cost accounting from the seat's own transcript.
//!
//! Claude Code writes one JSONL transcript per session under
//! `$HOME/.claude/projects/<encoded cwd>/<session>.jsonl`; every assistant
//! message carries `message.usage` with input / cache-read / cache-creation /
//! output token counts and an ISO timestamp. A cycle's cost is the sum of the
//! assistant messages written after the wake. That is measured, not modelled,
//! and it is what the run record stores.

use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    pub messages: u64,
    pub input: u64,
    pub cache_read: u64,
    pub cache_create: u64,
    pub output: u64,
}

impl Usage {
    /// What the meter effectively charges for (input-side tokens including
    /// cache reads, which are the bulk on a warm seat) and what was produced.
    pub fn tokens_in(&self) -> u64 {
        self.input + self.cache_read + self.cache_create
    }
    pub fn tokens_out(&self) -> u64 {
        self.output
    }
}

/// The transcript directory for a worktree under a given HOME:
/// `<home>/.claude/projects/<cwd with '/' and '.' → '-'>` (e.g.
/// `/Users/mt/.fwf/floors/x/wt-impl1` → `-Users-mt--fwf-floors-x-wt-impl1`).
pub fn project_dir(home: &Path, worktree: &Path) -> PathBuf {
    let enc = worktree.to_string_lossy().replace(['/', '.'], "-");
    home.join(".claude/projects").join(enc)
}

/// Newest transcript in a project dir, if any.
pub fn newest_transcript(project_dir: &Path) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for e in std::fs::read_dir(project_dir).ok()?.flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "jsonl") {
            if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
                if best.as_ref().is_none_or(|(t, _)| m > *t) {
                    best = Some((m, p));
                }
            }
        }
    }
    best.map(|(_, p)| p)
}

fn iso_to_epoch(s: &str) -> Option<u64> {
    // "2026-09-10T01:52:50.945Z" → seconds since epoch (UTC), no external crate.
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let t = time.trim_end_matches('Z');
    let mut tp = t.split(':');
    let (hh, mm) = (
        tp.next()?.parse::<i64>().ok()?,
        tp.next()?.parse::<i64>().ok()?,
    );
    let ss = tp.next()?.split('.').next()?.parse::<i64>().ok()?;
    // days from civil (Howard Hinnant)
    let (y2, m2) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * m2 + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some((days * 86400 + hh * 3600 + mm * 60 + ss) as u64)
}

/// Sum assistant usage in `transcript` for messages at or after `since` (unix secs).
pub fn usage_since(transcript: &Path, since: u64) -> std::io::Result<Usage> {
    let text = std::fs::read_to_string(transcript)?;
    let mut u = Usage::default();
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v["type"].as_str() != Some("assistant") {
            continue;
        }
        let ts = v["timestamp"].as_str().and_then(iso_to_epoch).unwrap_or(0);
        if ts < since {
            continue;
        }
        let usage = &v["message"]["usage"];
        if usage.is_null() {
            continue;
        }
        u.messages += 1;
        u.input += usage["input_tokens"].as_u64().unwrap_or(0);
        u.cache_read += usage["cache_read_input_tokens"].as_u64().unwrap_or(0);
        u.cache_create += usage["cache_creation_input_tokens"].as_u64().unwrap_or(0);
        u.output += usage["output_tokens"].as_u64().unwrap_or(0);
    }
    Ok(u)
}

/// Convenience: the newest transcript for a seat worktree under `home`, summed since `since`.
pub fn cycle_usage(home: &Path, worktree: &Path, since: u64) -> Option<Usage> {
    let p = newest_transcript(&project_dir(home, worktree))?;
    usage_since(&p, since).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_parses_to_the_right_epoch() {
        assert_eq!(iso_to_epoch("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_to_epoch("2026-09-10T01:52:50.945Z"), Some(1789005170));
    }

    #[test]
    fn sums_only_assistant_usage_after_since() {
        let dir = std::env::temp_dir().join(format!("fwfd-cost-{}", std::process::id()));
        let proj = project_dir(&dir, Path::new("/x/wt"));
        std::fs::create_dir_all(&proj).unwrap();
        let p = proj.join("s.jsonl");
        std::fs::write(&p, concat!(
            "{\"type\":\"user\",\"timestamp\":\"2026-09-10T01:00:00Z\",\"message\":{}}\n",
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-10T01:00:10Z\",\"message\":{\"usage\":{\"input_tokens\":5,\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":7,\"output_tokens\":40}}}\n",
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-10T00:59:00Z\",\"message\":{\"usage\":{\"input_tokens\":999,\"output_tokens\":999}}}\n",
            "not json\n",
        )).unwrap();
        let u = cycle_usage(
            &dir,
            Path::new("/x/wt"),
            iso_to_epoch("2026-09-10T01:00:00Z").unwrap(),
        )
        .unwrap();
        assert_eq!(
            u,
            Usage {
                messages: 1,
                input: 5,
                cache_read: 100,
                cache_create: 7,
                output: 40
            }
        );
        assert_eq!(u.tokens_in(), 112);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
