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

# Ensure the integration target exists locally + on origin.
git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" \
  || { log "creating $BASE_BRANCH from $DEFAULT_BRANCH"; git branch "$BASE_BRANCH" "$DEFAULT_BRANCH"; }
git ls-remote --exit-code --heads origin "$BASE_BRANCH" >/dev/null 2>&1 \
  || { log "pushing $BASE_BRANCH to origin"; git push -u origin "$BASE_BRANCH"; }

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
