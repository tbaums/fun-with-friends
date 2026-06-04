#!/usr/bin/env bash
# Provision worktrees + isolated dev-data for the selected profile (idempotent,
# additive). Creates: impl1-3 (+ paired qa1-3), pm, conductor. Optionally warms
# each worktree's build.
#
# Usage: [FWF_PROFILE=transom] fwf-provision.sh [--build]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
log() { printf '[fwf-provision %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

DO_BUILD=false
[ "${1:-}" = "--build" ] && DO_BUILD=true

cd "$FWF_REPO"
mkdir -p "$FWF_RUN"
gh auth status >/dev/null 2>&1 || log "WARNING: gh is not authenticated. Run 'gh auth login'."

# Ensure the staging + integration branches exist locally + on origin. The ladder
# must be continuous: integration branches from main, and staging from the CURRENT
# integration tip (NOT main) — otherwise staging diverges from any work already on
# integration and the conductor's ff-only promote fails.
git fetch origin -q
ensure_branch() { # $1=branch  $2=base-branch (created from origin/$2 if missing)
  git show-ref --verify --quiet "refs/heads/$1" \
    || { log "creating $1 from origin/$2"; git branch "$1" "origin/$2"; }
  git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1 \
    || { log "pushing $1 to origin"; git push -u origin "$1"; }
}
ensure_branch "$INTEGRATION_BRANCH" "$DEFAULT_BRANCH"
ensure_branch "$STAGING_BRANCH"     "$INTEGRATION_BRANCH"

# Ensure the PM draft label exists (implementers skip issues that carry it).
gh label create "$WIP_LABEL" --description "PM draft / product WIP — not ready; implementers skip until this label is removed" --color FBCA04 --force >/dev/null 2>&1 \
  && log "ensured label '$WIP_LABEL'" || log "label '$WIP_LABEL' ensure skipped (gh not ready?)"
# Ensure the release-freeze hold label exists (implementers skip held issues until the PM lifts it post-release).
gh label create "$HOLD_LABEL" --description "Held for a future release — implementers skip until the PM lifts it after the current release" --color 0052CC --force >/dev/null 2>&1 \
  && log "ensured label '$HOLD_LABEL'" || log "label '$HOLD_LABEL' ensure skipped (gh not ready?)"

add_branch_wt() { # $1=tag  $2=branch
  local d; d="$(wt_dir "$1")"
  [ -d "$d" ] && { log "exists: $d"; return; }
  log "worktree $d ($2)"
  git worktree add "$d" -b "$2" "$DEFAULT_BRANCH" 2>/dev/null || git worktree add "$d" "$2"
}
add_detached_wt() { # $1=tag
  local d; d="$(wt_dir "$1")"
  [ -d "$d" ] && { log "exists: $d"; return; }
  log "worktree $d (detached)"
  git worktree add --detach "$d" "$DEFAULT_BRANCH"
}
warm() { # $1=tag
  $DO_BUILD || return 0
  log "build: $(wt_dir "$1")"
  ( cd "$(wt_dir "$1")" && eval "$BUILD_CMD" ) || log "build FAILED: $1"
}

for id in "${PAIRS[@]}"; do
  add_branch_wt   "impl$id" "impl$id/work"
  add_detached_wt "qa$id"
  seed_data "$(data_dir "impl$id")"; log "seeded $(data_dir "impl$id")"
  warm "impl$id"; warm "qa$id"
done
add_detached_wt "pm"
add_detached_wt "conductor"
warm "conductor"

# e2e deps for the conductor (it owns e2e).
if [ -n "${E2E_SETUP_CMD:-}" ]; then
  ( cd "$(wt_dir conductor)" && eval "$E2E_SETUP_CMD" >/dev/null 2>&1 ) \
    && log "e2e deps installed in conductor" || log "e2e deps install skipped/failed"
fi

log "provision complete (profile=$PROFILE, build=$DO_BUILD)"
