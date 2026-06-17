//! `fwf-dash` — a Rust + ratatui dashboard for the fun-with-friends factory
//! (issue #40). Milestone 1 was the read-only status board; milestone 2 layers
//! the actions on the same proven foundation.
//!
//! The binary is the renderer + input layer; both the read side and the write
//! side stay in bash. A background thread shells out to the read-only data
//! provider (`fwf-dash-data.sh`, via `data::fetch`) on a refresh timer and pushes
//! snapshots over a channel; the main thread owns the terminal, handles input,
//! and draws the latest snapshot. On an action keypress it spawns a one-shot
//! thread that shells out to the action layer (`fwf-dash-act.sh`) and reports the
//! result back over a channel — so a slow gh call never freezes the UI. Keeping
//! the fetch and the mutations off the render thread is what keeps the board
//! flicker-free; ratatui only writes the per-frame diff, so an unchanged redraw
//! is a no-op.
//!
//! Input model is the prior-art one from the #40 research (NO F-keys): j/k+arrows
//! move the list cursor, Tab/Shift-Tab + [ ] + 1/2/3 switch section, PgUp/PgDn +
//! Ctrl-u/Ctrl-d scroll the preview (n/p are the primary detail-pane keys),
//! Ctrl-r refreshes, ? toggles help, q quits, mouse wheel scrolls. Actions
//! (milestone 2): on Decisions y approve / x reject /
//! c comment / o open; on Issues c comment / o open; on Roles r respawn / s stop;
//! t sends a line to the captain from anywhere. Mutating actions confirm first
//! (or take typed text in an inline modal) and never touch the tracker until then.

mod data;

use std::process::Command;
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

/// The four sections of the board. Order matters: it is the 1/2/3/4 jump order
/// and the Tab cycle order. Activity is first so it's the landing view — the
/// "what's going on right now" overview.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Activity,
    Roles,
    Decisions,
    Issues,
}

impl Tab {
    const ALL: [Tab; 4] = [Tab::Activity, Tab::Roles, Tab::Decisions, Tab::Issues];

    fn index(self) -> usize {
        match self {
            Tab::Activity => 0,
            Tab::Roles => 1,
            Tab::Decisions => 2,
            Tab::Issues => 3,
        }
    }

    fn title(self) -> &'static str {
        match self {
            Tab::Activity => "Activity",
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

/// A pending action and the target it acts on (an issue id or a role name; empty
/// for the swarm-wide stop and the captain passthrough). Verbs match the
/// `fwf-dash-act.sh` subcommands exactly.
#[derive(Clone)]
struct Action {
    verb: &'static str,
    target: String,
}

/// The modal overlay, if any. Only one is up at a time and it owns input until
/// dismissed — so an action can never half-fire.
enum Overlay {
    None,
    Help,
    /// A yes/no gate before a mutating action (approve / reject / respawn / stop).
    Confirm {
        action: Action,
        prompt: String,
    },
    /// A free-text field whose contents become the action's last argument
    /// (comment body / captain message).
    Input {
        action: Action,
        prompt: String,
        buffer: String,
    },
}

/// The result of a shelled-out action, sent back from the worker thread.
struct ActionOutcome {
    ok: bool,
    message: String,
}

/// A transient status line shown in the footer until the next keypress.
struct Status {
    message: String,
    is_err: bool,
}

/// All mutable UI state. One cursor + one preview scroll offset per tab so moving
/// between sections preserves where you were.
struct App {
    feed: Feed,
    tab: Tab,
    cursors: [ListState; 4],
    scroll: [u16; 4],
    overlay: Overlay,
    status: Option<Status>,
    /// True while an action is shelling out — disables firing another.
    busy: bool,
    refresh: Sender<()>,
    action_tx: Sender<ActionOutcome>,
    /// Requests the selected row's full thread (body + comments) from the detail worker.
    detail_tx: Sender<String>,
    /// (id, text) of the thread currently loaded for the selected row's preview.
    detail: Option<(String, String)>,
    /// Last id we asked the detail worker for, to dedupe rapid selection changes.
    detail_req: Option<String>,
    should_quit: bool,
}

impl App {
    fn new(
        refresh: Sender<()>,
        action_tx: Sender<ActionOutcome>,
        detail_tx: Sender<String>,
    ) -> App {
        let mut cursors: [ListState; 4] = Default::default();
        for c in &mut cursors {
            c.select(Some(0));
        }
        App {
            feed: Feed::Loading,
            tab: Tab::Activity,
            cursors,
            scroll: [0; 4],
            overlay: Overlay::None,
            status: None,
            busy: false,
            refresh,
            action_tx,
            detail_tx,
            detail: None,
            detail_req: None,
            should_quit: false,
        }
    }

    /// Ask the detail worker for the selected row's full thread, unless we already
    /// asked for this id. Numeric ids only (issues + numeric decisions); Roles and
    /// non-numeric decisions (e.g. a release pseudo-row) have no fetchable thread.
    fn request_detail(&mut self) {
        let id = match self.tab {
            Tab::Activity | Tab::Decisions | Tab::Issues => self.selected_id(),
            Tab::Roles => None,
        };
        match id {
            Some(id) if id.chars().all(|c| c.is_ascii_digit()) => {
                if self.detail_req.as_deref() != Some(id.as_str()) {
                    self.detail_req = Some(id.clone());
                    let _ = self.detail_tx.send(id);
                }
            }
            _ => self.detail_req = None,
        }
    }

    /// Force a detail re-fetch for the selected row after an action mutates the
    /// thread (comment / approve / reject), so the right pane reflects it at once.
    fn refetch_detail(&mut self) {
        self.detail = None; // fall back to the board's body until the fresh thread lands
        self.detail_req = None; // clear the dedupe so request_detail re-sends
        self.request_detail();
    }

    fn cursor(&mut self) -> &mut ListState {
        &mut self.cursors[self.tab.index()]
    }

    /// Number of rows in the active section's list, so cursor movement can clamp.
    fn row_count(&self) -> usize {
        match self.feed.dashboard() {
            None => 0,
            Some(d) => match self.tab {
                Tab::Activity => d.activity.len(),
                Tab::Roles => d.roles.len(),
                Tab::Decisions => d.decisions.len(),
                Tab::Issues => d.issues.len(),
            },
        }
    }

    fn select_tab(&mut self, tab: Tab) {
        self.tab = tab;
        self.request_detail();
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
        self.request_detail();
    }

    fn scroll_preview(&mut self, delta: i32) {
        let s = &mut self.scroll[self.tab.index()];
        *s = (*s as i32 + delta).max(0) as u16;
    }

    /// The id of the selected decision/issue row, as the act layer expects it
    /// (decisions carry a string id; issues a number). None on Roles or empty.
    fn selected_id(&self) -> Option<String> {
        let d = self.feed.dashboard()?;
        let sel = self.cursors[self.tab.index()].selected().unwrap_or(0);
        match self.tab {
            Tab::Activity => d.activity.flat().get(sel).map(|x| x.pr.to_string()),
            Tab::Decisions => d.decisions.get(sel).map(|x| x.id.clone()),
            Tab::Issues => d.issues.get(sel).map(|x| x.number.to_string()),
            Tab::Roles => None,
        }
    }

    fn selected_role(&self) -> Option<String> {
        let d = self.feed.dashboard()?;
        let sel = self.cursors[Tab::Roles.index()].selected().unwrap_or(0);
        d.roles.get(sel).map(|x| x.role.clone())
    }

    fn set_status(&mut self, message: impl Into<String>, is_err: bool) {
        self.status = Some(Status {
            message: message.into(),
            is_err,
        });
    }

    /// Shell out to the action layer on a worker thread and report back over the
    /// channel. `text` is the optional trailing argument (comment / captain body).
    fn spawn_action(&mut self, action: Action, text: Option<String>) {
        if self.busy {
            return;
        }
        let script = match std::env::var("FWF_DASH_ACT") {
            Ok(s) => s,
            Err(_) => {
                self.set_status("FWF_DASH_ACT is not set (run via `fwf dash`)", true);
                return;
            }
        };
        self.busy = true;
        self.set_status(format!("⏳ {} {}…", action.verb, action.target), false);
        let tx = self.action_tx.clone();
        thread::spawn(move || {
            let outcome = run_action(&script, &action, text.as_deref());
            let _ = tx.send(outcome);
        });
    }

    /// Begin an action from a key on the active row: gate mutating verbs behind a
    /// Confirm, route free-text verbs through an Input, fire read-only ones now.
    fn begin_action(&mut self, verb: &'static str) {
        if self.busy {
            return;
        }
        match verb {
            "approve" | "reject" => {
                if let Some(id) = self.selected_id() {
                    let action = Action {
                        verb,
                        target: id.clone(),
                    };
                    let prompt = if verb == "approve" {
                        format!(
                            "Approve #{id}?  un-gates (removes the WIP label) + posts the go-ahead"
                        )
                    } else {
                        format!("Reject #{id}?  posts a needs-changes comment; stays gated")
                    };
                    self.overlay = Overlay::Confirm { action, prompt };
                }
            }
            "comment" => {
                if let Some(id) = self.selected_id() {
                    self.overlay = Overlay::Input {
                        action: Action {
                            verb,
                            target: id.clone(),
                        },
                        prompt: format!("Comment on #{id}"),
                        buffer: String::new(),
                    };
                }
            }
            "open" => {
                if let Some(id) = self.selected_id() {
                    self.spawn_action(Action { verb, target: id }, None);
                }
            }
            "respawn" => {
                if let Some(role) = self.selected_role() {
                    self.overlay = Overlay::Confirm {
                        action: Action {
                            verb,
                            target: role.clone(),
                        },
                        prompt: format!("Respawn role '{role}'?  hot-swaps the pane"),
                    };
                }
            }
            "stop" => {
                self.overlay = Overlay::Confirm {
                    action: Action {
                        verb,
                        target: String::new(),
                    },
                    prompt: "Stop the WHOLE swarm?  every agent commits WIP and idles".to_string(),
                };
            }
            "passthrough" => {
                self.overlay = Overlay::Input {
                    action: Action {
                        verb,
                        target: String::new(),
                    },
                    prompt: "Send to the CAPTAIN".to_string(),
                    buffer: String::new(),
                };
            }
            _ => {}
        }
    }

    fn on_key(&mut self, key: KeyEvent) {
        // A keypress clears the last action's status line.
        self.status = None;
        // Modals own input until dismissed.
        match std::mem::replace(&mut self.overlay, Overlay::None) {
            Overlay::Help => {
                // Stays open unless a dismiss key was pressed.
                if !matches!(
                    key.code,
                    KeyCode::Char('?') | KeyCode::Esc | KeyCode::Char('q')
                ) {
                    self.overlay = Overlay::Help;
                }
                return;
            }
            Overlay::Confirm { action, prompt } => {
                match key.code {
                    KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                        self.spawn_action(action, None)
                    }
                    KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                        self.set_status("cancelled", false)
                    }
                    _ => self.overlay = Overlay::Confirm { action, prompt }, // keep waiting
                }
                return;
            }
            Overlay::Input {
                action,
                prompt,
                mut buffer,
            } => {
                match key.code {
                    KeyCode::Esc => self.set_status("cancelled", false),
                    KeyCode::Enter => {
                        let text = buffer.trim().to_string();
                        if text.is_empty() {
                            self.set_status("empty — skipped", false);
                        } else {
                            self.spawn_action(action, Some(text));
                        }
                    }
                    KeyCode::Backspace => {
                        buffer.pop();
                        self.overlay = Overlay::Input {
                            action,
                            prompt,
                            buffer,
                        };
                    }
                    KeyCode::Char(c) => {
                        buffer.push(c);
                        self.overlay = Overlay::Input {
                            action,
                            prompt,
                            buffer,
                        };
                    }
                    _ => {
                        self.overlay = Overlay::Input {
                            action,
                            prompt,
                            buffer,
                        }
                    }
                }
                return;
            }
            Overlay::None => {}
        }

        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => self.should_quit = true,
            KeyCode::Char('c') if ctrl => self.should_quit = true,
            KeyCode::Char('?') => self.overlay = Overlay::Help,
            KeyCode::Char('r') if ctrl => {
                let _ = self.refresh.send(());
                self.set_status("refreshing…", false);
            }
            // Section switching.
            KeyCode::Tab | KeyCode::Char(']') => self.select_tab(self.tab.cycle(1)),
            KeyCode::BackTab | KeyCode::Char('[') => self.select_tab(self.tab.cycle(-1)),
            KeyCode::Char('1') => self.select_tab(Tab::Activity),
            KeyCode::Char('2') => self.select_tab(Tab::Roles),
            KeyCode::Char('3') => self.select_tab(Tab::Decisions),
            KeyCode::Char('4') => self.select_tab(Tab::Issues),
            // List navigation.
            KeyCode::Char('j') | KeyCode::Down => self.move_cursor(1),
            KeyCode::Char('k') | KeyCode::Up => self.move_cursor(-1),
            KeyCode::Char('g') | KeyCode::Home => self.move_cursor(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => self.move_cursor(isize::MAX / 2),
            // Preview scroll. n/p are the primary detail-pane keys (next/prev);
            // Ctrl-d/u, PgDn/Up and the wheel remain as secondary.
            KeyCode::Char('n') => self.scroll_preview(3),
            KeyCode::Char('p') => self.scroll_preview(-3),
            KeyCode::Char('d') if ctrl => self.scroll_preview(10),
            KeyCode::Char('u') if ctrl => self.scroll_preview(-10),
            KeyCode::PageDown => self.scroll_preview(10),
            KeyCode::PageUp => self.scroll_preview(-10),
            // Actions — gated by the active section.
            KeyCode::Char('t') => self.begin_action("passthrough"),
            KeyCode::Char('y') if self.tab == Tab::Decisions => self.begin_action("approve"),
            KeyCode::Char('x') if self.tab == Tab::Decisions => self.begin_action("reject"),
            KeyCode::Char('c') if matches!(self.tab, Tab::Decisions | Tab::Issues) => {
                self.begin_action("comment")
            }
            KeyCode::Char('o') if matches!(self.tab, Tab::Decisions | Tab::Issues) => {
                self.begin_action("open")
            }
            KeyCode::Char('r') if self.tab == Tab::Roles => self.begin_action("respawn"),
            KeyCode::Char('s') if self.tab == Tab::Roles => self.begin_action("stop"),
            _ => {}
        }
    }
}

/// Run the action layer once (on a worker thread). gh's browser-open and the
/// local pager are suppressed via FWF_DASH_NO_PAGER so nothing fights the TUI.
fn run_action(script: &str, action: &Action, text: Option<&str>) -> ActionOutcome {
    let mut cmd = Command::new("bash");
    cmd.arg(script).arg(action.verb);
    if !action.target.is_empty() {
        cmd.arg(&action.target);
    }
    if let Some(t) = text {
        cmd.arg(t);
    }
    cmd.env("FWF_DASH_NO_PAGER", "1");
    match cmd.output() {
        Err(e) => ActionOutcome {
            ok: false,
            message: format!("could not run the action layer: {e}"),
        },
        Ok(out) => {
            let tail = |b: &[u8]| {
                String::from_utf8_lossy(b)
                    .lines()
                    .last()
                    .unwrap_or("")
                    .to_string()
            };
            if out.status.success() {
                let msg = tail(&out.stdout);
                ActionOutcome {
                    ok: true,
                    message: if msg.is_empty() {
                        format!("{} {} ✓", action.verb, action.target)
                    } else {
                        msg
                    },
                }
            } else {
                let err = tail(&out.stderr);
                ActionOutcome {
                    ok: false,
                    message: if err.is_empty() {
                        format!("{} failed", action.verb)
                    } else {
                        err
                    },
                }
            }
        }
    }
}

fn main() -> Result<()> {
    // Data thread: fetch immediately, then on each refresh tick or on-demand
    // request. recv_timeout doubles as the timer and the Ctrl-r listener.
    let (data_tx, data_rx) = mpsc::channel::<Result<Dashboard, String>>();
    let (refresh_tx, refresh_rx) = mpsc::channel::<()>();
    let (action_tx, action_rx) = mpsc::channel::<ActionOutcome>();
    let (detail_req_tx, detail_req_rx) = mpsc::channel::<String>();
    let (detail_tx, detail_rx) = mpsc::channel::<(String, String)>();
    let interval = refresh_interval();
    thread::spawn(move || data_loop(data_tx, refresh_rx, interval));
    thread::spawn(move || detail_loop(detail_req_rx, detail_tx));

    let mut terminal = init_terminal().context("initializing the terminal")?;
    let app = App::new(refresh_tx, action_tx, detail_req_tx);
    let result = run(&mut terminal, app, data_rx, action_rx, detail_rx);
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

/// Detail worker: fetches the selected row's full thread on demand. Coalesces a
/// burst of requests (fast j/k scrolling) down to the latest id so we only pay
/// for the row the cursor actually landed on.
fn detail_loop(req: Receiver<String>, tx: Sender<(String, String)>) {
    while let Ok(mut id) = req.recv() {
        while let Ok(newer) = req.try_recv() {
            id = newer;
        }
        let text = data::fetch_detail(&id).unwrap_or_else(|e| format!("(detail unavailable: {e})"));
        if tx.send((id, text)).is_err() {
            return; // main thread is gone.
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
    action_rx: Receiver<ActionOutcome>,
    detail_rx: Receiver<(String, String)>,
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

        // Drain finished actions: surface the result and refresh on success so
        // the board reflects the mutation (un-gated issue, respawned role, …) and
        // the detail pane re-pulls the thread (so your just-posted comment shows).
        while let Ok(outcome) = action_rx.try_recv() {
            app.busy = false;
            app.set_status(outcome.message, !outcome.ok);
            if outcome.ok {
                let _ = app.refresh.send(());
                app.refetch_detail();
            }
        }

        // Apply any detail thread that finished loading, if it still matches the
        // selected row (a stale result for a row we've scrolled past is dropped).
        while let Ok((id, text)) = detail_rx.try_recv() {
            if app.selected_id().as_deref() == Some(id.as_str()) {
                app.detail = Some((id, text));
            }
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
    // A red "CAPTAIN NEEDS YOU" banner slots in below the tab bar whenever the
    // captain is blocked on a human decision, so the dash is never calm-looking
    // while something is actually waiting on you.
    let needs = app
        .feed
        .dashboard()
        .map(|d| d.needs_you.active)
        .unwrap_or(false);

    let mut constraints = vec![
        Constraint::Length(4), // header
        Constraint::Length(1), // tab bar
    ];
    if needs {
        constraints.push(Constraint::Length(1)); // needs-you banner
    }
    constraints.push(Constraint::Min(3)); // body
    constraints.push(Constraint::Length(1)); // footer / legend / status
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(f.area());

    let mut i = 0;
    render_header(f, chunks[i], app);
    i += 1;
    render_tabs(f, chunks[i], app);
    i += 1;
    if needs {
        render_needs_banner(f, chunks[i], app);
        i += 1;
    }
    render_body(f, chunks[i], app);
    i += 1;
    render_footer(f, chunks[i], app);

    match &app.overlay {
        Overlay::Help => render_help(f, f.area()),
        Overlay::Confirm { prompt, .. } => render_confirm(f, f.area(), prompt),
        Overlay::Input { prompt, buffer, .. } => render_input(f, f.area(), prompt, buffer),
        Overlay::None => {}
    }
}

/// The red attention banner — shown only when `needs_you.active`, full-width
/// below the tabs so it's the first thing the eye hits on any tab.
fn render_needs_banner(f: &mut Frame, area: Rect, app: &App) {
    let summary = app
        .feed
        .dashboard()
        .map(|d| d.needs_you.summary.clone())
        .unwrap_or_default();
    let text = if summary.is_empty() {
        " ⛔ CAPTAIN NEEDS YOU — a decision is waiting · attach: tmux attach -t friends-coord "
            .to_string()
    } else {
        format!(" ⛔ CAPTAIN NEEDS YOU — {summary}  · attach: tmux attach -t friends-coord ")
    };
    let para = Paragraph::new(text).style(
        Style::default()
            .bg(Color::Red)
            .fg(Color::White)
            .add_modifier(Modifier::BOLD),
    );
    f.render_widget(para, area);
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
                (Some(d), Tab::Activity) => d.activity.len(),
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
        Tab::Activity => render_activity(f, area, app),
        Tab::Roles => render_roles(f, area, app),
        Tab::Decisions => render_list_with_preview(f, area, app, Tab::Decisions),
        Tab::Issues => render_list_with_preview(f, area, app, Tab::Issues),
    }
}

/// The Activity board — the landing view: BUILDING / IN TEST / MERGED / REVIEW→main
/// as one scrollable cursor list (left) with the selected PR's detail (right).
/// Row order matches `Activity::flat`, so the cursor index maps straight to a PR;
/// group headers are embedded in the first row of each group (purely cosmetic).
fn render_activity(f: &mut Frame, area: Rect, app: &mut App) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(42), Constraint::Percentage(58)])
        .split(area);

    let d = app.feed.dashboard().expect("checked by caller");
    let act = &d.activity;
    let selected = app.cursors[Tab::Activity.index()].selected().unwrap_or(0);

    let groups: [(&str, &[data::ActivityItem]); 4] = [
        ("BUILDING", &act.building),
        ("IN TEST / REVIEW", &act.in_test),
        ("MERGED (recent)", &act.merged),
        ("REVIEW → main (direct PRs)", &act.to_main),
    ];
    let mut items: Vec<ListItem> = Vec::new();
    let mut first_group = true;
    for (label, rows) in groups {
        if rows.is_empty() {
            continue;
        }
        for (i, it) in rows.iter().enumerate() {
            let mut lines: Vec<Line> = Vec::new();
            if i == 0 {
                if !first_group {
                    lines.push(Line::from(""));
                }
                lines.push(Line::from(Span::styled(
                    label.to_string(),
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )));
            }
            lines.push(activity_row_line(it, cols[0].width));
            items.push(ListItem::new(lines));
        }
        first_group = false;
    }

    let empty = act.is_empty();
    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Activity — factory motion "),
        )
        .highlight_style(Style::default().bg(Color::Rgb(40, 40, 50)))
        .highlight_symbol("▌");
    let mut state = app.cursors[Tab::Activity.index()].clone();
    f.render_stateful_widget(list, cols[0], &mut state);
    app.cursors[Tab::Activity.index()] = state;

    // Right preview: the selected PR's thread (lazily fetched), with a one-line
    // summary of the row as the placeholder until it lands.
    let flat = act.flat();
    let sel_pr = flat.get(selected).map(|x| x.pr.to_string());
    let thread = match &app.detail {
        Some((id, text)) if Some(id.as_str()) == sel_pr.as_deref() => Some(text.as_str()),
        _ => None,
    };
    let loading = thread.is_none() && sel_pr.is_some();
    let ptitle = if loading {
        " Detail · loading PR… "
    } else {
        " Detail "
    };
    let fallback = flat.get(selected).map(activity_summary).unwrap_or_default();
    let pblock = Block::default().borders(Borders::ALL).title(ptitle);
    let preview = if empty {
        Paragraph::new("— factory idle: no open PRs or recent merges —")
            .style(Style::default().fg(Color::DarkGray))
    } else {
        Paragraph::new(markdownish(thread.unwrap_or(&fallback))).wrap(Wrap { trim: false })
    };
    f.render_widget(
        preview
            .block(pblock)
            .scroll((app.scroll[Tab::Activity.index()], 0)),
        cols[1],
    );
}

/// One compact list line for an activity row. Merged rows (which carry a `when`)
/// render as `#pr →base when  title`; building/test rows as `role #issue ✓ title`.
fn activity_row_line(it: &data::ActivityItem, width: u16) -> Line<'static> {
    let w = width.saturating_sub(6) as usize;
    // Lead every row with the ISSUE (the unit of work — matches the Issues tab),
    // and always show the PR as an explicit secondary tag, so the two tabs key on
    // the same number. Rows with no linked issue lead with the PR instead.
    let lead = if it.issue.is_empty() {
        Span::styled(format!("  PR {} ", it.pr), Style::default().fg(Color::Blue))
    } else {
        Span::styled(
            format!("  #{} ", it.issue),
            Style::default().fg(Color::Blue),
        )
    };
    let pr_tag = if it.issue.is_empty() {
        Span::raw(String::new()) // PR already shown as the lead
    } else {
        Span::styled(
            format!("  · PR {}", it.pr),
            Style::default().fg(Color::DarkGray),
        )
    };
    if !it.when.is_empty() {
        // merged
        Line::from(vec![
            lead,
            Span::styled(
                format!("→{} {} ", it.base, it.when),
                Style::default().fg(Color::DarkGray),
            ),
            Span::raw(truncate(&it.title, w)),
            pr_tag,
        ])
    } else {
        // building / in test
        let (glyph, gcol) = checks_glyph(&it.checks);
        let who = if it.role.is_empty() {
            String::new()
        } else {
            format!("  {}", it.role)
        };
        Line::from(vec![
            lead,
            Span::styled(format!("{} ", glyph), Style::default().fg(gcol)),
            Span::raw(truncate(&it.title, w)),
            Span::styled(who, Style::default().fg(Color::Blue)),
            pr_tag,
        ])
    }
}

/// Glyph + colour for a PR's aggregate check state.
fn checks_glyph(checks: &str) -> (&'static str, Color) {
    match checks {
        "pass" => ("✓", Color::Green),
        "run" => ("●", Color::Yellow),
        "fail" => ("✗", Color::Red),
        _ => ("·", Color::DarkGray),
    }
}

/// Placeholder detail shown until the selected PR's full thread is fetched.
fn activity_summary(it: &&data::ActivityItem) -> String {
    let mut s = format!("PR #{}  → {}\n{}\n", it.pr, it.base, it.title);
    if !it.role.is_empty() {
        s.push_str(&format!("\nrole:   {}", it.role));
    }
    if !it.issue.is_empty() {
        s.push_str(&format!("\nissue:  #{}", it.issue));
    }
    if !it.checks.is_empty() {
        s.push_str(&format!("\nchecks: {}", it.checks));
    }
    if !it.when.is_empty() {
        s.push_str(&format!("\nmerged: {}", it.when));
    }
    s.push_str("\n\n(loading PR detail…)");
    s
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

    let (items, title, body, sel_id): (Vec<ListItem>, &str, String, Option<String>) = match tab {
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
            let sel_id = d.decisions.get(selected).map(|x| x.id.clone());
            (items, " Decisions — awaiting you ", body, sel_id)
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
            let sel_id = d.issues.get(selected).map(|x| x.number.to_string());
            (items, " Issues — all open ", body, sel_id)
        }
        Tab::Activity | Tab::Roles => unreachable!(),
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

    // Preview pane: the selected row's full thread (body + comments), lazily
    // loaded for this row only. Until it lands we show the board's body snapshot;
    // a title hint flags the in-flight fetch.
    let thread = match &app.detail {
        Some((id, text)) if Some(id.as_str()) == sel_id.as_deref() => Some(text.as_str()),
        _ => None,
    };
    let loading = thread.is_none()
        && sel_id
            .as_deref()
            .is_some_and(|s| s.chars().all(|c| c.is_ascii_digit()));
    let ptitle = if loading {
        " Detail · loading thread… "
    } else {
        " Detail "
    };
    let pblock = Block::default().borders(Borders::ALL).title(ptitle);
    let preview = if empty {
        Paragraph::new("— nothing here —").style(Style::default().fg(Color::DarkGray))
    } else {
        Paragraph::new(markdownish(thread.unwrap_or(&body))).wrap(Wrap { trim: false })
    };
    f.render_widget(
        preview.block(pblock).scroll((app.scroll[tab.index()], 0)),
        cols[1],
    );
}

/// The footer is the action+nav legend, unless a status line is up — a finished
/// action's result or a "working…" note, colour-coded.
fn render_footer(f: &mut Frame, area: Rect, app: &App) {
    if let Some(s) = &app.status {
        let style = if s.is_err {
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::Green)
        };
        let glyph = if s.is_err { " ✗ " } else { " ✓ " };
        f.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(glyph, style),
                Span::styled(
                    truncate(&s.message, area.width.saturating_sub(4) as usize),
                    style,
                ),
            ])),
            area,
        );
        return;
    }

    let dim = Style::default().fg(Color::DarkGray);
    let key = Style::default().fg(Color::Cyan);
    // Action hints depend on the active section.
    let actions: &[(&str, &str)] = match app.tab {
        Tab::Activity => &[("n/p", "scroll PR"), ("Ctrl-r", "refresh")],
        Tab::Decisions => &[
            ("y", "approve"),
            ("x", "reject"),
            ("c", "comment"),
            ("o", "open"),
        ],
        Tab::Issues => &[("c", "comment"), ("o", "open")],
        Tab::Roles => &[("r", "respawn"), ("s", "stop")],
    };
    let mut spans = vec![
        Span::styled(" 1-4 ", key),
        Span::styled("tab ", dim),
        Span::styled(" j/k ", key),
        Span::styled("move ", dim),
    ];
    for (k, label) in actions {
        spans.push(Span::styled(format!(" {k} "), key));
        spans.push(Span::styled(format!("{label} "), dim));
    }
    spans.push(Span::styled(" t ", key));
    spans.push(Span::styled("captain ", dim));
    spans.push(Span::styled(" ? ", key));
    spans.push(Span::styled("help ", dim));
    spans.push(Span::styled(" q ", key));
    spans.push(Span::styled("quit", dim));
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_help(f: &mut Frame, area: Rect) {
    let popup = centered_rect(64, 80, area);
    f.render_widget(Clear, popup);
    let lines = vec![
        Line::from(Span::styled(
            "fwf dash — status board + decision inbox (#40)",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        help_row(
            "1 / 2 / 3 / 4",
            "jump to Activity / Roles / Decisions / Issues",
        ),
        help_row("Tab / Shift-Tab  ·  [ ]", "next / previous section"),
        help_row("j / k  ·  ↓ / ↑", "move the list cursor"),
        help_row("g / G", "first / last row"),
        help_row(
            "n / p  ·  PgDn/PgUp · Ctrl-d/u · wheel",
            "scroll the detail preview",
        ),
        help_row("Ctrl-r", "force a data refresh now"),
        Line::from(""),
        Line::from(Span::styled(
            "  Activity",
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )),
        help_row(
            "(read-only)",
            "BUILDING · IN TEST · MERGED · REVIEW→main; rows lead with the issue (· PR N)",
        ),
        Line::from(""),
        Line::from(Span::styled(
            "  Decisions",
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        )),
        help_row("y / x", "approve (un-gate) / reject — confirms first"),
        help_row("c", "comment (opens a text field)"),
        help_row("o", "open in the browser (gh) / detail (local)"),
        Line::from(Span::styled(
            "  Issues",
            Style::default()
                .fg(Color::Blue)
                .add_modifier(Modifier::BOLD),
        )),
        help_row("c / o", "comment / open"),
        Line::from(Span::styled(
            "  Roles",
            Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
        )),
        help_row("r / s", "respawn the role / stop the swarm — confirms"),
        Line::from(Span::styled(
            "  Anywhere",
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )),
        help_row("t", "send a line to the captain (text field)"),
        help_row("? · q · Esc", "toggle help · quit"),
        Line::from(""),
        Line::from(Span::styled(
            "derived-first: roles←tmux · pipeline←git · decisions←label protocol",
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
        Span::styled(format!("  {keys:<28}"), Style::default().fg(Color::Cyan)),
        Span::raw(desc.to_string()),
    ])
}

/// A small centered yes/no gate for a mutating action.
fn render_confirm(f: &mut Frame, area: Rect, prompt: &str) {
    let popup = centered_rect(60, 22, area);
    f.render_widget(Clear, popup);
    let lines = vec![
        Line::from(Span::styled(
            prompt.to_string(),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  y ", Style::default().fg(Color::Black).bg(Color::Green)),
            Span::raw(" yes    "),
            Span::styled(" n ", Style::default().fg(Color::Black).bg(Color::Red)),
            Span::raw(" no / Esc"),
        ]),
    ];
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Confirm ")
        .style(Style::default().bg(Color::Black));
    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        popup,
    );
}

/// A single-line text field whose contents become the action's last argument.
fn render_input(f: &mut Frame, area: Rect, prompt: &str, buffer: &str) {
    let popup = centered_rect(70, 26, area);
    f.render_widget(Clear, popup);
    let lines = vec![
        Line::from(Span::styled(
            prompt.to_string(),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("▏", Style::default().fg(Color::DarkGray)),
            Span::raw(buffer.to_string()),
            Span::styled("█", Style::default().fg(Color::Cyan)),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Enter send · Esc cancel",
            Style::default().fg(Color::DarkGray),
        )),
    ];
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Input ")
        .style(Style::default().bg(Color::Black));
    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        popup,
    );
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

/// A centered rect `pct_x`×`pct_y` percent of `area`, for the overlays.
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

    fn test_app() -> App {
        let (rtx, _r) = mpsc::channel();
        let (atx, _a) = mpsc::channel();
        let (dtx, _d) = mpsc::channel();
        App::new(rtx, atx, dtx)
    }

    #[test]
    fn tab_cycles_and_wraps() {
        // Order: Activity → Roles → Decisions → Issues → (wrap) Activity.
        assert!(matches!(Tab::Activity.cycle(1), Tab::Roles));
        assert!(matches!(Tab::Issues.cycle(1), Tab::Activity));
        assert!(matches!(Tab::Activity.cycle(-1), Tab::Issues));
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
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            roles: vec![],
            ..Default::default()
        });
        app.move_cursor(5); // no rows: stays put, no panic.
        assert_eq!(app.cursor().selected(), Some(0));
    }

    #[test]
    fn selected_id_tracks_tab_and_cursor() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            decisions: vec![data::Decision {
                id: "337".into(),
                title: "t".into(),
                flags: String::new(),
                body: String::new(),
            }],
            issues: vec![data::Issue {
                number: 42,
                title: "i".into(),
                gated: false,
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Decisions;
        assert_eq!(app.selected_id().as_deref(), Some("337"));
        app.tab = Tab::Issues;
        assert_eq!(app.selected_id().as_deref(), Some("42"));
        app.tab = Tab::Roles;
        assert_eq!(app.selected_id(), None);
    }

    #[test]
    fn approve_opens_a_confirm_not_a_fire() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            decisions: vec![data::Decision {
                id: "337".into(),
                title: "t".into(),
                flags: String::new(),
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Decisions;
        app.begin_action("approve");
        match &app.overlay {
            Overlay::Confirm { action, .. } => {
                assert_eq!(action.verb, "approve");
                assert_eq!(action.target, "337");
            }
            _ => panic!("approve should open a confirm overlay"),
        }
    }

    #[test]
    fn comment_opens_an_input_field() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            issues: vec![data::Issue {
                number: 9,
                title: "i".into(),
                gated: false,
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Issues;
        app.begin_action("comment");
        assert!(matches!(app.overlay, Overlay::Input { .. }));
    }
}
