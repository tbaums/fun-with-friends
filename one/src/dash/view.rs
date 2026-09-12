//! #574 — the dash's render half: a `Board` + a `Floor` + a `View` in, one
//! screen of text out. Pure: no clock of its own (`now` is an argument), no
//! terminal, no I/O. `dash::tty` supplies the size, the keystrokes and the
//! frame loop; every test in here compares strings.
//!
//! The shape is the 0.x board an operator missed: a bordered header (repo,
//! branches, loop state, version, meter), a numbered tab bar, a needs-you
//! banner, a list pane beside a detail pane that follows the selection, and
//! a key hint footer. Colour is a flag, never a requirement — the frame is
//! the same width with it off, so goldens stay readable.

use super::panes::{decisions_tab, issues_tab, prs_tab, seats_tab, usage};
use crate::dash::{
    fmt_secs, hhmm, issue_rows, needs_you, pr_rows, seat_rows, Board, Floor, LoopState,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Seats,
    Issues,
    Prs,
    Decisions,
    Usage,
}

impl Tab {
    pub const ALL: [Tab; 5] = [
        Tab::Seats,
        Tab::Issues,
        Tab::Prs,
        Tab::Decisions,
        Tab::Usage,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Seats => "Seats",
            Tab::Issues => "Issues",
            Tab::Prs => "PRs",
            Tab::Decisions => "Decisions",
            Tab::Usage => "Usage",
        }
    }
    pub fn from_digit(c: char) -> Option<Tab> {
        c.to_digit(10)
            .and_then(|d| Tab::ALL.get(d.checked_sub(1)? as usize).copied())
    }
    /// `--tab seats|issues|prs|decisions|usage`, or the digit.
    pub fn parse(s: &str) -> Option<Tab> {
        let s = s.trim().to_ascii_lowercase();
        if let Some(t) = s.chars().next().and_then(Tab::from_digit) {
            if s.len() == 1 {
                return Some(t);
            }
        }
        Tab::ALL
            .into_iter()
            .find(|t| t.title().to_ascii_lowercase() == s)
    }
}

/// What the operator is looking at: which tab, which row, how big the
/// terminal is, and whether colour is wanted.
#[derive(Clone, Debug)]
pub struct View {
    pub tab: Tab,
    /// Selected row per tab, in `Tab::ALL` order.
    pub sel: [usize; 5],
    pub width: usize,
    pub height: usize,
    pub color: bool,
}

impl Default for View {
    fn default() -> View {
        View {
            tab: Tab::Seats,
            sel: [0; 5],
            width: 100,
            height: 32,
            color: false,
        }
    }
}

impl View {
    fn tab_ix(&self) -> usize {
        Tab::ALL.iter().position(|t| *t == self.tab).unwrap_or(0)
    }
    pub fn selected(&self) -> usize {
        self.sel[self.tab_ix()]
    }
    pub fn select(&mut self, i: usize) {
        let ix = self.tab_ix();
        self.sel[ix] = i;
    }
    /// j/k, clamped to the rows the current tab actually has.
    pub fn move_by(&mut self, delta: i64, rows: usize) {
        if rows == 0 {
            self.select(0);
            return;
        }
        let cur = self.selected().min(rows - 1) as i64;
        let next = (cur + delta).clamp(0, rows as i64 - 1) as usize;
        self.select(next);
    }
}

// ---- ANSI, counted honestly ----------------------------------------------

pub(super) const RESET: &str = "\x1b[0m";

pub(super) fn paint(s: &str, code: &str, on: bool) -> String {
    if on && !code.is_empty() {
        format!("\x1b[{code}m{s}{RESET}")
    } else {
        s.to_string()
    }
}

/// Visible columns: escape sequences occupy none.
pub fn vis_len(s: &str) -> usize {
    let mut n = 0;
    let mut esc = false;
    for c in s.chars() {
        if esc {
            if c == 'm' {
                esc = false;
            }
        } else if c == '\x1b' {
            esc = true;
        } else {
            n += 1;
        }
    }
    n
}

/// Clip to `w` visible columns, keeping escapes intact and closing any that
/// were still open.
pub(super) fn clip(s: &str, w: usize) -> String {
    if vis_len(s) <= w {
        return s.to_string();
    }
    let mut out = String::new();
    let mut n = 0;
    let mut esc = false;
    let mut painted = false;
    for c in s.chars() {
        if esc {
            out.push(c);
            if c == 'm' {
                esc = false;
            }
            continue;
        }
        if c == '\x1b' {
            out.push(c);
            esc = true;
            painted = true;
            continue;
        }
        if n + 1 > w.saturating_sub(1) {
            out.push('…');
            if painted {
                out.push_str(RESET);
            }
            return out;
        }
        out.push(c);
        n += 1;
    }
    out
}

pub(super) fn pad(s: &str, w: usize) -> String {
    let c = clip(s, w);
    let l = vis_len(&c);
    format!("{c}{}", " ".repeat(w.saturating_sub(l)))
}

/// One bordered pane, exactly `w` columns and `h` lines (border included).
pub(super) fn boxed(title: &str, body: &[String], w: usize, h: usize) -> Vec<String> {
    let inner = w.saturating_sub(2);
    let mut out = Vec::with_capacity(h);
    let t = clip(&format!(" {title} "), inner.saturating_sub(2));
    let dashes = inner.saturating_sub(vis_len(&t));
    out.push(format!("┌{t}{}┐", "─".repeat(dashes)));
    for i in 0..h.saturating_sub(2) {
        let line = body.get(i).map(String::as_str).unwrap_or("");
        out.push(format!("│{}│", pad(line, inner)));
    }
    out.push(format!("└{}┘", "─".repeat(inner)));
    out
}

pub(super) fn beside(left: Vec<String>, right: Vec<String>) -> Vec<String> {
    left.into_iter()
        .zip(right)
        .map(|(l, r)| format!("{l}{r}"))
        .collect()
}

// ---- the frame -----------------------------------------------------------

/// The whole screen. `now` is the operator's clock, passed in so the render
/// is a function of its arguments alone.
pub fn render(b: &Board, f: &Floor, v: &View, now: u64) -> String {
    let w = v.width.max(60);
    let h = v.height.max(14);
    let mut lines: Vec<String> = Vec::new();
    lines.extend(header(b, f, v, now, w));
    let needs = needs_you(b, f, now);
    lines.push(tab_bar(b, f, v, &needs, w));
    lines.push(banner(&needs, v, w));
    let body_h = h.saturating_sub(lines.len() + 1);
    lines.extend(body(b, f, v, now, w, body_h));
    lines.push(pad(
        " 1-5 tab · j/k row · g/G first/last · r refresh · q quit",
        w,
    ));
    let mut out = String::new();
    for l in lines {
        out.push_str(l.trim_end());
        out.push('\n');
    }
    out
}

fn header(b: &Board, f: &Floor, v: &View, now: u64, w: usize) -> Vec<String> {
    let (dot, word, code) = match &f.loop_state {
        LoopState::Running => ("●", "running".to_string(), "32"),
        LoopState::Parked(why) => ("◐", format!("PARKED — {why}"), "33"),
        LoopState::NotRunning => ("○", "not running".to_string(), "31"),
        LoopState::Unknown if f.session.is_empty() => (
            "?",
            "loop UNKNOWN (no manifest: no session to look in)".to_string(),
            "35",
        ),
        LoopState::Unknown => ("?", "loop UNKNOWN (tmux not read)".to_string(), "35"),
    };
    let repo = if f.repo.is_empty() {
        "(no manifest)".to_string()
    } else {
        f.repo.clone()
    };
    let one = format!(
        "repo {repo}  ·  {} → {}  ·  {} {}  ·  fwfd {}",
        if f.base.is_empty() { "?" } else { &f.base },
        if f.release.is_empty() {
            "?"
        } else {
            &f.release
        },
        paint(dot, code, v.color),
        paint(&word, code, v.color),
        if f.version.is_empty() {
            "?"
        } else {
            &f.version
        },
    );
    let record = if b.last_ts == 0 {
        "record empty".to_string()
    } else {
        format!(
            "record {} → {} ({:.1}h) · last event {} ago",
            hhmm(b.first_ts),
            hhmm(b.last_ts),
            span_hours(b),
            fmt_secs(now.saturating_sub(b.last_ts))
        )
    };
    let meter = match &f.meter {
        Some(m) => format!(
            "meter weekly {}%{} · read {} ({})",
            m.weekly,
            m.session
                .map(|s| format!(" session {s}%"))
                .unwrap_or_default(),
            m.when,
            m.age
                .map(|a| format!("{} ago", fmt_secs(a)))
                .unwrap_or_else(|| "unparseable".into())
        ),
        None => "meter no reading in ~/.fwf-meter-log (the brake cannot see it)".to_string(),
    };
    boxed("fwfd dash", &[one, format!("{record}   {meter}")], w, 4)
}

pub(super) fn span_hours(b: &Board) -> f64 {
    ((b.last_ts.saturating_sub(b.first_ts)) as f64 / 3600.0).max(1.0 / 60.0)
}

fn counts(b: &Board, f: &Floor, needs: &[String]) -> [String; 5] {
    [
        seat_rows(b, f).len().to_string(),
        issue_rows(b, f).len().to_string(),
        pr_rows(b).len().to_string(),
        needs.len().to_string(),
        format!("{:.1}M", total_tokens(b) as f64 / 1e6),
    ]
}

fn total_tokens(b: &Board) -> u64 {
    b.roles.values().map(|r| r.tokens_in + r.tokens_out).sum()
}

fn tab_bar(b: &Board, f: &Floor, v: &View, needs: &[String], w: usize) -> String {
    let c = counts(b, f, needs);
    let mut s = String::from(" ");
    for (i, t) in Tab::ALL.into_iter().enumerate() {
        let label = format!(" {} {} ({}) ", i + 1, t.title(), c[i]);
        s.push_str(&paint(
            &label,
            if t == v.tab { "1;7" } else { "2" },
            v.color,
        ));
        s.push(' ');
    }
    pad(&s, w)
}

fn banner(needs: &[String], v: &View, w: usize) -> String {
    if needs.is_empty() {
        return pad(&paint(" ✓ nothing needs you", "32", v.color), w);
    }
    let more = if needs.len() > 1 {
        format!("  (+{} more on tab 4)", needs.len() - 1)
    } else {
        String::new()
    };
    pad(
        &paint(
            &format!(" ⛔ NEEDS YOU — {}{more}", needs[0]),
            "1;31",
            v.color,
        ),
        w,
    )
}

fn body(b: &Board, f: &Floor, v: &View, now: u64, w: usize, h: usize) -> Vec<String> {
    if v.tab == Tab::Usage {
        return boxed("Usage — throughput and measured cost", &usage(b, f), w, h);
    }
    let lw = (w * 45 / 100).max(34);
    let rw = w - lw;
    let (title, rows, detail) = match v.tab {
        Tab::Seats => seats_tab(b, f, v, now),
        Tab::Issues => issues_tab(b, f, v, now),
        Tab::Prs => prs_tab(b, v, now),
        Tab::Decisions => decisions_tab(b, f, v, now),
        Tab::Usage => unreachable!(),
    };
    let inner = h.saturating_sub(2);
    let sel = v.selected().min(rows.len().saturating_sub(1));
    let first = sel.saturating_sub(inner.saturating_sub(1));
    let shown: Vec<String> = rows
        .iter()
        .enumerate()
        .skip(first)
        .take(inner)
        .map(|(i, r)| {
            if i == sel {
                format!("{}{}", paint("▌", "1;36", v.color), paint(r, "1", v.color))
            } else {
                format!(" {r}")
            }
        })
        .collect();
    beside(
        boxed(&title, &shown, lw, h),
        boxed(&detail.0, &detail.1, rw, h),
    )
}

/// How many rows the current tab has — `tty` needs it to clamp j/k.
pub fn rows_in(b: &Board, f: &Floor, tab: Tab, now: u64) -> usize {
    match tab {
        Tab::Seats => seat_rows(b, f).len(),
        Tab::Issues => issue_rows(b, f).len(),
        Tab::Prs => pr_rows(b).len(),
        Tab::Decisions => needs_you(b, f, now).len(),
        Tab::Usage => 0,
    }
}

#[cfg(test)]
pub(crate) mod fixture {
    //! One board and one floor every view test renders: a claimed
    //! issue with an impl seat working, a draft PR under QA, and a
    //! gated issue nobody has un-gated.

    use super::*;
    use crate::dash::{fold, Meter, Slot};
    use crate::log::{Event, Kind};
    use crate::types::{Fence, IssueState, JobRef, PrState, Role, SeatState, Sha};

    pub fn sha(c: char) -> Sha {
        Sha::parse(&std::iter::repeat_n(c, 40).collect::<String>()).unwrap()
    }
    pub fn ev(ts: u64, kind: Kind) -> Event {
        Event {
            ts,
            repo: "o/r".into(),
            kind,
        }
    }

    pub fn record() -> Vec<Event> {
        let job = JobRef {
            role: Role::Impl,
            issue: Some(574),
            pr: None,
        };
        let qa_job = JobRef {
            role: Role::Qa,
            issue: Some(574),
            pr: Some(9),
        };
        vec![
            ev(
                1_000_000,
                Kind::Human {
                    actor: "jamie".into(),
                    action: "ungate".into(),
                    target: "#574".into(),
                },
            ),
            ev(
                1_000_010,
                Kind::Issue {
                    issue: 574,
                    to: IssueState::Ready,
                },
            ),
            ev(
                1_000_020,
                Kind::Issue {
                    issue: 574,
                    to: IssueState::Claimed {
                        seat: 1,
                        fence: Fence("evt-1".into()),
                    },
                },
            ),
            ev(
                1_000_030,
                Kind::Seat {
                    seat: 1,
                    role: Role::Impl,
                    to: SeatState::Working {
                        job: job.clone(),
                        deadline: 1_001_830,
                    },
                    tokens_in: None,
                    tokens_out: None,
                },
            ),
            ev(
                1_000_040,
                Kind::Pr {
                    pr: 9,
                    issue: Some(574),
                    to: PrState::Draft { head: sha('a') },
                },
            ),
            ev(
                1_000_050,
                Kind::Seat {
                    seat: 1,
                    role: Role::Qa,
                    to: SeatState::Working {
                        job: qa_job,
                        deadline: 1_001_850,
                    },
                    tokens_in: None,
                    tokens_out: None,
                },
            ),
            ev(
                1_000_060,
                Kind::Issue {
                    issue: 575,
                    to: IssueState::Gated,
                },
            ),
        ]
    }

    pub fn floor() -> Floor {
        Floor {
            repo: "tbaums/fun-with-friends".into(),
            base: "staging".into(),
            release: "main".into(),
            session: "fwf-one".into(),
            version: "1.0.0".into(),
            slots: vec![
                Slot {
                    role: Role::Impl,
                    seat: 1,
                    target: "fwf-one:impl1".into(),
                    pane: Some("2.1.266".into()),
                },
                Slot {
                    role: Role::Qa,
                    seat: 1,
                    target: "fwf-one:qa1".into(),
                    pane: Some("claude".into()),
                },
            ],
            allow: vec![574],
            loop_state: LoopState::Running,
            meter: Some(Meter {
                weekly: 62,
                session: Some(11),
                when: "2026-09-12 03:00:00".into(),
                age: Some(120),
            }),
            park_at: 85,
        }
    }

    pub fn frame(tab: Tab) -> String {
        let b = fold(&record());
        let v = View {
            tab,
            width: 110,
            height: 26,
            ..Default::default()
        };
        render(&b, &floor(), &v, 1_000_100)
    }

    pub fn frame_at(tab: Tab, now: u64) -> String {
        let v = View {
            tab,
            width: 110,
            height: 26,
            ..Default::default()
        };
        render(&fold(&record()), &floor(), &v, now)
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::*;
    use super::*;
    use crate::dash::fold;

    #[test]
    fn the_header_names_the_repo_the_branches_the_loop_and_the_meter() {
        let f = frame(Tab::Seats);
        assert!(f.starts_with("┌ fwfd dash "), "{f}");
        assert!(f.contains("repo tbaums/fun-with-friends"));
        assert!(f.contains("staging → main"));
        assert!(f.contains("● running"));
        assert!(f.contains("fwfd 1.0.0"));
        assert!(f.contains("meter weekly 62% session 11%"));
        assert!(f.contains("last event 40s ago"));
    }

    #[test]
    fn five_tabs_with_counts_and_a_needs_you_banner() {
        let f = frame(Tab::Seats);
        assert!(f.contains("1 Seats (2)"), "{f}");
        assert!(f.contains("2 Issues (2)"));
        assert!(f.contains("3 PRs (1)"));
        assert!(f.contains("4 Decisions (1)"));
        assert!(f.contains("5 Usage"));
        assert!(f.contains("⛔ NEEDS YOU — gated, awaiting `fwfd ungate`: #575"));
        assert!(f.contains("1-5 tab · j/k row"));
    }

    #[test]
    fn j_moves_the_selection_and_the_detail_pane_follows() {
        let b = fold(&record());
        let fl = floor();
        let mut v = View {
            tab: Tab::Seats,
            width: 110,
            height: 26,
            ..Default::default()
        };
        v.move_by(1, rows_in(&b, &fl, Tab::Seats, 1_000_100));
        let f = render(&b, &fl, &v, 1_000_100);
        assert!(f.contains("Detail · seat qa1"), "{f}");
        assert!(f.contains("tmux live, claude"));
        // and it clamps at the end
        v.move_by(9, rows_in(&b, &fl, Tab::Seats, 1_000_100));
        assert_eq!(v.selected(), 1);
        v.move_by(-9, rows_in(&b, &fl, Tab::Seats, 1_000_100));
        assert_eq!(v.selected(), 0);
    }

    #[test]
    fn an_empty_record_still_renders_a_board() {
        let v = View {
            width: 90,
            height: 20,
            ..Default::default()
        };
        let f = render(&fold(&[]), &Floor::default(), &v, 0);
        assert!(f.contains("record empty"), "{f}");
        assert!(f.contains("repo (no manifest)"));
        assert!(f.contains("loop UNKNOWN (no manifest"));
        assert!(f.contains("no seats"));
        let u = render(
            &fold(&[]),
            &Floor::default(),
            &View {
                tab: Tab::Usage,
                ..v
            },
            0,
        );
        assert!(u.contains("run record is empty"));
    }

    #[test]
    fn every_line_fits_the_terminal_with_colour_on_or_off() {
        for w in [60usize, 72, 100, 140] {
            for color in [false, true] {
                for tab in Tab::ALL {
                    let v = View {
                        tab,
                        width: w,
                        height: 24,
                        color,
                        ..Default::default()
                    };
                    let f = render(&fold(&record()), &floor(), &v, 1_000_100);
                    for l in f.lines() {
                        assert!(
                            vis_len(l) <= w,
                            "w={w} color={color} tab={:?} len={} line={l:?}",
                            tab,
                            vis_len(l)
                        );
                    }
                    assert_eq!(f.lines().count(), 24, "w={w} tab={:?}", tab);
                }
            }
        }
    }

    #[test]
    fn colour_changes_bytes_but_not_the_visible_frame() {
        let b = fold(&record());
        let plain = render(
            &b,
            &floor(),
            &View {
                width: 100,
                height: 22,
                ..Default::default()
            },
            1_000_100,
        );
        let lit = render(
            &b,
            &floor(),
            &View {
                width: 100,
                height: 22,
                color: true,
                ..Default::default()
            },
            1_000_100,
        );
        assert_ne!(plain, lit);
        let strip = |s: &str| -> String {
            let mut out = String::new();
            let mut esc = false;
            for c in s.chars() {
                if esc {
                    if c == 'm' {
                        esc = false;
                    }
                } else if c == '\x1b' {
                    esc = true;
                } else {
                    out.push(c);
                }
            }
            out
        };
        // Trailing blanks differ: a highlighted tab's padding sits inside
        // its escape, so `trim_end` cannot reach it. Compare per line.
        let lines = |s: &str| -> Vec<String> {
            s.lines().map(|l| strip(l).trim_end().to_string()).collect()
        };
        assert_eq!(lines(&plain), lines(&lit));
    }

    #[test]
    fn tabs_parse_from_digits_and_names() {
        assert_eq!(Tab::parse("1"), Some(Tab::Seats));
        assert_eq!(Tab::parse("prs"), Some(Tab::Prs));
        assert_eq!(Tab::parse("Decisions"), Some(Tab::Decisions));
        assert_eq!(Tab::parse("5"), Some(Tab::Usage));
        assert_eq!(Tab::parse("6"), None);
        assert_eq!(Tab::parse("nope"), None);
        assert_eq!(Tab::from_digit('3'), Some(Tab::Prs));
        assert_eq!(Tab::from_digit('0'), None);
    }

    #[test]
    fn a_long_cell_is_clipped_not_wrapped() {
        let long = "x".repeat(400);
        let one = boxed("t", &[long], 30, 3);
        assert_eq!(one.len(), 3);
        assert!(one[1].ends_with("…│"), "{:?}", one[1]);
        assert!(one.iter().all(|l| vis_len(l) == 30));
        // an escape opened inside a clipped cell is closed again
        let painted = vec![paint(&"y".repeat(50), "1;31", true)];
        let two = boxed("t", &painted, 20, 3);
        assert!(two[1].contains(RESET));
        assert_eq!(vis_len(&two[1]), 20);
    }
}
