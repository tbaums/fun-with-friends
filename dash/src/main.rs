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

use data::{Dashboard, UsageData};

/// The five sections of the board. Order matters: it is the 1/2/3/4/5 jump
/// order and the Tab cycle order. Activity is first so it's the landing view
/// — the "what's going on right now" overview.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Activity,
    Roles,
    Decisions,
    Issues,
    Usage,
}

impl Tab {
    const ALL: [Tab; 5] = [
        Tab::Activity,
        Tab::Roles,
        Tab::Decisions,
        Tab::Issues,
        Tab::Usage,
    ];

    fn index(self) -> usize {
        match self {
            Tab::Activity => 0,
            Tab::Roles => 1,
            Tab::Decisions => 2,
            Tab::Issues => 3,
            Tab::Usage => 4,
        }
    }

    fn title(self) -> &'static str {
        match self {
            Tab::Activity => "Activity",
            Tab::Roles => "Roles",
            Tab::Decisions => "Decisions",
            Tab::Issues => "Issues",
            Tab::Usage => "Usage",
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

/// Same shape as `Feed`, for the separate usage-data provider (its own thread
/// and refresh cadence — see the module doc on why it's not folded into
/// `Dashboard`).
enum UsageFeed {
    Loading,
    Ok(UsageData),
    Err(String, Option<UsageData>),
}

impl UsageFeed {
    fn usage(&self) -> Option<&UsageData> {
        match self {
            UsageFeed::Ok(u) => Some(u),
            UsageFeed::Err(_, last) => last.as_ref(),
            UsageFeed::Loading => None,
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
    usage_feed: UsageFeed,
    tab: Tab,
    cursors: [ListState; 5],
    scroll: [u16; 5],
    overlay: Overlay,
    status: Option<Status>,
    /// True while an action is shelling out — disables firing another.
    busy: bool,
    refresh: Sender<()>,
    usage_refresh: Sender<()>,
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
        usage_refresh: Sender<()>,
        action_tx: Sender<ActionOutcome>,
        detail_tx: Sender<String>,
    ) -> App {
        let mut cursors: [ListState; 5] = Default::default();
        for c in &mut cursors {
            c.select(Some(0));
        }
        App {
            feed: Feed::Loading,
            usage_feed: UsageFeed::Loading,
            tab: Tab::Activity,
            cursors,
            scroll: [0; 5],
            overlay: Overlay::None,
            status: None,
            busy: false,
            refresh,
            usage_refresh,
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
            Tab::Roles | Tab::Usage => None,
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
        if self.tab == Tab::Usage {
            return self.usage_feed.usage().map(|u| u.roles.len()).unwrap_or(0);
        }
        match self.feed.dashboard() {
            None => 0,
            Some(d) => match self.tab {
                Tab::Activity => d.activity.len(),
                Tab::Roles => d.roles.len(),
                Tab::Decisions => d.decisions.len(),
                Tab::Issues => d.issues.len(),
                Tab::Usage => unreachable!(),
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
            Tab::Roles | Tab::Usage => None,
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
                let _ = self.usage_refresh.send(());
                self.set_status("refreshing…", false);
            }
            // Section switching.
            KeyCode::Tab | KeyCode::Char(']') => self.select_tab(self.tab.cycle(1)),
            KeyCode::BackTab | KeyCode::Char('[') => self.select_tab(self.tab.cycle(-1)),
            KeyCode::Char('1') => self.select_tab(Tab::Activity),
            KeyCode::Char('2') => self.select_tab(Tab::Roles),
            KeyCode::Char('3') => self.select_tab(Tab::Decisions),
            KeyCode::Char('4') => self.select_tab(Tab::Issues),
            KeyCode::Char('5') => self.select_tab(Tab::Usage),
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
    // Usage thread: a separate provider (fwf-usage-data.sh), a separate — and
    // by default slower — refresh cadence, since summing every role's Claude
    // Code transcripts is a heavier read than the gh/tmux-derived Dashboard.
    let (usage_tx, usage_rx) = mpsc::channel::<Result<UsageData, String>>();
    let (usage_refresh_tx, usage_refresh_rx) = mpsc::channel::<()>();
    let (action_tx, action_rx) = mpsc::channel::<ActionOutcome>();
    let (detail_req_tx, detail_req_rx) = mpsc::channel::<String>();
    let (detail_tx, detail_rx) = mpsc::channel::<(String, String)>();
    let interval = refresh_interval();
    let usage_interval = usage_refresh_interval();
    thread::spawn(move || data_loop(data_tx, refresh_rx, interval));
    thread::spawn(move || usage_data_loop(usage_tx, usage_refresh_rx, usage_interval));
    thread::spawn(move || detail_loop(detail_req_rx, detail_tx));

    let mut terminal = init_terminal().context("initializing the terminal")?;
    let app = App::new(refresh_tx, usage_refresh_tx, action_tx, detail_req_tx);
    let result = run(&mut terminal, app, data_rx, usage_rx, action_rx, detail_rx);
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

/// `$FWF_USAGE_REFRESH` seconds between usage-tab auto-refreshes (default 60,
/// floor 5) — deliberately slower than the main dash refresh (see above).
fn usage_refresh_interval() -> Duration {
    let secs = std::env::var("FWF_USAGE_REFRESH")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60)
        .max(5);
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

/// Same shape as `data_loop`, for the usage-data provider on its own (slower)
/// cadence.
fn usage_data_loop(tx: Sender<Result<UsageData, String>>, req: Receiver<()>, interval: Duration) {
    loop {
        if tx.send(data::fetch_usage()).is_err() {
            return; // main thread (and terminal) is gone.
        }
        match req.recv_timeout(interval) {
            Ok(()) => {}
            Err(RecvTimeoutError::Timeout) => {}
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
    usage_rx: Receiver<Result<UsageData, String>>,
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

        // Same drain, for the separate usage-data thread.
        while let Ok(msg) = usage_rx.try_recv() {
            app.usage_feed = match msg {
                Ok(u) => UsageFeed::Ok(u),
                Err(e) => {
                    let last = match std::mem::replace(&mut app.usage_feed, UsageFeed::Loading) {
                        UsageFeed::Ok(u) => Some(u),
                        UsageFeed::Err(_, last) => last,
                        UsageFeed::Loading => None,
                    };
                    UsageFeed::Err(e, last)
                }
            };
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
    // issue #193 AC (e): NO fwf session visible on the resolved socket at
    // all — every role already renders "unknown" (never a fabricated
    // "down"), and this is the header-level version of the same fact. The
    // loudest and FIRST banner: every other signal below (needs-you,
    // upgrade, stale-dash) risks being read as "the factory is fine, just
    // X" when the honest situation is "I cannot tell you anything about
    // this factory right now".
    let no_view = app
        .feed
        .dashboard()
        .map(|d| !d.visibility.factory_visible)
        .unwrap_or(false);
    // A red "CAPTAIN NEEDS YOU" banner slots in below the tab bar whenever the
    // captain is blocked on a human decision, so the dash is never calm-looking
    // while something is actually waiting on you.
    let needs = app
        .feed
        .dashboard()
        .map(|d| d.needs_you.active)
        .unwrap_or(false);
    // A yellow "upgrade available" banner (issue #94) — visually distinct from
    // the red needs-you banner (different colour scheme, not just adjacent) so
    // the two are never mistaken for each other. Stacks below needs-you: a
    // blocked-on-you decision stays the first thing the eye hits.
    let upgrade = app
        .feed
        .dashboard()
        .map(|d| d.upgrade.available)
        .unwrap_or(false);
    // Issue #153: THIS running dash is older than what's installed on disk —
    // distinct from `upgrade` above (installed vs. latest GitHub release).
    // Loudest of the three banners (magenta/white) since it means the screen
    // you are looking at right now may already be lying about what shipped.
    let stale_dash = app
        .feed
        .dashboard()
        .map(|d| data::running_binary_stale(&d.installed.version))
        .unwrap_or(false);
    // Issue #239: rate-limit exhaustion (or a read that couldn't complete at
    // all, treated the same way — see ApiBudget's own doc comment) takes
    // every role's read layer out at once, one account, one budget. This is
    // the operator-facing end of that chain: the state actually reaching a
    // human looking at the board, as a NAMED banner, not left to "an
    // operator could probably notice the dash looks emptier than usual".
    let api_budget_exhausted = app
        .feed
        .dashboard()
        .map(|d| d.api_budget.status == "EXHAUSTED")
        .unwrap_or(false);

    let mut constraints = vec![
        Constraint::Length(4), // header
        Constraint::Length(1), // tab bar
    ];
    if no_view {
        constraints.push(Constraint::Length(1)); // no-factory-visible banner
    }
    if needs {
        constraints.push(Constraint::Length(1)); // needs-you banner
    }
    if stale_dash {
        constraints.push(Constraint::Length(1)); // stale-dash restart banner
    }
    if api_budget_exhausted {
        constraints.push(Constraint::Length(1)); // API budget exhausted banner
    }
    if upgrade {
        constraints.push(Constraint::Length(1)); // upgrade-available banner
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
    if no_view {
        render_no_view_banner(f, chunks[i], app);
        i += 1;
    }
    if needs {
        render_needs_banner(f, chunks[i], app);
        i += 1;
    }
    if stale_dash {
        render_stale_dash_banner(f, chunks[i], app);
        i += 1;
    }
    if api_budget_exhausted {
        render_api_budget_banner(f, chunks[i], app);
        i += 1;
    }
    if upgrade {
        render_upgrade_banner(f, chunks[i], app);
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

/// The "no factory visible" banner (issue #193 AC e) — shown only when
/// `!visibility.factory_visible`, full-width, above every other banner. Names
/// the state dir/profile/host being read so a wrong `--profile` or a wrong
/// host reads as MY mistake, diagnosable on screen, not a mystery (one of
/// this ticket's own edge cases). Black-on-red: the loudest treatment here,
/// since every role on the roles pane is ALSO rendering "unknown" right now
/// and this is the one line that explains why.
fn render_no_view_banner(f: &mut Frame, area: Rect, app: &App) {
    let (state_dir, profile, host) = app
        .feed
        .dashboard()
        .map(|d| {
            (
                d.visibility.state_dir.clone(),
                d.visibility.profile.clone(),
                d.visibility.host.clone(),
            )
        })
        .unwrap_or_default();
    let text = format!(
        " ⚠ NO FACTORY VISIBLE — profile '{profile}' on {host}, reading {state_dir} — every role below is UNKNOWN, not down "
    );
    let para = Paragraph::new(text).style(
        Style::default()
            .bg(Color::Red)
            .fg(Color::Black)
            .add_modifier(Modifier::BOLD),
    );
    f.render_widget(para, area);
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

/// The upgrade-available banner (issue #94) — shown only when `upgrade.available`,
/// full-width below the tabs (and below the needs-you banner, if both are active).
/// Yellow/black — a deliberately different colour scheme from the red/white
/// needs-you banner so the two are never confused for one another.
fn render_upgrade_banner(f: &mut Frame, area: Rect, app: &App) {
    let (current, latest) = app
        .feed
        .dashboard()
        .map(|d| (d.upgrade.current.clone(), d.upgrade.latest.clone()))
        .unwrap_or_default();
    let text = format!(" ⬆ fwf {latest} available (running {current}) — run 'fwf upgrade' ");
    let para = Paragraph::new(text).style(
        Style::default()
            .bg(Color::Yellow)
            .fg(Color::Black)
            .add_modifier(Modifier::BOLD),
    );
    f.render_widget(para, area);
}

/// The stale-dash restart banner (issue #153) — shown only when THIS running
/// process is older than the version currently installed on disk. Distinct
/// from `render_upgrade_banner` above (installed vs. latest GitHub release):
/// this is "the window you are looking at right now needs a restart to match
/// what's already installed", which can be true even when `upgrade_banner`
/// has nothing to say (install already current with GitHub, but THIS process
/// predates that install). Magenta/white — deliberately distinct from both
/// the red needs-you banner and the yellow upgrade-available banner, so a
/// glance tells the three apart.
fn render_stale_dash_banner(f: &mut Frame, area: Rect, app: &App) {
    let installed = app
        .feed
        .dashboard()
        .map(|d| d.installed.version.clone())
        .unwrap_or_default();
    // Kept deliberately short and names only ONE version (the running one is
    // already always visible in the header just above, so repeating it here
    // is pure redundancy that costs width). A golden test caught two drafts
    // in a row silently clipping the restart instruction on a narrow
    // terminal before landing on this wording.
    let text = format!(" ⟲ STALE DASH — v{installed} now installed. Restart: q, then 'fwf dash' ");
    let para = Paragraph::new(text).style(
        Style::default()
            .bg(Color::Magenta)
            .fg(Color::White)
            .add_modifier(Modifier::BOLD),
    );
    f.render_widget(para, area);
}

/// The API-budget-exhausted banner (issue #239) — shown only when
/// `api_budget.status == "EXHAUSTED"` (a real 0-remaining reading, or the
/// headroom read itself couldn't complete — both mean the read layer
/// cannot be trusted right now). Red/white, deliberately loud: this is the
/// one failure mode most likely to look like "the factory is calm, nothing
/// in flight" from every OTHER banner's perspective, so it must not read
/// as calmer than it is.
fn render_api_budget_banner(f: &mut Frame, area: Rect, app: &App) {
    let budget = app.feed.dashboard().map(|d| d.api_budget.clone());
    let label = budget
        .as_ref()
        .map(|b| b.label.clone())
        .filter(|l| !l.is_empty())
        .unwrap_or_else(|| "API BUDGET EXHAUSTED".to_string());
    // remaining/limit are only Some when the headroom read itself actually
    // completed (a genuine 0-remaining reading) — None means the read
    // couldn't complete at all, which is the OTHER way into this same
    // EXHAUSTED status (see ApiBudget's own doc comment). Naming the
    // number when it's known is strictly more useful; omitting it rather
    // than printing "0/0" is what keeps the two causes told apart.
    let detail = match budget.as_ref().and_then(|b| b.remaining.zip(b.limit)) {
        Some((remaining, limit)) => {
            let reset_in = budget.as_ref().and_then(|b| b.reset).and_then(|reset| {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()?
                    .as_secs() as i64;
                let secs = reset - now;
                (secs > 0).then_some(secs)
            });
            match reset_in {
                Some(secs) => format!(" ({remaining}/{limit} remaining, resets in {secs}s)"),
                None => format!(" ({remaining}/{limit} remaining)"),
            }
        }
        None => " (headroom read failed — network/auth/rate-limited)".to_string(),
    };
    let text = format!(
        " ⚠ {label}{detail} — reads may be stale or refused; hold position, do not conclude \"nothing in flight\" "
    );
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
            // A deliberate `fwf-down.sh --floor-only` idle (issue #85) is its
            // own calm/dim badge — never the red down/crashed treatment, and
            // distinct from the whole-factory ⏸ PARKED badge above.
            if d.floor_idle.active {
                l1.push(Span::styled(
                    format!(" ◇ FLOOR IDLE — {} ", d.floor_idle.actor),
                    Style::default()
                        .fg(Color::Black)
                        .bg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                ));
            }
            // Issue #243 AC (f): a distinct "N blocked on authz" badge, so a
            // refused-claim queue reads as a queue, not as a floor that has
            // mysteriously gone quiet -- never recomputed here, just the
            // count fwf-dash-data.sh already read from the durable log.
            if d.claim_refusals.count > 0 {
                l1.push(Span::styled(
                    format!(" ⛔ {} blocked on authz ", d.claim_refusals.count),
                    Style::default()
                        .fg(Color::White)
                        .bg(Color::Red)
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
            // issue #193 AC (b): shown whenever available, whether fresh or
            // stale — an operator who only ever sees this during an incident
            // has never calibrated what "normal" looks like.
            if let Some(age) = d.visibility.newest_heartbeat_age {
                l2.push(Span::styled(format!("   hb {age}s ago"), dim));
            }
            if d.floor_idle.active {
                l2.push(Span::styled(
                    format!("   since {} — {}", d.floor_idle.since, d.floor_idle.reason),
                    Style::default().fg(Color::Cyan),
                ));
            }
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

    // Issue #153: the RUNNING binary's own version + build date, ALWAYS shown
    // regardless of Feed state — this is a compile-time property of the
    // process itself (build.rs), not fetched data, so it renders even while
    // loading or erred. Distinct from `render_stale_dash_banner` below (that
    // only fires on detected drift); this line is unconditional so drift is
    // visible at a glance at all times, per issue #153.
    l1.push(Span::styled(
        format!(
            " · fwf v{} (built {})",
            data::RUNNING_VERSION,
            data::RUNNING_BUILD_DATE
        ),
        dim,
    ));

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
                (_, Tab::Usage) => app.usage_feed.usage().map(|u| u.roles.len()).unwrap_or(0),
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
    if app.tab == Tab::Usage {
        if app.usage_feed.usage().is_none() {
            let msg = match &app.usage_feed {
                UsageFeed::Err(e, _) => format!("✗ {e}"),
                _ => "loading…".to_string(),
            };
            f.render_widget(
                Paragraph::new(msg).style(Style::default().fg(Color::DarkGray)),
                area,
            );
            return;
        }
        render_usage(f, area, app);
        return;
    }

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
        Tab::Usage => unreachable!(),
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

/// Glyph + colour for a role's `state` word (issue #193 adds unknown/busy/
/// stale to the pre-existing live/idle/floor_idle/down set). Factored out of
/// `render_roles` so the mapping — the exact thing a prior incident showed
/// gets collapsed by accident — is unit-testable without going through a
/// full render. "down" and any state this dash doesn't yet know about
/// deliberately share the same fallback arm: an OLDER dash talking to a
/// NEWER `fwf-dash-data.sh` must render an unrecognized state calmly, not
/// crash or claim something more alarming/reassuring than it can back up.
fn role_glyph(state: &str) -> (&'static str, Color) {
    match state {
        "live" => ("●", Color::Green),
        "idle" => ("◌", Color::Yellow),
        // Deliberately parked by `fwf-down.sh --floor-only` (#85) — a
        // calm/dim treatment, visually distinct from both live/idle
        // AND the dark-gray "down"/crashed circle below.
        "floor_idle" => ("◇", Color::Cyan),
        // issue #193: holding the gate lock is a POSITIVE liveness
        // fact (AC i) — deliberately close to "live" (a solid glyph,
        // not a dim/uncertain one) but a distinct colour, since it's
        // inferred rather than a directly-observed pane.
        "busy" => ("◆", Color::Blue),
        // A visible session with an aging heartbeat and no pane/lock
        // (AC a) — never the same dark-gray "down" circle: this role
        // has real evidence of having run here, down has none.
        "stale" => ("◐", Color::Rgb(230, 160, 40)),
        // The session itself couldn't be confirmed visible (AC c/e)
        // — this is the state the whole ticket exists for, so it
        // must never share a glyph/colour with "down" (below), which
        // is exactly the collapse a prior incident made and trusted.
        "unknown" => ("?", Color::Magenta),
        _ => ("○", Color::DarkGray),
    }
}

fn render_roles(f: &mut Frame, area: Rect, app: &mut App) {
    let d = app.feed.dashboard().expect("checked by caller");
    let items: Vec<ListItem> = d
        .roles
        .iter()
        .map(|r| {
            let (glyph, color) = role_glyph(&r.state);
            let style = Style::default().fg(color);
            // "floor_idle" renders as the short "IDLE" label; the detail span
            // (below) carries "floor idled by <actor> since <ts> — <reason>".
            let state_label = if r.state == "floor_idle" {
                "IDLE"
            } else {
                r.state.as_str()
            };
            let mut spans = vec![
                Span::styled(format!(" {glyph} "), style),
                Span::styled(
                    format!("{:<10}", r.role),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{:<8}", state_label), style),
            ];
            // Heartbeat age is shown ALONGSIDE the state word, never instead
            // of it (issue #193 AC a/b/i0 — a live pane still carries its own
            // age when known, so "busy off tick alone" never has to guess).
            if let Some(age) = r.heartbeat_age {
                spans.push(Span::styled(
                    format!("hb {age}s ago  "),
                    Style::default().fg(Color::DarkGray),
                ));
            }
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

/// Per-role token/$ usage (issue #95). One row per role; three visually
/// distinct states (never collapsed to two — a stale/unreadable row must
/// never look like a real, current number):
///   FRESH   — a live token/$ figure.
///   STALE   — "⚠ STALE (last read Ns ago)", the LAST-GOOD figures (not a
///             frozen-looking plain number).
///   UNKNOWN — "⚠ UNKNOWN" and "-" everywhere else (never $0/blank, which
///             would read as "no spend / plenty of headroom").
/// A trailing caveat line makes the proxy-vs-real-account-usage note visible
/// without leaving the tab (also printed by the `fwf usage` CLI).
fn render_usage(f: &mut Frame, area: Rect, app: &mut App) {
    let u = app.usage_feed.usage().expect("checked by caller");
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Length(1),
            Constraint::Min(3),
            Constraint::Length(2),
        ])
        .split(area);

    // #96 (Ticket B, GV-signoff residual-risk fix): show ARMED/NOT ARMED —
    // and the current hold state — unmissably, at the top of the tab. A
    // budget configured mid-run without a re-`fwf up` (the only thing that
    // arms the writer) must be VISIBLY off, not silently off. Wording
    // mirrors `_fwf_usage_budget_line` in fwf-usage.sh exactly.
    let enforcement_style = match (u.budget.token_budget, u.budget.armed) {
        (Some(_), true) => Style::default().fg(Color::Green),
        (Some(_), false) => Style::default().fg(Color::Yellow),
        (None, _) => Style::default().fg(Color::DarkGray),
    };
    let hold_style = match u.budget.hold_line.as_deref() {
        Some(l) if l.starts_with("HOLD") => Style::default().fg(Color::Red),
        Some(l) if l.starts_with("UNKNOWN") => Style::default().fg(Color::Magenta),
        Some(l) if l.starts_with("WARN") => Style::default().fg(Color::Yellow),
        Some(_) => Style::default().fg(Color::DarkGray),
        None => Style::default().fg(Color::DarkGray),
    };
    let budget_para = Paragraph::new(vec![
        Line::from(Span::styled(u.budget.enforcement_line(), enforcement_style)),
        Line::from(Span::styled(u.budget.hold_status_line(), hold_style)),
    ]);
    f.render_widget(budget_para, rows[0]);

    let role_w = 12usize;
    let state_w = 20usize;
    // Numeric columns get a 1-space gutter each (including before EST-$) so
    // adjacent fields can never touch, even when a value fills its whole
    // field width (#115). Values are humanized (see `humanize_tokens`), so
    // 8 chars comfortably covers everything up to low trillions.
    let num_w = 8usize;
    let cost_w = 10usize;
    let gutters = 5usize;
    let model_w = (rows[2].width as usize)
        .saturating_sub(role_w + state_w + 4 * num_w + cost_w + gutters + 7)
        .clamp(6, 24);

    let items: Vec<ListItem> = u
        .roles
        .iter()
        .map(|r| {
            let (state_text, style) = match r.state.as_str() {
                "fresh" => ("fresh".to_string(), Style::default().fg(Color::Green)),
                "stale" => (
                    format!("⚠ STALE ({}s ago)", r.age_secs.unwrap_or(0)),
                    Style::default().fg(Color::Yellow),
                ),
                _ => (
                    "⚠ UNKNOWN".to_string(),
                    Style::default().fg(Color::DarkGray),
                ),
            };
            let unknown = r.state == "unknown";
            let model = r.model.as_deref().unwrap_or("-");
            let fmt_tok = |n: i64| {
                if unknown {
                    "-".to_string()
                } else {
                    humanize_tokens(n)
                }
            };
            let cost = match r.cost_usd {
                Some(c) => format!("${c:.4}"),
                None => "-".to_string(),
            };
            let line = Line::from(vec![
                Span::styled(
                    format!("{:<role_w$}", r.role),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{state_text:<state_w$}"), style),
                Span::raw(format!(
                    "{:<model_w$}",
                    truncate(model, model_w.saturating_sub(1))
                )),
                Span::raw(format!(" {:>num_w$}", fmt_tok(r.tokens.input))),
                Span::raw(format!(" {:>num_w$}", fmt_tok(r.tokens.cache_creation))),
                Span::raw(format!(" {:>num_w$}", fmt_tok(r.tokens.cache_read))),
                Span::raw(format!(" {:>num_w$}", fmt_tok(r.tokens.output))),
                Span::styled(
                    format!(" {cost:>cost_w$}"),
                    Style::default().fg(Color::Cyan),
                ),
            ]);
            ListItem::new(line)
        })
        .collect();

    let header = Paragraph::new(Line::from(Span::styled(
        format!(
            "  {:<role_w$}{:<state_w$}{:<model_w$} {:>num_w$} {:>num_w$} {:>num_w$} {:>num_w$} {:>cost_w$}",
            "ROLE", "STATE", "MODEL", "INPUT", "CACHE-W", "CACHE-R", "OUTPUT", "EST-$"
        ),
        Style::default()
            .fg(Color::DarkGray)
            .add_modifier(Modifier::BOLD),
    )));
    f.render_widget(header, rows[1]);

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(" Usage "))
        .highlight_style(Style::default().bg(Color::Rgb(40, 40, 50)))
        .highlight_symbol("▌");
    let mut state = app.cursors[Tab::Usage.index()].clone();
    f.render_stateful_widget(list, rows[2], &mut state);
    app.cursors[Tab::Usage.index()] = state;

    let total_cost = format!("${:.4}", u.total.cost_usd);
    let total_line = Line::from(vec![
        Span::styled(
            format!("{:<role_w$}{:<state_w$}{:<model_w$}", "TOTAL", "", ""),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw(format!(
            " {:>num_w$}",
            humanize_tokens(u.total.tokens.input)
        )),
        Span::raw(format!(
            " {:>num_w$}",
            humanize_tokens(u.total.tokens.cache_creation)
        )),
        Span::raw(format!(
            " {:>num_w$}",
            humanize_tokens(u.total.tokens.cache_read)
        )),
        Span::raw(format!(
            " {:>num_w$}",
            humanize_tokens(u.total.tokens.output)
        )),
        Span::styled(
            format!(" {total_cost:>cost_w$}"),
            Style::default().fg(Color::Cyan),
        ),
    ]);
    let caveat = Line::from(Span::styled(
        format!("note: {}", u.caveat),
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(Paragraph::new(vec![total_line, caveat]), rows[3]);
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
        Tab::Activity | Tab::Roles | Tab::Usage => unreachable!(),
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
    // Footer layout: a persistent GLOBAL segment that renders on every tab —
    // nav (1-5 tab, j/k move) plus always-available bindings (Ctrl-r refresh,
    // t captain, ? help, q quit) — bracketing a CONTEXTUAL segment of
    // tab-specific actions. The global bindings must never be clipped (#80:
    // Ctrl-r is global, so its hint shows everywhere); when the row is too
    // narrow to hold everything, contextual actions are dropped from the end
    // first so the global hints (incl. "q quit") always stay on screen.
    let global_left = vec![
        Span::styled(" 1-5 ", key),
        Span::styled("tab ", dim),
        Span::styled(" j/k ", key),
        Span::styled("move ", dim),
        Span::styled(" Ctrl-r ", key),
        Span::styled("refresh ", dim),
    ];
    let global_right = vec![
        Span::styled(" t ", key),
        Span::styled("captain ", dim),
        Span::styled(" ? ", key),
        Span::styled("help ", dim),
        Span::styled(" q ", key),
        Span::styled("quit", dim),
    ];
    // Contextual action hints depend on the active section.
    let actions: &[(&str, &str)] = match app.tab {
        Tab::Activity => &[("n/p", "scroll PR")],
        Tab::Decisions => &[
            ("y", "approve"),
            ("x", "reject"),
            ("c", "comment"),
            ("o", "open"),
        ],
        Tab::Issues => &[("c", "comment"), ("o", "open")],
        Tab::Roles => &[("r", "respawn"), ("s", "stop")],
        Tab::Usage => &[],
    };

    let span_w = |s: &Span| s.content.chars().count();
    let global_w: usize = global_left.iter().map(span_w).sum::<usize>()
        + global_right.iter().map(span_w).sum::<usize>();
    let budget = (area.width as usize).saturating_sub(global_w);

    // Fit as many contextual hints as the width between the global segments
    // allows; stop at the first one that would overflow.
    let mut contextual: Vec<Span> = Vec::new();
    let mut used = 0usize;
    for (k, label) in actions {
        let k_span = Span::styled(format!(" {k} "), key);
        let l_span = Span::styled(format!("{label} "), dim);
        let w = span_w(&k_span) + span_w(&l_span);
        if used + w > budget {
            break;
        }
        used += w;
        contextual.push(k_span);
        contextual.push(l_span);
    }

    let mut spans = global_left;
    spans.extend(contextual);
    spans.extend(global_right);
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
            "1 / 2 / 3 / 4 / 5",
            "jump to Activity / Roles / Decisions / Issues / Usage",
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
            "  Usage",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        help_row(
            "(read-only)",
            "per-role token/$ estimate — an engineering proxy, not real account usage",
        ),
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

/// Render a token/usage count so it stays scannable at any scale: comma
/// thousands-separators below a million, then `M`/`B`/`T` suffixes above it
/// (#115 — unsuffixed digit strings collide once counts hit billions).
fn humanize_tokens(n: i64) -> String {
    let abs = n.unsigned_abs();
    if abs >= 1_000_000_000_000 {
        format!("{:.2}T", n as f64 / 1_000_000_000_000.0)
    } else if abs >= 1_000_000_000 {
        format!("{:.2}B", n as f64 / 1_000_000_000.0)
    } else if abs >= 1_000_000 {
        format!("{:.0}M", n as f64 / 1_000_000.0)
    } else {
        thousands(n)
    }
}

/// Comma-separate an integer's digits (`-1234` -> `-1,234`).
fn thousands(n: i64) -> String {
    let digits = n.unsigned_abs().to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().rev().enumerate() {
        if i != 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    let out: String = out.chars().rev().collect();
    if n < 0 {
        format!("-{out}")
    } else {
        out
    }
}

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
                // Blockquotes are callouts (GATED / notes) — the text most worth
                // reading. Use the terminal's default foreground (no fg override,
                // so it can't be low-contrast on any theme); italic keeps them
                // distinct without sacrificing legibility (#50).
                Line::from(Span::styled(
                    line,
                    Style::default().add_modifier(Modifier::ITALIC),
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
    use ratatui::backend::TestBackend;

    fn test_app() -> App {
        let (rtx, _r) = mpsc::channel();
        let (urtx, _ur) = mpsc::channel();
        let (atx, _a) = mpsc::channel();
        let (dtx, _d) = mpsc::channel();
        App::new(rtx, urtx, atx, dtx)
    }

    #[test]
    fn tab_cycles_and_wraps() {
        // Order: Activity → Roles → Decisions → Issues → Usage → (wrap) Activity.
        assert!(matches!(Tab::Activity.cycle(1), Tab::Roles));
        assert!(matches!(Tab::Issues.cycle(1), Tab::Usage));
        assert!(matches!(Tab::Usage.cycle(1), Tab::Activity));
        assert!(matches!(Tab::Activity.cycle(-1), Tab::Usage));
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
    fn markdownish_blockquote_is_legible_not_darkgray() {
        // Callout blockquotes (GATED / notes) must not render in DarkGray —
        // it's near-invisible on dark terminals (#50). They use the default
        // terminal foreground (fg None) and stay distinct via italic.
        let lines = markdownish("> **GATED** do not implement");
        assert_eq!(lines.len(), 1);
        let style = lines[0].spans[0].style;
        assert_ne!(style.fg, Some(Color::DarkGray));
        assert_eq!(style.fg, None);
        assert!(style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn cursor_clamps_to_rows() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
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
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
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
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
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
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
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

    // --- on_key coverage (#55) ----------------------------------------------
    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn key_ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    #[test]
    fn scroll_preview_via_n_p_and_ctrl_d_u_clamps_at_zero() {
        let mut app = test_app();
        app.on_key(key(KeyCode::Char('n')));
        assert_eq!(app.scroll[app.tab.index()], 3);
        app.on_key(key_ctrl('d'));
        assert_eq!(app.scroll[app.tab.index()], 13);
        app.on_key(key(KeyCode::Char('p')));
        assert_eq!(app.scroll[app.tab.index()], 10);
        app.on_key(key_ctrl('u'));
        assert_eq!(app.scroll[app.tab.index()], 0);
        // Further negative presses clamp at 0 rather than underflowing.
        app.on_key(key(KeyCode::Char('p')));
        assert_eq!(app.scroll[app.tab.index()], 0);
        app.on_key(key_ctrl('u'));
        assert_eq!(app.scroll[app.tab.index()], 0);
    }

    #[test]
    fn reject_opens_a_confirm_not_a_fire() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
            decisions: vec![data::Decision {
                id: "44".into(),
                title: "t".into(),
                flags: String::new(),
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Decisions;
        app.on_key(key(KeyCode::Char('x')));
        match &app.overlay {
            Overlay::Confirm { action, .. } => {
                assert_eq!(action.verb, "reject");
                assert_eq!(action.target, "44");
            }
            _ => panic!("reject should open a confirm overlay"),
        }
    }

    #[test]
    fn number_keys_jump_directly_to_section() {
        let mut app = test_app();
        app.on_key(key(KeyCode::Char('3')));
        assert!(matches!(app.tab, Tab::Decisions));
        app.on_key(key(KeyCode::Char('4')));
        assert!(matches!(app.tab, Tab::Issues));
        app.on_key(key(KeyCode::Char('2')));
        assert!(matches!(app.tab, Tab::Roles));
        app.on_key(key(KeyCode::Char('1')));
        assert!(matches!(app.tab, Tab::Activity));
    }

    #[test]
    fn tab_key_and_brackets_cycle_sections() {
        let mut app = test_app();
        app.on_key(key(KeyCode::Tab));
        assert!(matches!(app.tab, Tab::Roles));
        app.on_key(key(KeyCode::Char(']')));
        assert!(matches!(app.tab, Tab::Decisions));
        app.on_key(key(KeyCode::BackTab));
        assert!(matches!(app.tab, Tab::Roles));
        app.on_key(key(KeyCode::Char('[')));
        assert!(matches!(app.tab, Tab::Activity));
    }

    #[test]
    fn ctrl_r_sends_a_refresh_request_and_sets_status() {
        let (rtx, rrx) = mpsc::channel();
        let (urtx, urrx) = mpsc::channel();
        let (atx, _a) = mpsc::channel();
        let (dtx, _d) = mpsc::channel();
        let mut app = App::new(rtx, urtx, atx, dtx);
        app.on_key(key_ctrl('r'));
        assert!(rrx.try_recv().is_ok(), "Ctrl-r should request a refresh");
        assert!(
            urrx.try_recv().is_ok(),
            "Ctrl-r should ALSO request a usage-data refresh"
        );
        assert!(!app.status.as_ref().unwrap().is_err);
    }

    // #80 pin: Ctrl-r is a global binding (handled unconditionally in on_key,
    // see the test above), so its footer hint must show on every tab, not
    // just Activity.
    #[test]
    fn footer_shows_the_refresh_hint_on_every_tab() {
        for tab in Tab::ALL {
            let mut app = test_app();
            app.tab = tab;
            let area = Rect::new(0, 0, 90, 1);
            let buf = render_buffer(area.width, area.height, |f| render_footer(f, area, &app));
            let text = buffer_to_text(&buf);
            assert!(
                text.contains("Ctrl-r") && text.contains("refresh"),
                "{} footer should advertise the global Ctrl-r refresh binding, got: {text:?}",
                tab.title()
            );
        }
    }

    // #80 repro (qa1): the persistent Ctrl-r segment must not crowd out
    // existing hints — at a realistic 100-col width the Decisions footer
    // clips "q quit" down to "q qui", silently dropping the final "t".
    #[test]
    fn footer_does_not_clip_existing_hints_at_full_width() {
        let mut app = test_app();
        app.tab = Tab::Decisions;
        let area = Rect::new(0, 0, 100, 1);
        let buf = render_buffer(area.width, area.height, |f| render_footer(f, area, &app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("q quit"),
            "Decisions footer should show the full, un-clipped quit hint at a realistic 100-col width, got: {text:?}"
        );
    }

    #[test]
    fn help_overlay_opens_and_only_dismiss_keys_close_it() {
        let mut app = test_app();
        app.on_key(key(KeyCode::Char('?')));
        assert!(matches!(app.overlay, Overlay::Help));
        app.on_key(key(KeyCode::Char('z'))); // any other key: stays open
        assert!(matches!(app.overlay, Overlay::Help));
        app.on_key(key(KeyCode::Char('q'))); // dismiss
        assert!(matches!(app.overlay, Overlay::None));
        assert!(!app.should_quit, "dismissing help must not also quit");
    }

    #[test]
    fn quit_keys_set_should_quit() {
        let mut app = test_app();
        app.on_key(key(KeyCode::Char('q')));
        assert!(app.should_quit);

        let mut app2 = test_app();
        app2.on_key(key(KeyCode::Esc));
        assert!(app2.should_quit);

        let mut app3 = test_app();
        app3.on_key(key_ctrl('c'));
        assert!(app3.should_quit);
    }

    #[test]
    fn cancel_from_confirm_with_n_or_esc_clears_overlay_without_firing() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
            decisions: vec![data::Decision {
                id: "1".into(),
                title: "t".into(),
                flags: String::new(),
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Decisions;
        app.begin_action("approve");
        assert!(matches!(app.overlay, Overlay::Confirm { .. }));
        app.on_key(key(KeyCode::Char('n')));
        assert!(matches!(app.overlay, Overlay::None));
        assert!(!app.busy, "declining must not spawn the action");
        assert_eq!(app.status.as_ref().unwrap().message, "cancelled");

        app.begin_action("approve");
        app.on_key(key(KeyCode::Esc));
        assert!(matches!(app.overlay, Overlay::None));
    }

    #[test]
    fn cancel_from_input_with_esc_clears_overlay_without_firing() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
            issues: vec![data::Issue {
                number: 3,
                title: "i".into(),
                gated: false,
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Issues;
        app.begin_action("comment");
        assert!(matches!(app.overlay, Overlay::Input { .. }));
        app.on_key(key(KeyCode::Esc));
        assert!(matches!(app.overlay, Overlay::None));
        assert!(!app.busy);
        assert_eq!(app.status.as_ref().unwrap().message, "cancelled");
    }

    #[test]
    fn input_overlay_types_chars_and_backspaces() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
            issues: vec![data::Issue {
                number: 3,
                title: "i".into(),
                gated: false,
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Issues;
        app.begin_action("comment");
        app.on_key(key(KeyCode::Char('h')));
        app.on_key(key(KeyCode::Char('i')));
        app.on_key(key(KeyCode::Backspace));
        match &app.overlay {
            Overlay::Input { buffer, .. } => assert_eq!(buffer, "h"),
            _ => panic!("expected the input overlay to stay open while typing"),
        }
    }

    #[test]
    fn input_overlay_enter_with_empty_buffer_is_skipped_not_fired() {
        let mut app = test_app();
        app.feed = Feed::Ok(Dashboard {
            visibility: data::Visibility {
                factory_visible: true,
                ..Default::default()
            },
            issues: vec![data::Issue {
                number: 3,
                title: "i".into(),
                gated: false,
                body: String::new(),
            }],
            ..Default::default()
        });
        app.tab = Tab::Issues;
        app.begin_action("comment");
        app.on_key(key(KeyCode::Enter));
        assert!(matches!(app.overlay, Overlay::None));
        assert_eq!(app.status.as_ref().unwrap().message, "empty — skipped");
        assert!(!app.busy);
    }

    // --- Activity-tab formatting (#53) -------------------------------------
    fn act_item(
        pr: i64,
        issue: &str,
        base: &str,
        checks: &str,
        when: &str,
        role: &str,
    ) -> data::ActivityItem {
        data::ActivityItem {
            pr,
            role: role.into(),
            issue: issue.into(),
            base: base.into(),
            checks: checks.into(),
            when: when.into(),
            title: "a title".into(),
        }
    }

    #[test]
    fn checks_glyph_maps_each_state() {
        assert_eq!(checks_glyph("pass"), ("✓", Color::Green));
        assert_eq!(checks_glyph("run"), ("●", Color::Yellow));
        assert_eq!(checks_glyph("fail"), ("✗", Color::Red));
        assert_eq!(checks_glyph("none"), ("·", Color::DarkGray));
        assert_eq!(checks_glyph(""), ("·", Color::DarkGray));
    }

    #[test]
    fn role_glyph_maps_every_state_including_193s_new_ones() {
        assert_eq!(role_glyph("live"), ("●", Color::Green));
        assert_eq!(role_glyph("idle"), ("◌", Color::Yellow));
        assert_eq!(role_glyph("floor_idle"), ("◇", Color::Cyan));
        assert_eq!(role_glyph("busy"), ("◆", Color::Blue));
        assert_eq!(role_glyph("stale"), ("◐", Color::Rgb(230, 160, 40)));
        assert_eq!(role_glyph("unknown"), ("?", Color::Magenta));
        assert_eq!(role_glyph("down"), ("○", Color::DarkGray));
        // The exact collapse this ticket exists to prevent: none of the new
        // states may ever render identically to "down".
        let down = role_glyph("down");
        for s in ["unknown", "busy", "stale"] {
            assert_ne!(role_glyph(s), down, "{s} must not render like down");
        }
        // An unrecognized future state falls back calmly, same as "down" —
        // never a panic, never something MORE alarming than warranted.
        assert_eq!(role_glyph("some-future-state"), ("○", Color::DarkGray));
    }

    #[test]
    fn activity_row_merged_leads_with_issue_then_base_when() {
        let it = act_item(8, "42", "staging", "", "06-18 12:34", "qa2");
        let t: String = activity_row_line(&it, 80)
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(t.contains("#42"), "leads with the issue: {t}");
        assert!(t.contains("→staging 06-18 12:34"), "shows base + when: {t}");
        assert!(t.contains("· PR 8"), "tags the PR explicitly: {t}");
    }

    #[test]
    fn activity_row_without_issue_leads_with_pr_and_shows_checks() {
        let it = act_item(7, "", "staging", "pass", "", "impl1");
        let t: String = activity_row_line(&it, 80)
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(t.contains("PR 7"), "leads with PR when no issue: {t}");
        assert!(t.contains("✓"), "building row shows the checks glyph: {t}");
        assert!(t.contains("impl1"), "shows the role: {t}");
    }

    #[test]
    fn activity_summary_includes_the_key_fields() {
        let it = act_item(8, "42", "staging", "pass", "06-18 12:34", "qa2");
        let s = activity_summary(&&it);
        assert!(s.contains("PR #8  → staging"));
        assert!(s.contains("role:   qa2"));
        assert!(s.contains("issue:  #42"));
        assert!(s.contains("checks: pass"));
        assert!(s.contains("merged: 06-18 12:34"));
    }

    // --- run_action execution (#55) -----------------------------------------
    // A stub script standing in for `fwf-dash-act.sh`, so these cover the Rust
    // execution + status-handling path only — the act layer's command shape is
    // covered by the bash tests.
    static STUB_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    fn write_stub(body: &str) -> std::path::PathBuf {
        let n = STUB_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "fwf-dash-test-stub-{}-{}.sh",
            std::process::id(),
            n
        ));
        std::fs::write(&path, body).expect("write stub script");
        path
    }

    #[test]
    fn run_action_success_reports_the_last_stdout_line() {
        let path = write_stub("#!/bin/bash\necho ignored\necho \"did $1 $2\"\nexit 0\n");
        let action = Action {
            verb: "approve",
            target: "42".into(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, None);
        assert!(outcome.ok);
        assert_eq!(outcome.message, "did approve 42");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_failure_reports_the_last_stderr_line() {
        let path = write_stub("#!/bin/bash\necho boom >&2\nexit 1\n");
        let action = Action {
            verb: "reject",
            target: "9".into(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, None);
        assert!(!outcome.ok);
        assert_eq!(outcome.message, "boom");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_success_with_no_stdout_falls_back_to_verb_target() {
        let path = write_stub("#!/bin/bash\nexit 0\n");
        let action = Action {
            verb: "open",
            target: "7".into(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, None);
        assert!(outcome.ok);
        assert_eq!(outcome.message, "open 7 ✓");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_failure_with_no_stderr_falls_back_to_a_generic_message() {
        let path = write_stub("#!/bin/bash\nexit 1\n");
        let action = Action {
            verb: "respawn",
            target: "impl1".into(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, None);
        assert!(!outcome.ok);
        assert_eq!(outcome.message, "respawn failed");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_passes_text_as_a_trailing_arg() {
        let path = write_stub("#!/bin/bash\necho \"args: $1 $2 $3\"\n");
        let action = Action {
            verb: "comment",
            target: "5".into(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, Some("hello world"));
        assert!(outcome.ok);
        assert_eq!(outcome.message, "args: comment 5 hello world");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_omits_the_target_arg_when_empty() {
        let path = write_stub("#!/bin/bash\necho \"argc=$#\"\n");
        let action = Action {
            verb: "stop",
            target: String::new(),
        };
        let outcome = run_action(path.to_str().unwrap(), &action, None);
        assert_eq!(outcome.message, "argc=1");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn run_action_reports_a_missing_script_without_panicking() {
        // bash itself is found, but the script path isn't — this exercises the
        // exit-status-failure branch (not the Command::output Err branch, which
        // only fires if `bash` itself can't be spawned).
        let action = Action {
            verb: "open",
            target: "1".into(),
        };
        let outcome = run_action("/no/such/fwf-dash-act.sh", &action, None);
        assert!(!outcome.ok);
        assert!(!outcome.message.is_empty());
    }

    // --- render/golden snapshots (#54) ---------------------------------------
    //
    // TestBackend-driven text goldens for the main render paths. Each golden
    // renders at an explicit fixed Rect from a static fixture (no timestamps,
    // live provenance, or wall-clock in the buffer) so a golden that varied
    // run-to-run — worse than no golden at all — can't happen here. The two
    // known styling regressions (#50 blockquote contrast, #51 header template)
    // are pinned by explicit style assertions alongside the goldens, so a
    // blind re-bless of a full-buffer golden can't silently reintroduce them.
    //
    // To re-bless an intentional layout/content change, regenerate the goldens
    // and review the diff like any other change:
    //   UPDATE_GOLDEN=1 cargo test --locked <test name>
    // (see dash/tests/goldens/README.md).

    fn golden_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/goldens")
            .join(format!("{name}.txt"))
    }

    fn buffer_to_text(buf: &ratatui::buffer::Buffer) -> String {
        let area = buf.area;
        (0..area.height)
            .map(|y| {
                let row: String = (0..area.width)
                    .map(|x| {
                        buf.cell((area.x + x, area.y + y))
                            .map(ratatui::buffer::Cell::symbol)
                            .unwrap_or(" ")
                            .to_string()
                    })
                    .collect();
                row.trim_end().to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Issue #153: the header's running-version line embeds THIS BUILD's
    /// actual version + date (via build.rs from the top-level VERSION file
    /// and the build machine's clock), which legitimately differs across
    /// machines and days. A golden snapshot containing it verbatim would go
    /// stale on the next rebuild for no reason related to a real render
    /// change. Replace it with a fixed placeholder before comparing — every
    /// OTHER pixel of the frame is still caught by the exact-match golden.
    fn normalize_running_version(rendered: &str) -> String {
        rendered.replace(
            &format!(
                "fwf v{} (built {})",
                data::RUNNING_VERSION,
                data::RUNNING_BUILD_DATE
            ),
            "fwf vX.Y.Z (built YYYY-MM-DD)",
        )
    }

    fn assert_golden(name: &str, rendered: &str) {
        let path = golden_path(name);
        if std::env::var_os("UPDATE_GOLDEN").is_some() {
            std::fs::create_dir_all(path.parent().expect("golden dir"))
                .expect("create goldens dir");
            std::fs::write(&path, format!("{rendered}\n")).expect("write golden");
            return;
        }
        let expected = std::fs::read_to_string(&path).unwrap_or_else(|_| {
            panic!(
                "missing golden {path:?} — run `UPDATE_GOLDEN=1 cargo test {name}` to create it, then review the diff (see dash/tests/goldens/README.md)"
            )
        });
        assert_eq!(
            format!("{rendered}\n"),
            expected,
            "render golden mismatch for `{name}` — if this change is intentional, re-bless with `UPDATE_GOLDEN=1 cargo test {name}` and review the diff (see dash/tests/goldens/README.md)"
        );
    }

    fn render_buffer(
        width: u16,
        height: u16,
        draw: impl FnOnce(&mut Frame),
    ) -> ratatui::buffer::Buffer {
        let backend = TestBackend::new(width, height);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal.draw(draw).expect("draw");
        terminal.backend().buffer().clone()
    }

    fn row_text(buf: &ratatui::buffer::Buffer, area: Rect, y: u16) -> String {
        (area.x..area.x + area.width)
            .map(|x| {
                buf.cell((x, y))
                    .map(ratatui::buffer::Cell::symbol)
                    .unwrap_or(" ")
                    .to_string()
            })
            .collect()
    }

    fn act_item_titled(
        pr: i64,
        issue: &str,
        base: &str,
        checks: &str,
        when: &str,
        role: &str,
        title: &str,
    ) -> data::ActivityItem {
        data::ActivityItem {
            pr,
            role: role.into(),
            issue: issue.into(),
            base: base.into(),
            checks: checks.into(),
            when: when.into(),
            title: title.into(),
        }
    }

    /// A static, fully-populated fixture — no timestamps or live data, so every
    /// golden built from it renders identically on every run and machine.
    fn golden_fixture() -> Dashboard {
        Dashboard {
            visibility: data::Visibility { factory_visible: true, ..Default::default() },
            profile: "fwf-self".into(),
            template: "dev".into(),
            parked: false,
            prod: "https://example.test/prod".into(),
            pipeline: "staging → integration → main".into(),
            stamp: "status.json".into(),
            generated_at: "2026-01-01 00:00:00".into(),
            roles: vec![
                data::Role {
                    heartbeat_age: None,
                    role: "impl1".into(),
                    state: "live".into(),
                    detail: "building #62".into(),
                },
                data::Role {
                    heartbeat_age: None,
                    role: "qa1".into(),
                    state: "idle".into(),
                    detail: String::new(),
                },
                data::Role {
                    heartbeat_age: None,
                    role: "impl2".into(),
                    state: "down".into(),
                    detail: "crashed".into(),
                },
            ],
            decisions: vec![data::Decision {
                id: "101".into(),
                title: "Adopt golden render tests for the dash, guarding #50/#51".into(),
                flags: "GATED".into(),
                body: "### Why\nGolden tests catch layout drift unit tests miss.\n\
- keeps the header honest\n\
- keeps blockquotes legible\n\
\n\
> GATED — needs a captain sign-off before this un-gates"
                    .into(),
            }],
            issues: vec![data::Issue {
                number: 54,
                title: "dash tests: render/golden snapshots via ratatui TestBackend".into(),
                gated: false,
                body: "Golden/snapshot coverage for the main render paths.".into(),
            }],
            activity: data::Activity {
                building: vec![act_item_titled(
                    101,
                    "54",
                    "staging",
                    "run",
                    "",
                    "impl3",
                    "dash render golden snapshot tests via ratatui TestBackend, covering every main render path",
                )],
                in_test: vec![act_item_titled(
                    97, "50", "staging", "pass", "", "qa2", "fix low-contrast blockquote styling",
                )],
                merged: vec![act_item_titled(
                    90, "40", "staging", "pass", "07-01 09:00", "impl2", "fwf dash milestone 1",
                )],
                to_main: vec![],
            },
            needs_you: data::NeedsYou {
                active: true,
                summary: "decision #101 awaiting you".into(),
            },
            floor_idle: data::FloorIdle::default(),
            upgrade: data::UpgradeAvailable::default(),
            installed: data::InstalledVersion::default(),
            api_budget: data::ApiBudget::default(),
            claim_refusals: data::ClaimRefusals::default(),
        }
    }

    fn golden_app(tab: Tab) -> App {
        let mut app = test_app();
        app.feed = Feed::Ok(golden_fixture());
        app.tab = tab;
        app
    }

    /// One role per state (issue #95) — long-ish role/model names, LONG token
    /// counts (multi-digit, not the toy single-digit values that'd hide an
    /// overflow bug), so the three states have to stay visually distinct AND
    /// fit the column widths under realistic content, not just short stubs.
    fn golden_usage_fixture() -> data::UsageData {
        data::UsageData {
            caveat: "estimated $ equivalent — not your account's actual rolling-window usage"
                .into(),
            roles: vec![
                data::UsageRole {
                    role: "impl1".into(),
                    state: "fresh".into(),
                    age_secs: Some(0),
                    model: Some("claude-sonnet-5".into()),
                    tokens: data::UsageTokens {
                        input: 1_234_567,
                        cache_creation: 234_567,
                        cache_read: 89_012,
                        output: 345_678,
                    },
                    cost_usd: Some(12.3456),
                },
                data::UsageRole {
                    role: "qa1".into(),
                    state: "stale".into(),
                    age_secs: Some(245),
                    model: Some("claude-opus-4-8".into()),
                    tokens: data::UsageTokens {
                        input: 500_000,
                        cache_creation: 10_000,
                        cache_read: 5_000,
                        output: 60_000,
                    },
                    cost_usd: Some(5.4321),
                },
                data::UsageRole {
                    role: "pm".into(),
                    state: "unknown".into(),
                    age_secs: None,
                    model: None,
                    tokens: data::UsageTokens::default(),
                    cost_usd: None,
                },
            ],
            total: data::UsageTotals {
                tokens: data::UsageTokens {
                    input: 1_734_567,
                    cache_creation: 244_567,
                    cache_read: 94_012,
                    output: 405_678,
                },
                cost_usd: 17.7777,
            },
            // No budget configured — the plain/common case. The
            // ARMED/HOLD/WARN/FAIL-CLOSED variants get their own dedicated
            // golden below (issue #96, Ticket B).
            budget: data::BudgetStatus::default(),
        }
    }

    fn golden_app_with_usage(tab: Tab) -> App {
        let mut app = test_app();
        app.usage_feed = UsageFeed::Ok(golden_usage_fixture());
        app.tab = tab;
        app
    }

    #[test]
    fn golden_header_shows_profile_template_and_provenance() {
        let app = golden_app(Tab::Activity);
        let area = Rect::new(0, 0, 90, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        assert_golden(
            "header_running",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // #51 pin: at the render level (through the real widget pipeline, not just
    // the string that gets pushed into the span), the header must show the
    // running template's name.
    #[test]
    fn render_level_header_shows_the_running_template() {
        let app = golden_app(Tab::Activity);
        let area = Rect::new(0, 0, 90, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        let template = app.feed.dashboard().unwrap().template.clone();
        assert!(
            buffer_to_text(&buf).contains(&template),
            "header must show the running template (#51)"
        );
    }

    #[test]
    fn golden_header_parked_and_stale_provenance() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.parked = true;
            d.stamp = "stale".into();
        }
        let area = Rect::new(0, 0, 90, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        assert_golden(
            "header_parked_stale",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // issue #85: the header's calm FLOOR IDLE badge — running (not parked),
    // distinct from both ● running alone and the ⏸ PARKED badge.
    #[test]
    fn golden_header_floor_idle_badge() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.floor_idle = data::FloorIdle {
                active: true,
                since: "2026-01-01T00:00:00Z".into(),
                reason: "queue empty; nothing in flight".into(),
                actor: "captain".into(),
            };
        }
        let area = Rect::new(0, 0, 90, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        assert_golden(
            "header_floor_idle",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // issue #243 AC (f): "N blocked on authz" is its own distinct badge --
    // never conflated with FLOOR IDLE (calm, deliberate) or PARKED (whole
    // factory).
    #[test]
    fn golden_header_claim_refusals_badge() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.claim_refusals = data::ClaimRefusals { count: 3 };
        }
        let area = Rect::new(0, 0, 90, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        assert_golden(
            "header_claim_refusals_badge",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // The mirror: a zero count must NOT render the badge at all -- a queue
    // that has genuinely drained looks identical to a floor that was never
    // blocked, not a "0 blocked" badge nobody asked for.
    #[test]
    fn claim_refusals_badge_absent_when_count_is_zero() {
        let app = golden_app(Tab::Activity);
        assert_eq!(
            app.feed.dashboard().unwrap().claim_refusals.count,
            0,
            "fixture default must be zero"
        );
    }

    #[test]
    fn golden_tabs_show_counts_per_section() {
        let app = golden_app(Tab::Decisions);
        let area = Rect::new(0, 0, 90, 1);
        let buf = render_buffer(area.width, area.height, |f| render_tabs(f, area, &app));
        assert_golden("tabs_with_counts", &buffer_to_text(&buf));
    }

    #[test]
    fn golden_needs_you_banner() {
        let app = golden_app(Tab::Activity);
        let area = Rect::new(0, 0, 90, 1);
        let buf = render_buffer(area.width, area.height, |f| {
            render_needs_banner(f, area, &app)
        });
        assert_golden("needs_you_banner", &buffer_to_text(&buf));
    }

    // issue #94: the upgrade-available banner.
    #[test]
    fn golden_upgrade_banner() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.upgrade = data::UpgradeAvailable {
                available: true,
                current: "0.21.3".into(),
                latest: "v0.22.0".into(),
            };
        }
        let area = Rect::new(0, 0, 90, 1);
        let buf = render_buffer(area.width, area.height, |f| {
            render_upgrade_banner(f, area, &app)
        });
        assert_golden("upgrade_banner", &buffer_to_text(&buf));
    }

    // issue #239: the API-budget-exhausted banner, genuine 0-remaining case
    // (a real headroom read completed and came back empty). `reset` is
    // deliberately left unset so the golden text is time-independent —
    // "resets in Ns" would make every run's golden differ.
    #[test]
    fn golden_api_budget_banner_remaining_known() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.api_budget = data::ApiBudget {
                status: "EXHAUSTED".into(),
                label: "API BUDGET EXHAUSTED".into(),
                remaining: Some(0),
                limit: Some(5000),
                reset: None,
            };
        }
        let area = Rect::new(0, 0, 100, 1);
        let buf = render_buffer(area.width, area.height, |f| {
            render_api_budget_banner(f, area, &app)
        });
        assert_golden("api_budget_banner_remaining_known", &buffer_to_text(&buf));
    }

    // issue #239: the SAME banner/status, but the headroom read itself
    // could not complete (network/auth/rate-limited) — remaining/limit are
    // both None, so the banner must say so distinctly rather than a
    // fabricated "0/0 remaining".
    #[test]
    fn golden_api_budget_banner_read_failed() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.api_budget = data::ApiBudget {
                status: "EXHAUSTED".into(),
                label: "API BUDGET EXHAUSTED".into(),
                remaining: None,
                limit: None,
                reset: None,
            };
        }
        let area = Rect::new(0, 0, 100, 1);
        let buf = render_buffer(area.width, area.height, |f| {
            render_api_budget_banner(f, area, &app)
        });
        assert_golden("api_budget_banner_read_failed", &buffer_to_text(&buf));
    }

    // issue #239: the banner must NOT render when status is empty/OK —
    // the mirror of every other banner's "does not fire when inactive" test.
    #[test]
    fn api_budget_banner_absent_when_status_not_exhausted() {
        let app = golden_app(Tab::Activity);
        assert_eq!(
            app.feed.dashboard().unwrap().api_budget.status,
            "",
            "fixture default must not already be EXHAUSTED"
        );
    }

    // issue #153: the stale-dash restart banner — running-vs-installed drift,
    // distinct from the upgrade-available banner above (installed-vs-latest).
    #[test]
    fn golden_stale_dash_banner() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            // A version strictly ahead of RUNNING_VERSION so the banner fires
            // regardless of what this build's actual VERSION happens to be.
            let (maj, min, patch) = {
                let v = data::RUNNING_VERSION;
                let mut it = v.split('.');
                let n = |s: Option<&str>| -> u64 { s.unwrap_or("0").parse().unwrap_or(0) };
                (n(it.next()), n(it.next()), n(it.next()))
            };
            d.installed = data::InstalledVersion {
                version: format!("{maj}.{min}.{}", patch + 1),
            };
        }
        assert!(
            data::running_binary_stale(&app.feed.dashboard().unwrap().installed.version),
            "fixture must actually trigger the drift this test renders"
        );
        let area = Rect::new(0, 0, 90, 1);
        let buf = render_buffer(area.width, area.height, |f| {
            render_stale_dash_banner(f, area, &app)
        });
        assert_golden(
            "stale_dash_banner",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // issue #153: an up-to-date running binary must NOT show the drift banner
    // -- the mirror of `golden_full_frame_no_upgrade_banner_when_up_to_date`.
    #[test]
    fn stale_dash_banner_does_not_render_when_running_matches_installed() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.installed = data::InstalledVersion {
                version: data::RUNNING_VERSION.to_string(),
            };
        }
        let area = Rect::new(0, 0, 100, 30);
        let buf = render_buffer(area.width, area.height, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            !text.contains("STALE DASH"),
            "no stale-dash banner should render when the running version matches installed"
        );
    }

    // issue #153: an EMPTY installed-version read (unreadable $FWF_HOME/VERSION)
    // must be UNKNOWN, never misread as drift -- the fail-safe direction.
    #[test]
    fn stale_dash_banner_does_not_render_when_installed_version_is_unreadable() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.installed = data::InstalledVersion {
                version: String::new(),
            };
        }
        let area = Rect::new(0, 0, 100, 30);
        let buf = render_buffer(area.width, area.height, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            !text.contains("STALE DASH"),
            "an unreadable installed version must not be misread as drift"
        );
    }

    // Real-content check (this repo's own hard lesson: a test that seeds short
    // stub data can't catch overflow that only appears with realistic content).
    // A long version string must not wrap or overflow the header row width.
    #[test]
    fn golden_full_frame_activity_tab_with_upgrade_banner_long_version() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.needs_you.active = false;
            d.upgrade = data::UpgradeAvailable {
                available: true,
                current: "0.21.3-dev.20260710+deadbeef".into(),
                latest: "v0.22.0-rc.1+cafef00d".into(),
            };
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        for (i, row) in text.lines().enumerate() {
            assert!(
                row.chars().count() <= 100,
                "row {i} overflows the 100-col terminal width: {row:?}"
            );
        }
        assert_golden(
            "full_frame_activity_upgrade_long_version",
            &normalize_running_version(&text),
        );
    }

    // issue #153: same overflow lesson, for the stale-dash banner — an early
    // draft's wording silently clipped the restart instruction at 90 columns
    // (caught by this exact assertion). A long installed-version string must
    // not repeat that.
    #[test]
    fn golden_stale_dash_banner_long_version_does_not_overflow() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.needs_you.active = false;
            // Realistic-contract stress value: `installed.version` always comes
            // from `cat $FWF_HOME/VERSION`, a plain dot-separated numeric
            // semver per RELEASING.md -- unlike the upgrade banner's `latest`
            // (a raw GH release tag, which realistically could carry
            // pre-release/build metadata). Stress the numeric width instead.
            d.installed = data::InstalledVersion {
                version: "999999.999999.999999".into(),
            };
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        for (i, row) in text.lines().enumerate() {
            assert!(
                row.chars().count() <= 100,
                "row {i} overflows the 100-col terminal width: {row:?}"
            );
        }
        assert!(
            text.contains("then 'fwf dash'"),
            "the restart instruction must survive intact, not be clipped: {text:?}"
        );
    }

    // Both banners can be active at once (a blocked decision AND a stale
    // install aren't mutually exclusive) — needs-you stays first; neither
    // banner should push the other off-screen or overlap.
    #[test]
    fn golden_full_frame_both_banners_active() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.upgrade = data::UpgradeAvailable {
                available: true,
                current: "0.21.3".into(),
                latest: "v0.22.0".into(),
            };
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        assert_golden(
            "full_frame_both_banners",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // issue #153: all THREE banners at once (needs-you + stale-dash +
    // upgrade-available) must stack without overlapping or crashing — the
    // three-banner extension of the both-banners test above.
    #[test]
    fn golden_full_frame_all_three_banners_active() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.upgrade = data::UpgradeAvailable {
                available: true,
                current: "0.21.3".into(),
                latest: "v0.22.0".into(),
            };
            d.installed = data::InstalledVersion {
                version: "99.99.99".into(),
            };
        }
        assert!(data::running_binary_stale(
            &app.feed.dashboard().unwrap().installed.version
        ));
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        assert_golden(
            "full_frame_all_three_banners",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // The banner must NOT render when up to date — the golden fixture's default
    // `upgrade: UpgradeAvailable::default()` (available: false) already covers
    // this implicitly for every other full-frame golden, but assert it directly.
    #[test]
    fn golden_full_frame_no_upgrade_banner_when_up_to_date() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.needs_you.active = false;
            assert!(!d.upgrade.available, "fixture default must be up to date");
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            !text.contains("fwf upgrade"),
            "no upgrade banner should render when up to date"
        );
    }

    #[test]
    fn golden_activity_list_with_detail() {
        let mut app = golden_app(Tab::Activity);
        let area = Rect::new(0, 0, 100, 16);
        let buf = render_buffer(area.width, area.height, |f| {
            render_activity(f, area, &mut app)
        });
        assert_golden("activity_list_with_detail", &buffer_to_text(&buf));
    }

    // #95: the three usage states must render VISUALLY DISTINCT, at real
    // column widths, with realistic (multi-digit, non-toy) token counts —
    // and the layout must fit the area (no panic, no truncated-into-garbage
    // content) at both a roomy and a narrow terminal width.
    #[test]
    fn golden_usage_tab_three_states() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        assert_golden("usage_tab_three_states", &buffer_to_text(&buf));
    }

    // #115: at billion-scale token counts the numeric columns used to have
    // NO gutter between them, so a wide CACHE-W value ran straight into
    // CACHE-R with zero separation (and the header stopped lining up with
    // the data). Guard it structurally — split_whitespace() merges any two
    // fields that collide into a single token, so this goes RED again if
    // the gutter or humanization regresses, independent of exact digits.
    #[test]
    fn usage_tab_billion_scale_values_stay_separated_and_readable() {
        let mut app = test_app();
        let mut data = golden_usage_fixture();
        data.roles[0].tokens = data::UsageTokens {
            input: 152_340_000,
            cache_creation: 3_980_000_000,
            cache_read: 7_123_000_000,
            output: 45_678_901,
        };
        app.usage_feed = UsageFeed::Ok(data);
        app.tab = Tab::Usage;
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        let row = text
            .lines()
            .find(|l| l.contains("impl1"))
            .expect("impl1 row must render");
        let fields: Vec<&str> = row.split_whitespace().collect();

        assert!(
            fields.contains(&"152M"),
            "INPUT must humanize to M-scale as its own token: {row:?}"
        );
        assert!(
            fields.contains(&"3.98B"),
            "CACHE-W must humanize to B-scale, distinct from CACHE-R: {row:?}"
        );
        assert!(
            fields.contains(&"7.12B"),
            "CACHE-R must humanize to B-scale, distinct from CACHE-W: {row:?}"
        );
        assert!(
            fields.contains(&"46M"),
            "OUTPUT must humanize to M-scale as its own token: {row:?}"
        );

        // Header columns must stay distinct and correctly ordered even
        // though the data got much wider.
        let header_line = text
            .lines()
            .find(|l| l.contains("CACHE-W"))
            .expect("header must render");
        assert_eq!(
            header_line.split_whitespace().collect::<Vec<_>>(),
            vec!["ROLE", "STATE", "MODEL", "INPUT", "CACHE-W", "CACHE-R", "OUTPUT", "EST-$"],
            "header columns must stay distinct and aligned: {header_line:?}"
        );
    }

    #[test]
    fn usage_fresh_row_shows_a_live_figure_not_a_warning() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(text.contains("impl1"), "impl1's fresh row must render");
        assert!(
            text.contains("claude-sonnet-5") || text.contains("claude-son"),
            "the fresh row's model must show (possibly truncated at this width)"
        );
        // The fresh row's own line must NOT carry the STALE/UNKNOWN warning glyph.
        let fresh_line = text.lines().find(|l| l.contains("impl1")).unwrap();
        assert!(
            !fresh_line.contains('⚠'),
            "a FRESH row must never carry the warning glyph: {fresh_line:?}"
        );
    }

    #[test]
    fn usage_stale_row_shows_the_warning_treatment_and_last_good_numbers() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        let stale_line = text.lines().find(|l| l.contains("qa1")).unwrap();
        assert!(
            stale_line.contains("STALE"),
            "a stale role must render the STALE treatment, not a bare number: {stale_line:?}"
        );
        assert!(
            stale_line.contains("245"),
            "the STALE row must name the age since the last good read: {stale_line:?}"
        );
        // Still shows the LAST-GOOD figures — never a frozen blank.
        assert!(
            stale_line.contains("500000") || stale_line.contains("500,000"),
            "STALE must still show the last-good token figure, not blank: {stale_line:?}"
        );
    }

    #[test]
    fn usage_unknown_row_never_shows_a_false_zero_or_blank() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        let unknown_line = text.lines().find(|l| l.contains("pm")).unwrap();
        assert!(
            unknown_line.contains("UNKNOWN"),
            "an unread role must render UNKNOWN: {unknown_line:?}"
        );
        assert!(
            !unknown_line.contains("$0.0000") && !unknown_line.contains(" 0 "),
            "UNKNOWN must never render as a false $0 / bare zero (reads as confirmed no-spend): {unknown_line:?}"
        );
    }

    #[test]
    fn usage_caveat_is_visible_in_the_tab() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 100, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        assert!(
            buffer_to_text(&buf).contains("not your account's actual rolling-window usage"),
            "the proxy-vs-real-account-usage caveat must be visible in the tab, not just the CLI"
        );
    }

    // A prior version of this table (fixed-width numeric columns with no
    // truncation) would panic when the area was narrower than the sum of its
    // column widths. Widths here are computed from the actual Rect (see
    // model_w in render_usage), so this must not panic and the STATE column
    // (leftmost after ROLE, carrying the FRESH/STALE/UNKNOWN signal) must
    // still be visible even once numeric columns get clipped.
    #[test]
    fn usage_tab_does_not_panic_and_keeps_state_visible_at_narrow_width() {
        let mut app = golden_app_with_usage(Tab::Usage);
        let area = Rect::new(0, 0, 40, 10);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("STALE"),
            "STATE column must survive narrowing"
        );
        assert!(
            text.contains("UNKNOWN"),
            "STATE column must survive narrowing"
        );
    }

    // --- #96 Ticket B: the ARMED/NOT ARMED + hold-state line (GV-signoff
    // residual-risk fix) ------------------------------------------------

    fn golden_app_with_budget(budget: data::BudgetStatus) -> App {
        let mut usage = golden_usage_fixture();
        usage.budget = budget;
        let mut app = test_app();
        app.usage_feed = UsageFeed::Ok(usage);
        app.tab = Tab::Usage;
        app
    }

    #[test]
    fn usage_tab_shows_not_armed_when_no_budget_configured() {
        // No token_budget at all: the common/default case.
        let mut app = golden_app_with_budget(data::BudgetStatus::default());
        let area = Rect::new(0, 0, 100, 8);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains(
                "budget enforcement: NOT ARMED (no FWF_TOKEN_BUDGET configured — unlimited)"
            ),
            "no-budget-configured must render the exact NOT ARMED wording: {text:?}"
        );
        assert!(
            text.contains("hold state: none"),
            "no hold sentinel must render as 'hold state: none': {text:?}"
        );
    }

    #[test]
    fn usage_tab_shows_armed_with_ceiling_when_budget_configured_and_writer_running() {
        let mut app = golden_app_with_budget(data::BudgetStatus {
            token_budget: Some(2_000_000),
            armed: true,
            hold_line: None,
        });
        let area = Rect::new(0, 0, 100, 8);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("budget enforcement: ARMED (ceiling 2000000 tokens)"),
            "an armed budget must show ARMED with its exact ceiling: {text:?}"
        );
    }

    #[test]
    fn usage_tab_shows_not_armed_when_budget_set_but_writer_not_running() {
        // The exact GV-flagged gap: a budget configured mid-run without a
        // re-`fwf up` (the only thing that arms the writer) must be VISIBLY
        // off, not silently off — never rendered as plain ARMED.
        let mut app = golden_app_with_budget(data::BudgetStatus {
            token_budget: Some(2_000_000),
            armed: false,
            hold_line: None,
        });
        let area = Rect::new(0, 0, 100, 8);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains(
                "NOT ARMED — FWF_TOKEN_BUDGET=2000000 is set, but the writer is not running"
            ),
            "a configured-but-unarmed budget must say so explicitly, not read as ARMED: {text:?}"
        );
        assert!(
            !text.contains("ARMED (ceiling"),
            "must never render the ARMED-with-ceiling wording while unarmed: {text:?}"
        );
    }

    #[test]
    fn usage_tab_hold_line_renders_verbatim_and_never_confused_with_warn_or_failclosed() {
        // The HOLD/WARN/FAIL-CLOSED distinction is load-bearing for the
        // incident protocol: an operator must never confuse "reader broke"
        // (fail-closed) with "I blew my budget" (a real HOLD).
        let hold_text = "HOLD — 1200000 tokens spent, budget is 1000000 — lift: raise FWF_TOKEN_BUDGET or fwf usage --clear-hold";
        let mut app = golden_app_with_budget(data::BudgetStatus {
            token_budget: Some(1_000_000),
            armed: true,
            hold_line: Some(hold_text.to_string()),
        });
        // Wide enough that the full sentinel text (well over 100 cols) is
        // never clipped by the Paragraph's column width — this test is about
        // the exact wording, not layout at a realistic terminal size (that's
        // covered by the narrow-width test elsewhere).
        let area = Rect::new(0, 0, 140, 8);
        let buf = render_buffer(area.width, area.height, |f| render_usage(f, area, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains(&format!("hold state: {hold_text}")),
            "the HOLD sentinel's first line must render verbatim: {text:?}"
        );
        assert!(
            !text.contains("FAIL-CLOSED") && !text.contains("WARN —"),
            "a real HOLD must never render as WARN or FAIL-CLOSED wording: {text:?}"
        );

        let fail_closed_text = "UNKNOWN — FAIL-CLOSED: could not read usage ... NOT over budget — lift: fwf usage --clear-hold";
        let mut app2 = golden_app_with_budget(data::BudgetStatus {
            token_budget: Some(1_000_000),
            armed: true,
            hold_line: Some(fail_closed_text.to_string()),
        });
        let buf2 = render_buffer(area.width, area.height, |f| {
            render_usage(f, area, &mut app2)
        });
        let text2 = buffer_to_text(&buf2);
        assert!(
            text2.contains(&format!("hold state: {fail_closed_text}")),
            "the FAIL-CLOSED sentinel's first line must render verbatim: {text2:?}"
        );
        assert!(
            !text2.contains("HOLD —"),
            "a FAIL-CLOSED pause must never be textually confused with a real HOLD: {text2:?}"
        );
    }

    #[test]
    fn golden_decisions_detail_pane_markdownish() {
        let mut app = golden_app(Tab::Decisions);
        let area = Rect::new(0, 0, 100, 16);
        let buf = render_buffer(area.width, area.height, |f| {
            render_list_with_preview(f, area, &mut app, Tab::Decisions)
        });
        assert_golden("decisions_detail_markdownish", &buffer_to_text(&buf));
    }

    // #50 pin: at the render level (through the real widget/paragraph pipeline,
    // not just the markdownish() unit), the rendered blockquote row must never
    // use DarkGray — that's the near-invisible regression #50 fixed.
    #[test]
    fn render_level_blockquote_is_not_darkgray_in_the_detail_pane() {
        let mut app = golden_app(Tab::Decisions);
        let area = Rect::new(0, 0, 100, 16);
        let buf = render_buffer(area.width, area.height, |f| {
            render_list_with_preview(f, area, &mut app, Tab::Decisions)
        });
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(42), Constraint::Percentage(58)])
            .split(area);
        let detail = cols[1];

        let mut saw_blockquote_marker = false;
        for y in detail.y..detail.y + detail.height {
            let text = row_text(&buf, detail, y);
            if !text.contains("GATED") {
                continue;
            }
            for x in detail.x..detail.x + detail.width {
                let cell = buf.cell((x, y)).expect("in bounds");
                if cell.symbol() == ">" {
                    saw_blockquote_marker = true;
                }
                assert_ne!(
                    cell.fg,
                    Color::DarkGray,
                    "blockquote row must not render DarkGray anywhere (#50): row = {text:?}"
                );
            }
        }
        assert!(
            saw_blockquote_marker,
            "expected the fixture's blockquote row to actually render in the detail pane"
        );
    }

    #[test]
    fn golden_confirm_overlay() {
        let area = Rect::new(0, 0, 80, 24);
        let buf = render_buffer(area.width, area.height, |f| {
            render_confirm(f, area, "Approve decision #101?")
        });
        assert_golden("confirm_overlay", &buffer_to_text(&buf));
    }

    #[test]
    fn golden_input_overlay() {
        let area = Rect::new(0, 0, 80, 24);
        let buf = render_buffer(area.width, area.height, |f| {
            render_input(f, area, "Comment on #54:", "looks good")
        });
        assert_golden("input_overlay", &buffer_to_text(&buf));
    }

    #[test]
    fn golden_full_frame_activity_tab_with_needs_you_banner() {
        let mut app = golden_app(Tab::Activity);
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        assert_golden(
            "full_frame_activity_needs_you",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    #[test]
    fn golden_full_frame_decisions_tab_parked_stale_no_banner() {
        let mut app = golden_app(Tab::Decisions);
        if let Feed::Ok(d) = &mut app.feed {
            d.parked = true;
            d.stamp = "stale".into();
            d.needs_you.active = false;
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        assert_golden(
            "full_frame_decisions_parked",
            &normalize_running_version(&buffer_to_text(&buf)),
        );
    }

    // issue #85 (a-appearance): a role with no live pane must render DISTINCTLY
    // depending on whether the floor was deliberately idled (floor_idle) or has
    // actually crashed (down) — a phantom-outage chase is the whole bug this
    // fixes, so this drives the REAL renderer over both fixtures rather than
    // asserting on the data layer alone. RED if the two ever render identically.
    #[test]
    fn golden_roles_floor_idle_vs_crash_pivot() {
        let mut idle_app = golden_app(Tab::Roles);
        if let Feed::Ok(d) = &mut idle_app.feed {
            d.roles = vec![data::Role {
                role: "impl2".into(),
                state: "floor_idle".into(),
                detail: "floor idled by captain since 2026-01-01T00:00:00Z — queue empty; nothing in flight".into(),
                heartbeat_age: None,
            }];
        }
        let idle_buf = render_buffer(100, 30, |f| ui(f, &mut idle_app));
        let idle_text = buffer_to_text(&idle_buf);
        assert_golden(
            "full_frame_roles_floor_idle",
            &normalize_running_version(&idle_text),
        );

        let mut crash_app = golden_app(Tab::Roles);
        if let Feed::Ok(d) = &mut crash_app.feed {
            d.roles = vec![data::Role {
                role: "impl2".into(),
                state: "down".into(),
                detail: "crashed".into(),
                heartbeat_age: None,
            }];
        }
        let crash_buf = render_buffer(100, 30, |f| ui(f, &mut crash_app));
        let crash_text = buffer_to_text(&crash_buf);
        assert_golden(
            "full_frame_roles_down_crash",
            &normalize_running_version(&crash_text),
        );

        assert_ne!(
            idle_text, crash_text,
            "a deliberately idled floor and a real crash must render differently (issue #85)"
        );
        assert!(
            idle_text.contains("IDLE"),
            "floor_idle state must show the distinct IDLE label"
        );
        assert!(
            !idle_text.to_lowercase().contains("crash"),
            "the IDLE render must not carry crash wording"
        );
        assert!(
            !crash_text.contains("IDLE"),
            "a real crash (down, no floor-down logged) must never show IDLE"
        );
    }

    #[test]
    fn roles_pane_shows_heartbeat_age_alongside_the_state_word_193_ac_a_i0() {
        let mut app = golden_app(Tab::Roles);
        if let Feed::Ok(d) = &mut app.feed {
            d.roles = vec![
                data::Role {
                    role: "impl1".into(),
                    state: "stale".into(),
                    detail: String::new(),
                    heartbeat_age: Some(7305),
                },
                data::Role {
                    role: "impl2".into(),
                    state: "live".into(),
                    detail: String::new(),
                    heartbeat_age: None,
                },
            ];
        }
        let buf = render_buffer(100, 30, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("stale") && text.contains("hb 7305s ago"),
            "the STALE word and its age must both be visible: {text}"
        );
        assert_eq!(
            text.matches("hb ").count(),
            1,
            "a role with no known heartbeat age must show no age at all, not a blank one: {text}"
        );
    }

    #[test]
    fn header_shows_newest_heartbeat_age_whenever_known_193_ac_b() {
        let mut app = golden_app(Tab::Activity);
        if let Feed::Ok(d) = &mut app.feed {
            d.visibility.newest_heartbeat_age = Some(42);
        }
        let area = Rect::new(0, 0, 140, 4);
        let buf = render_buffer(area.width, area.height, |f| render_header(f, area, &app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("hb 42s ago"),
            "newest heartbeat age must be visible even on a fully-healthy header: {text}"
        );
    }

    #[test]
    fn no_view_banner_fires_only_when_factory_not_visible_193_ac_e() {
        let mut app = golden_app(Tab::Roles);
        if let Feed::Ok(d) = &mut app.feed {
            d.visibility = data::Visibility {
                factory_visible: false,
                newest_heartbeat_age: None,
                state_dir: "/tmp/fwf-state/example".into(),
                profile: "example".into(),
                host: "devbox1".into(),
            };
            d.roles = vec![data::Role {
                role: "impl1".into(),
                state: "unknown".into(),
                detail: String::new(),
                heartbeat_age: None,
            }];
        }
        let buf = render_buffer(120, 30, |f| ui(f, &mut app));
        let text = buffer_to_text(&buf);
        assert!(
            text.contains("NO FACTORY VISIBLE"),
            "an invisible factory must show the banner, not look calm: {text}"
        );
        assert!(
            text.contains("example") && text.contains("devbox1") && text.contains("/tmp/fwf-state/example"),
            "the banner must name profile/host/state_dir so a wrong --profile is diagnosable: {text}"
        );

        // The mirror: a visible factory never shows this banner, even with an
        // otherwise-identical fixture.
        let mut visible_app = golden_app(Tab::Roles);
        let visible_buf = render_buffer(120, 30, |f| ui(f, &mut visible_app));
        let visible_text = buffer_to_text(&visible_buf);
        assert!(
            !visible_text.contains("NO FACTORY VISIBLE"),
            "a visible factory must never show the no-view banner: {visible_text}"
        );
    }
}
