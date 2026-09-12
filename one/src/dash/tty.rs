//! #574 — the dash's terminal layer, and deliberately the only impure part.
//!
//! Everything decided here is a terminal fact: how wide the window is, is
//! stdout a terminal at all, which key was pressed, when to redraw. The board
//! itself is `dash::fold` + `dash::view::render`, which this module calls and
//! never second-guesses.
//!
//! No TUI crate: raw mode comes from `stty` (the same way the meter's stamp
//! comes from `date`), the alternate screen from two escape codes, and the
//! frame from the string the view already produces. That keeps the whole
//! board testable as text and adds no dependency.

use crate::dash::view::{render, rows_in, Tab, View};
use crate::dash::{Board, Floor};
use crate::seat::now;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

/// How long a liveness probe may take before the dash calls it Unknown.
pub const PROBE: Duration = Duration::from_millis(1500);

/// Run a command and give up on it. Every frame asks tmux what its panes are
/// doing, and a board that freezes because one read never returned is worse
/// than a board that says "pane unknown" — so the child is killed at the
/// deadline and the answer is `None` (the record's own rule: a read that
/// cannot complete must never collapse into a confident value).
pub fn run_within(cmd: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = child.wait_with_output().ok()?;
                return status
                    .success()
                    .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string());
            }
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Err(_) => return None,
        }
    }
}

fn tmux_within(args: &[&str]) -> Option<String> {
    run_within("tmux", args, PROBE)
}

/// The pane's foreground command, bounded — `None` when tmux did not answer.
/// tmux resolves an unmatched `session:window` to the session's CURRENT
/// window, so the window name is matched exactly first (the same rule
/// `fwfd seats` follows); a missing window reads as `absent`.
pub fn pane_command(target: &str) -> Option<String> {
    if let Some((session, window)) = target.split_once(':') {
        let names = tmux_within(&["list-windows", "-t", session, "-F", "#{window_name}"])?;
        if !names.lines().any(|n| n.trim() == window) {
            return Some("absent".to_string());
        }
    }
    tmux_within(&[
        "display-message",
        "-p",
        "-t",
        target,
        "#{pane_current_command}",
    ])
}

/// Does the session hold a window with this name? `None` when tmux did not
/// answer — which the header renders as "loop UNKNOWN", never "not running".
pub fn window_exists(session: &str, window: &str) -> Option<bool> {
    let names = tmux_within(&["list-windows", "-t", session, "-F", "#{window_name}"])?;
    Some(names.lines().any(|n| n.trim() == window))
}

/// `stty` talks to the terminal on ITS stdin, so stdin must be inherited;
/// `output()` would hand it /dev/null and every call would fail.
fn stty(args: &[&str]) -> Option<String> {
    let out = Command::new("stty")
        .args(args)
        .stdin(Stdio::inherit())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

pub fn is_tty() -> bool {
    stty(&["-g"]).is_some()
}

/// Rows and columns, from the terminal itself; `LINES`/`COLUMNS` and then a
/// conservative 100×32 when there is no terminal (a pipe, a CI log).
pub fn size() -> (usize, usize) {
    if let Some(s) = stty(&["size"]) {
        let mut it = s.split_whitespace();
        if let (Some(r), Some(c)) = (
            it.next().and_then(|v| v.parse::<usize>().ok()),
            it.next().and_then(|v| v.parse::<usize>().ok()),
        ) {
            if r > 0 && c > 0 {
                return (c, r);
            }
        }
    }
    let env = |k: &str| std::env::var(k).ok().and_then(|v| v.parse::<usize>().ok());
    (env("COLUMNS").unwrap_or(100), env("LINES").unwrap_or(32))
}

/// Colour unless the operator or the terminal says otherwise.
pub fn wants_color() -> bool {
    std::env::var_os("NO_COLOR").is_none()
        && std::env::var("TERM").map(|t| t != "dumb").unwrap_or(false)
        && is_tty()
}

/// Raw mode + the alternate screen, restored on drop so a panic or a `q`
/// both leave the operator's terminal as they found it.
pub struct Term {
    saved: Option<String>,
}

impl Term {
    pub fn enter() -> Term {
        let saved = stty(&["-g"]);
        if saved.is_some() {
            // `raw -echo` so j/k arrive without Enter and Ctrl-C arrives as
            // a byte we can handle (and restore from) ourselves.
            let _ = Command::new("stty")
                .args(["raw", "-echo"])
                .stdin(Stdio::inherit())
                .status();
            print!("\x1b[?1049h\x1b[?25l");
            let _ = std::io::stdout().flush();
        }
        Term { saved }
    }
    pub fn restore(&mut self) {
        if let Some(s) = self.saved.take() {
            print!("\x1b[?25h\x1b[?1049l");
            let _ = std::io::stdout().flush();
            if Command::new("stty")
                .arg(&s)
                .stdin(Stdio::inherit())
                .status()
                .map(|st| !st.success())
                .unwrap_or(true)
            {
                let _ = Command::new("stty")
                    .arg("sane")
                    .stdin(Stdio::inherit())
                    .status();
            }
        }
    }
    pub fn interactive(&self) -> bool {
        self.saved.is_some()
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        self.restore();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Go(Tab),
    Down,
    Up,
    First,
    Last,
    Refresh,
    Quit,
    Ignored,
}

/// One keystroke, from the bytes a raw terminal sends.
pub fn key(b: u8, arrow: Option<u8>) -> Key {
    match b {
        b'q' | b'Q' | 3 | 4 | 27 if arrow.is_none() => Key::Quit,
        27 => match arrow {
            Some(b'A') => Key::Up,
            Some(b'B') => Key::Down,
            _ => Key::Ignored,
        },
        b'j' | b'n' | 14 => Key::Down,
        b'k' | b'p' | 16 => Key::Up,
        b'g' => Key::First,
        b'G' => Key::Last,
        b'r' | b'R' | 12 => Key::Refresh,
        b'\t' => Key::Ignored,
        c => match Tab::from_digit(c as char) {
            Some(t) => Key::Go(t),
            None => Key::Ignored,
        },
    }
}

fn spawn_keys() -> Receiver<u8> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        use std::io::Read;
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 1];
        while let Ok(n) = stdin.read(&mut buf) {
            if n == 0 || tx.send(buf[0]).is_err() {
                break;
            }
        }
    });
    rx
}

/// Redraw in place: home, then every line clear-to-end, then clear the rest.
/// (A full `2J` clear on every frame is what made the old watch mode blink.)
fn draw(text: &str, interactive: bool) {
    let mut out = std::io::stdout().lock();
    if interactive {
        let _ = write!(out, "\x1b[H");
        for line in text.lines() {
            let _ = write!(out, "{line}\x1b[K\r\n");
        }
        let _ = write!(out, "\x1b[J");
    } else {
        let _ = write!(out, "\x1b[2J\x1b[H{text}");
    }
    let _ = out.flush();
}

/// One frame, printed plainly: what `fwfd dash` without `--watch` does, and
/// what a pipe or a CI log gets.
pub fn once(b: &Board, f: &Floor, v: &View) -> String {
    render(b, f, v, now())
}

/// `--watch N`: redraw every N seconds, and — on a real terminal — take
/// 1-5/j/k/g/G/r/q while waiting. `refresh` re-reads the record each frame.
pub fn watch(interval: u64, mut v: View, mut refresh: impl FnMut() -> (Board, Floor)) {
    let mut term = Term::enter();
    let interactive = term.interactive();
    let rx = interactive.then(spawn_keys);
    let interval = Duration::from_secs(interval.max(1));
    loop {
        let (w, h) = size();
        v.width = w;
        v.height = h;
        let (b, f) = refresh();
        let now = now();
        let rows = rows_in(&b, &f, v.tab, now);
        v.move_by(0, rows); // the record may have shrunk under the cursor
        draw(&render(&b, &f, &v, now), interactive);
        let Some(rx) = rx.as_ref() else {
            std::thread::sleep(interval);
            continue;
        };
        let deadline = Instant::now() + interval;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(left) {
                Ok(byte) => {
                    // An arrow key is ESC [ A/B; anything else after ESC is
                    // a quit (the operator pressed Escape).
                    let arrow = if byte == 27 {
                        match rx.recv_timeout(Duration::from_millis(40)) {
                            Ok(b'[') => rx.recv_timeout(Duration::from_millis(40)).ok(),
                            _ => None,
                        }
                    } else {
                        None
                    };
                    match key(byte, arrow) {
                        Key::Quit => {
                            term.restore();
                            return;
                        }
                        Key::Go(t) => v.tab = t,
                        Key::Down => v.move_by(1, rows),
                        Key::Up => v.move_by(-1, rows),
                        Key::First => v.move_by(-(rows as i64), rows),
                        Key::Last => v.move_by(rows as i64, rows),
                        Key::Refresh => {}
                        Key::Ignored => continue,
                    }
                    break;
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    std::thread::sleep(left);
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_map_to_the_moves_the_footer_promises() {
        assert_eq!(key(b'1', None), Key::Go(Tab::Seats));
        assert_eq!(key(b'4', None), Key::Go(Tab::Decisions));
        assert_eq!(key(b'6', None), Key::Ignored);
        assert_eq!(key(b'j', None), Key::Down);
        assert_eq!(key(b'k', None), Key::Up);
        assert_eq!(key(b'g', None), Key::First);
        assert_eq!(key(b'G', None), Key::Last);
        assert_eq!(key(b'r', None), Key::Refresh);
        assert_eq!(key(b'q', None), Key::Quit);
        assert_eq!(key(3, None), Key::Quit, "Ctrl-C in raw mode");
        assert_eq!(key(27, None), Key::Quit, "bare Escape");
        assert_eq!(key(27, Some(b'A')), Key::Up);
        assert_eq!(key(27, Some(b'B')), Key::Down);
        assert_eq!(key(27, Some(b'C')), Key::Ignored);
        assert_eq!(key(b'x', None), Key::Ignored);
    }

    #[test]
    fn a_probe_that_never_returns_is_unknown_not_a_frozen_board() {
        let t0 = Instant::now();
        assert_eq!(
            run_within("sleep", &["30"], Duration::from_millis(200)),
            None
        );
        assert!(t0.elapsed() < Duration::from_secs(5), "it waited it out");
        assert_eq!(
            run_within("echo", &["hi"], Duration::from_secs(5)),
            Some("hi".to_string())
        );
        // a non-zero exit is not an answer either
        assert_eq!(run_within("false", &[], Duration::from_secs(5)), None);
        assert_eq!(
            run_within("no-such-binary-here", &[], Duration::from_secs(5)),
            None
        );
    }

    #[test]
    fn size_is_positive_even_with_no_terminal() {
        let (w, h) = size();
        assert!(w >= 1 && h >= 1);
    }
}
