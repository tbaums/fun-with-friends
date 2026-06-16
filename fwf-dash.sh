#!/usr/bin/env bash
# fwf dash — launch the read-only status board (issue #40, milestone 1).
#
# The gh-dash model: this bash wrapper resolves the profile/config, makes sure the
# compiled Rust + ratatui binary exists (building it on first use), points it at
# the bash data provider, and execs it. The binary is purely the renderer; all the
# derived-first data gathering and the gh/local backend abstraction live in
# `fwf-dash-data.sh` (which sources lib.sh just like every other engine script).
#
# Usage: [FWF_PROFILE=example] fwf dash
#   FWF_DASH_BIN      override the binary path (skip the build entirely)
#   FWF_DASH_REFRESH  auto-refresh seconds (default 5; read by the binary)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

CRATE="$DIR/dash"
BIN="${FWF_DASH_BIN:-$CRATE/target/release/fwf-dash}"

# Build on first use (the gh-dash model: a bash tool shelling out to a compiled
# dashboard). Skip the build if a prebuilt binary was handed in via FWF_DASH_BIN.
if [ -z "${FWF_DASH_BIN:-}" ] && [ ! -x "$BIN" ]; then
  command -v cargo >/dev/null 2>&1 \
    || die "dash: the binary isn't built and cargo isn't installed — install Rust (https://rustup.rs) or set FWF_DASH_BIN to a prebuilt fwf-dash."
  echo "fwf: building the dash binary (first run; cargo build --release) ..." >&2
  ( cd "$CRATE" && cargo build --release ) \
    || die "dash: cargo build failed — see the output above."
fi
[ -x "$BIN" ] || die "dash: no runnable binary at $BIN."

command -v jq >/dev/null 2>&1 || die "dash: jq is required for the data provider (brew install jq)."

# The renderer shells out to these — the read-only provider on its refresh timer,
# the action layer on a y/n/c/o/r/s/t keypress. Export both (and let the resolved
# FWF_PROFILE flow through) so they resolve the same factory the binary renders.
export FWF_DASH_DATA="$DIR/fwf-dash-data.sh"
export FWF_DASH_ACT="$DIR/fwf-dash-act.sh"

# Mouse-wheel scroll in the detail pane needs the host tmux to forward wheel
# events to the alt-screen TUI, which only happens when that session has
# `mouse on`. Enable it for the duration (session-local) and revert on exit so
# the wheel works wherever the dash is stood up — concierge, factory, or the
# user's own tmux — without editing any tmux.conf. Outside tmux this is a no-op.
if [ -n "${TMUX:-}" ]; then
  tmux set mouse on 2>/dev/null || true
  "$BIN"; rc=$?
  tmux set -u mouse 2>/dev/null || true   # drop our override; revert to prior default
  exit "$rc"
fi
exec "$BIN"
