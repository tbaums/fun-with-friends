//! `fwf-dash` — a read-only Rust + ratatui status board for the fun-with-friends
//! factory (issue #40, milestone 1).
//!
//! The binary is purely the renderer: a background thread shells out to the bash
//! data provider (`fwf-dash-data.sh`, via `data::fetch`) on a refresh timer and
//! pushes snapshots over a channel; the main thread owns the terminal, handles
//! input, and draws the latest snapshot. Keeping the fetch off the render thread
//! is what keeps the board flicker-free even when the provider makes a slow gh
//! call — ratatui only writes the per-frame diff, so an unchanged redraw is a
//! no-op.
//!
//! Input model is the prior-art one from the #40 research (NO F-keys): j/k+arrows
//! move the list cursor, Tab/Shift-Tab + [ ] + 1/2/3 switch section, PgUp/PgDn +
//! Ctrl-u/Ctrl-d scroll the preview, ? toggles help, r forces a refresh, q quits,
//! and the mouse wheel scrolls the preview.

mod data;

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
    KeyModifiers, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Tabs, Wrap};
use ratatui::{Frame, Terminal};

use data::Dashboard;

/// The three sections of the board. Order matters: it is the 1/2/3 jump order and
/// the Tab cycle order.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Roles,
    Decisions,
    Issues,
}

impl Tab {
    const ALL: [Tab; 3] = [Tab::Roles, Tab::Decisions, Tab::Issues];

    fn index(self) -> usize {
        match self {
            Tab::Roles => 0,
            Tab::Decisions => 1,
            Tab::Issues => 2,
        }
    }

    fn title(self) -> &'static str {
        match self {
            Tab::Roles => "Roles",
            Tab::Decisions => "Decisions",
            Tab::Issues => "Issues",
        }
    }

    /// Cycle to the next/previous section, wrapping. `delta` is +1 or -1.
    fn cycle(self, delta: isize) -> Tab {
        let n = Tab::ALL.len() as isize;
        let i = (self.index() as isize + delta).rem_euclid(n) as usize;
        Tab::ALL[i]
    }
}

/// What the data thread last handed us. We keep the last good snapshot so a
/// transient provider error doesn't blank the board — we keep showing the stale
/// data with an error banner instead.
enum Feed {
    /// First fetch has not returned yet.
    Loading,
    Ok(Dashboard),
    /// Error string, plus the last good snapshot if we ever had one.
    Err(String, Option<Dashboard>),
}

impl Feed {
    /// The dashboard currently worth rendering, if any.
    fn dashboard(&self) -> Option<&Dashboard> {
        match self {
            Feed::Ok(d) => Some(d),
            Feed::Err(_, last) => last.as_ref(),
            Feed::Loading => None,
        }
    }
}

/// All mutable UI state. One cursor + one preview scroll offset per tab so moving
/// between sections preserves where you were.
struct App {
    feed: Feed,
    tab: Tab,
    cursors: [ListState; 3],
    scroll: [u16; 3],
    show_help: bool,
    refresh: Sender<()>,
    should_quit: bool,
}

impl App {
    fn new(refresh: Sender<()>) -> App {
        let mut cursors: [ListState; 3] = Default::default();
        for c in &mut cursors {
            c.select(Some(0));
        }
        App {
            feed: Feed::Loading,
            tab: Tab::Roles,
            cursors,
            scroll: [0; 3],
            show_help: false,
            refresh,
            should_quit: false,
        }
    }

    fn cursor(&mut self) -> &mut ListState {
        &mut self.cursors[self.tab.index()]
    }

    /// Number of rows in the active section's list, so cursor movement can clamp.
    fn row_count(&self) -> usize {
        match self.feed.dashboard() {
            None => 0,
            Some(d) => match self.tab {
                Tab::Roles => d.roles.len(),
                Tab::Decisions => d.decisions.len(),
                Tab::Issues => d.issues.len(),
            },
        }
    }

    fn select_tab(&mut self, tab: Tab) {
        self.tab = tab;
    }

    /// Move the list cursor by `delta`, clamped to the row range. Resets the
    /// preview scroll, since the preview now shows a different item.
    fn move_cursor(&mut self, delta: isize) {
        let count = self.row_count();
        if count == 0 {
            return;
        }
        let cur = self.cursor().selected().unwrap_or(0) as isize;
        let next = (cur + delta).clamp(0, count as isize - 1) as usize;
        self.cursor().select(Some(next));
        self.scroll[self.tab.index()] = 0;
    }

    fn scroll_preview(&mut self, delta: i32) {
        let s = &mut self.scroll[self.tab.index()];
        *s = (*s as i32 + delta).max(0) as u16;
    }

    fn on_key(&mut self, key: KeyEvent) {
        // Help overlay swallows everything except the keys that dismiss it.
        if self.show_help {
            match key.code {
                KeyCode::Char('?') | KeyCode::Esc | KeyCode::Char('q') => self.show_help = false,
                _ => {}
            }
            return;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => self.should_quit = true,
            KeyCode::Char('c') if ctrl => self.should_quit = true,
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Char('r') => {
                let _ = self.refresh.send(());
            }
            // Section switching.
            KeyCode::Tab | KeyCode::Char(']') => self.select_tab(self.tab.cycle(1)),
            KeyCode::BackTab | KeyCode::Char('[') => self.select_tab(self.tab.cycle(-1)),
            KeyCode::Char('1') => self.select_tab(Tab::Roles),
            KeyCode::Char('2') => self.select_tab(Tab::Decisions),
            KeyCode::Char('3') => self.select_tab(Tab::Issues),
            // List navigation.
            KeyCode::Char('j') | KeyCode::Down => self.move_cursor(1),
            KeyCode::Char('k') | KeyCode::Up => self.move_cursor(-1),
            KeyCode::Char('g') | KeyCode::Home => self.move_cursor(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => self.move_cursor(isize::MAX / 2),
            // Preview scroll.
            KeyCode::Char('d') if ctrl => self.scroll_preview(10),
            KeyCode::Char('u') if ctrl => self.scroll_preview(-10),
            KeyCode::PageDown => self.scroll_preview(10),
            KeyCode::PageUp => self.scroll_preview(-10),
            _ => {}
        }
    }
}

fn main() -> Result<()> {
    // Data thread: fetch immediately, then on each refresh tick or on-demand
    // request. recv_timeout doubles as the timer and the `r`-key listener.
    let (data_tx, data_rx) = mpsc::channel::<Result<Dashboard, String>>();
    let (refresh_tx, refresh_rx) = mpsc::channel::<()>();
    let interval = refresh_interval();
    thread::spawn(move || data_loop(data_tx, refresh_rx, interval));

    let mut terminal = init_terminal().context("initializing the terminal")?;
    let app = App::new(refresh_tx);
    let result = run(&mut terminal, app, data_rx);
    restore_terminal();
    result
}

/// `$FWF_DASH_REFRESH` seconds between auto-refreshes (default 5, floor 1).
fn refresh_interval() -> Duration {
    let secs = std::env::var("FWF_DASH_REFRESH")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(5)
        .max(1);
    Duration::from_secs(secs)
}

fn data_loop(tx: Sender<Result<Dashboard, String>>, req: Receiver<()>, interval: Duration) {
    loop {
        if tx.send(data::fetch()).is_err() {
            return; // main thread (and terminal) is gone.
        }
        match req.recv_timeout(interval) {
            Ok(()) => {}                         // forced refresh: refetch now.
            Err(RecvTimeoutError::Timeout) => {} // tick: refetch.
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

type Tui = Terminal<ratatui::backend::CrosstermBackend<std::io::Stdout>>;

fn init_terminal() -> Result<Tui> {
    let terminal = ratatui::init();
    // Mouse capture is not part of ratatui::init(); enable it so the wheel
    // scrolls the preview. restore_terminal disables it again.
    execute!(std::io::stdout(), EnableMouseCapture)?;
    Ok(terminal)
}

fn restore_terminal() {
    let _ = execute!(std::io::stdout(), DisableMouseCapture);
    ratatui::restore();
}

fn run(
    terminal: &mut Tui,
    mut app: App,
    data_rx: Receiver<Result<Dashboard, String>>,
) -> Result<()> {
    while !app.should_quit {
        // Drain any snapshots the data thread produced since last frame.
        while let Ok(msg) = data_rx.try_recv() {
            app.feed = match msg {
                Ok(d) => Feed::Ok(d),
                Err(e) => {
                    let last = match std::mem::replace(&mut app.feed, Feed::Loading) {
                        Feed::Ok(d) => Some(d),
                        Feed::Err(_, last) => last,
                        Feed::Loading => None,
                    };
                    Feed::Err(e, last)
                }
            };
            // Keep the cursor in range if the row count shrank.
            clamp_cursor(&mut app);
        }

        terminal.draw(|f| ui(f, &mut app))?;

        // Block up to 250ms for input; on timeout we loop, pick up fresh data,
        // and redraw. ratatui diffs frames, so a no-change redraw writes nothing.
        if event::poll(Duration::from_millis(250))? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => app.on_key(key),
                Event::Mouse(m) => match m.kind {
                    MouseEventKind::ScrollDown => app.scroll_preview(3),
                    MouseEventKind::ScrollUp => app.scroll_preview(-3),
                    _ => {}
                },
                _ => {}
            }
        }
    }
    Ok(())
}

/// Clamp the active cursor after a data refresh changed the row count.
fn clamp_cursor(app: &mut App) {
    let count = app.row_count();
    let sel = app.cursor().selected().unwrap_or(0);
    if count == 0 {
        app.cursor().select(Some(0));
    } else if sel >= count {
        app.cursor().select(Some(count - 1));
    }
}

// --- rendering --------------------------------------------------------------

fn ui(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4), // header
            Constraint::Length(1), // tab bar
            Constraint::Min(3),    // body
            Constraint::Length(1), // footer / legend
        ])
        .split(f.area());

    render_header(f, chunks[0], app);
    render_tabs(f, chunks[1], app);
    render_body(f, chunks[2], app);
    render_footer(f, chunks[3]);

    if app.show_help {
        render_help(f, f.area());
    }
}

fn render_header(f: &mut Frame, area: Rect, app: &App) {
    let block = Block::default().borders(Borders::ALL).title(" fwf dash ");
    let inner = block.inner(area);
    f.render_widget(block, area);

    let dim = Style::default().fg(Color::DarkGray);
    let key = Style::default().fg(Color::Gray);

    let mut l1: Vec<Span> = Vec::new();
    let mut l2: Vec<Span> = Vec::new();

    match &app.feed {
        Feed::Loading => {
            l1.push(Span::styled("loading…", Style::default().fg(Color::Yellow)));
        }
        Feed::Ok(d) | Feed::Err(_, Some(d)) => {
            // Line 1: identity + parked state.
            l1.push(Span::styled("profile ", dim));
            l1.push(Span::styled(
                &d.profile,
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ));
            l1.push(Span::styled(format!("  ·  {} ", d.template), dim));
            if d.parked {
                l1.push(Span::styled(
                    " ⏸ PARKED ",
                    Style::default()
                        .fg(Color::Black)
                        .bg(Color::Yellow)
                        .add_modifier(Modifier::BOLD),
                ));
            } else {
                l1.push(Span::styled(
                    " ● running ",
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::BOLD),
                ));
            }
            // Line 2: prod / pipeline / provenance / clock.
            l2.push(Span::styled("prod ", key));
            l2.push(Span::raw(d.prod.clone()));
            l2.push(Span::styled("   pipeline ", key));
            l2.push(Span::raw(d.pipeline.clone()));
            l2.push(Span::styled(
                format!("   [{}] ", d.stamp),
                provenance_style(&d.stamp),
            ));
            l2.push(Span::styled(format!("  ⟳ {}", d.generated_at), dim));
        }
        Feed::Err(e, None) => {
            l1.push(Span::styled(
                "data provider error",
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            ));
            l2.push(Span::styled(
                truncate(e, inner.width as usize),
                Style::default().fg(Color::Red),
            ));
        }
    }

    // A transient error while we still have a last-good snapshot: warn inline.
    if let Feed::Err(e, Some(_)) = &app.feed {
        l2.push(Span::styled(
            format!("   ⚠ refresh failed: {}", truncate(e, 40)),
            Style::default().fg(Color::Red),
        ));
    }

    let para = Paragraph::new(vec![Line::from(l1), Line::from(l2)]);
    f.render_widget(para, inner);
}

/// Provenance colour: live status.json is green, stale amber, pure-derived gray.
fn provenance_style(stamp: &str) -> Style {
    match stamp {
        "status.json" => Style::default().fg(Color::Green),
        "stale" => Style::default().fg(Color::Yellow),
        _ => Style::default().fg(Color::DarkGray),
    }
}

fn render_tabs(f: &mut Frame, area: Rect, app: &App) {
    let titles: Vec<Line> = Tab::ALL
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let count = match (app.feed.dashboard(), t) {
                (Some(d), Tab::Roles) => d.roles.len(),
                (Some(d), Tab::Decisions) => d.decisions.len(),
                (Some(d), Tab::Issues) => d.issues.len(),
                _ => 0,
            };
            Line::from(format!(" {} {} ({}) ", i + 1, t.title(), count))
        })
        .collect();
    let tabs = Tabs::new(titles)
        .select(app.tab.index())
        .divider("")
        .highlight_style(
            Style::default()
                .fg(Color::Black)
                .bg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        );
    f.render_widget(tabs, area);
}

fn render_body(f: &mut Frame, area: Rect, app: &mut App) {
    if app.feed.dashboard().is_none() {
        let msg = match &app.feed {
            Feed::Err(e, _) => format!("✗ {e}"),
            _ => "loading…".to_string(),
        };
        f.render_widget(
            Paragraph::new(msg).style(Style::default().fg(Color::DarkGray)),
            area,
        );
        return;
    }

    match app.tab {
        Tab::Roles => render_roles(f, area, app),
        Tab::Decisions => render_list_with_preview(f, area, app, Tab::Decisions),
        Tab::Issues => render_list_with_preview(f, area, app, Tab::Issues),
    }
}

fn render_roles(f: &mut Frame, area: Rect, app: &mut App) {
    let d = app.feed.dashboard().expect("checked by caller");
    let items: Vec<ListItem> = d
        .roles
        .iter()
        .map(|r| {
            let (glyph, style) = match r.state.as_str() {
                "live" => ("●", Style::default().fg(Color::Green)),
                "idle" => ("◌", Style::default().fg(Color::Yellow)),
                _ => ("○", Style::default().fg(Color::DarkGray)),
            };
            let mut spans = vec![
                Span::styled(format!(" {glyph} "), style),
                Span::styled(
                    format!("{:<10}", r.role),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{:<6}", r.state), style),
            ];
            if !r.detail.is_empty() {
                spans.push(Span::styled(
                    format!("  {}", r.detail),
                    Style::default().fg(Color::Gray),
                ));
            }
            ListItem::new(Line::from(spans))
        })
        .collect();

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(" Roles "))
        .highlight_style(Style::default().bg(Color::Rgb(40, 40, 50)))
        .highlight_symbol("▌");
    let mut state = app.cursors[Tab::Roles.index()].clone();
    f.render_stateful_widget(list, area, &mut state);
    app.cursors[Tab::Roles.index()] = state;
}

/// Decisions and Issues share a list-left / body-preview-right layout — the
/// prior-art standard. The selected row's body renders (lightly markdown-styled)
/// in the right pane and scrolls independently.
fn render_list_with_preview(f: &mut Frame, area: Rect, app: &mut App, tab: Tab) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(42), Constraint::Percentage(58)])
        .split(area);

    let d = app.feed.dashboard().expect("checked by caller");
    let selected = app.cursors[tab.index()].selected().unwrap_or(0);

    let (items, title, body): (Vec<ListItem>, &str, String) = match tab {
        Tab::Decisions => {
            let items = d
                .decisions
                .iter()
                .map(|dec| {
                    let head = Line::from(vec![
                        Span::styled(
                            format!(" #{} ", dec.id),
                            Style::default().fg(Color::Magenta),
                        ),
                        Span::styled(
                            truncate(&dec.title, cols[0].width.saturating_sub(8) as usize),
                            Style::default().add_modifier(Modifier::BOLD),
                        ),
                    ]);
                    let flags = Line::from(Span::styled(
                        format!("     {}", dec.flags),
                        Style::default().fg(Color::Green),
                    ));
                    ListItem::new(vec![head, flags])
                })
                .collect();
            let body = d
                .decisions
                .get(selected)
                .map(|x| x.body.clone())
                .unwrap_or_default();
            (items, " Decisions — awaiting you ", body)
        }
        Tab::Issues => {
            let items = d
                .issues
                .iter()
                .map(|iss| {
                    let mut spans = vec![Span::styled(
                        format!(" #{} ", iss.number),
                        Style::default().fg(Color::Blue),
                    )];
                    if iss.gated {
                        spans.push(Span::styled("🔒 ", Style::default().fg(Color::Yellow)));
                    }
                    spans.push(Span::raw(truncate(
                        &iss.title,
                        cols[0].width.saturating_sub(10) as usize,
                    )));
                    ListItem::new(Line::from(spans))
                })
                .collect();
            let body = d
                .issues
                .get(selected)
                .map(|x| x.body.clone())
                .unwrap_or_default();
            (items, " Issues — all open ", body)
        }
        Tab::Roles => unreachable!(),
    };

    let empty = items.is_empty();
    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(title.to_string()),
        )
        .highlight_style(Style::default().bg(Color::Rgb(40, 40, 50)))
        .highlight_symbol("▌");
    let mut state = app.cursors[tab.index()].clone();
    f.render_stateful_widget(list, cols[0], &mut state);
    app.cursors[tab.index()] = state;

    // Preview pane.
    let pblock = Block::default().borders(Borders::ALL).title(" Detail ");
    let preview = if empty {
        Paragraph::new("— nothing here —").style(Style::default().fg(Color::DarkGray))
    } else {
        Paragraph::new(markdownish(&body)).wrap(Wrap { trim: false })
    };
    f.render_widget(
        preview.block(pblock).scroll((app.scroll[tab.index()], 0)),
        cols[1],
    );
}

fn render_footer(f: &mut Frame, area: Rect) {
    let dim = Style::default().fg(Color::DarkGray);
    let key = Style::default().fg(Color::Cyan);
    let spans = vec![
        Span::styled(" 1/2/3·Tab ", key),
        Span::styled("section ", dim),
        Span::styled(" j/k ", key),
        Span::styled("move ", dim),
        Span::styled(" PgUp/Dn·^u/^d ", key),
        Span::styled("scroll ", dim),
        Span::styled(" r ", key),
        Span::styled("refresh ", dim),
        Span::styled(" ? ", key),
        Span::styled("help ", dim),
        Span::styled(" q ", key),
        Span::styled("quit", dim),
    ];
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_help(f: &mut Frame, area: Rect) {
    let popup = centered_rect(60, 70, area);
    f.render_widget(Clear, popup);
    let lines = vec![
        Line::from(Span::styled(
            "fwf dash — read-only status board (#40)",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        help_row("1 / 2 / 3", "jump to Roles / Decisions / Issues"),
        help_row("Tab / Shift-Tab", "next / previous section"),
        help_row("[ / ]", "previous / next section"),
        help_row("j / k  ·  ↓ / ↑", "move the list cursor"),
        help_row("g / G", "first / last row"),
        help_row("PgDn / PgUp", "scroll the detail preview"),
        help_row("Ctrl-d / Ctrl-u", "scroll the detail preview"),
        help_row("mouse wheel", "scroll the detail preview"),
        help_row("r", "force a data refresh now"),
        help_row("?", "toggle this help"),
        help_row("q  ·  Esc", "quit"),
        Line::from(""),
        Line::from(Span::styled(
            "derived-first: roles←tmux · pipeline←git · decisions←label protocol",
            Style::default().fg(Color::DarkGray),
        )),
        Line::from(Span::styled(
            "press ?, Esc, or q to close",
            Style::default().fg(Color::DarkGray),
        )),
    ];
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Help ")
        .style(Style::default().bg(Color::Black));
    f.render_widget(Paragraph::new(lines).block(block), popup);
}

fn help_row(keys: &str, desc: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("  {keys:<18}"), Style::default().fg(Color::Cyan)),
        Span::raw(desc.to_string()),
    ])
}

// --- text helpers -----------------------------------------------------------

/// Truncate to `max` display columns (best-effort by char count), adding an
/// ellipsis. Guards the many places we drop user/issue text into fixed widths.
fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if s.chars().count() <= max {
        return s.to_string();
    }
    let take = max.saturating_sub(1);
    let mut out: String = s.chars().take(take).collect();
    out.push('…');
    out
}

/// Very light markdown-ish styling for issue/decision bodies: headings, bullets,
/// and quotes get a colour so a wall of text scans. Not a real markdown engine —
/// just enough to read at a glance (the #40 research flagged raw text as a miss).
fn markdownish(body: &str) -> Vec<Line<'static>> {
    if body.trim().is_empty() {
        return vec![Line::from(Span::styled(
            "— no body —",
            Style::default().fg(Color::DarkGray),
        ))];
    }
    body.lines()
        .map(|raw| {
            let line = raw.to_string();
            let trimmed = line.trim_start();
            if trimmed.starts_with("###") {
                Line::from(Span::styled(
                    line,
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                ))
            } else if trimmed.starts_with('#') {
                Line::from(Span::styled(
                    line,
                    Style::default()
                        .fg(Color::Magenta)
                        .add_modifier(Modifier::BOLD),
                ))
            } else if trimmed.starts_with("- ") || trimmed.starts_with("* ") {
                Line::from(Span::styled(line, Style::default().fg(Color::Green)))
            } else if trimmed.starts_with('>') {
                Line::from(Span::styled(
                    line,
                    Style::default()
                        .fg(Color::DarkGray)
                        .add_modifier(Modifier::ITALIC),
                ))
            } else {
                Line::from(line)
            }
        })
        .collect()
}

/// A centered rect `pct_x`×`pct_y` percent of `area`, for the help popup.
fn centered_rect(pct_x: u16, pct_y: u16, area: Rect) -> Rect {
    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - pct_y) / 2),
            Constraint::Percentage(pct_y),
            Constraint::Percentage((100 - pct_y) / 2),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - pct_x) / 2),
            Constraint::Percentage(pct_x),
            Constraint::Percentage((100 - pct_x) / 2),
        ])
        .split(v[1])[1]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tab_cycles_and_wraps() {
        assert!(matches!(Tab::Roles.cycle(1), Tab::Decisions));
        assert!(matches!(Tab::Issues.cycle(1), Tab::Roles));
        assert!(matches!(Tab::Roles.cycle(-1), Tab::Issues));
    }

    #[test]
    fn truncate_adds_ellipsis() {
        assert_eq!(truncate("hello", 10), "hello");
        assert_eq!(truncate("hello world", 5), "hell…");
        assert_eq!(truncate("hi", 0), "");
    }

    #[test]
    fn markdownish_handles_empty_and_headings() {
        assert_eq!(markdownish("   ").len(), 1);
        let lines = markdownish("# Title\n- a bullet\nplain");
        assert_eq!(lines.len(), 3);
    }

    #[test]
    fn cursor_clamps_to_rows() {
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new(tx);
        app.feed = Feed::Ok(Dashboard {
            roles: vec![],
            ..Default::default()
        });
        app.move_cursor(5); // no rows: stays put, no panic.
        assert_eq!(app.cursor().selected(), Some(0));
    }
}
